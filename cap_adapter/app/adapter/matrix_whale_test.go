package adapter

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"

	"matrixwhale/adapters/common/core"
)

func TestCorePOSTRetrySuccessOnThirdAttempt(t *testing.T) {
	var attempts int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		att := atomic.AddInt32(&attempts, 1)
		if att < 3 {
			w.WriteHeader(http.StatusInternalServerError)
			_, _ = w.Write([]byte("temporary internal error"))
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"received":1,"deduped":0,"written":1,"dropped":0,"message":"ok"}`))
	}))
	defer server.Close()

	client := NewMatrixWhaleClient(core.NewClient(server.URL, &http.Client{Timeout: 5 * time.Second}), nil)
	meta := core.PollMeta{
		FetchedAt:    time.Now().UTC().Format(time.RFC3339),
		HTTPStatus:   200,
		FeatureCount: 1,
		FeedURL:      "https://example.com/feed",
	}
	features := []FeedIndexFeature{
		{
			Title: ptr("Alert 1"),
		},
	}

	err := client.SendIndex(context.Background(), meta, features)
	if err != nil {
		t.Fatalf("expected SendIndex to succeed after 3 attempts, got: %v", err)
	}
	if atomic.LoadInt32(&attempts) != 3 {
		t.Errorf("expected exactly 3 attempts, got %d", atomic.LoadInt32(&attempts))
	}
}

func TestCorePOSTRetryExhaustion(t *testing.T) {
	var attempts int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&attempts, 1)
		w.WriteHeader(http.StatusBadGateway)
		_, _ = w.Write([]byte("502 bad gateway"))
	}))
	defer server.Close()

	client := NewMatrixWhaleClient(core.NewClient(server.URL, &http.Client{Timeout: 5 * time.Second}), nil)
	meta := core.PollMeta{
		FetchedAt:    time.Now().UTC().Format(time.RFC3339),
		HTTPStatus:   200,
		FeatureCount: 1,
		FeedURL:      "https://example.com/feed",
	}
	features := []FeedIndexFeature{
		{Title: ptr("Alert 1")},
	}

	err := client.SendIndex(context.Background(), meta, features)
	if err == nil {
		t.Fatal("expected SendIndex to fail after exhausting retries")
	}
	if atomic.LoadInt32(&attempts) != 3 {
		t.Errorf("expected 3 attempts, got %d", atomic.LoadInt32(&attempts))
	}
}

func TestCoreClientEndpoints(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/cap_data/registry":
			_, _ = w.Write([]byte(`{"received":1,"deduped":0,"written":1,"dropped":0,"message":"ok"}`))
		case "/cap_data/feeds":
			_, _ = w.Write([]byte(`{"feeds":[{"url":"https://example.com/rss.xml","poll_interval_seconds":300}]}`))
		case "/cap_data/index":
			_, _ = w.Write([]byte(`{"received":1,"deduped":0,"written":1,"dropped":0,"message":"ok"}`))
		case "/cap_data/pending":
			_, _ = w.Write([]byte(`{"items":[{"cap_url":"https://example.com/a.xml","feed_url":"https://example.com/rss.xml"}]}`))
		case "/cap_data/alerts":
			_, _ = w.Write([]byte(`{"received":1,"deduped":0,"written":1,"dropped":0,"message":"ok"}`))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer server.Close()

	client := NewMatrixWhaleClient(core.NewClient(server.URL, &http.Client{Timeout: 5 * time.Second}), nil)
	ctx := context.Background()

	// 1. SendRegistry
	regFeatures := []RAARegistryFeature{
		{
			GUID:  ptr("urn:oid:123"),
			Title: ptr("Test Authority"),
			Feeds: []RAAFeed{},
		},
	}
	if err := client.SendRegistry(ctx, core.PollMeta{FeatureCount: 1}, regFeatures); err != nil {
		t.Errorf("SendRegistry failed: %v", err)
	}

	// 2. FetchFeeds
	feeds, err := client.FetchFeeds(ctx)
	if err != nil {
		t.Errorf("FetchFeeds failed: %v", err)
	}
	if len(feeds) != 1 || feeds[0].URL != "https://example.com/rss.xml" || feeds[0].PollIntervalSeconds != 300 {
		t.Errorf("unexpected feeds: %+v", feeds)
	}

	// 3. SendIndex
	indexFeatures := []FeedIndexFeature{
		{Title: ptr("Item 1")},
	}
	if err := client.SendIndex(ctx, core.PollMeta{FeatureCount: 1}, indexFeatures); err != nil {
		t.Errorf("SendIndex failed: %v", err)
	}

	// 4. FetchPending
	pending, err := client.FetchPending(ctx, 50)
	if err != nil {
		t.Errorf("FetchPending failed: %v", err)
	}
	if len(pending) != 1 || pending[0].CAPURL != "https://example.com/a.xml" {
		t.Errorf("unexpected pending: %+v", pending)
	}

	// 5. SendAlerts
	alerts := []AlertResult{
		{
			CAPURL:     "https://example.com/a.xml",
			FeedURL:    "https://example.com/rss.xml",
			FetchedAt:  time.Now().UTC().Format(time.RFC3339),
			HTTPStatus: 200,
		},
	}
	if err := client.SendAlerts(ctx, core.PollMeta{FeatureCount: 1}, alerts); err != nil {
		t.Errorf("SendAlerts failed: %v", err)
	}
}

func ptr(s string) *string {
	return &s
}

// Ensure unused import warning suppressor
var _ = json.Marshal
