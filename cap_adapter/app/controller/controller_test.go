package controller

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"matrixwhale/adapters/common/core"

	"cap_adapter/adapter"
)

const fixtureRAA = `<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0">
  <channel>
    <title>WMO RAA</title>
    <item>
      <title>Ghana: GMet</title>
      <countrycode>GHA</countrycode>
      <guid>urn:oid:2.49.0.0.288.0</guid>
      <capAlertFeed xml:lang="en">https://example.com/feed.xml</capAlertFeed>
    </item>
  </channel>
</rss>`

const fixtureRSS = `<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0">
  <channel>
    <title>Alerts Feed</title>
    <item>
      <title>Severe Storm Warning</title>
      <link>https://example.com/alert-1.xml</link>
      <guid>alert-1</guid>
      <pubDate>Thu, 17 Sep 2026 12:00:00 GMT</pubDate>
    </item>
  </channel>
</rss>`

const fixtureCAP = `<?xml version="1.0" encoding="UTF-8"?>
<alert xmlns="urn:oasis:names:tc:emergency:cap:1.2">
  <identifier>ALERT-%d</identifier>
  <sender>test@example.com</sender>
  <sent>2026-09-17T12:00:00Z</sent>
  <status>Actual</status>
  <msgType>Alert</msgType>
  <scope>Public</scope>
  <info>
    <category>Met</category>
    <event>Severe Storm</event>
    <urgency>Immediate</urgency>
    <severity>Severe</severity>
    <certainty>Observed</certainty>
    <area><areaDesc>Test Area</areaDesc></area>
  </info>
</alert>`

func TestControllerPendingDrainBatching(t *testing.T) {
	var alertBatchesMu sync.Mutex
	var alertBatchCounts []int

	// Fake CAP server returning CAP documents
	capServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/cap+xml")
		_, _ = fmt.Fprintf(w, fixtureCAP, 1)
	}))
	defer capServer.Close()

	// Fake Core server
	var pendingCalls int32
	coreServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/api/v1/cap_data/pending":
			call := atomic.AddInt32(&pendingCalls, 1)
			if call == 1 {
				// Return 25 pending items on first call
				items := make([]adapter.PendingEntry, 25)
				for i := 0; i < 25; i++ {
					items[i] = adapter.PendingEntry{
						CAPURL:  fmt.Sprintf("%s/alert-%d.xml", capServer.URL, i+1),
						FeedURL: "https://example.com/feed.xml",
					}
				}
				_ = json.NewEncoder(w).Encode(map[string]any{"items": items})
			} else {
				// Empty on subsequent calls
				_ = json.NewEncoder(w).Encode(map[string]any{"items": []adapter.PendingEntry{}})
			}
		case "/api/v1/cap_data/alerts":
			var env struct {
				PollMeta core.PollMeta         `json:"poll_meta"`
				Features []adapter.AlertResult `json:"features"`
			}
			if err := json.NewDecoder(r.Body).Decode(&env); err != nil {
				t.Errorf("decode alerts: %v", err)
			}
			alertBatchesMu.Lock()
			alertBatchCounts = append(alertBatchCounts, len(env.Features))
			alertBatchesMu.Unlock()
			ack := fmt.Sprintf(`{"received":%d,"deduped":0,"written":%d,"dropped":0,"message":"ok"}`,
				len(env.Features), len(env.Features))
			_, _ = w.Write([]byte(ack))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer coreServer.Close()

	cfg := Config{
		RAAURL:           "https://example.com/raa.xml",
		PollInterval:     5 * time.Minute,
		RegistryInterval: 24 * time.Hour,
		HostMinInterval:  1 * time.Millisecond,
		MaxParallelHosts: 4,
	}

	coreClient := core.NewClient(coreServer.URL+"/api/v1", &http.Client{Timeout: 5 * time.Second})
	mwClient := adapter.NewMatrixWhaleClient(coreClient, nil)
	limiter := adapter.NewHostLimiter(cfg.HostMinInterval, cfg.MaxParallelHosts)
	httpClient := &http.Client{Timeout: 5 * time.Second}

	ctrl := NewController(cfg, mwClient, httpClient, limiter, time.Now)
	deadline := time.Now().Add(10 * time.Second)

	ctrl.drainPending(context.Background(), deadline)

	alertBatchesMu.Lock()
	defer alertBatchesMu.Unlock()

	// 25 items batched in 10, 10, 5
	if len(alertBatchCounts) != 3 {
		t.Fatalf("expected 3 alert batches, got %d: %v", len(alertBatchCounts), alertBatchCounts)
	}
	if alertBatchCounts[0] != 10 || alertBatchCounts[1] != 10 || alertBatchCounts[2] != 5 {
		t.Errorf("expected batches of [10, 10, 5], got %v", alertBatchCounts)
	}
}

func TestControllerPendingDrainStopsWhenNextCycleDue(t *testing.T) {
	// Fake Core server that never stops returning pending items
	coreServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/api/v1/cap_data/pending":
			items := []adapter.PendingEntry{
				{CAPURL: "https://example.com/alert-1.xml", FeedURL: "https://example.com/feed.xml"},
			}
			_ = json.NewEncoder(w).Encode(map[string]any{"items": items})
		case "/api/v1/cap_data/alerts":
			_, _ = w.Write([]byte(`{"received":1,"deduped":0,"written":1,"dropped":0,"message":"ok"}`))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer coreServer.Close()

	cfg := Config{
		HostMinInterval:  1 * time.Millisecond,
		MaxParallelHosts: 2,
	}
	coreClient := core.NewClient(coreServer.URL+"/api/v1", &http.Client{Timeout: 5 * time.Second})
	mwClient := adapter.NewMatrixWhaleClient(coreClient, nil)
	limiter := adapter.NewHostLimiter(cfg.HostMinInterval, cfg.MaxParallelHosts)

	// Simulated clock that advances past deadline
	currentTime := time.Now()
	clockMu := sync.Mutex{}
	mockNow := func() time.Time {
		clockMu.Lock()
		defer clockMu.Unlock()
		return currentTime
	}

	ctrl := NewController(cfg, mwClient, &http.Client{Timeout: 2 * time.Second}, limiter, mockNow)
	deadline := currentTime.Add(50 * time.Millisecond)

	// Set clock past deadline after 20ms
	go func() {
		time.Sleep(20 * time.Millisecond)
		clockMu.Lock()
		currentTime = currentTime.Add(1 * time.Minute)
		clockMu.Unlock()
	}()

	done := make(chan struct{})
	go func() {
		ctrl.drainPending(context.Background(), deadline)
		close(done)
	}()

	select {
	case <-done:
		// Succeeded: drainPending stopped when deadline expired
	case <-time.After(3 * time.Second):
		t.Fatal("drainPending did not stop when deadline expired")
	}
}

func TestControllerFeedCycleAndRAA(t *testing.T) {
	var raaPosted int32
	var indexPosted int32

	raaServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("If-None-Match") == `"raa-v1"` {
			w.WriteHeader(http.StatusNotModified)
			return
		}
		w.Header().Set("Content-Type", "application/xml")
		w.Header().Set("ETag", `"raa-v1"`)
		_, _ = w.Write([]byte(fixtureRAA))
	}))
	defer raaServer.Close()

	feedServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/xml")
		_, _ = w.Write([]byte(fixtureRSS))
	}))
	defer feedServer.Close()

	coreServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/api/v1/cap_data/registry":
			atomic.AddInt32(&raaPosted, 1)
			_, _ = w.Write([]byte(`{"received":1,"deduped":0,"written":1,"dropped":0,"message":"ok"}`))
		case "/api/v1/cap_data/feeds":
			feeds := []adapter.FeedEntry{
				{URL: feedServer.URL, PollIntervalSeconds: 300},
			}
			_ = json.NewEncoder(w).Encode(map[string]any{"feeds": feeds})
		case "/api/v1/cap_data/index":
			atomic.AddInt32(&indexPosted, 1)
			_, _ = w.Write([]byte(`{"received":1,"deduped":0,"written":1,"dropped":0,"message":"ok"}`))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer coreServer.Close()

	cfg := Config{
		RAAURL:           raaServer.URL,
		PollInterval:     5 * time.Minute,
		RegistryInterval: 24 * time.Hour,
		HostMinInterval:  1 * time.Millisecond,
		MaxParallelHosts: 4,
	}

	coreClient := core.NewClient(coreServer.URL+"/api/v1", &http.Client{Timeout: 5 * time.Second})
	mwClient := adapter.NewMatrixWhaleClient(coreClient, nil)
	limiter := adapter.NewHostLimiter(cfg.HostMinInterval, cfg.MaxParallelHosts)
	httpClient := &http.Client{Timeout: 5 * time.Second}

	ctrl := NewController(cfg, mwClient, httpClient, limiter, time.Now)
	ctx := context.Background()

	// 1. Poll RAA
	ctrl.pollRAA(ctx)
	if atomic.LoadInt32(&raaPosted) != 1 {
		t.Errorf("expected 1 RAA post, got %d", atomic.LoadInt32(&raaPosted))
	}

	// Second RAA poll with 304: should not post to core
	ctrl.pollRAA(ctx)
	if atomic.LoadInt32(&raaPosted) != 1 {
		t.Errorf("expected RAA 304 to not post, got %d", atomic.LoadInt32(&raaPosted))
	}

	// 2. Poll Feed cycle
	ctrl.pollFeedsCycle(ctx, ctrl.now())
	if atomic.LoadInt32(&indexPosted) != 1 {
		t.Errorf("expected 1 index post, got %d", atomic.LoadInt32(&indexPosted))
	}
}

func TestLoadConfig(t *testing.T) {
	_ = os.Setenv("CAP_RAA_URL", "https://custom.raa.org/rss.xml")
	_ = os.Setenv("CAP_POLL_INTERVAL", "10m")
	_ = os.Setenv("CAP_REGISTRY_INTERVAL", "12h")
	_ = os.Setenv("CAP_HOST_MIN_INTERVAL", "3s")
	_ = os.Setenv("CAP_MAX_PARALLEL_HOSTS", "16")
	_ = os.Setenv("CAP_CONTACT_EMAIL", "admin@example.org")
	defer func() {
		_ = os.Unsetenv("CAP_RAA_URL")
		_ = os.Unsetenv("CAP_POLL_INTERVAL")
		_ = os.Unsetenv("CAP_REGISTRY_INTERVAL")
		_ = os.Unsetenv("CAP_HOST_MIN_INTERVAL")
		_ = os.Unsetenv("CAP_MAX_PARALLEL_HOSTS")
		_ = os.Unsetenv("CAP_CONTACT_EMAIL")
	}()

	cfg := LoadConfig()
	if cfg.RAAURL != "https://custom.raa.org/rss.xml" {
		t.Errorf("RAAURL mismatch: %s", cfg.RAAURL)
	}
	if cfg.PollInterval != 10*time.Minute {
		t.Errorf("PollInterval mismatch: %v", cfg.PollInterval)
	}
	if cfg.RegistryInterval != 12*time.Hour {
		t.Errorf("RegistryInterval mismatch: %v", cfg.RegistryInterval)
	}
	if cfg.HostMinInterval != 3*time.Second {
		t.Errorf("HostMinInterval mismatch: %v", cfg.HostMinInterval)
	}
	if cfg.MaxParallelHosts != 16 {
		t.Errorf("MaxParallelHosts mismatch: %d", cfg.MaxParallelHosts)
	}
	if cfg.ContactEmail != "admin@example.org" {
		t.Errorf("ContactEmail mismatch: %s", cfg.ContactEmail)
	}
}

func TestControllerFeedStateRaceDistinctHosts(t *testing.T) {
	// Single httptest server serving RSS feeds for all ~30 hosts
	feedServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/xml")
		w.Header().Set("ETag", `"test-etag"`)
		w.Header().Set("Last-Modified", "Wed, 16 Sep 2026 10:00:00 GMT")
		_, _ = w.Write([]byte(fixtureRSS))
	}))
	defer feedServer.Close()

	const numFeeds = 30
	feeds := make([]adapter.FeedEntry, numFeeds)
	for i := 0; i < numFeeds; i++ {
		feeds[i] = adapter.FeedEntry{
			URL:                 fmt.Sprintf("http://distinct-host-%d.example.com/rss.xml", i),
			PollIntervalSeconds: 300,
		}
	}

	// Fake core server
	var postedCount int32
	coreServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/api/v1/cap_data/feeds":
			_ = json.NewEncoder(w).Encode(map[string]any{"feeds": feeds})
		case "/api/v1/cap_data/index":
			atomic.AddInt32(&postedCount, 1)
			_, _ = w.Write([]byte(`{"received":1,"deduped":0,"written":1,"dropped":0,"message":"ok"}`))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer coreServer.Close()

	// http.Client whose Transport.DialContext always dials the test server's listener
	feedClient := &http.Client{
		Transport: &http.Transport{
			DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
				var d net.Dialer
				return d.DialContext(ctx, "tcp", feedServer.Listener.Addr().String())
			},
		},
		Timeout: 5 * time.Second,
	}

	cfg := Config{
		PollInterval:     5 * time.Minute,
		RegistryInterval: 24 * time.Hour,
		HostMinInterval:  1 * time.Millisecond,
		MaxParallelHosts: 16,
	}

	coreHTTPClient := &http.Client{Timeout: 5 * time.Second}
	coreClient := core.NewClient(coreServer.URL+"/api/v1", coreHTTPClient)
	mwClient := adapter.NewMatrixWhaleClient(coreClient, coreHTTPClient)
	limiter := adapter.NewHostLimiter(cfg.HostMinInterval, cfg.MaxParallelHosts)

	ctrl := NewController(cfg, mwClient, feedClient, limiter, time.Now)

	ctrl.pollFeedsCycle(context.Background(), time.Now())

	if atomic.LoadInt32(&postedCount) != numFeeds {
		t.Fatalf("expected %d index posts, got %d", numFeeds, atomic.LoadInt32(&postedCount))
	}

	ctrl.feedMu.Lock()
	dueLen := len(ctrl.feedDueTimes)
	etagsLen := len(ctrl.feedETags)
	ctrl.feedMu.Unlock()

	if dueLen != numFeeds {
		t.Errorf("expected %d feedDueTimes entries, got %d", numFeeds, dueLen)
	}
	if etagsLen != numFeeds {
		t.Errorf("expected %d feedETags entries, got %d", numFeeds, etagsLen)
	}
}

func TestControllerRAARetryOnFailedRegistryPost(t *testing.T) {
	var raaFetchCount int32
	raaServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&raaFetchCount, 1)
		w.Header().Set("Content-Type", "application/xml")
		w.Header().Set("ETag", `"raa-v1-etag"`)
		w.Header().Set("Last-Modified", "Thu, 17 Sep 2026 06:00:00 GMT")
		_, _ = w.Write([]byte(fixtureRAA))
	}))
	defer raaServer.Close()

	var raaCycle int32
	atomic.StoreInt32(&raaCycle, 1)
	coreServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/api/v1/cap_data/registry":
			if atomic.LoadInt32(&raaCycle) == 1 {
				// Fail the first registry POST (including all retries)
				w.WriteHeader(http.StatusInternalServerError)
				_, _ = w.Write([]byte(`{"error":"temporary db error"}`))
				return
			}
			_, _ = w.Write([]byte(`{"received":1,"deduped":0,"written":1,"dropped":0,"message":"ok"}`))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer coreServer.Close()

	cfg := Config{
		RAAURL:           raaServer.URL,
		PollInterval:     5 * time.Minute,
		RegistryInterval: 24 * time.Hour,
		HostMinInterval:  1 * time.Millisecond,
		MaxParallelHosts: 4,
	}

	simulatedTime := time.Date(2026, 9, 19, 10, 0, 0, 0, time.UTC)
	var timeMu sync.Mutex
	nowFunc := func() time.Time {
		timeMu.Lock()
		defer timeMu.Unlock()
		return simulatedTime
	}

	coreClient := core.NewClient(coreServer.URL+"/api/v1", &http.Client{Timeout: 5 * time.Second})
	mwClient := adapter.NewMatrixWhaleClient(coreClient, nil)
	limiter := adapter.NewHostLimiter(cfg.HostMinInterval, cfg.MaxParallelHosts)
	ctrl := NewController(cfg, mwClient, &http.Client{Timeout: 5 * time.Second}, limiter, nowFunc)
	ctx := context.Background()

	// First attempt: core POST fails
	ctrl.pollRAA(ctx)

	// Since SendRegistry failed, validators and lastRAAFetch MUST NOT be stored
	if !ctrl.lastRAAFetch.IsZero() {
		t.Errorf("expected lastRAAFetch to remain zero after failed POST, got: %v", ctrl.lastRAAFetch)
	}
	if ctrl.raaETag != "" {
		t.Errorf("expected raaETag to be empty after failed POST, got: %s", ctrl.raaETag)
	}
	if ctrl.raaLastModified != "" {
		t.Errorf("expected raaLastModified to be empty after failed POST, got: %s", ctrl.raaLastModified)
	}

	// Advance time by 5 minutes (next feed cycle, NOT 24 hours later)
	timeMu.Lock()
	simulatedTime = simulatedTime.Add(5 * time.Minute)
	timeMu.Unlock()

	// Condition in Execute loop: c.lastRAAFetch.IsZero() || currentTime.Sub(c.lastRAAFetch) >= c.cfg.RegistryInterval
	shouldRetry := ctrl.lastRAAFetch.IsZero() || nowFunc().Sub(ctrl.lastRAAFetch) >= ctrl.cfg.RegistryInterval
	if !shouldRetry {
		t.Fatalf("expected RAA to be due for retry on next feed cycle (5 minutes later)")
	}

	// Second attempt: core POST succeeds
	atomic.StoreInt32(&raaCycle, 2)
	ctrl.pollRAA(ctx)

	if ctrl.lastRAAFetch.IsZero() {
		t.Error("expected lastRAAFetch to be set after successful POST")
	}
	if ctrl.raaETag != `"raa-v1-etag"` {
		t.Errorf("expected raaETag to be 'raa-v1-etag', got: %s", ctrl.raaETag)
	}

	// Advance time by another 5 minutes: now that it succeeded, it should NOT be retried next cycle
	timeMu.Lock()
	simulatedTime = simulatedTime.Add(5 * time.Minute)
	timeMu.Unlock()

	shouldRunAgain := ctrl.lastRAAFetch.IsZero() || nowFunc().Sub(ctrl.lastRAAFetch) >= ctrl.cfg.RegistryInterval
	if shouldRunAgain {
		t.Error("RAA should NOT be retried 5 minutes after a successful POST; must wait 24 hours")
	}
}

func TestControllerFeedDueTimeComputedFromCycleStart(t *testing.T) {
	var polls int32
	feedServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&polls, 1)
		time.Sleep(50 * time.Millisecond) // simulates network/processing delay during request
		w.Header().Set("Content-Type", "application/xml")
		_, _ = w.Write([]byte(fixtureRSS))
	}))
	defer feedServer.Close()

	coreServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/api/v1/cap_data/feeds":
			feeds := []adapter.FeedEntry{
				{URL: feedServer.URL, PollIntervalSeconds: 300}, // 5 minutes
			}
			_ = json.NewEncoder(w).Encode(map[string]any{"feeds": feeds})
		case "/api/v1/cap_data/index":
			_, _ = w.Write([]byte(`{"received":1,"deduped":0,"written":1,"dropped":0,"message":"ok"}`))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer coreServer.Close()

	cfg := Config{
		PollInterval:     5 * time.Minute,
		RegistryInterval: 24 * time.Hour,
		HostMinInterval:  1 * time.Millisecond,
		MaxParallelHosts: 4,
	}

	coreClient := core.NewClient(coreServer.URL+"/api/v1", &http.Client{Timeout: 5 * time.Second})
	mwClient := adapter.NewMatrixWhaleClient(coreClient, nil)
	limiter := adapter.NewHostLimiter(cfg.HostMinInterval, cfg.MaxParallelHosts)
	ctrl := NewController(cfg, mwClient, &http.Client{Timeout: 5 * time.Second}, limiter, time.Now)
	ctx := context.Background()

	// Cycle 1 starts at t0
	t0 := time.Date(2026, 9, 19, 12, 0, 0, 0, time.UTC)
	ctrl.pollFeedsCycle(ctx, t0)

	if atomic.LoadInt32(&polls) != 1 {
		t.Fatalf("expected 1 poll in cycle 1, got %d", atomic.LoadInt32(&polls))
	}

	// Due time must be computed from cycleStart (t0), NOT completion time (t0 + 50ms)
	ctrl.feedMu.Lock()
	dueTime := ctrl.feedDueTimes[feedServer.URL]
	ctrl.feedMu.Unlock()

	expectedDue := t0.Add(5 * time.Minute)
	if !dueTime.Equal(expectedDue) {
		t.Fatalf("expected due time exactly %v (t0 + 5m), got: %v", expectedDue, dueTime)
	}

	// Cycle 2 starts at t0 + 5m (exactly cycle length later)
	t1 := t0.Add(5 * time.Minute)
	ctrl.pollFeedsCycle(ctx, t1)

	if atomic.LoadInt32(&polls) != 2 {
		t.Fatalf("expected feed to be polled in cycle 2 as well, but poll count was %d", atomic.LoadInt32(&polls))
	}
}

func TestControllerMaxParallelHostsBoundsConcurrentDownloads(t *testing.T) {
	const maxParallel = 2
	var currentlyReading int32
	var maxObserved int32

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/xml")
		w.WriteHeader(http.StatusOK)
		if f, ok := w.(http.Flusher); ok {
			f.Flush()
		}
		// Track active body downloads
		cur := atomic.AddInt32(&currentlyReading, 1)
		for {
			old := atomic.LoadInt32(&maxObserved)
			if cur <= old || atomic.CompareAndSwapInt32(&maxObserved, old, cur) {
				break
			}
		}
		time.Sleep(50 * time.Millisecond) // hold download open
		_, _ = w.Write([]byte(fixtureRSS))
		atomic.AddInt32(&currentlyReading, -1)
	}))
	defer server.Close()

	coreServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/api/v1/cap_data/index":
			_, _ = w.Write([]byte(`{"received":1,"deduped":0,"written":1,"dropped":0,"message":"ok"}`))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer coreServer.Close()

	// Route 6 distinct hosts to server
	feedClient := &http.Client{
		Transport: &http.Transport{
			DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
				var d net.Dialer
				return d.DialContext(ctx, "tcp", server.Listener.Addr().String())
			},
		},
		Timeout: 5 * time.Second,
	}

	const numFeeds = 6
	feeds := make([]adapter.FeedEntry, numFeeds)
	for i := 0; i < numFeeds; i++ {
		feeds[i] = adapter.FeedEntry{
			URL:                 fmt.Sprintf("http://download-host-%d.example.com/rss.xml", i),
			PollIntervalSeconds: 300,
		}
	}

	cfg := Config{
		PollInterval:     5 * time.Minute,
		RegistryInterval: 24 * time.Hour,
		HostMinInterval:  1 * time.Millisecond,
		MaxParallelHosts: maxParallel,
	}

	coreClient := core.NewClient(coreServer.URL+"/api/v1", &http.Client{Timeout: 5 * time.Second})
	mwClient := adapter.NewMatrixWhaleClient(coreClient, nil)
	limiter := adapter.NewHostLimiter(cfg.HostMinInterval, cfg.MaxParallelHosts)
	ctrl := NewController(cfg, mwClient, feedClient, limiter, time.Now)

	var wg sync.WaitGroup
	cycleStart := time.Now()
	for _, feed := range feeds {
		wg.Add(1)
		host := adapter.HostFromURL(feed.URL)
		go func(h string, f adapter.FeedEntry) {
			defer wg.Done()
			ctrl.pollSingleFeed(context.Background(), h, f, cycleStart)
		}(host, feed)
	}
	wg.Wait()

	if maxObserved > int32(maxParallel) {
		t.Fatalf("expected at most %d concurrent downloads, observed %d", maxParallel, maxObserved)
	}
	if maxObserved < 2 {
		t.Fatalf("expected at least 2 parallel downloads with %d hosts, observed %d", maxParallel, maxObserved)
	}
}

func TestControllerFeedFailuresPostStatusZeroAndError(t *testing.T) {
	var postedMetaMu sync.Mutex
	var postedMetas []core.PollMeta

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/html":
			w.Header().Set("Content-Type", "text/html")
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(`<!DOCTYPE html><html><body>Error page</body></html>`))
		case "/json":
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(`{"error":"not found"}`))
		case "/parse-error":
			w.Header().Set("Content-Type", "application/xml")
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(`<rss><channel><broken`))
		case "/oversize":
			w.Header().Set("Content-Type", "application/xml")
			w.WriteHeader(http.StatusOK)
			chunk := make([]byte, 1024*1024)
			for i := 0; i < 9; i++ { // 9 MiB > 8 MiB limit
				_, _ = w.Write(chunk)
			}
		}
	}))
	defer server.Close()

	coreServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.URL.Path == "/api/v1/cap_data/index" {
			var env struct {
				PollMeta core.PollMeta `json:"poll_meta"`
			}
			_ = json.NewDecoder(r.Body).Decode(&env)
			postedMetaMu.Lock()
			postedMetas = append(postedMetas, env.PollMeta)
			postedMetaMu.Unlock()
			_, _ = w.Write([]byte(`{"received":0,"deduped":0,"written":0,"dropped":0,"message":"ok"}`))
		}
	}))
	defer coreServer.Close()

	cfg := Config{HostMinInterval: 1 * time.Millisecond, MaxParallelHosts: 4}
	coreClient := core.NewClient(coreServer.URL+"/api/v1", &http.Client{Timeout: 5 * time.Second})
	mwClient := adapter.NewMatrixWhaleClient(coreClient, nil)
	limiter := adapter.NewHostLimiter(cfg.HostMinInterval, cfg.MaxParallelHosts)
	ctrl := NewController(cfg, mwClient, &http.Client{Timeout: 5 * time.Second}, limiter, time.Now)

	cases := []string{"/html", "/json", "/parse-error", "/oversize"}
	for _, p := range cases {
		feed := adapter.FeedEntry{URL: server.URL + p}
		ctrl.pollSingleFeed(context.Background(), adapter.HostFromURL(feed.URL), feed, time.Now())
	}

	postedMetaMu.Lock()
	defer postedMetaMu.Unlock()

	if len(postedMetas) != len(cases) {
		t.Fatalf("expected %d posted failures, got %d", len(cases), len(postedMetas))
	}
	for _, meta := range postedMetas {
		if meta.HTTPStatus != 0 {
			t.Errorf("feed failure for %s expected http_status: 0, got: %d", meta.FeedURL, meta.HTTPStatus)
		}
		if meta.Error == "" {
			t.Errorf("feed failure for %s expected error message, got empty", meta.FeedURL)
		}
	}
}

func TestControllerCAPFailuresPostStatusZeroOrRealStatus(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/html-200":
			w.Header().Set("Content-Type", "text/html")
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(`<!DOCTYPE html><html><body>Non-CAP page</body></html>`))
		case "/oversize":
			w.Header().Set("Content-Type", "application/xml")
			w.WriteHeader(http.StatusOK)
			chunk := make([]byte, 1024*1024)
			for i := 0; i < 9; i++ {
				_, _ = w.Write(chunk)
			}
		case "/status-404":
			w.WriteHeader(http.StatusNotFound)
			_, _ = w.Write([]byte("Not found"))
		}
	}))
	defer server.Close()

	cfg := Config{HostMinInterval: 1 * time.Millisecond, MaxParallelHosts: 4}
	coreClient := core.NewClient("http://127.0.0.1:9999", &http.Client{Timeout: 5 * time.Second})
	mwClient := adapter.NewMatrixWhaleClient(coreClient, nil)
	limiter := adapter.NewHostLimiter(cfg.HostMinInterval, cfg.MaxParallelHosts)
	ctrl := NewController(cfg, mwClient, &http.Client{Timeout: 5 * time.Second}, limiter, time.Now)
	ctx := context.Background()

	// 1. Fully read non-CAP HTML document (HTTP 200) -> keeps real status 200 with cap: null + error
	resNonCAP := ctrl.fetchSingleCAP(ctx, adapter.HostFromURL(server.URL), adapter.PendingEntry{CAPURL: server.URL + "/html-200"})
	if resNonCAP.HTTPStatus != 200 {
		t.Errorf("expected non-CAP 200 to keep HTTP status 200, got: %d", resNonCAP.HTTPStatus)
	}
	if resNonCAP.Cap != nil {
		t.Errorf("expected cap to be null for non-CAP document")
	}
	if resNonCAP.Error == nil || !strings.Contains(*resNonCAP.Error, "not a CAP alert") {
		t.Errorf("expected error message for non-CAP, got: %v", resNonCAP.Error)
	}

	// 2. Read failure / oversize -> status 0 + error
	resOversize := ctrl.fetchSingleCAP(ctx, adapter.HostFromURL(server.URL), adapter.PendingEntry{CAPURL: server.URL + "/oversize"})
	if resOversize.HTTPStatus != 0 {
		t.Errorf("expected oversize CAP fetch to have HTTPStatus 0, got: %d", resOversize.HTTPStatus)
	}
	if resOversize.Error == nil {
		t.Error("expected error for oversize CAP fetch")
	}

	// 3. Network error (connection refused) -> status 0 + error
	resNetwork := ctrl.fetchSingleCAP(ctx, "invalid.local", adapter.PendingEntry{CAPURL: "http://127.0.0.1:1/nonexistent.xml"})
	if resNetwork.HTTPStatus != 0 {
		t.Errorf("expected network error to have HTTPStatus 0, got: %d", resNetwork.HTTPStatus)
	}
	if resNetwork.Error == nil {
		t.Error("expected error for network failure")
	}

	// 4. HTTP 404 -> keeps real status 404 with error
	res404 := ctrl.fetchSingleCAP(ctx, adapter.HostFromURL(server.URL), adapter.PendingEntry{CAPURL: server.URL + "/status-404"})
	if res404.HTTPStatus != 404 {
		t.Errorf("expected 404 to keep HTTPStatus 404, got: %d", res404.HTTPStatus)
	}
	if res404.Cap != nil {
		t.Errorf("expected cap to be null for 404")
	}
}

func TestControllerDrainPendingStopsAfterFailedAlertsPOST(t *testing.T) {
	capServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/cap+xml")
		_, _ = fmt.Fprintf(w, fixtureCAP, 1)
	}))
	defer capServer.Close()

	var alertsPostCalls int32
	var pendingFetchCalls int32
	coreServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/api/v1/cap_data/pending":
			atomic.AddInt32(&pendingFetchCalls, 1)
			items := make([]adapter.PendingEntry, 15)
			for i := 0; i < 15; i++ {
				items[i] = adapter.PendingEntry{CAPURL: capServer.URL, FeedURL: "https://example.com/feed"}
			}
			_ = json.NewEncoder(w).Encode(map[string]any{"items": items})
		case "/api/v1/cap_data/alerts":
			atomic.AddInt32(&alertsPostCalls, 1)
			w.WriteHeader(http.StatusInternalServerError)
			_, _ = w.Write([]byte(`{"error":"failed to store alerts"}`))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer coreServer.Close()

	cfg := Config{HostMinInterval: 1 * time.Millisecond, MaxParallelHosts: 4}
	coreClient := core.NewClient(coreServer.URL+"/api/v1", &http.Client{Timeout: 5 * time.Second})
	mwClient := adapter.NewMatrixWhaleClient(coreClient, nil)
	limiter := adapter.NewHostLimiter(cfg.HostMinInterval, cfg.MaxParallelHosts)
	ctrl := NewController(cfg, mwClient, &http.Client{Timeout: 5 * time.Second}, limiter, time.Now)

	deadline := time.Now().Add(10 * time.Second)
	ctrl.drainPending(context.Background(), deadline)

	// Draining must stop immediately after the failed alerts POST.
	// It should NOT perform another pending fetch in this cycle.
	if atomic.LoadInt32(&pendingFetchCalls) != 1 {
		t.Errorf("expected exactly 1 pending fetch before aborting, got %d", atomic.LoadInt32(&pendingFetchCalls))
	}
	if atomic.LoadInt32(&alertsPostCalls) != 3 {
		t.Errorf("expected 3 alerts POST attempts (retries) before aborting, got %d", atomic.LoadInt32(&alertsPostCalls))
	}
}

func TestControllerAlertBatchCappedBySize(t *testing.T) {
	var alertBatchesMu sync.Mutex
	var batchCounts []int

	// CAP server serves 3 large alerts of ~6 MiB each
	largeDesc := strings.Repeat("A", 6<<20)
	capXML := fmt.Sprintf(`<?xml version="1.0" encoding="UTF-8"?>
<alert xmlns="urn:oasis:names:tc:emergency:cap:1.2">
  <identifier>LARGE-ALERT</identifier>
  <sender>test@example.org</sender>
  <sent>2026-09-17T12:00:00Z</sent>
  <status>Actual</status>
  <msgType>Alert</msgType>
  <scope>Public</scope>
  <info>
    <category>Met</category>
    <event>Large Alert</event>
    <urgency>Immediate</urgency>
    <severity>Severe</severity>
    <certainty>Observed</certainty>
    <description>%s</description>
    <area><areaDesc>Test Area</areaDesc></area>
  </info>
</alert>`, largeDesc)

	capServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/cap+xml")
		_, _ = w.Write([]byte(capXML))
	}))
	defer capServer.Close()

	var pendingCalls int32
	coreServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/api/v1/cap_data/pending":
			call := atomic.AddInt32(&pendingCalls, 1)
			if call == 1 {
				items := []adapter.PendingEntry{
					{CAPURL: capServer.URL + "/alert-1.xml", FeedURL: "https://example.com/feed"},
					{CAPURL: capServer.URL + "/alert-2.xml", FeedURL: "https://example.com/feed"},
					{CAPURL: capServer.URL + "/alert-3.xml", FeedURL: "https://example.com/feed"},
				}
				_ = json.NewEncoder(w).Encode(map[string]any{"items": items})
			} else {
				_ = json.NewEncoder(w).Encode(map[string]any{"items": []adapter.PendingEntry{}})
			}
		case "/api/v1/cap_data/alerts":
			var env struct {
				Features []adapter.AlertResult `json:"features"`
			}
			_ = json.NewDecoder(r.Body).Decode(&env)
			alertBatchesMu.Lock()
			batchCounts = append(batchCounts, len(env.Features))
			alertBatchesMu.Unlock()
			ack := fmt.Sprintf(`{"received":%d,"deduped":0,"written":%d,"dropped":0,"message":"ok"}`,
				len(env.Features), len(env.Features))
			_, _ = w.Write([]byte(ack))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer coreServer.Close()

	cfg := Config{HostMinInterval: 1 * time.Millisecond, MaxParallelHosts: 4}
	coreClient := core.NewClient(coreServer.URL+"/api/v1", &http.Client{Timeout: 5 * time.Second})
	mwClient := adapter.NewMatrixWhaleClient(coreClient, nil)
	limiter := adapter.NewHostLimiter(cfg.HostMinInterval, cfg.MaxParallelHosts)
	ctrl := NewController(cfg, mwClient, &http.Client{Timeout: 5 * time.Second}, limiter, time.Now)

	ctrl.drainPending(context.Background(), time.Now().Add(5*time.Second))

	alertBatchesMu.Lock()
	defer alertBatchesMu.Unlock()

	if len(batchCounts) != 2 || batchCounts[0] != 2 || batchCounts[1] != 1 {
		t.Fatalf("expected batches [2, 1] due to 16 MiB cap, got %v", batchCounts)
	}
}

func TestSanitizeRawXMLNULStrippingAndTrailingDrop(t *testing.T) {
	input := "<?xml version=\"1.0\"?>\x00<alert>\x00<!-- inner comment with <b>bold</b> -->\x00<identifier>TEST</identifier></alert>\x00\n<!-- trailing comment containing </b> and extra text -->\x00\ntrailing junk outside xml\n"
	sanitized := sanitizeRawXML(&input)
	if sanitized == nil {
		t.Fatal("expected non-nil sanitized string")
	}
	v := *sanitized

	if strings.Contains(v, "\x00") {
		t.Errorf("sanitized XML must not contain NUL bytes: %q", v)
	}
	if strings.Contains(v, "trailing comment") || strings.Contains(v, "trailing junk") {
		t.Errorf("sanitized XML should not contain trailing comment or junk: %q", v)
	}
	if !strings.Contains(v, "<!-- inner comment with <b>bold</b> -->") {
		t.Errorf("sanitized XML must preserve inner comments: %q", v)
	}
	expected := "<?xml version=\"1.0\"?><alert><!-- inner comment with <b>bold</b> --><identifier>TEST</identifier></alert>"
	if v != expected {
		t.Errorf("expected %q, got %q", expected, v)
	}
}

func TestControllerFeedRetryOnFailedIndexPost(t *testing.T) {
	var feedPolls int32
	var lastIfNoneMatch string
	var headerMu sync.Mutex

	feedServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&feedPolls, 1)
		headerMu.Lock()
		lastIfNoneMatch = r.Header.Get("If-None-Match")
		headerMu.Unlock()

		if r.Header.Get("If-None-Match") == `"etag-v1"` {
			w.WriteHeader(http.StatusNotModified)
			return
		}
		w.Header().Set("Content-Type", "application/xml")
		w.Header().Set("ETag", `"etag-v1"`)
		w.Header().Set("Last-Modified", "Wed, 16 Sep 2026 10:00:00 GMT")
		_, _ = w.Write([]byte(fixtureRSS))
	}))
	defer feedServer.Close()

	var indexPostAttempts int32
	var indexPostSuccesses int32
	coreServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/api/v1/cap_data/feeds":
			feeds := []adapter.FeedEntry{
				{URL: feedServer.URL, PollIntervalSeconds: 300},
			}
			_ = json.NewEncoder(w).Encode(map[string]any{"feeds": feeds})
		case "/api/v1/cap_data/index":
			attempt := atomic.AddInt32(&indexPostAttempts, 1)
			if attempt <= 3 { // Core client retries up to 3 times on 500
				w.WriteHeader(http.StatusInternalServerError)
				_, _ = w.Write([]byte(`{"error":"db failure"}`))
				return
			}
			atomic.AddInt32(&indexPostSuccesses, 1)
			_, _ = w.Write([]byte(`{"received":1,"deduped":0,"written":1,"dropped":0,"message":"ok"}`))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer coreServer.Close()

	cfg := Config{
		PollInterval:     5 * time.Minute,
		RegistryInterval: 24 * time.Hour,
		HostMinInterval:  1 * time.Millisecond,
		MaxParallelHosts: 4,
	}

	coreClient := core.NewClient(coreServer.URL+"/api/v1", &http.Client{Timeout: 5 * time.Second})
	mwClient := adapter.NewMatrixWhaleClient(coreClient, nil)
	limiter := adapter.NewHostLimiter(cfg.HostMinInterval, cfg.MaxParallelHosts)
	ctrl := NewController(cfg, mwClient, &http.Client{Timeout: 5 * time.Second}, limiter, time.Now)
	ctx := context.Background()

	// Poll 1: SendIndex fails after retries
	t0 := time.Date(2026, 9, 19, 10, 0, 0, 0, time.UTC)
	ctrl.pollFeedsCycle(ctx, t0)

	// Since SendIndex failed, feedETags and feedLastModified MUST NOT be stored
	ctrl.feedMu.Lock()
	savedETag := ctrl.feedETags[feedServer.URL]
	savedLM := ctrl.feedLastModified[feedServer.URL]
	ctrl.feedMu.Unlock()

	if savedETag != "" {
		t.Fatalf("expected feedETag to remain empty after failed index POST, got: %s", savedETag)
	}
	if savedLM != "" {
		t.Fatalf("expected feedLastModified to remain empty after failed index POST, got: %s", savedLM)
	}

	// Poll 2: Next poll must be unconditional (no If-None-Match header)
	t1 := t0.Add(5 * time.Minute)
	ctrl.pollFeedsCycle(ctx, t1)

	headerMu.Lock()
	sentHeader := lastIfNoneMatch
	headerMu.Unlock()

	if sentHeader != "" {
		t.Fatalf("expected next poll to be unconditional (empty If-None-Match), got: %s", sentHeader)
	}

	if atomic.LoadInt32(&indexPostSuccesses) != 1 {
		t.Fatalf("expected index POST to succeed and deliver items on next poll, successes: %d", atomic.LoadInt32(&indexPostSuccesses))
	}

	// After successful POST, validators MUST be saved
	ctrl.feedMu.Lock()
	savedETag = ctrl.feedETags[feedServer.URL]
	savedLM = ctrl.feedLastModified[feedServer.URL]
	ctrl.feedMu.Unlock()

	if savedETag != `"etag-v1"` {
		t.Fatalf("expected feedETags to be 'etag-v1' after successful POST, got: %s", savedETag)
	}
	if savedLM != "Wed, 16 Sep 2026 10:00:00 GMT" {
		t.Fatalf("expected feedLastModified to be set after successful POST, got: %s", savedLM)
	}

	// Poll 3: With validators saved, feed server receives conditional GET and responds 304
	t2 := t1.Add(5 * time.Minute)
	ctrl.pollFeedsCycle(ctx, t2)

	headerMu.Lock()
	sentHeader = lastIfNoneMatch
	headerMu.Unlock()

	if sentHeader != `"etag-v1"` {
		t.Fatalf("expected third poll to send If-None-Match 'etag-v1', got: %s", sentHeader)
	}
}

func TestControllerFeedDeadlineAllowsPendingDrainWithSlowHost(t *testing.T) {
	// Slow feed server simulates hanging feeds
	slowServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		<-r.Context().Done() // hangs until request context is cancelled
	}))
	defer slowServer.Close()

	var pendingCalled int32
	coreServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/api/v1/cap_data/feeds":
			feeds := []adapter.FeedEntry{
				{URL: slowServer.URL, PollIntervalSeconds: 60},
			}
			_ = json.NewEncoder(w).Encode(map[string]any{"feeds": feeds})
		case "/api/v1/cap_data/pending":
			atomic.AddInt32(&pendingCalled, 1)
			_ = json.NewEncoder(w).Encode(map[string]any{"items": []adapter.PendingEntry{}})
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer coreServer.Close()

	cfg := Config{
		PollInterval:     300 * time.Millisecond,
		RegistryInterval: 24 * time.Hour,
		HostMinInterval:  1 * time.Millisecond,
		MaxParallelHosts: 4,
	}

	coreClient := core.NewClient(coreServer.URL+"/api/v1", &http.Client{Timeout: 5 * time.Second})
	mwClient := adapter.NewMatrixWhaleClient(coreClient, nil)
	limiter := adapter.NewHostLimiter(cfg.HostMinInterval, cfg.MaxParallelHosts)
	ctrl := NewController(cfg, mwClient, &http.Client{Timeout: 5 * time.Second}, limiter, time.Now)

	ctx := context.Background()
	cycleStart := time.Now()
	cycleDeadline := cycleStart.Add(cfg.PollInterval)

	// Hard deadline at 60% of PollInterval (180ms)
	ctrl.pollFeedsCycle(ctx, cycleStart)

	feedDuration := time.Since(cycleStart)
	if feedDuration >= cfg.PollInterval {
		t.Fatalf("feed polling overran the entire poll interval: took %v", feedDuration)
	}

	// Drain pending runs with remaining time before cycleDeadline
	ctrl.drainPending(ctx, cycleDeadline)

	if atomic.LoadInt32(&pendingCalled) == 0 {
		t.Fatalf("expected /pending to be called during cycle despite slow feed host")
	}

	// Feeds not completed stay due for next cycle (due time not set to future interval)
	ctrl.feedMu.Lock()
	due, exists := ctrl.feedDueTimes[slowServer.URL]
	ctrl.feedMu.Unlock()
	if exists && due.After(time.Now()) {
		t.Fatalf("aborted feed should remain due for next cycle, got due time: %v", due)
	}
}

func TestControllerWorkersCancelledOnFailedAlertsPOST(t *testing.T) {
	var capRequests int32
	capServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&capRequests, 1)
		select {
		case <-time.After(50 * time.Millisecond):
		case <-r.Context().Done():
			return
		}
		w.Header().Set("Content-Type", "application/cap+xml")
		_, _ = w.Write([]byte(fixtureCAP))
	}))
	defer capServer.Close()

	coreServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/api/v1/cap_data/pending":
			// Return 60 items across 6 hosts (10 items per host)
			items := make([]adapter.PendingEntry, 60)
			for i := 0; i < 60; i++ {
				items[i] = adapter.PendingEntry{
					CAPURL:  fmt.Sprintf("%s/host-%d/alert-%d.xml", capServer.URL, i%6, i),
					FeedURL: "https://example.com/feed",
				}
			}
			_ = json.NewEncoder(w).Encode(map[string]any{"items": items})
		case "/api/v1/cap_data/alerts":
			// Fail immediately on the first alerts batch POST
			w.WriteHeader(http.StatusInternalServerError)
			_, _ = w.Write([]byte(`{"error":"database unavailable"}`))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer coreServer.Close()

	cfg := Config{HostMinInterval: 1 * time.Millisecond, MaxParallelHosts: 6}
	coreClient := core.NewClient(coreServer.URL+"/api/v1", &http.Client{Timeout: 5 * time.Second})
	mwClient := adapter.NewMatrixWhaleClient(coreClient, nil)
	limiter := adapter.NewHostLimiter(cfg.HostMinInterval, cfg.MaxParallelHosts)
	ctrl := NewController(cfg, mwClient, &http.Client{Timeout: 5 * time.Second}, limiter, time.Now)

	deadline := time.Now().Add(5 * time.Second)
	ctrl.drainPending(context.Background(), deadline)

	// Capture count right after drainPending finishes
	countAfterDrain := atomic.LoadInt32(&capRequests)

	// Wait to verify no further CAP GETs are initiated by background workers
	time.Sleep(100 * time.Millisecond)
	countAfterWait := atomic.LoadInt32(&capRequests)

	if countAfterWait != countAfterDrain {
		t.Fatalf("expected no further CAP GETs after worker cancellation: before wait %d, after wait %d",
			countAfterDrain, countAfterWait)
	}
	if countAfterWait >= 60 {
		t.Fatalf("expected workers to be cancelled before fetching all 60 items, fetched %d", countAfterWait)
	}
}

func TestFeedFetchHTTPStatusHandling(t *testing.T) {
	var etagSent, ifModifiedSinceSent string
	var headerMu sync.Mutex

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		headerMu.Lock()
		etagSent = r.Header.Get("If-None-Match")
		ifModifiedSinceSent = r.Header.Get("If-Modified-Since")
		headerMu.Unlock()

		switch r.URL.Path {
		case "/304":
			w.WriteHeader(http.StatusNotModified)
		case "/404":
			w.WriteHeader(http.StatusNotFound)
			_, _ = w.Write([]byte("Not Found"))
		case "/oversize":
			w.Header().Set("Content-Type", "application/xml")
			// write 9 MiB (> 8 MiB MaxBodyBytes)
			chunk := make([]byte, 1024*1024)
			for i := 0; i < 9; i++ {
				_, _ = w.Write(chunk)
			}
		default:
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(fixtureRSS))
		}
	}))
	defer server.Close()

	var postedMetasMu sync.Mutex
	var postedMetas []core.PollMeta

	coreServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.URL.Path == "/api/v1/cap_data/index" {
			var env struct {
				PollMeta core.PollMeta `json:"poll_meta"`
			}
			_ = json.NewDecoder(r.Body).Decode(&env)
			postedMetasMu.Lock()
			postedMetas = append(postedMetas, env.PollMeta)
			postedMetasMu.Unlock()
			_, _ = w.Write([]byte(`{"received":0,"deduped":0,"written":0,"dropped":0,"message":"ok"}`))
		} else {
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer coreServer.Close()

	cfg := Config{
		PollInterval:     5 * time.Minute,
		RegistryInterval: 24 * time.Hour,
		HostMinInterval:  1 * time.Millisecond,
		MaxParallelHosts: 4,
	}

	coreClient := core.NewClient(coreServer.URL+"/api/v1", &http.Client{Timeout: 5 * time.Second})
	mwClient := adapter.NewMatrixWhaleClient(coreClient, nil)
	limiter := adapter.NewHostLimiter(cfg.HostMinInterval, cfg.MaxParallelHosts)
	ctrl := NewController(cfg, mwClient, &http.Client{Timeout: 5 * time.Second}, limiter, time.Now)
	ctx := context.Background()
	cycleStart := time.Now()

	// 1. Test 304 Not Modified via controller path
	ctrl.feedMu.Lock()
	ctrl.feedETags[server.URL+"/304"] = `"abc-etag"`
	ctrl.feedLastModified[server.URL+"/304"] = "Wed, 16 Sep 2026 09:00:00 GMT"
	ctrl.feedLastFormat[server.URL+"/304"] = adapter.FormatRSS
	ctrl.feedMu.Unlock()

	feed304 := adapter.FeedEntry{URL: server.URL + "/304", PollIntervalSeconds: 300}
	ctrl.pollSingleFeed(ctx, adapter.HostFromURL(feed304.URL), feed304, cycleStart)

	headerMu.Lock()
	sentE := etagSent
	sentLM := ifModifiedSinceSent
	headerMu.Unlock()

	if sentE != `"abc-etag"` || sentLM != "Wed, 16 Sep 2026 09:00:00 GMT" {
		t.Errorf("validators not passed correctly to feed server: etag=%s, ims=%s", sentE, sentLM)
	}

	postedMetasMu.Lock()
	if len(postedMetas) != 1 {
		t.Fatalf("expected 1 posted meta for 304, got %d", len(postedMetas))
	}
	meta304 := postedMetas[0]
	postedMetasMu.Unlock()

	if meta304.HTTPStatus != http.StatusNotModified {
		t.Errorf("304 meta expected status 304, got %d", meta304.HTTPStatus)
	}
	if meta304.Bytes != 0 || meta304.FeatureCount != 0 {
		t.Errorf("304 meta expected 0 bytes and 0 features, got %d bytes, %d features", meta304.Bytes, meta304.FeatureCount)
	}
	if meta304.Format != adapter.FormatRSS {
		t.Errorf("304 meta expected last format 'rss', got %s", meta304.Format)
	}

	// 2. Test 404 Not Found via controller path
	feed404 := adapter.FeedEntry{URL: server.URL + "/404", PollIntervalSeconds: 300}
	ctrl.pollSingleFeed(ctx, adapter.HostFromURL(feed404.URL), feed404, cycleStart)

	postedMetasMu.Lock()
	if len(postedMetas) != 2 {
		t.Fatalf("expected 2 posted metas, got %d", len(postedMetas))
	}
	meta404 := postedMetas[1]
	postedMetasMu.Unlock()

	if meta404.HTTPStatus != http.StatusNotFound {
		t.Errorf("404 meta expected status 404, got %d", meta404.HTTPStatus)
	}
	if meta404.Format != adapter.FormatOther {
		t.Errorf("404 meta expected format 'other', got %s", meta404.Format)
	}
	if meta404.Error != "HTTP 404" {
		t.Errorf("404 meta expected error 'HTTP 404', got %q", meta404.Error)
	}

	// 3. Test Oversized body (> 8 MiB) via controller path
	feedOversize := adapter.FeedEntry{URL: server.URL + "/oversize", PollIntervalSeconds: 300}
	ctrl.pollSingleFeed(ctx, adapter.HostFromURL(feedOversize.URL), feedOversize, cycleStart)

	postedMetasMu.Lock()
	if len(postedMetas) != 3 {
		t.Fatalf("expected 3 posted metas, got %d", len(postedMetas))
	}
	metaOversize := postedMetas[2]
	postedMetasMu.Unlock()

	// Per contract §5.3, status 0 for read/oversize failures
	if metaOversize.HTTPStatus != 0 {
		t.Errorf("oversize meta expected status 0, got %d", metaOversize.HTTPStatus)
	}
	if !strings.Contains(metaOversize.Error, "exceeds") {
		t.Errorf("oversize meta expected error mentioning exceeds limit, got %q", metaOversize.Error)
	}
}
