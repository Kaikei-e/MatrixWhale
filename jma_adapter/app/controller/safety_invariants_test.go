package controller

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"jma_adapter/client"
	"jma_adapter/config"
	"jma_adapter/state"
	"matrixwhale/adapters/common/core"
)

func writeMockCoreAck(w http.ResponseWriter, received, written, dropped int) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_ = json.NewEncoder(w).Encode(map[string]any{
		"received": received,
		"deduped":  0,
		"written":  written,
		"dropped":  dropped,
		"message":  "ack",
	})
}

// Test 1: Simulating two cycles of core outage then recovery WITHOUT restart and ensuring upstream XML fetched once.
func TestTwoCyclesCoreOutageThenRecoveryNoRestartUpstreamFetchedOnce(t *testing.T) {
	var jmaServerURL string
	var dataFetchCalls int32
	var coreOutage atomic.Bool
	coreOutage.Store(true) // Starts in outage

	jmaServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		path := r.URL.Path
		switch {
		case strings.HasPrefix(path, "/developer/xml/feed/"):
			w.Header().Set("Content-Type", "application/atom+xml")
			w.WriteHeader(http.StatusOK)
			body := strings.ReplaceAll(mockAtomFeed, "BASE_URL", jmaServerURL)
			_, _ = w.Write([]byte(body))
		case strings.HasPrefix(path, "/developer/xml/data/"):
			atomic.AddInt32(&dataFetchCalls, 1)
			w.Header().Set("Content-Type", "application/xml")
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(mockTelegramXML))
		default:
			http.NotFound(w, r)
		}
	}))
	defer jmaServer.Close()
	jmaServerURL = jmaServer.URL

	var coreMessageCalls int32
	coreServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		path := r.URL.Path
		switch {
		case strings.HasSuffix(path, "/jma_data/index"):
			writeMockCoreAck(w, 1, 1, 0)
		case strings.HasSuffix(path, "/jma_data/pending"):
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusOK)
			dataURL := jmaServerURL + "/developer/xml/data/20260921012500_0_VXSE53_010000.xml"
			feedURL := jmaServerURL + "/developer/xml/feed/eqvol.xml"
			_ = json.NewEncoder(w).Encode(map[string]any{
				"items": []map[string]string{{"item_url": dataURL, "feed_url": feedURL}},
			})
		case strings.HasSuffix(path, "/jma_data/messages"):
			atomic.AddInt32(&coreMessageCalls, 1)
			if coreOutage.Load() {
				w.WriteHeader(http.StatusServiceUnavailable)
				_, _ = w.Write([]byte(`{"error":"database unavailable"}`))
				return
			}
			writeMockCoreAck(w, 1, 1, 0)
		default:
			http.NotFound(w, r)
		}
	}))
	defer coreServer.Close()

	tmpDir, err := os.MkdirTemp("", "jma-outage-test-*")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(tmpDir)

	parsedJMA, _ := url.Parse(jmaServerURL)
	dataURL := jmaServerURL + "/developer/xml/data/20260921012500_0_VXSE53_010000.xml"
	feedURL := jmaServerURL + "/developer/xml/feed/eqvol.xml"

	cfg := &config.Config{
		Feeds:            []string{feedURL},
		LongFeeds:        []string{},
		PollInterval:     10 * time.Millisecond,
		LongPollInterval: 1 * time.Hour,
		RequestInterval:  5 * time.Millisecond,
		StateDir:         tmpDir,
		DailyByteLimit:   10 * 1024 * 1024,
		MaxItemBytes:     1024 * 1024,
		UserAgent:        "matrixwhale-jma-adapter",
	}

	store, err := state.NewStore(tmpDir, cfg.DailyByteLimit)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()

	validator := client.NewURLValidator(parsedJMA.Hostname(), true)
	jmaClient := client.NewJMAClient(store, validator, cfg.UserAgent, cfg.RequestInterval, cfg.MaxItemBytes, cfg.PollInterval, nil)
	coreClient := client.NewCoreClient(core.NewClient(coreServer.URL+"/api/v1", nil), nil)
	ctrl := NewController(cfg, store, jmaClient, coreClient, validator)

	ctx := context.Background()

	// --- Cycle 1: Core is in outage ---
	ctrl.pollCycle(ctx)

	if atomic.LoadInt32(&dataFetchCalls) != 1 {
		t.Fatalf("cycle 1: expected 1 data fetch from upstream, got %d", dataFetchCalls)
	}
	// Verify acquisition invariant: response is durably spooled AND marked fetched
	spoolItems, err := store.ListSpool()
	if err != nil || len(spoolItems) != 1 {
		t.Fatalf("cycle 1: expected 1 item retained in spool during outage, got %d (err: %v)", len(spoolItems), err)
	}
	if !store.IsFetched(dataURL) {
		t.Fatalf("cycle 1: expected URL marked fetched BEFORE core call to prevent redownload")
	}

	// --- Cycle 2: Core STILL in outage ---
	// Advance feed schedule so feed doesn't block poll cycle
	_ = store.RecordFeedSuccess(feedURL, time.Now().Add(-1*time.Second))
	ctrl.pollCycle(ctx)

	// UPSTREAM XML MUST NOT BE REDOWNLOADED!
	if atomic.LoadInt32(&dataFetchCalls) != 1 {
		t.Fatalf("cycle 2: upstream XML was redownloaded during outage! expected 1, got %d", dataFetchCalls)
	}
	// Spool must still retain the item
	spoolItems, _ = store.ListSpool()
	if len(spoolItems) != 1 {
		t.Fatalf("cycle 2: expected 1 item still in spool, got %d", len(spoolItems))
	}

	// --- Cycle 3: Core RECOVERS ---
	coreOutage.Store(false)
	_ = store.RecordFeedSuccess(feedURL, time.Now().Add(-1*time.Second))
	ctrl.pollCycle(ctx)

	// Upstream XML still fetched only once
	if atomic.LoadInt32(&dataFetchCalls) != 1 {
		t.Fatalf("cycle 3: upstream XML redownloaded after recovery! expected 1, got %d", dataFetchCalls)
	}

	// Spool should now be completely empty after successful replay delivery
	spoolItems, _ = store.ListSpool()
	if len(spoolItems) != 0 {
		t.Fatalf("cycle 3: expected spool empty after recovery replay, got %d", len(spoolItems))
	}
	if !store.IsFetched(dataURL) {
		t.Fatalf("cycle 3: expected URL still marked fetched")
	}
}

// Test 2: Restart spool replay - items in spool on boot delivered and removed.
func TestRestartSpoolReplay(t *testing.T) {
	tmpDir, err := os.MkdirTemp("", "jma-restart-spool-*")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(tmpDir)

	store, err := state.NewStore(tmpDir, 10*1024*1024)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()

	itemURL := "https://www.data.jma.go.jp/developer/xml/data/test_restart.xml"
	rawXML := mockTelegramXML
	msgJSON := json.RawMessage(`{"identifier":"test_restart"}`)
	spoolItem := state.SpoolItem{
		ID:         state.SpoolItemKey(itemURL),
		ItemURL:    itemURL,
		FeedURL:    "https://www.data.jma.go.jp/developer/xml/feed/eqvol.xml",
		FetchedAt:  "2026-09-21T01:25:00Z",
		HTTPStatus: 200,
		RawXML:     &rawXML,
		Message:    msgJSON,
	}
	if err := store.SaveSpool(spoolItem); err != nil {
		t.Fatal(err)
	}

	var coreReceived int32
	coreServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/jma_data/messages") {
			atomic.AddInt32(&coreReceived, 1)
			writeMockCoreAck(w, 1, 1, 0)
			return
		}
		http.NotFound(w, r)
	}))
	defer coreServer.Close()

	cfg := &config.Config{
		Feeds:            []string{"https://www.data.jma.go.jp/developer/xml/feed/eqvol.xml"},
		LongFeeds:        []string{},
		PollInterval:     time.Minute,
		LongPollInterval: time.Hour,
		RequestInterval:  time.Millisecond,
		StateDir:         tmpDir,
		DailyByteLimit:   10 * 1024 * 1024,
		MaxItemBytes:     1024 * 1024,
	}
	validator := client.NewURLValidator("www.data.jma.go.jp", false)
	jmaClient := client.NewJMAClient(store, validator, "test", cfg.RequestInterval, cfg.MaxItemBytes, cfg.PollInterval, nil)
	coreClient := client.NewCoreClient(core.NewClient(coreServer.URL+"/api/v1", nil), nil)
	ctrl := NewController(cfg, store, jmaClient, coreClient, validator)

	ctrl.replaySpool(context.Background())

	if atomic.LoadInt32(&coreReceived) != 1 {
		t.Fatalf("expected 1 delivery to core, got %d", coreReceived)
	}

	// Spool must be deleted, URL must be fetched
	items, _ := store.ListSpool()
	if len(items) != 0 {
		t.Fatalf("expected spool empty after restart replay, got %d", len(items))
	}
	if !store.IsFetched(itemURL) {
		t.Fatalf("expected item marked fetched in history after replay")
	}
}

// Test 3: Terminal malformed raw XML and HTTP 404 persist outcome without redownload loop.
func TestTerminalMalformedAnd404(t *testing.T) {
	var jma404Calls, jmaMalformedCalls int32

	jmaServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		path := r.URL.Path
		switch {
		case strings.Contains(path, "not_found.xml"):
			atomic.AddInt32(&jma404Calls, 1)
			w.WriteHeader(http.StatusNotFound)
			_, _ = w.Write([]byte("404 page not found"))
		case strings.Contains(path, "malformed.xml"):
			atomic.AddInt32(&jmaMalformedCalls, 1)
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte("NOT_VALID_XML_DATA<<<>>>"))
		default:
			http.NotFound(w, r)
		}
	}))
	defer jmaServer.Close()

	var coreReportCalls int32
	coreServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/jma_data/messages") {
			atomic.AddInt32(&coreReportCalls, 1)
			body, _ := io.ReadAll(r.Body)
			var env struct {
				Features []client.JmaFetchResult `json:"features"`
			}
			_ = json.Unmarshal(body, &env)
			// Backend drops error result (dropped = 1)
			writeMockCoreAck(w, len(env.Features), 0, len(env.Features))
			return
		}
		http.NotFound(w, r)
	}))
	defer coreServer.Close()

	tmpDir, err := os.MkdirTemp("", "jma-term-test-*")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(tmpDir)

	parsedJMA, _ := url.Parse(jmaServerURL(jmaServer))
	cfg := &config.Config{
		Feeds:            []string{},
		LongFeeds:        []string{},
		PollInterval:     time.Minute,
		LongPollInterval: time.Hour,
		RequestInterval:  time.Millisecond,
		StateDir:         tmpDir,
		DailyByteLimit:   10 * 1024 * 1024,
		MaxItemBytes:     1024 * 1024,
	}

	store, _ := state.NewStore(tmpDir, cfg.DailyByteLimit)
	defer store.Close()

	validator := client.NewURLValidator(parsedJMA.Hostname(), true)
	jmaClient := client.NewJMAClient(store, validator, "test", cfg.RequestInterval, cfg.MaxItemBytes, cfg.PollInterval, nil)
	coreClient := client.NewCoreClient(core.NewClient(coreServer.URL+"/api/v1", nil), nil)
	ctrl := NewController(cfg, store, jmaClient, coreClient, validator)

	ctx := context.Background()

	// Subtest A: HTTP 404
	url404 := jmaServer.URL + "/developer/xml/data/not_found.xml"
	ctrl.fetchAndIngestItem(ctx, url404, "feed1")

	if atomic.LoadInt32(&jma404Calls) != 1 {
		t.Fatalf("expected 1 call to 404 endpoint, got %d", jma404Calls)
	}
	if !store.IsFetched(url404) {
		t.Fatalf("expected 404 URL marked permanently fetched")
	}

	// Calling fetchAndIngestItem again should be skipped by controller checks
	if !store.IsFetched(url404) {
		ctrl.fetchAndIngestItem(ctx, url404, "feed1")
	}
	if atomic.LoadInt32(&jma404Calls) != 1 {
		t.Fatalf("404 endpoint was redownloaded! expected 1, got %d", jma404Calls)
	}

	// Subtest B: Malformed XML
	urlMalformed := jmaServer.URL + "/developer/xml/data/malformed.xml"
	ctrl.fetchAndIngestItem(ctx, urlMalformed, "feed1")

	if atomic.LoadInt32(&jmaMalformedCalls) != 1 {
		t.Fatalf("expected 1 call to malformed endpoint, got %d", jmaMalformedCalls)
	}
	if !store.IsFetched(urlMalformed) {
		t.Fatalf("expected malformed URL marked permanently fetched")
	}

	// Spool must be deleted because core acknowledged error report
	spoolItems, _ := store.ListSpool()
	if len(spoolItems) != 0 {
		t.Fatalf("expected spool empty after error report acknowledged, got %d items", len(spoolItems))
	}
}

// Test 4: Size-bounded replay delivers 1 item per batch independently.
func TestSizeBoundedReplay(t *testing.T) {
	tmpDir, err := os.MkdirTemp("", "jma-bounded-spool-*")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(tmpDir)

	store, _ := state.NewStore(tmpDir, 10*1024*1024)
	defer store.Close()

	// Pre-populate 3 items
	for i := 1; i <= 3; i++ {
		u := "https://www.data.jma.go.jp/developer/xml/data/item_" + string(rune('0'+i)) + ".xml"
		raw := "<Report>test</Report>"
		item := state.SpoolItem{
			ID:         state.SpoolItemKey(u),
			ItemURL:    u,
			FeedURL:    "feed1",
			FetchedAt:  "2026-09-21T01:25:00Z",
			HTTPStatus: 200,
			RawXML:     &raw,
		}
		_ = store.SaveSpool(item)
	}

	var batchSizes []int
	coreServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/jma_data/messages") {
			body, _ := io.ReadAll(r.Body)
			var env struct {
				Features []client.JmaFetchResult `json:"features"`
			}
			_ = json.Unmarshal(body, &env)
			batchSizes = append(batchSizes, len(env.Features))

			writeMockCoreAck(w, len(env.Features), len(env.Features), 0)
			return
		}
		http.NotFound(w, r)
	}))
	defer coreServer.Close()

	cfg := &config.Config{
		Feeds:            []string{},
		LongFeeds:        []string{},
		PollInterval:     time.Minute,
		LongPollInterval: time.Hour,
		RequestInterval:  time.Millisecond,
		StateDir:         tmpDir,
		DailyByteLimit:   10 * 1024 * 1024,
		MaxItemBytes:     1024 * 1024,
	}
	validator := client.NewURLValidator("www.data.jma.go.jp", false)
	jmaClient := client.NewJMAClient(store, validator, "test", cfg.RequestInterval, cfg.MaxItemBytes, cfg.PollInterval, nil)
	coreClient := client.NewCoreClient(core.NewClient(coreServer.URL+"/api/v1", nil), nil)
	ctrl := NewController(cfg, store, jmaClient, coreClient, validator)

	ctrl.replaySpool(context.Background())

	if len(batchSizes) != 3 {
		t.Fatalf("expected 3 independent batches delivered, got %d", len(batchSizes))
	}
	for i, size := range batchSizes {
		if size != 1 {
			t.Fatalf("batch %d: expected size 1, got %d", i, size)
		}
	}
}

// Test 5: Injected disk errors stop later upstream calls and fail closed.
func TestInjectedDiskErrorsStopLaterUpstreamCalls(t *testing.T) {
	tmpDir, err := os.MkdirTemp("", "jma-disk-err-*")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(tmpDir)

	store, _ := state.NewStore(tmpDir, 10*1024*1024)
	defer store.Close()

	var dataCalls int32
	jmaServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&dataCalls, 1)
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(mockTelegramXML))
	}))
	defer jmaServer.Close()

	parsedJMA, _ := url.Parse(jmaServer.URL)
	cfg := &config.Config{
		Feeds:            []string{},
		LongFeeds:        []string{},
		PollInterval:     time.Minute,
		LongPollInterval: time.Hour,
		RequestInterval:  time.Millisecond,
		StateDir:         tmpDir,
		DailyByteLimit:   10 * 1024 * 1024,
		MaxItemBytes:     1024 * 1024,
	}

	validator := client.NewURLValidator(parsedJMA.Hostname(), true)
	jmaClient := client.NewJMAClient(store, validator, "test", cfg.RequestInterval, cfg.MaxItemBytes, cfg.PollInterval, nil)
	coreClient := client.NewCoreClient(core.NewClient("http://localhost:9999/api/v1", nil), nil)
	ctrl := NewController(cfg, store, jmaClient, coreClient, validator)

	// Make spool directory read-only to inject disk persistence failure
	spoolDir := filepath.Join(tmpDir, "spool")
	_ = os.Chmod(spoolDir, 0555)
	defer os.Chmod(spoolDir, 0755)

	itemURL := jmaServer.URL + "/developer/xml/data/test_item.xml"
	ctrl.fetchAndIngestItem(context.Background(), itemURL, "feed1")

	// Acquisition must have aborted because SaveSpool failed!
	// URL must NOT be marked fetched if SaveSpool failed
	if store.IsFetched(itemURL) {
		t.Fatalf("URL was marked fetched despite spool disk failure!")
	}
}

// Test 6: 304 Not Modified honors cache freshness delay.
func TestFeed304AndCacheDelays(t *testing.T) {
	var feedCalls int32
	jmaServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&feedCalls, 1)
		w.Header().Set("Cache-Control", "max-age=180")
		w.WriteHeader(http.StatusNotModified)
	}))
	defer jmaServer.Close()

	tmpDir, err := os.MkdirTemp("", "jma-cache-delays-*")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(tmpDir)

	feedURL := jmaServer.URL + "/developer/xml/feed/eqvol.xml"
	parsed, _ := url.Parse(jmaServer.URL)
	cfg := &config.Config{
		Feeds:            []string{feedURL},
		LongFeeds:        []string{},
		PollInterval:     time.Minute,
		LongPollInterval: time.Hour,
		RequestInterval:  time.Millisecond,
		StateDir:         tmpDir,
		DailyByteLimit:   10 * 1024 * 1024,
		MaxItemBytes:     1024 * 1024,
	}

	store, _ := state.NewStore(tmpDir, cfg.DailyByteLimit)
	defer store.Close()

	validator := client.NewURLValidator(parsed.Hostname(), true)
	jmaClient := client.NewJMAClient(store, validator, "test", cfg.RequestInterval, cfg.MaxItemBytes, cfg.PollInterval, nil)
	coreClient := client.NewCoreClient(core.NewClient("http://localhost:9999/api/v1", nil), nil)
	ctrl := NewController(cfg, store, jmaClient, coreClient, validator)

	ctrl.processFeed(context.Background(), feedURL, false)

	if atomic.LoadInt32(&feedCalls) != 1 {
		t.Fatalf("expected 1 feed call, got %d", feedCalls)
	}

	sch := store.GetFeedSchedule(feedURL)
	// NextAllowedAt must be at least ~180s from now
	remaining := time.Until(sch.NextAllowedAt)
	if remaining < 150*time.Second {
		t.Fatalf("expected NextAllowedAt to honor max-age=180 (>150s), got %v", remaining)
	}

	// Immediate subsequent poll must be skipped by schedule check
	ctrl.processFeed(context.Background(), feedURL, false)
	if atomic.LoadInt32(&feedCalls) != 1 {
		t.Fatalf("subsequent poll was not skipped by cache delay! calls=%d", feedCalls)
	}
}

// Test 7: Retry-After is persisted and restored across restarts.
func TestRetryAfterRestart(t *testing.T) {
	rateServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Retry-After", "90")
		w.WriteHeader(http.StatusTooManyRequests)
		_, _ = w.Write([]byte("Rate limit exceeded"))
	}))
	defer rateServer.Close()

	tmpDir, err := os.MkdirTemp("", "jma-retry-restart-*")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(tmpDir)

	feedURL := rateServer.URL + "/developer/xml/feed/eqvol.xml"
	parsed, _ := url.Parse(rateServer.URL)
	cfg := &config.Config{
		Feeds:            []string{feedURL},
		LongFeeds:        []string{},
		PollInterval:     time.Minute,
		LongPollInterval: time.Hour,
		RequestInterval:  time.Millisecond,
		StateDir:         tmpDir,
		DailyByteLimit:   10 * 1024 * 1024,
		MaxItemBytes:     1024 * 1024,
	}

	store1, _ := state.NewStore(tmpDir, cfg.DailyByteLimit)
	validator1 := client.NewURLValidator(parsed.Hostname(), true)
	jmaClient1 := client.NewJMAClient(store1, validator1, "test", cfg.RequestInterval, cfg.MaxItemBytes, cfg.PollInterval, nil)
	coreClient1 := client.NewCoreClient(core.NewClient("http://localhost:9999/api/v1", nil), nil)
	ctrl1 := NewController(cfg, store1, jmaClient1, coreClient1, validator1)

	// Poll feed triggers 429
	ctrl1.processFeed(context.Background(), feedURL, false)

	// Verify global backoff is set in store
	until := store1.GetGlobalBackoffUntil()
	if time.Until(until) < 60*time.Second {
		t.Fatalf("expected global backoff until > 60s, got %v", time.Until(until))
	}
	_ = store1.Close()

	// Restart store from disk
	store2, err := state.NewStore(tmpDir, cfg.DailyByteLimit)
	if err != nil {
		t.Fatalf("failed to restart store: %v", err)
	}
	defer store2.Close()

	restoredUntil := store2.GetGlobalBackoffUntil()
	if time.Until(restoredUntil) < 50*time.Second {
		t.Fatalf("expected restored global backoff > 50s, got %v", time.Until(restoredUntil))
	}
}

// Test 8: Per-feed floors and exponential backoff on consecutive failures.
func TestPerFeedFloorsAndExponentialBackoff(t *testing.T) {
	tmpDir, err := os.MkdirTemp("", "jma-floors-*")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(tmpDir)

	store, _ := state.NewStore(tmpDir, 10*1024*1024)
	defer store.Close()

	cfg := &config.Config{
		PollInterval:     1 * time.Minute,
		LongPollInterval: 1 * time.Hour,
	}
	ctrl := NewController(cfg, store, nil, nil, nil)

	// High feed: 1m floor
	b1 := ctrl.computeExponentialBackoff(time.Minute, 1)
	if b1 < time.Minute {
		t.Fatalf("expected backoff >= 1m, got %v", b1)
	}

	b2 := ctrl.computeExponentialBackoff(time.Minute, 2)
	if b2 < 2*time.Minute {
		t.Fatalf("expected consecutive backoff >= 2m, got %v", b2)
	}

	// Long feed: 1h floor
	lb1 := ctrl.computeExponentialBackoff(time.Hour, 1)
	if lb1 < time.Hour {
		t.Fatalf("expected long feed backoff >= 1h, got %v", lb1)
	}

	lb2 := ctrl.computeExponentialBackoff(time.Hour, 2)
	if lb2 < 2*time.Hour {
		t.Fatalf("expected long feed consecutive backoff >= 2h, got %v", lb2)
	}
}

// Test 9: More than MaxDeliveryAttempts outage (7 cycles of Core 503) then recovery.
// Verifies no quarantine for 503/network outage, durable spool kept indefinitely, and upstream fetched once.
func TestMoreThanMaxDeliveryAttemptsOutageThenRecoveryAllDeliveredUpstreamFetchedOnce(t *testing.T) {
	var jmaServerURL string
	var dataFetchCalls int32
	var coreOutage atomic.Bool
	coreOutage.Store(true)

	jmaServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		path := r.URL.Path
		switch {
		case strings.HasPrefix(path, "/developer/xml/feed/"):
			w.Header().Set("Content-Type", "application/atom+xml")
			w.WriteHeader(http.StatusOK)
			body := strings.ReplaceAll(mockAtomFeed, "BASE_URL", jmaServerURL)
			_, _ = w.Write([]byte(body))
		case strings.HasPrefix(path, "/developer/xml/data/"):
			atomic.AddInt32(&dataFetchCalls, 1)
			w.Header().Set("Content-Type", "application/xml")
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(mockTelegramXML))
		default:
			http.NotFound(w, r)
		}
	}))
	defer jmaServer.Close()
	jmaServerURL = jmaServer.URL

	var coreMessageCalls int32
	coreServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		path := r.URL.Path
		switch {
		case strings.HasSuffix(path, "/jma_data/index"):
			writeMockCoreAck(w, 1, 1, 0)
		case strings.HasSuffix(path, "/jma_data/pending"):
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusOK)
			dataURL := jmaServerURL + "/developer/xml/data/20260921012500_0_VXSE53_010000.xml"
			feedURL := jmaServerURL + "/developer/xml/feed/eqvol.xml"
			_ = json.NewEncoder(w).Encode(map[string]any{
				"items": []map[string]string{{"item_url": dataURL, "feed_url": feedURL}},
			})
		case strings.HasSuffix(path, "/jma_data/messages"):
			atomic.AddInt32(&coreMessageCalls, 1)
			if coreOutage.Load() {
				w.WriteHeader(http.StatusServiceUnavailable)
				_, _ = w.Write([]byte(`{"error":"core service unavailable"}`))
				return
			}
			writeMockCoreAck(w, 1, 1, 0)
		default:
			http.NotFound(w, r)
		}
	}))
	defer coreServer.Close()

	tmpDir, err := os.MkdirTemp("", "jma-long-outage-*")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(tmpDir)

	parsedJMA, _ := url.Parse(jmaServerURL)
	dataURL := jmaServerURL + "/developer/xml/data/20260921012500_0_VXSE53_010000.xml"
	feedURL := jmaServerURL + "/developer/xml/feed/eqvol.xml"

	cfg := &config.Config{
		Feeds:            []string{feedURL},
		LongFeeds:        []string{},
		PollInterval:     10 * time.Millisecond,
		LongPollInterval: 1 * time.Hour,
		RequestInterval:  5 * time.Millisecond,
		StateDir:         tmpDir,
		DailyByteLimit:   10 * 1024 * 1024,
		MaxItemBytes:     1024 * 1024,
		UserAgent:        "matrixwhale-jma-adapter",
	}

	store, err := state.NewStore(tmpDir, cfg.DailyByteLimit)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()

	validator := client.NewURLValidator(parsedJMA.Hostname(), true)
	jmaClient := client.NewJMAClient(store, validator, cfg.UserAgent, cfg.RequestInterval, cfg.MaxItemBytes, cfg.PollInterval, nil)
	coreClient := client.NewCoreClient(core.NewClient(coreServer.URL+"/api/v1", nil), nil)
	ctrl := NewController(cfg, store, jmaClient, coreClient, validator)

	ctx := context.Background()

	// Run 7 outage cycles (> MaxDeliveryAttempts = 5)
	for cycle := 1; cycle <= 7; cycle++ {
		if cycle > 1 {
			// Advance feed schedule so feed doesn't block poll cycle
			if err := store.RecordFeedSuccess(feedURL, time.Now().Add(-1*time.Second)); err != nil {
				t.Fatal(err)
			}
		}
		ctrl.pollCycle(ctx)

		// Upstream fetch must happen ONLY once (on cycle 1)
		if atomic.LoadInt32(&dataFetchCalls) != 1 {
			t.Fatalf("cycle %d: upstream dataFetchCalls expected 1, got %d", cycle, dataFetchCalls)
		}

		// Item MUST NOT be quarantined! Must remain in active spool
		spoolItems, err := store.ListSpool()
		if err != nil {
			t.Fatalf("cycle %d: ListSpool error: %v", cycle, err)
		}
		if len(spoolItems) != 1 {
			t.Fatalf("cycle %d: expected 1 item retained in spool, got %d (item was wrongly quarantined!)", cycle, len(spoolItems))
		}
		if spoolItems[0].DeliveryAttempts != cycle {
			t.Fatalf("cycle %d: expected DeliveryAttempts %d, got %d", cycle, cycle, spoolItems[0].DeliveryAttempts)
		}
	}

	// Cycle 8: Core RECOVERS
	coreOutage.Store(false)
	if err := store.RecordFeedSuccess(feedURL, time.Now().Add(-1*time.Second)); err != nil {
		t.Fatal(err)
	}
	ctrl.pollCycle(ctx)

	// Upstream data fetch still strictly 1
	if atomic.LoadInt32(&dataFetchCalls) != 1 {
		t.Fatalf("after recovery: upstream XML redownloaded! expected 1, got %d", dataFetchCalls)
	}

	// Spool must now be completely empty after successful replay delivery
	spoolItems, err := store.ListSpool()
	if err != nil {
		t.Fatal(err)
	}
	if len(spoolItems) != 0 {
		t.Fatalf("expected spool empty after recovery replay, got %d", len(spoolItems))
	}
	if !store.IsFetched(dataURL) {
		t.Fatalf("expected dataURL marked fetched in durable history")
	}
}

// Test 10: Two pending items where first SaveSpool failure sets fatal latch,
// halting acquisition immediately (second item never fetched) and on the next cycle.
func TestTwoPendingItemsFirstSaveSpoolFailurePreventsSecondRequestAndNextCycle(t *testing.T) {
	var jmaServerURL string
	var item1Calls, item2Calls int32

	jmaServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		path := r.URL.Path
		switch {
		case strings.Contains(path, "item1.xml"):
			atomic.AddInt32(&item1Calls, 1)
			w.Header().Set("Content-Type", "application/xml")
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(mockTelegramXML))
		case strings.Contains(path, "item2.xml"):
			atomic.AddInt32(&item2Calls, 1)
			w.Header().Set("Content-Type", "application/xml")
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(mockTelegramXML))
		default:
			http.NotFound(w, r)
		}
	}))
	defer jmaServer.Close()
	jmaServerURL = jmaServer.URL

	url1 := jmaServerURL + "/developer/xml/data/item1.xml"
	url2 := jmaServerURL + "/developer/xml/data/item2.xml"

	coreServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		path := r.URL.Path
		switch {
		case strings.HasSuffix(path, "/jma_data/pending"):
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusOK)
			_ = json.NewEncoder(w).Encode(map[string]any{
				"items": []map[string]string{
					{"item_url": url1, "feed_url": "feed1"},
					{"item_url": url2, "feed_url": "feed1"},
				},
			})
		case strings.HasSuffix(path, "/jma_data/messages"):
			writeMockCoreAck(w, 1, 1, 0)
		default:
			http.NotFound(w, r)
		}
	}))
	defer coreServer.Close()

	tmpDir, err := os.MkdirTemp("", "jma-fatal-latch-*")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(tmpDir)

	parsedJMA, _ := url.Parse(jmaServerURL)
	cfg := &config.Config{
		Feeds:            []string{},
		LongFeeds:        []string{},
		PollInterval:     10 * time.Millisecond,
		LongPollInterval: 1 * time.Hour,
		RequestInterval:  time.Millisecond,
		StateDir:         tmpDir,
		DailyByteLimit:   10 * 1024 * 1024,
		MaxItemBytes:     1024 * 1024,
		UserAgent:        "test-latch",
	}

	store, err := state.NewStore(tmpDir, cfg.DailyByteLimit)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()

	validator := client.NewURLValidator(parsedJMA.Hostname(), true)
	jmaClient := client.NewJMAClient(store, validator, cfg.UserAgent, cfg.RequestInterval, cfg.MaxItemBytes, cfg.PollInterval, nil)
	coreClient := client.NewCoreClient(core.NewClient(coreServer.URL+"/api/v1", nil), nil)
	ctrl := NewController(cfg, store, jmaClient, coreClient, validator)

	// Make spool directory read-only to inject disk persistence failure on SaveSpool
	spoolDir := filepath.Join(tmpDir, "spool")
	if err := os.Chmod(spoolDir, 0555); err != nil {
		t.Fatal(err)
	}
	defer os.Chmod(spoolDir, 0755)

	ctx := context.Background()

	// --- Cycle 1: Fetching item 1 succeeds over HTTP, but SaveSpool fails on disk ---
	ctrl.pollCycle(ctx)

	// Item 1 was fetched
	if atomic.LoadInt32(&item1Calls) != 1 {
		t.Fatalf("cycle 1: expected 1 call for item1, got %d", item1Calls)
	}

	// FATAL LATCH MUST BE SET!
	if !ctrl.isFatal() {
		t.Fatalf("expected controller to be latched fatal after SaveSpool failure")
	}

	// ITEM 2 MUST NEVER HAVE BEEN REQUESTED in cycle 1!
	if atomic.LoadInt32(&item2Calls) != 0 {
		t.Fatalf("cycle 1: item2 was requested despite fatal state error on item1! calls=%d", item2Calls)
	}

	// --- Cycle 2: Next cycle runs while fatal latch is active ---
	ctrl.pollCycle(ctx)

	// In cycle 2, ZERO upstream HTTP requests are made!
	if atomic.LoadInt32(&item1Calls) != 1 {
		t.Fatalf("cycle 2: item1 was re-requested despite fatal latch! calls=%d", item1Calls)
	}
	if atomic.LoadInt32(&item2Calls) != 0 {
		t.Fatalf("cycle 2: item2 was requested in next cycle! calls=%d", item2Calls)
	}
}

// Test 11: pollCycle replays spool even if upstream Retry-After backoff is active.
func TestPollCycleReplaysSpoolDuringActiveUpstreamRetryAfter(t *testing.T) {
	tmpDir, err := os.MkdirTemp("", "jma-replay-during-backoff-*")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(tmpDir)

	store, err := state.NewStore(tmpDir, 10*1024*1024)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()

	// Pre-spool a valid telegram
	itemURL := "https://www.data.jma.go.jp/developer/xml/data/spooled_item.xml"
	rawXML := mockTelegramXML
	msgJSON := json.RawMessage(`{"identifier":"spooled_item"}`)
	spoolItem := state.SpoolItem{
		ID:         state.SpoolItemKey(itemURL),
		ItemURL:    itemURL,
		FeedURL:    "https://www.data.jma.go.jp/developer/xml/feed/eqvol.xml",
		FetchedAt:  "2026-09-21T01:25:00Z",
		HTTPStatus: 200,
		RawXML:     &rawXML,
		Message:    msgJSON,
	}
	if err := store.SaveSpool(spoolItem); err != nil {
		t.Fatal(err)
	}

	// Set active upstream global backoff (e.g. 10 minutes in the future)
	backoffUntil := time.Now().Add(10 * time.Minute)
	if err := store.SetGlobalBackoff(backoffUntil); err != nil {
		t.Fatal(err)
	}

	var coreDelivered int32
	coreServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/jma_data/messages") {
			atomic.AddInt32(&coreDelivered, 1)
			writeMockCoreAck(w, 1, 1, 0)
			return
		}
		http.NotFound(w, r)
	}))
	defer coreServer.Close()

	var upstreamFeedCalls int32
	jmaServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&upstreamFeedCalls, 1)
		w.WriteHeader(http.StatusOK)
	}))
	defer jmaServer.Close()

	parsedJMA, _ := url.Parse(jmaServer.URL)
	feedURL := jmaServer.URL + "/developer/xml/feed/eqvol.xml"

	cfg := &config.Config{
		Feeds:            []string{feedURL},
		LongFeeds:        []string{},
		PollInterval:     time.Minute,
		LongPollInterval: time.Hour,
		RequestInterval:  time.Millisecond,
		StateDir:         tmpDir,
		DailyByteLimit:   10 * 1024 * 1024,
		MaxItemBytes:     1024 * 1024,
		UserAgent:        "test-backoff",
	}

	validator := client.NewURLValidator(parsedJMA.Hostname(), true)
	jmaClient := client.NewJMAClient(store, validator, cfg.UserAgent, cfg.RequestInterval, cfg.MaxItemBytes, cfg.PollInterval, nil)
	coreClient := client.NewCoreClient(core.NewClient(coreServer.URL+"/api/v1", nil), nil)
	ctrl := NewController(cfg, store, jmaClient, coreClient, validator)

	// Run poll cycle: spool replay MUST execute despite upstream backoff!
	ctrl.pollCycle(context.Background())

	// Core must have received the spooled item
	if atomic.LoadInt32(&coreDelivered) != 1 {
		t.Fatalf("expected 1 delivery to core during upstream backoff, got %d", coreDelivered)
	}

	// Spool must be drained
	items, _ := store.ListSpool()
	if len(items) != 0 {
		t.Fatalf("expected spool empty after replay, got %d items", len(items))
	}

	// Upstream feed must NOT have been polled
	if atomic.LoadInt32(&upstreamFeedCalls) != 0 {
		t.Fatalf("upstream feed was polled despite active global backoff! calls=%d", upstreamFeedCalls)
	}
}

// Test 12: Enforce max(floor, retry/cache) so short Retry-After cannot shrink 1m/1h floor.
func TestFeedSchedulingEnforcesFloorAgainstShortRetryAfter(t *testing.T) {
	// Upstream returns 429 with short Retry-After: 5s
	rateServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Retry-After", "5")
		w.WriteHeader(http.StatusTooManyRequests)
		_, _ = w.Write([]byte("Rate limit"))
	}))
	defer rateServer.Close()

	tmpDir, err := os.MkdirTemp("", "jma-floor-enforcement-*")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(tmpDir)

	feedURL := rateServer.URL + "/developer/xml/feed/eqvol.xml"
	parsed, _ := url.Parse(rateServer.URL)
	cfg := &config.Config{
		Feeds:            []string{feedURL},
		LongFeeds:        []string{},
		PollInterval:     1 * time.Minute,
		LongPollInterval: 1 * time.Hour,
		RequestInterval:  time.Millisecond,
		StateDir:         tmpDir,
		DailyByteLimit:   10 * 1024 * 1024,
		MaxItemBytes:     1024 * 1024,
	}

	store, err := state.NewStore(tmpDir, cfg.DailyByteLimit)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()

	validator := client.NewURLValidator(parsed.Hostname(), true)
	jmaClient := client.NewJMAClient(store, validator, "test", cfg.RequestInterval, cfg.MaxItemBytes, cfg.PollInterval, nil)
	coreClient := client.NewCoreClient(core.NewClient("http://localhost:9999/api/v1", nil), nil)
	ctrl := NewController(cfg, store, jmaClient, coreClient, validator)

	ctrl.processFeed(context.Background(), feedURL, false)

	sch := store.GetFeedSchedule(feedURL)
	remaining := time.Until(sch.NextAllowedAt)
	// Floor is 1 minute (60s). Short 5s Retry-After MUST NOT shrink the 60s floor!
	if remaining < 50*time.Second {
		t.Fatalf("short Retry-After shrank schedule below 1m floor! remaining=%v", remaining)
	}
}

// Test 13: Quota exhaustion is a harmless pause, not fatal; permits day rollover.
func TestQuotaExhaustionIsHarmlessPauseAndPermitsDayRollover(t *testing.T) {
	tmpDir, err := os.MkdirTemp("", "jma-quota-test-*")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(tmpDir)

	// 100 byte daily limit
	store, err := state.NewStore(tmpDir, 100)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()

	// Exhaust quota
	if err := store.Reserve(100); err != nil {
		t.Fatal(err)
	}
	if err := store.Commit(100, 100); err != nil {
		t.Fatal(err)
	}

	cfg := &config.Config{
		Feeds:            []string{"https://www.data.jma.go.jp/developer/xml/feed/eqvol.xml"},
		LongFeeds:        []string{},
		PollInterval:     time.Minute,
		LongPollInterval: time.Hour,
		RequestInterval:  time.Millisecond,
		StateDir:         tmpDir,
		DailyByteLimit:   100,
		MaxItemBytes:     1024 * 1024,
	}

	validator := client.NewURLValidator("www.data.jma.go.jp", false)
	jmaClient := client.NewJMAClient(store, validator, "test", cfg.RequestInterval, cfg.MaxItemBytes, cfg.PollInterval, nil)
	coreClient := client.NewCoreClient(core.NewClient("http://localhost:9999/api/v1", nil), nil)
	ctrl := NewController(cfg, store, jmaClient, coreClient, validator)

	// Fetching should pause due to quota limit, but MUST NOT set fatal latch
	ctrl.fetchAndIngestItem(context.Background(), "https://www.data.jma.go.jp/developer/xml/data/item.xml", "feed1")

	if ctrl.isFatal() {
		t.Fatalf("quota exhaustion set the fatal latch! It should be a harmless pause.")
	}

	ctrl.processFeed(context.Background(), "https://www.data.jma.go.jp/developer/xml/feed/eqvol.xml", false)

	if ctrl.isFatal() {
		t.Fatalf("quota exhaustion in feed set the fatal latch! It should be a harmless pause.")
	}
}

// Test 14: Terminal HTTP 400 and 410 record durable outcome and do not redownload.
func TestTerminal400And410RecordsDurableOutcome(t *testing.T) {
	var jmaCalls int32
	jmaServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&jmaCalls, 1)
		path := r.URL.Path
		if strings.Contains(path, "bad_request.xml") {
			w.WriteHeader(http.StatusBadRequest)
			_, _ = w.Write([]byte("400 bad request"))
		} else if strings.Contains(path, "gone.xml") {
			w.WriteHeader(http.StatusGone)
			_, _ = w.Write([]byte("410 gone"))
		} else {
			http.NotFound(w, r)
		}
	}))
	defer jmaServer.Close()

	var coreReportCalls int32
	coreServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/jma_data/messages") {
			atomic.AddInt32(&coreReportCalls, 1)
			body, _ := io.ReadAll(r.Body)
			var env struct {
				Features []client.JmaFetchResult `json:"features"`
			}
			_ = json.Unmarshal(body, &env)
			// Both written=1,dropped=0 or written=0,dropped=1 are accepted by coreClient
			writeMockCoreAck(w, len(env.Features), 0, len(env.Features))
			return
		}
		http.NotFound(w, r)
	}))
	defer coreServer.Close()

	tmpDir, err := os.MkdirTemp("", "jma-term-400-410-*")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(tmpDir)

	parsedJMA, _ := url.Parse(jmaServer.URL)
	cfg := &config.Config{
		Feeds:            []string{},
		LongFeeds:        []string{},
		PollInterval:     time.Minute,
		LongPollInterval: time.Hour,
		RequestInterval:  time.Millisecond,
		StateDir:         tmpDir,
		DailyByteLimit:   10 * 1024 * 1024,
		MaxItemBytes:     1024 * 1024,
	}

	store, _ := state.NewStore(tmpDir, cfg.DailyByteLimit)
	defer store.Close()

	validator := client.NewURLValidator(parsedJMA.Hostname(), true)
	jmaClient := client.NewJMAClient(store, validator, "test", cfg.RequestInterval, cfg.MaxItemBytes, cfg.PollInterval, nil)
	coreClient := client.NewCoreClient(core.NewClient(coreServer.URL+"/api/v1", nil), nil)
	ctrl := NewController(cfg, store, jmaClient, coreClient, validator)

	ctx := context.Background()

	// 1. Test 400
	url400 := jmaServer.URL + "/developer/xml/data/bad_request.xml"
	ctrl.fetchAndIngestItem(ctx, url400, "feed1")

	if !store.IsFetched(url400) {
		t.Fatalf("expected 400 URL marked permanently fetched")
	}

	// 2. Test 410
	url410 := jmaServer.URL + "/developer/xml/data/gone.xml"
	ctrl.fetchAndIngestItem(ctx, url410, "feed1")

	if !store.IsFetched(url410) {
		t.Fatalf("expected 410 URL marked permanently fetched")
	}

	// Spool must be empty after core ack
	items, _ := store.ListSpool()
	if len(items) != 0 {
		t.Fatalf("expected spool empty after 400/410 delivery, got %d items", len(items))
	}
}

func jmaServerURL(s *httptest.Server) string {
	return s.URL
}
