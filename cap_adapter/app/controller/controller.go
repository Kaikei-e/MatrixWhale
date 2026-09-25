package controller

import (
	"context"
	"encoding/xml"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"matrixwhale/adapters/common/cap"
	"matrixwhale/adapters/common/core"
	"matrixwhale/adapters/common/metrics"
	"matrixwhale/adapters/common/useragent"

	"cap_adapter/adapter"
)

const (
	DefaultRAAURL           = "https://alertingauthority.wmo.int/rss.xml"
	DefaultPollInterval     = 5 * time.Minute
	DefaultRegistryInterval = 24 * time.Hour
	DefaultHostMinInterval  = 2 * time.Second
	DefaultMaxParallelHosts = 8
	DefaultRequestTimeout   = 30 * time.Second
	MaxBodyBytes            = 8 << 20 // 8 MiB
	PendingFetchLimit       = 50
	AlertBatchSize          = 10
	alertBatchMaxBytes      = 16 << 20 // 16 MiB raw_xml accumulated per POST
)

type Config struct {
	RAAURL           string
	PollInterval     time.Duration
	RegistryInterval time.Duration
	HostMinInterval  time.Duration
	MaxParallelHosts int
	ContactEmail     string
}

func LoadConfig() Config {
	cfg := Config{
		RAAURL:           DefaultRAAURL,
		PollInterval:     DefaultPollInterval,
		RegistryInterval: DefaultRegistryInterval,
		HostMinInterval:  DefaultHostMinInterval,
		MaxParallelHosts: DefaultMaxParallelHosts,
	}

	if v := strings.TrimSpace(os.Getenv("CAP_RAA_URL")); v != "" {
		cfg.RAAURL = v
	}
	if v := strings.TrimSpace(os.Getenv("CAP_POLL_INTERVAL")); v != "" {
		if d, err := time.ParseDuration(v); err == nil && d > 0 {
			cfg.PollInterval = d
		} else {
			slog.Warn("CAP_POLL_INTERVAL is invalid; using default", "value", v, "default", DefaultPollInterval)
		}
	}
	if v := strings.TrimSpace(os.Getenv("CAP_REGISTRY_INTERVAL")); v != "" {
		if d, err := time.ParseDuration(v); err == nil && d > 0 {
			cfg.RegistryInterval = d
		} else {
			slog.Warn("CAP_REGISTRY_INTERVAL is invalid; using default", "value", v, "default", DefaultRegistryInterval)
		}
	}
	if v := strings.TrimSpace(os.Getenv("CAP_HOST_MIN_INTERVAL")); v != "" {
		if d, err := time.ParseDuration(v); err == nil && d > 0 {
			cfg.HostMinInterval = d
		} else {
			slog.Warn("CAP_HOST_MIN_INTERVAL is invalid; using default", "value", v, "default", DefaultHostMinInterval)
		}
	}
	if v := strings.TrimSpace(os.Getenv("CAP_MAX_PARALLEL_HOSTS")); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			cfg.MaxParallelHosts = n
		} else {
			slog.Warn("CAP_MAX_PARALLEL_HOSTS is invalid; using default", "value", v, "default", DefaultMaxParallelHosts)
		}
	}
	cfg.ContactEmail = os.Getenv("CAP_CONTACT_EMAIL")
	return cfg
}

type Controller struct {
	cfg         Config
	mwClient    *adapter.MatrixWhaleClient
	httpClient  *http.Client
	hostLimiter *adapter.HostLimiter

	lastRAAFetch    time.Time
	raaETag         string
	raaLastModified string

	// feedMu guards feedDueTimes, feedETags, feedLastModified, feedLastFormat;
	// all four are written from per-host goroutines.
	feedMu           sync.Mutex
	feedDueTimes     map[string]time.Time
	feedETags        map[string]string
	feedLastModified map[string]string
	feedLastFormat   map[string]string

	now func() time.Time
}

func Run(ctx context.Context) {
	cfg := LoadConfig()
	coreClient := core.NewClientFromEnv()
	coreHTTPClient := &http.Client{Timeout: DefaultRequestTimeout, Transport: metrics.Transport("core", nil)}
	mwClient := adapter.NewMatrixWhaleClient(coreClient, coreHTTPClient)
	upstreamHTTPClient := &http.Client{Timeout: DefaultRequestTimeout, Transport: metrics.Transport("upstream", nil)}
	limiter := adapter.NewHostLimiter(cfg.HostMinInterval, cfg.MaxParallelHosts)

	c := NewController(cfg, mwClient, upstreamHTTPClient, limiter, time.Now)
	c.Execute(ctx)
}

func NewController(
	cfg Config,
	mwClient *adapter.MatrixWhaleClient,
	httpClient *http.Client,
	hostLimiter *adapter.HostLimiter,
	now func() time.Time,
) *Controller {
	if httpClient == nil {
		httpClient = &http.Client{Timeout: DefaultRequestTimeout, Transport: metrics.Transport("upstream", nil)}
	}
	if now == nil {
		now = time.Now
	}
	return &Controller{
		cfg:              cfg,
		mwClient:         mwClient,
		httpClient:       httpClient,
		hostLimiter:      hostLimiter,
		feedDueTimes:     make(map[string]time.Time),
		feedETags:        make(map[string]string),
		feedLastModified: make(map[string]string),
		feedLastFormat:   make(map[string]string),
		now:              now,
	}
}

func (c *Controller) Execute(ctx context.Context) {
	slog.Info("Starting CAP adapter controller",
		"poll_interval", c.cfg.PollInterval,
		"registry_interval", c.cfg.RegistryInterval,
		"host_min_interval", c.cfg.HostMinInterval,
		"max_parallel_hosts", c.cfg.MaxParallelHosts,
	)

	for {
		if ctx.Err() != nil {
			return
		}

		currentTime := c.now()

		// 1. RAA Registry check
		if c.lastRAAFetch.IsZero() || currentTime.Sub(c.lastRAAFetch) >= c.cfg.RegistryInterval {
			c.pollRAA(ctx)
		}

		if ctx.Err() != nil {
			return
		}

		// 2. Feed cycle
		cycleStart := c.now()
		cycleDeadline := cycleStart.Add(c.cfg.PollInterval)
		c.pollFeedsCycle(ctx, cycleStart)

		if ctx.Err() != nil {
			return
		}

		// 3. Drain pending alerts until cycleDeadline
		c.drainPending(ctx, cycleDeadline)

		if ctx.Err() != nil {
			return
		}

		// Sleep if remaining time before next cycle
		remaining := cycleDeadline.Sub(c.now())
		if remaining > 0 {
			timer := time.NewTimer(remaining)
			select {
			case <-ctx.Done():
				timer.Stop()
				return
			case <-timer.C:
			}
		}
	}
}

func (c *Controller) pollRAA(ctx context.Context) {
	raaHost := adapter.HostFromURL(c.cfg.RAAURL)
	if err := c.hostLimiter.Wait(ctx, raaHost); err != nil {
		return
	}
	fetchedAt := c.now().UTC().Format(time.RFC3339)

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.cfg.RAAURL, nil)
	if err != nil {
		c.hostLimiter.Done(raaHost)
		slog.Error("Failed to create RAA request", "error", err)
		return
	}
	req.Header.Set("User-Agent", c.userAgent())
	req.Header.Set("Accept", "application/xml, text/xml, */*")
	if c.raaETag != "" {
		req.Header.Set("If-None-Match", c.raaETag)
	}
	if c.raaLastModified != "" {
		req.Header.Set("If-Modified-Since", c.raaLastModified)
	}

	resp, err := c.httpClient.Do(req)
	if err != nil {
		c.hostLimiter.Done(raaHost)
		slog.Error("Failed to fetch RAA", "url", c.cfg.RAAURL, "error", err)
		return
	}
	defer resp.Body.Close()

	body, err := readLimited(resp.Body, MaxBodyBytes)
	c.hostLimiter.Done(raaHost)
	if err != nil {
		slog.Error("Failed to read RAA response body", "error", err)
		return
	}

	if resp.StatusCode == http.StatusNotModified {
		slog.Info("RAA registry not modified (304)", "url", c.cfg.RAAURL)
		c.lastRAAFetch = c.now()
		return
	}

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		slog.Error("RAA responded with error status", "status", resp.StatusCode)
		return
	}

	features, err := adapter.ParseRAA(body)
	if err != nil {
		slog.Error("Failed to parse RAA RSS XML", "error", err)
		return
	}

	meta := core.PollMeta{
		FetchedAt:    fetchedAt,
		HTTPStatus:   resp.StatusCode,
		FeatureCount: len(features),
		Bytes:        len(body),
		FeedURL:      c.cfg.RAAURL,
		Backfill:     false,
	}

	// Only store validators and lastRAAFetch after a successful POST, so a
	// rejected POST causes a full re-fetch on the next cycle rather than a 304.
	if err := c.mwClient.SendRegistry(ctx, meta, features); err != nil {
		slog.Error("Failed to post RAA registry to Matrix Whale core", "error", err)
		return
	}

	if etag := resp.Header.Get("ETag"); etag != "" {
		c.raaETag = etag
	}
	if lm := resp.Header.Get("Last-Modified"); lm != "" {
		c.raaLastModified = lm
	}
	c.lastRAAFetch = c.now()
	slog.Info("Successfully posted RAA registry to Matrix Whale core", "item_count", len(features))
}

func (c *Controller) pollFeedsCycle(ctx context.Context, cycleStart time.Time) {
	feeds, err := c.mwClient.FetchFeeds(ctx)
	if err != nil {
		slog.Error("Failed to fetch subscribed feeds from core", "error", err)
		return
	}

	c.feedMu.Lock()
	dueFeeds := make([]adapter.FeedEntry, 0)
	for _, feed := range feeds {
		due, exists := c.feedDueTimes[feed.URL]
		if !exists || !cycleStart.Before(due) {
			dueFeeds = append(dueFeeds, feed)
		}
	}
	c.feedMu.Unlock()

	if len(dueFeeds) == 0 {
		return
	}

	// Group due feeds by host so different hosts proceed in parallel
	hostMap := make(map[string][]adapter.FeedEntry)
	for _, feed := range dueFeeds {
		h := adapter.HostFromURL(feed.URL)
		hostMap[h] = append(hostMap[h], feed)
	}

	feedDeadline := cycleStart.Add(c.cfg.PollInterval * 60 / 100)
	feedCtx, cancelFeed := context.WithDeadline(ctx, feedDeadline)
	defer cancelFeed()

	var wg sync.WaitGroup
	for host, feedList := range hostMap {
		wg.Add(1)
		go func(h string, fl []adapter.FeedEntry) {
			defer wg.Done()
			for _, feed := range fl {
				if feedCtx.Err() != nil {
					return
				}
				c.pollSingleFeed(feedCtx, h, feed, cycleStart)
			}
		}(host, feedList)
	}
	wg.Wait()
}

func (c *Controller) pollSingleFeed(ctx context.Context, host string, feed adapter.FeedEntry, cycleStart time.Time) {
	if err := c.hostLimiter.Wait(ctx, host); err != nil {
		return
	}
	fetchedAt := c.now().UTC().Format(time.RFC3339)

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, feed.URL, nil)
	if err != nil {
		c.hostLimiter.Done(host)
		if ctx.Err() != nil {
			return
		}
		interval := feedInterval(feed, c.cfg.PollInterval)
		c.feedMu.Lock()
		c.feedDueTimes[feed.URL] = cycleStart.Add(interval)
		c.feedMu.Unlock()
		c.postFeedFailure(ctx, feed.URL, 0, err.Error(), fetchedAt)
		return
	}
	req.Header.Set("User-Agent", c.userAgent())
	req.Header.Set("Accept", "application/atom+xml, application/rss+xml, application/xml, text/xml, */*")

	c.feedMu.Lock()
	etag := c.feedETags[feed.URL]
	lm := c.feedLastModified[feed.URL]
	lastFmt := c.feedLastFormat[feed.URL]
	c.feedMu.Unlock()

	if etag != "" {
		req.Header.Set("If-None-Match", etag)
	}
	if lm != "" {
		req.Header.Set("If-Modified-Since", lm)
	}

	resp, err := c.httpClient.Do(req)
	if err != nil {
		c.hostLimiter.Done(host)
		if ctx.Err() != nil {
			return
		}
		// Compute due time from cycle start so interval accuracy is not affected by
		// how long Wait or the request itself took.
		interval := feedInterval(feed, c.cfg.PollInterval)
		c.feedMu.Lock()
		c.feedDueTimes[feed.URL] = cycleStart.Add(interval)
		c.feedMu.Unlock()
		slog.Warn("Single feed HTTP request error", "url", feed.URL, "error", err)
		c.postFeedFailure(ctx, feed.URL, 0, err.Error(), fetchedAt)
		return
	}
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusNotModified {
		body, _ := io.ReadAll(resp.Body) // drain so connection is reusable
		_ = body
		c.hostLimiter.Done(host)

		interval := feedInterval(feed, c.cfg.PollInterval)
		c.feedMu.Lock()
		c.feedDueTimes[feed.URL] = cycleStart.Add(interval)
		c.feedMu.Unlock()

		slog.Debug("Feed not modified (304)", "url", feed.URL)
		meta := core.PollMeta{
			FetchedAt:    fetchedAt,
			HTTPStatus:   http.StatusNotModified,
			FeatureCount: 0,
			Bytes:        0,
			FeedURL:      feed.URL,
			Backfill:     false,
			Format:       lastFmt,
		}
		_ = c.mwClient.SendIndex(ctx, meta, []adapter.FeedIndexFeature{})
		return
	}

	// Read body before calling Done so the global slot bounds actual downloads.
	body, readErr := readLimited(resp.Body, MaxBodyBytes)
	c.hostLimiter.Done(host)
	if ctx.Err() != nil {
		return
	}

	interval := feedInterval(feed, c.cfg.PollInterval)
	c.feedMu.Lock()
	c.feedDueTimes[feed.URL] = cycleStart.Add(interval)
	c.feedMu.Unlock()

	if readErr != nil {
		slog.Warn("Single feed read error (oversized or network)", "url", feed.URL, "error", readErr)
		// status 0 for read/oversize failures per contract §5.3
		c.postFeedFailure(ctx, feed.URL, 0, readErr.Error(), fetchedAt)
		return
	}

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		errStr := fmt.Sprintf("HTTP %d", resp.StatusCode)
		c.postFeedFailure(ctx, feed.URL, resp.StatusCode, errStr, fetchedAt)
		return
	}

	parseRes := adapter.ParseFeed(feed.URL, body)

	// Parse failures (wrong format, HTML, JSON body, etc.) use status 0 per §5.3.
	httpStatus := resp.StatusCode
	if parseRes.Error != "" {
		httpStatus = 0
	}

	meta := core.PollMeta{
		FetchedAt:    fetchedAt,
		HTTPStatus:   httpStatus,
		FeatureCount: len(parseRes.Features),
		Bytes:        len(body),
		FeedURL:      feed.URL,
		Backfill:     false,
		Format:       parseRes.Format,
		Error:        parseRes.Error,
	}

	if err := c.mwClient.SendIndex(ctx, meta, parseRes.Features); err != nil {
		slog.Error("Failed to send feed index to core", "url", feed.URL, "error", err)
		return
	}

	c.feedMu.Lock()
	if parseRes.Format != "" {
		c.feedLastFormat[feed.URL] = parseRes.Format
	}
	// Only store validators after SendIndex succeeds.
	if parseRes.Error == "" {
		if newETag := resp.Header.Get("ETag"); newETag != "" {
			c.feedETags[feed.URL] = newETag
		}
		if newLM := resp.Header.Get("Last-Modified"); newLM != "" {
			c.feedLastModified[feed.URL] = newLM
		}
	}
	c.feedMu.Unlock()
}

func feedInterval(feed adapter.FeedEntry, fallback time.Duration) time.Duration {
	if feed.PollIntervalSeconds > 0 {
		return time.Duration(feed.PollIntervalSeconds) * time.Second
	}
	return fallback
}

func (c *Controller) postFeedFailure(ctx context.Context, feedURL string, status int, errMsg string, fetchedAt string) {
	meta := core.PollMeta{
		FetchedAt:    fetchedAt,
		HTTPStatus:   status,
		FeatureCount: 0,
		Bytes:        0,
		FeedURL:      feedURL,
		Backfill:     false,
		Format:       adapter.FormatOther,
		Error:        errMsg,
	}
	_ = c.mwClient.SendIndex(ctx, meta, []adapter.FeedIndexFeature{})
}

func (c *Controller) drainPending(ctx context.Context, deadline time.Time) {
	for c.now().Before(deadline) {
		if ctx.Err() != nil {
			return
		}

		items, err := c.mwClient.FetchPending(ctx, PendingFetchLimit)
		if err != nil {
			slog.Error("Failed to fetch pending items from core", "error", err)
			return
		}
		if len(items) == 0 {
			// No pending items; return so caller can sleep until next cycle.
			return
		}

		// Group items by host to process in parallel
		hostMap := make(map[string][]adapter.PendingEntry)
		for _, item := range items {
			h := adapter.HostFromURL(item.CAPURL)
			hostMap[h] = append(hostMap[h], item)
		}

		drainCtx, drainCancel := context.WithCancel(ctx)
		resultsCh := make(chan adapter.AlertResult, len(items))
		var workerWg sync.WaitGroup

		for host, hostItems := range hostMap {
			workerWg.Add(1)
			go func(h string, pendingList []adapter.PendingEntry) {
				defer workerWg.Done()
				for _, p := range pendingList {
					if drainCtx.Err() != nil || !c.now().Before(deadline) {
						return
					}
					res := c.fetchSingleCAP(drainCtx, h, p)
					select {
					case resultsCh <- res:
					case <-drainCtx.Done():
						return
					}
				}
			}(host, hostItems)
		}

		// Close resultsCh once workers complete
		go func() {
			workerWg.Wait()
			close(resultsCh)
		}()

		// Collect results and flush in batches bounded by count and raw_xml size.
		batch := make([]adapter.AlertResult, 0, AlertBatchSize)
		batchBytes := 0
		ok := true
		for res := range resultsCh {
			itemBytes := 0
			if res.RawXML != nil {
				itemBytes = len(*res.RawXML)
			}
			// Flush early if adding this result would exceed 16 MiB
			if len(batch) > 0 && (batchBytes+itemBytes > alertBatchMaxBytes) {
				if err := c.sendAlertsBatch(ctx, batch); err != nil {
					drainCancel()
					ok = false
					break
				}
				batch = batch[:0]
				batchBytes = 0
			}
			batch = append(batch, res)
			batchBytes += itemBytes
			flush := len(batch) >= AlertBatchSize || batchBytes >= alertBatchMaxBytes
			if flush {
				if err := c.sendAlertsBatch(ctx, batch); err != nil {
					// Stop draining after a failed POST; cancel workers and retry next cycle.
					drainCancel()
					ok = false
					break
				}
				batch = batch[:0]
				batchBytes = 0
			}
		}

		// Drain resultsCh if we broke out early (avoid goroutine leak)
		for range resultsCh {
		}

		drainCancel()

		if !ok {
			return
		}

		if len(batch) > 0 {
			if err := c.sendAlertsBatch(ctx, batch); err != nil {
				return
			}
		}
	}
}

func (c *Controller) fetchSingleCAP(ctx context.Context, host string, item adapter.PendingEntry) adapter.AlertResult {
	result := adapter.AlertResult{
		CAPURL:  item.CAPURL,
		FeedURL: item.FeedURL,
	}

	if err := c.hostLimiter.Wait(ctx, host); err != nil {
		errStr := err.Error()
		result.Error = &errStr
		result.HTTPStatus = 0
		result.FetchedAt = c.now().UTC().Format(time.RFC3339)
		return result
	}
	result.FetchedAt = c.now().UTC().Format(time.RFC3339)

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, item.CAPURL, nil)
	if err != nil {
		c.hostLimiter.Done(host)
		errStr := err.Error()
		result.Error = &errStr
		result.HTTPStatus = 0
		return result
	}
	req.Header.Set("User-Agent", c.userAgent())
	req.Header.Set("Accept", "application/cap+xml, application/xml, text/xml, */*")

	resp, err := c.httpClient.Do(req)
	if err != nil {
		c.hostLimiter.Done(host)
		errStr := err.Error()
		result.Error = &errStr
		result.HTTPStatus = 0
		return result
	}
	defer resp.Body.Close()

	result.HTTPStatus = resp.StatusCode

	// Read body before Done so the global slot bounds concurrent downloads.
	body, readErr := readLimited(resp.Body, MaxBodyBytes)
	c.hostLimiter.Done(host)

	if readErr != nil {
		errStr := readErr.Error()
		result.Error = &errStr
		// status 0 for network/read/oversize so the core retries
		result.HTTPStatus = 0
		return result
	}

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		errStr := fmt.Sprintf("HTTP %d", resp.StatusCode)
		result.Error = &errStr
		return result
	}

	parseRes := cap.ParseCAP(body)
	result.Cap = parseRes.Cap
	result.Error = parseRes.Error
	result.RawXML = sanitizeRawXML(parseRes.RawXML)
	// Non-CAP root or parse error: keep real HTTP status, cap=nil (already nil).
	return result
}

// sanitizeRawXML strips NUL bytes and cuts at the root element end using decoder InputOffset().
func sanitizeRawXML(s *string) *string {
	if s == nil {
		return nil
	}
	v := *s
	// Strip NUL bytes (Postgres TEXT rejects them)
	v = strings.ReplaceAll(v, "\x00", "")

	decoder := xml.NewDecoder(strings.NewReader(v))
	for {
		tok, err := decoder.Token()
		if err != nil {
			break
		}
		if _, ok := tok.(xml.StartElement); ok {
			if err := decoder.Skip(); err == nil {
				offset := decoder.InputOffset()
				if offset > 0 && offset <= int64(len(v)) {
					v = v[:offset]
				}
			}
			break
		}
	}
	return &v
}

func (c *Controller) sendAlertsBatch(ctx context.Context, batch []adapter.AlertResult) error {
	if len(batch) == 0 {
		return nil
	}
	meta := core.PollMeta{
		FetchedAt:    c.now().UTC().Format(time.RFC3339),
		HTTPStatus:   200,
		FeatureCount: len(batch),
		Backfill:     false,
	}
	if err := c.mwClient.SendAlerts(ctx, meta, batch); err != nil {
		slog.Error("Failed to post alerts batch to core", "count", len(batch), "error", err)
		return err
	}
	return nil
}

func (c *Controller) userAgent() string {
	return useragent.Build("cap_adapter", "CAP_CONTACT_EMAIL", "", nil)
}

func readLimited(r io.Reader, limit int64) ([]byte, error) {
	lr := io.LimitReader(r, limit+1)
	b, err := io.ReadAll(lr)
	if err != nil {
		return nil, err
	}
	if int64(len(b)) > limit {
		return b[:limit], fmt.Errorf("response body exceeds %d bytes limit", limit)
	}
	return b, nil
}
