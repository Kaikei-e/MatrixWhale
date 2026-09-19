package adapter

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"time"

	"matrixwhale/adapters/common/core"
	"matrixwhale/adapters/common/metrics"
	"matrixwhale/adapters/common/poll"
)

const (
	minCoreBackoff = 200 * time.Millisecond
	maxCoreBackoff = 5 * time.Second
	maxCoreRetries = 3
)

type FeedEntry struct {
	URL                 string `json:"url"`
	PollIntervalSeconds int    `json:"poll_interval_seconds"`
}

type feedsResponse struct {
	Feeds []FeedEntry `json:"feeds"`
}

type PendingEntry struct {
	CAPURL  string `json:"cap_url"`
	FeedURL string `json:"feed_url"`
}

type pendingResponse struct {
	Items []PendingEntry `json:"items"`
}

type AlertResult struct {
	CAPURL     string    `json:"cap_url"`
	FeedURL    string    `json:"feed_url"`
	FetchedAt  string    `json:"fetched_at"`
	HTTPStatus int       `json:"http_status"`
	Error      *string   `json:"error"`
	Cap        *CAPAlert `json:"cap"`
	RawXML     *string   `json:"raw_xml"`
}

type MatrixWhaleClient struct {
	coreClient *core.Client
	httpClient *http.Client
}

func NewMatrixWhaleClient(coreClient *core.Client, httpClient *http.Client) *MatrixWhaleClient {
	if httpClient == nil {
		httpClient = &http.Client{Timeout: 30 * time.Second, Transport: metrics.Transport("core", nil)}
	}
	return &MatrixWhaleClient{
		coreClient: coreClient,
		httpClient: httpClient,
	}
}

func (mw *MatrixWhaleClient) SendRegistry(ctx context.Context, meta core.PollMeta, features []RAARegistryFeature) error {
	rawFeatures := make([]json.RawMessage, 0, len(features))
	for _, f := range features {
		b, err := json.Marshal(f)
		if err != nil {
			return fmt.Errorf("marshal registry feature: %w", err)
		}
		rawFeatures = append(rawFeatures, b)
	}
	return mw.sendWithRetry(ctx, "cap_data/registry", meta, rawFeatures)
}

func (mw *MatrixWhaleClient) FetchFeeds(ctx context.Context) ([]FeedEntry, error) {
	target := mw.coreClient.BaseURL() + "/cap_data/feeds"
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, target, nil)
	if err != nil {
		return nil, fmt.Errorf("create feeds request: %w", err)
	}
	req.Header.Set("Accept", "application/json")

	resp, err := mw.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("fetch feeds: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("fetch feeds failed with status %d", resp.StatusCode)
	}

	var res feedsResponse
	if err := json.NewDecoder(resp.Body).Decode(&res); err != nil {
		return nil, fmt.Errorf("decode feeds response: %w", err)
	}
	return res.Feeds, nil
}

func (mw *MatrixWhaleClient) SendIndex(ctx context.Context, meta core.PollMeta, features []FeedIndexFeature) error {
	rawFeatures := make([]json.RawMessage, 0, len(features))
	for _, f := range features {
		b, err := json.Marshal(f)
		if err != nil {
			return fmt.Errorf("marshal index feature: %w", err)
		}
		rawFeatures = append(rawFeatures, b)
	}
	return mw.sendWithRetry(ctx, "cap_data/index", meta, rawFeatures)
}

func (mw *MatrixWhaleClient) FetchPending(ctx context.Context, limit int) ([]PendingEntry, error) {
	target := fmt.Sprintf("%s/cap_data/pending?limit=%d", mw.coreClient.BaseURL(), limit)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, target, nil)
	if err != nil {
		return nil, fmt.Errorf("create pending request: %w", err)
	}
	req.Header.Set("Accept", "application/json")

	resp, err := mw.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("fetch pending: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("fetch pending failed with status %d", resp.StatusCode)
	}

	var res pendingResponse
	if err := json.NewDecoder(resp.Body).Decode(&res); err != nil {
		return nil, fmt.Errorf("decode pending response: %w", err)
	}
	return res.Items, nil
}

func (mw *MatrixWhaleClient) SendAlerts(ctx context.Context, meta core.PollMeta, results []AlertResult) error {
	rawFeatures := make([]json.RawMessage, 0, len(results))
	for _, r := range results {
		b, err := json.Marshal(r)
		if err != nil {
			return fmt.Errorf("marshal alert result: %w", err)
		}
		rawFeatures = append(rawFeatures, b)
	}
	return mw.sendWithRetry(ctx, "cap_data/alerts", meta, rawFeatures)
}

func (mw *MatrixWhaleClient) sendWithRetry(ctx context.Context, path string, meta core.PollMeta, features []json.RawMessage) error {
	var backoff time.Duration
	var lastErr error

	for attempt := 1; attempt <= maxCoreRetries; attempt++ {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		ack, err := mw.coreClient.Send(ctx, path, meta, features)
		if err == nil {
			if valErr := core.ValidateAck(ack, len(features)); valErr == nil {
				return nil
			} else {
				lastErr = valErr
			}
		} else {
			lastErr = err
		}

		if attempt < maxCoreRetries {
			backoff = poll.ComputeBackoff(nil, backoff, minCoreBackoff, maxCoreBackoff)
			timer := time.NewTimer(backoff)
			select {
			case <-ctx.Done():
				timer.Stop()
				return ctx.Err()
			case <-timer.C:
			}
		}
	}
	return fmt.Errorf("send to %s failed after %d attempts: %w", path, maxCoreRetries, lastErr)
}
