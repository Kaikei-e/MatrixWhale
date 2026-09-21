package client

import (
	"compress/gzip"
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"sync"
	"time"

	"jma_adapter/state"
	"matrixwhale/adapters/common/metrics"
	"matrixwhale/adapters/common/poll"
)

var (
	ErrItemTooLarge           = errors.New("item body exceeds maximum allowed size")
	ErrRedirectNotAllowed     = errors.New("HTTP redirects are not permitted for JMA upstream")
	ErrGlobalRetryActive      = errors.New("upstream backoff active: 429/503 Retry-After not yet expired")
	ErrStatePersistenceFailed = errors.New("critical state persistence error, stopping upstream calls")
)

// UpstreamError is a typed error containing HTTP status and server Retry-After hints.
type UpstreamError struct {
	StatusCode int
	RetryAfter time.Duration
	HasRetry   bool
	Err        error
}

func (e *UpstreamError) Error() string {
	if e.HasRetry {
		return fmt.Sprintf("upstream status %d (Retry-After %v): %v", e.StatusCode, e.RetryAfter, e.Err)
	}
	return fmt.Sprintf("upstream status %d: %v", e.StatusCode, e.Err)
}

func (e *UpstreamError) Unwrap() error {
	return e.Err
}

// countingReader measures raw network bytes read from wire.
type countingReader struct {
	reader io.Reader
	count  int64
}

func (c *countingReader) Read(p []byte) (int, error) {
	n, err := c.reader.Read(p)
	c.count += int64(n)
	return n, err
}

// JMAClient manages all upstream HTTP communication with JMA servers.
type JMAClient struct {
	httpClient      *http.Client
	store           *state.Store
	validator       *URLValidator
	userAgent       string
	requestInterval time.Duration
	maxItemBytes    int64
	minPollInterval time.Duration

	rateMu          sync.Mutex
	lastRequestTime time.Time

	retryMu          sync.Mutex
	globalRetryUntil time.Time
}

// NewJMAClient creates a new upstream JMA client.
func NewJMAClient(
	store *state.Store,
	validator *URLValidator,
	userAgent string,
	requestInterval time.Duration,
	maxItemBytes int64,
	minPollInterval time.Duration,
	customTransport http.RoundTripper,
) *JMAClient {
	transport := customTransport
	if transport == nil {
		transport = metrics.Transport("upstream", nil)
	}

	httpClient := &http.Client{
		Timeout:   30 * time.Second,
		Transport: transport,
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}

	return &JMAClient{
		httpClient:      httpClient,
		store:           store,
		validator:       validator,
		userAgent:       userAgent,
		requestInterval: requestInterval,
		maxItemBytes:    maxItemBytes,
		minPollInterval: minPollInterval,
	}
}

// CheckGlobalRetry verifies if a server-requested Retry-After backoff is still active.
func (c *JMAClient) CheckGlobalRetry() (time.Duration, bool) {
	// Check persistent store backoff first
	until := c.store.GetGlobalBackoffUntil()
	now := time.Now()
	if now.Before(until) {
		return until.Sub(now), true
	}

	c.retryMu.Lock()
	defer c.retryMu.Unlock()
	if now.Before(c.globalRetryUntil) {
		return c.globalRetryUntil.Sub(now), true
	}
	return 0, false
}

// SetGlobalRetry sets the global backoff deadline across all endpoints and persists it.
func (c *JMAClient) SetGlobalRetry(until time.Time) error {
	c.retryMu.Lock()
	defer c.retryMu.Unlock()
	if until.IsZero() || until.After(c.globalRetryUntil) {
		c.globalRetryUntil = until
	}
	if err := c.store.SetGlobalBackoff(until); err != nil {
		return fmt.Errorf("%w: persist global backoff: %v", ErrStatePersistenceFailed, err)
	}
	return nil
}

// waitRateLimit enforces the global serial request interval across all upstream calls.
func (c *JMAClient) waitRateLimit(ctx context.Context) error {
	if remaining, active := c.CheckGlobalRetry(); active {
		return fmt.Errorf("%w: must wait %v", ErrGlobalRetryActive, remaining)
	}

	c.rateMu.Lock()
	defer c.rateMu.Unlock()

	elapsed := time.Since(c.lastRequestTime)
	if elapsed < c.requestInterval {
		wait := c.requestInterval - elapsed
		select {
		case <-time.After(wait):
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	c.lastRequestTime = time.Now()
	return nil
}

// FeedResult contains the outcome of an Atom feed fetch.
type FeedResult struct {
	Body         []byte
	LastModified string
	ETag         string
	NotModified  bool
	NextDelay    time.Duration
	RetryAfter   time.Duration
	HasRetry     bool
}

// DataResult contains the outcome of an XML data telegram fetch.
type DataResult struct {
	Body       []byte
	HTTPStatus int
}

// FetchFeed polls an Atom feed with conditional GET, bounded decoding, and budget reservation.
func (c *JMAClient) FetchFeed(ctx context.Context, feedURL string) (*FeedResult, error) {
	if _, err := c.validator.ValidateFeedURL(feedURL); err != nil {
		return nil, fmt.Errorf("validate feed URL: %w", err)
	}

	if err := c.waitRateLimit(ctx); err != nil {
		return nil, err
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, feedURL, nil)
	if err != nil {
		return nil, fmt.Errorf("create feed request: %w", err)
	}
	req.Header.Set("User-Agent", c.userAgent)
	req.Header.Set("Accept", "application/atom+xml, application/xml")
	// Only advertise gzip; Go handles decompression safely
	req.Header.Set("Accept-Encoding", "gzip")

	// Set conditional headers from stored validator
	sch := c.store.GetFeedSchedule(feedURL)
	if sch.LastModified != "" {
		req.Header.Set("If-Modified-Since", sch.LastModified)
	}
	if sch.ETag != "" {
		req.Header.Set("If-None-Match", sch.ETag)
	}

	// Reserve worst-case budget (maxItemBytes + 1)
	reserved := c.maxItemBytes + 1
	if err := c.store.Reserve(reserved); err != nil {
		return nil, err
	}

	resp, err := c.httpClient.Do(req)
	if err != nil {
		if cErr := c.store.Commit(reserved, 0); cErr != nil {
			return nil, fmt.Errorf("%w: commit on Do error: %v", ErrStatePersistenceFailed, cErr)
		}
		return nil, fmt.Errorf("execute feed request: %w", err)
	}
	defer resp.Body.Close()

	// Check redirects
	if resp.StatusCode >= 301 && resp.StatusCode <= 308 && resp.StatusCode != http.StatusNotModified {
		if cErr := c.store.Commit(reserved, 0); cErr != nil {
			return nil, fmt.Errorf("%w: commit on redirect error: %v", ErrStatePersistenceFailed, cErr)
		}
		return nil, fmt.Errorf("%w: status %d to %s", ErrRedirectNotAllowed, resp.StatusCode, resp.Header.Get("Location"))
	}

	retryAfter, hasRetry := poll.ParseRetryAfter(resp.Header)
	nextDelay := poll.ComputeNextPollDelay(resp.Header, c.minPollInterval)

	if hasRetry {
		if rErr := c.SetGlobalRetry(time.Now().Add(retryAfter)); rErr != nil {
			_ = c.store.Commit(reserved, 0)
			return nil, rErr
		}
	} else if resp.StatusCode == 403 || resp.StatusCode == 429 || resp.StatusCode >= 500 {
		if rErr := c.SetGlobalRetry(time.Now().Add(30 * time.Second)); rErr != nil {
			_ = c.store.Commit(reserved, 0)
			return nil, rErr
		}
	}

	// 304 Not Modified
	if resp.StatusCode == http.StatusNotModified {
		if err := c.store.Commit(reserved, 0); err != nil {
			return nil, fmt.Errorf("%w: commit 304 budget: %v", ErrStatePersistenceFailed, err)
		}
		return &FeedResult{
			NotModified: true,
			NextDelay:   nextDelay,
			RetryAfter:  retryAfter,
			HasRetry:    hasRetry,
		}, nil
	}

	counter := &countingReader{reader: resp.Body}

	// Non-200 Error
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		errBody, _ := io.ReadAll(io.LimitReader(counter, 4096))
		if err := c.store.Commit(reserved, counter.count); err != nil {
			return nil, fmt.Errorf("%w: commit error budget: %v", ErrStatePersistenceFailed, err)
		}

		upErr := &UpstreamError{
			StatusCode: resp.StatusCode,
			RetryAfter: retryAfter,
			HasRetry:   hasRetry,
			Err:        fmt.Errorf("feed request returned status %d: %s", resp.StatusCode, string(errBody)),
		}
		return &FeedResult{
			RetryAfter: retryAfter,
			HasRetry:   hasRetry,
			NextDelay:  nextDelay,
		}, upErr
	}

	var bodyReader io.Reader = counter
	if resp.StatusCode == http.StatusOK && resp.Header.Get("Content-Encoding") == "gzip" {
		gzReader, err := gzip.NewReader(counter)
		if err != nil {
			if cErr := c.store.Commit(reserved, counter.count); cErr != nil {
				return nil, fmt.Errorf("%w: commit on gzip error: %v", ErrStatePersistenceFailed, cErr)
			}
			return nil, fmt.Errorf("gzip reader: %w", err)
		}
		defer gzReader.Close()
		bodyReader = gzReader
	}

	// Read decoded stream bounded by maxItemBytes + 1
	body, err := io.ReadAll(io.LimitReader(bodyReader, c.maxItemBytes+1))
	if err != nil {
		if cErr := c.store.Commit(reserved, counter.count); cErr != nil {
			return nil, fmt.Errorf("%w: commit on read error: %v", ErrStatePersistenceFailed, cErr)
		}
		return nil, fmt.Errorf("read feed body: %w", err)
	}

	if int64(len(body)) > c.maxItemBytes || counter.count > c.maxItemBytes {
		if cErr := c.store.Commit(reserved, counter.count); cErr != nil {
			return nil, fmt.Errorf("%w: commit on oversize error: %v", ErrStatePersistenceFailed, cErr)
		}
		return nil, fmt.Errorf("%w: decoded %d, wire %d exceeds %d", ErrItemTooLarge, len(body), counter.count, c.maxItemBytes)
	}

	// Commit actual consumed wire bytes
	if err := c.store.Commit(reserved, counter.count); err != nil {
		return nil, fmt.Errorf("%w: commit feed wire bytes: %v", ErrStatePersistenceFailed, err)
	}

	return &FeedResult{
		Body:         body,
		LastModified: resp.Header.Get("Last-Modified"),
		ETag:         resp.Header.Get("ETag"),
		NotModified:  false,
		NextDelay:    nextDelay,
		RetryAfter:   retryAfter,
		HasRetry:     hasRetry,
	}, nil
}

// FetchData downloads an individual XML telegram document with strict stream bounding.
func (c *JMAClient) FetchData(ctx context.Context, dataURL string) (*DataResult, error) {
	if _, err := c.validator.ValidateDataURL(dataURL); err != nil {
		return nil, fmt.Errorf("validate data URL: %w", err)
	}

	if err := c.waitRateLimit(ctx); err != nil {
		return nil, err
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, dataURL, nil)
	if err != nil {
		return nil, fmt.Errorf("create data request: %w", err)
	}
	req.Header.Set("User-Agent", c.userAgent)
	req.Header.Set("Accept", "application/xml")
	req.Header.Set("Accept-Encoding", "gzip")

	reserved := c.maxItemBytes + 1
	if err := c.store.Reserve(reserved); err != nil {
		return nil, err
	}

	resp, err := c.httpClient.Do(req)
	if err != nil {
		if cErr := c.store.Commit(reserved, 0); cErr != nil {
			return nil, fmt.Errorf("%w: commit on data Do error: %v", ErrStatePersistenceFailed, cErr)
		}
		return nil, fmt.Errorf("execute data request: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode >= 301 && resp.StatusCode <= 308 {
		if cErr := c.store.Commit(reserved, 0); cErr != nil {
			return nil, fmt.Errorf("%w: commit on data redirect error: %v", ErrStatePersistenceFailed, cErr)
		}
		return nil, fmt.Errorf("%w: status %d", ErrRedirectNotAllowed, resp.StatusCode)
	}

	retryAfter, hasRetry := poll.ParseRetryAfter(resp.Header)
	if hasRetry {
		if rErr := c.SetGlobalRetry(time.Now().Add(retryAfter)); rErr != nil {
			_ = c.store.Commit(reserved, 0)
			return nil, rErr
		}
	} else if resp.StatusCode == 403 || resp.StatusCode == 429 || resp.StatusCode >= 500 {
		if rErr := c.SetGlobalRetry(time.Now().Add(30 * time.Second)); rErr != nil {
			_ = c.store.Commit(reserved, 0)
			return nil, rErr
		}
	}

	counter := &countingReader{reader: resp.Body}

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		errBody, _ := io.ReadAll(io.LimitReader(counter, 4096))
		if cErr := c.store.Commit(reserved, counter.count); cErr != nil {
			return nil, fmt.Errorf("%w: commit data error budget: %v", ErrStatePersistenceFailed, cErr)
		}
		return nil, &UpstreamError{
			StatusCode: resp.StatusCode,
			RetryAfter: retryAfter,
			HasRetry:   hasRetry,
			Err:        fmt.Errorf("data request returned status %d: %s", resp.StatusCode, string(errBody)),
		}
	}

	var bodyReader io.Reader = counter
	if resp.StatusCode == http.StatusOK && resp.Header.Get("Content-Encoding") == "gzip" {
		gzReader, err := gzip.NewReader(counter)
		if err != nil {
			if cErr := c.store.Commit(reserved, counter.count); cErr != nil {
				return nil, fmt.Errorf("%w: commit on data gzip error: %v", ErrStatePersistenceFailed, cErr)
			}
			return nil, fmt.Errorf("gzip reader: %w", err)
		}
		defer gzReader.Close()
		bodyReader = gzReader
	}

	body, err := io.ReadAll(io.LimitReader(bodyReader, c.maxItemBytes+1))
	if err != nil {
		if cErr := c.store.Commit(reserved, counter.count); cErr != nil {
			return nil, fmt.Errorf("%w: commit on data read error: %v", ErrStatePersistenceFailed, cErr)
		}
		return nil, fmt.Errorf("read data body: %w", err)
	}

	if int64(len(body)) > c.maxItemBytes || counter.count > c.maxItemBytes {
		if cErr := c.store.Commit(reserved, counter.count); cErr != nil {
			return nil, fmt.Errorf("%w: commit on data oversize error: %v", ErrStatePersistenceFailed, cErr)
		}
		return nil, fmt.Errorf("%w: decoded %d, wire %d exceeds %d", ErrItemTooLarge, len(body), counter.count, c.maxItemBytes)
	}

	if err := c.store.Commit(reserved, counter.count); err != nil {
		return nil, fmt.Errorf("%w: commit data wire bytes: %v", ErrStatePersistenceFailed, err)
	}

	return &DataResult{
		Body:       body,
		HTTPStatus: resp.StatusCode,
	}, nil
}
