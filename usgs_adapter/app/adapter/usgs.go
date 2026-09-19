package adapter

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"time"

	"matrixwhale/adapters/common/metrics"
	"matrixwhale/adapters/common/useragent"
)

var defaultHTTPClient = &http.Client{
	Timeout:   60 * time.Second,
	Transport: metrics.Transport("upstream", nil),
}

const (
	USGSAllDayURL       = "https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/all_day.geojson"
	USGSAllWeekURL      = "https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/all_week.geojson"
	maxFeedBodyBytes    = 16 << 20
	maxResponseBodySize = 1 << 20
)

type PollResult struct {
	Body       []byte
	FetchedAt  time.Time
	HTTPStatus int
	Header     http.Header
	Bytes      int
	FeedURL    string
	Backfill   bool
}

type featureCollection struct {
	Type     string            `json:"type"`
	Features []json.RawMessage `json:"features"`
}

func FetchFeed(ctx context.Context, feedURL, previousLastModified string) (PollResult, error) {
	if feedURL == "" {
		return PollResult{}, fmt.Errorf("USGS feed URL is empty")
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, feedURL, nil)
	if err != nil {
		return PollResult{}, err
	}
	req.Header.Set("User-Agent", userAgent())
	req.Header.Set("Accept", "application/geo+json, application/json")
	if previousLastModified != "" {
		req.Header.Set("If-Modified-Since", previousLastModified)
	}
	res, err := defaultHTTPClient.Do(req)
	if err != nil {
		return PollResult{}, err
	}
	defer res.Body.Close()

	result := PollResult{
		FetchedAt:  time.Now().UTC(),
		HTTPStatus: res.StatusCode,
		Header:     res.Header.Clone(),
		FeedURL:    feedURL,
	}
	if res.StatusCode == http.StatusNotModified {
		return result, nil
	}
	body, readErr := readLimited(res.Body, maxFeedBodyBytes)
	result.Body = body
	result.Bytes = len(body)
	if readErr != nil {
		return result, readErr
	}
	if res.StatusCode < http.StatusOK || res.StatusCode >= http.StatusMultipleChoices {
		return result, fmt.Errorf("USGS feed request failed with status %d", res.StatusCode)
	}
	if err := validateFeatureCollection(body); err != nil {
		return result, fmt.Errorf("invalid USGS GeoJSON: %w", err)
	}
	slog.Info("USGS response", "status", res.Status, "bytes", len(body), "url", feedURL)
	return result, nil
}

func readLimited(reader io.Reader, limit int64) ([]byte, error) {
	body, err := io.ReadAll(io.LimitReader(reader, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(body)) > limit {
		return nil, fmt.Errorf("response body exceeds %d bytes", limit)
	}
	return body, nil
}

func validateFeatureCollection(body []byte) error {
	var collection featureCollection
	if err := json.Unmarshal(body, &collection); err != nil {
		return err
	}
	if collection.Type != "FeatureCollection" {
		return fmt.Errorf("top-level type is %q", collection.Type)
	}
	if collection.Features == nil {
		return fmt.Errorf("features is missing or null")
	}
	return nil
}

func userAgent() string {
	return useragent.Build("MatrixWhale/1.0", "USGS_CONTACT_EMAIL", "", nil)
}
