package controller

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"jma_adapter/client"
	"jma_adapter/config"
	"jma_adapter/state"
	"matrixwhale/adapters/common/core"
)

const mockAtomFeed = `<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>高頻度（地震火山）</title>
  <updated>2026-09-21T01:30:00+09:00</updated>
  <entry>
    <title>震源・震度に関する情報</title>
    <id>BASE_URL/developer/xml/data/20260921012500_0_VXSE53_010000.xml</id>
    <updated>2026-09-21T01:25:00Z</updated>
    <link type="application/xml" href="BASE_URL/developer/xml/data/20260921012500_0_VXSE53_010000.xml"/>
  </entry>
</feed>`

const mockTelegramXML = `<?xml version="1.0" encoding="UTF-8"?>
<Report xmlns="http://xml.kishou.go.jp/jmaxml1/">
  <Control>
    <Title>震源・震度に関する情報</Title>
    <DateTime>2026-09-21T01:25:00Z</DateTime>
    <Status>通常</Status>
    <EditorialOffice>気象庁本庁</EditorialOffice>
    <PublishingOffice>気象庁</PublishingOffice>
  </Control>
  <Head xmlns="http://xml.kishou.go.jp/jmaxml1/informationBasis1/">
    <Title>震源・震度に関する情報</Title>
    <ReportDateTime>2026-09-21T10:25:00+09:00</ReportDateTime>
    <EventID>20260921012500</EventID>
    <InfoType>発表</InfoType>
    <Serial>1</Serial>
    <InfoKind>震源・震度に関する情報</InfoKind>
    <Headline>
      <Text>２１日１０時２５分ころ、地震がありました。</Text>
    </Headline>
  </Head>
  <Body xmlns="http://xml.kishou.go.jp/jmaxml1/body/seismology1/">
    <Earthquake>
      <OriginTime>2026-09-21T10:25:00+09:00</OriginTime>
      <Hypocenter>
        <Area>
          <Name>東京湾</Name>
          <Code>350</Code>
          <Coordinate>+35.6+139.8-20000/</Coordinate>
        </Area>
      </Hypocenter>
      <Magnitude type="Mj">4.5</Magnitude>
    </Earthquake>
    <Intensity>
      <Observation>
        <MaxInt>3</MaxInt>
      </Observation>
    </Intensity>
  </Body>
</Report>`

func TestControllerEndToEnd(t *testing.T) {
	var jmaServerURL string
	var feedCalls, dataCalls int32

	// 1. Mock upstream JMA server
	jmaServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		path := r.URL.Path
		switch {
		case strings.HasPrefix(path, "/developer/xml/feed/"):
			atomic.AddInt32(&feedCalls, 1)
			w.Header().Set("Content-Type", "application/atom+xml")
			w.Header().Set("Last-Modified", "Mon, 21 Sep 2026 01:30:00 GMT")
			w.Header().Set("ETag", `"feed-tag-1"`)
			w.WriteHeader(http.StatusOK)
			body := strings.ReplaceAll(mockAtomFeed, "BASE_URL", jmaServerURL)
			_, _ = w.Write([]byte(body))
		case strings.HasPrefix(path, "/developer/xml/data/"):
			atomic.AddInt32(&dataCalls, 1)
			w.Header().Set("Content-Type", "application/xml")
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(mockTelegramXML))
		default:
			http.NotFound(w, r)
		}
	}))
	defer jmaServer.Close()
	jmaServerURL = jmaServer.URL

	// 2. Mock Core backend server
	var indexCalls, pendingCalls, messageCalls int32
	var lastReceivedMessages []client.JmaFetchResult

	coreServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		path := r.URL.Path
		switch {
		case strings.HasSuffix(path, "/jma_data/index"):
			atomic.AddInt32(&indexCalls, 1)
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusOK)
			_ = json.NewEncoder(w).Encode(map[string]any{
				"received": 1,
				"deduped":  0,
				"written":  1,
				"dropped":  0,
				"message":  "1 items written",
			})
		case strings.HasSuffix(path, "/jma_data/pending"):
			atomic.AddInt32(&pendingCalls, 1)
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusOK)
			dataURL := jmaServerURL + "/developer/xml/data/20260921012500_0_VXSE53_010000.xml"
			feedURL := jmaServerURL + "/developer/xml/feed/eqvol.xml"
			_ = json.NewEncoder(w).Encode(map[string]any{
				"items": []map[string]string{
					{"item_url": dataURL, "feed_url": feedURL},
				},
			})
		case strings.HasSuffix(path, "/jma_data/messages"):
			atomic.AddInt32(&messageCalls, 1)
			body, _ := io.ReadAll(r.Body)
			var env struct {
				Features []client.JmaFetchResult `json:"features"`
			}
			_ = json.Unmarshal(body, &env)
			lastReceivedMessages = env.Features

			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusOK)
			_ = json.NewEncoder(w).Encode(map[string]any{
				"received": 1,
				"deduped":  0,
				"written":  1,
				"dropped":  0,
				"message":  "1 messages written",
			})
		default:
			http.NotFound(w, r)
		}
	}))
	defer coreServer.Close()

	tmpDir, err := os.MkdirTemp("", "jma-ctrl-test-*")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(tmpDir)

	parsedJMA, _ := url.Parse(jmaServerURL)
	cfg := &config.Config{
		Feeds:            []string{jmaServerURL + "/developer/xml/feed/eqvol.xml"},
		LongFeeds:        []string{jmaServerURL + "/developer/xml/feed/eqvol_l.xml"},
		PollInterval:     1 * time.Minute,
		LongPollInterval: 1 * time.Hour,
		RequestInterval:  10 * time.Millisecond,
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

	coreHTTPClient := core.NewClient(coreServer.URL+"/api/v1", nil)
	coreClient := client.NewCoreClient(coreHTTPClient, nil)

	ctrl := NewController(cfg, store, jmaClient, coreClient, validator)

	// Execute one poll cycle
	ctx := context.Background()
	ctrl.pollCycle(ctx)

	if atomic.LoadInt32(&feedCalls) == 0 {
		t.Fatalf("expected feed calls, got 0")
	}
	if atomic.LoadInt32(&indexCalls) == 0 {
		t.Fatalf("expected index calls to core, got 0")
	}
	if atomic.LoadInt32(&pendingCalls) == 0 {
		t.Fatalf("expected pending calls to core, got 0")
	}
	if atomic.LoadInt32(&dataCalls) == 0 {
		t.Fatalf("expected data calls to JMA, got 0")
	}
	if atomic.LoadInt32(&messageCalls) == 0 {
		t.Fatalf("expected message calls to core, got 0")
	}

	if len(lastReceivedMessages) != 1 {
		t.Fatalf("expected 1 message received at core, got %d", len(lastReceivedMessages))
	}

	msg := lastReceivedMessages[0].Message
	if msg == nil {
		t.Fatalf("expected parsed message, got nil")
	}
	if msg.ControlTitle != "震源・震度に関する情報" {
		t.Fatalf("title mismatch: %s", msg.ControlTitle)
	}
	if msg.SeriesKey == nil || *msg.SeriesKey != "震源・震度に関する情報:気象庁本庁:通常:20260921012500" {
		t.Fatalf("series_key mismatch: %v", msg.SeriesKey)
	}
	if msg.Sent != "2026-09-21T01:25:00Z" {
		t.Fatalf("sent mismatch: %s", msg.Sent)
	}
	if msg.Earthquake == nil {
		t.Fatalf("expected earthquake populated, got nil")
	}
	if *msg.Earthquake.Place != "東京湾" {
		t.Fatalf("earthquake place mismatch: %s", *msg.Earthquake.Place)
	}
	if float64(*msg.Earthquake.DepthKM) != 20.0 {
		t.Fatalf("expected 20.0km depth, got %f", *msg.Earthquake.DepthKM)
	}

	// Verify spool is empty after successful ingestion
	spoolItems, err := store.ListSpool()
	if err != nil {
		t.Fatal(err)
	}
	if len(spoolItems) != 0 {
		t.Fatalf("expected spool empty after successful core delivery, got %d", len(spoolItems))
	}
}

func TestControllerSpoolReplayOnRestart(t *testing.T) {
	tmpDir, err := os.MkdirTemp("", "jma-spool-restart-*")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(tmpDir)

	store, err := state.NewStore(tmpDir, 10*1024*1024)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()

	// Pre-populate an uncommitted spool item
	rawXML := mockTelegramXML
	msgJSON := json.RawMessage(`{"identifier":"20260921012500_0_VXSE53_010000","control_title":"震源・震度に関する情報","status":"通常"}`)
	spoolItem := state.SpoolItem{
		ID:         state.SpoolItemKey("https://www.data.jma.go.jp/developer/xml/data/20260921012500_0_VXSE53_010000.xml"),
		ItemURL:    "https://www.data.jma.go.jp/developer/xml/data/20260921012500_0_VXSE53_010000.xml",
		FeedURL:    "https://www.data.jma.go.jp/developer/xml/feed/eqvol.xml",
		FetchedAt:  "2026-09-21T01:25:00Z",
		HTTPStatus: 200,
		RawXML:     &rawXML,
		Message:    msgJSON,
	}
	if err := store.SaveSpool(spoolItem); err != nil {
		t.Fatal(err)
	}

	// Mock core receiving messages
	var messageReplayReceived int32
	coreServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/jma_data/messages") {
			atomic.AddInt32(&messageReplayReceived, 1)
			w.WriteHeader(http.StatusOK)
			_ = json.NewEncoder(w).Encode(map[string]any{
				"received": 1,
				"deduped":  0,
				"written":  1,
				"dropped":  0,
				"message":  "1 messages written",
			})
			return
		}
		http.NotFound(w, r)
	}))
	defer coreServer.Close()

	coreHTTPClient := core.NewClient(coreServer.URL+"/api/v1", nil)
	coreClient := client.NewCoreClient(coreHTTPClient, nil)

	cfg := &config.Config{
		Feeds:            []string{"https://www.data.jma.go.jp/developer/xml/feed/eqvol.xml"},
		LongFeeds:        []string{"https://www.data.jma.go.jp/developer/xml/feed/eqvol_l.xml"},
		PollInterval:     1 * time.Minute,
		LongPollInterval: 1 * time.Hour,
		RequestInterval:  10 * time.Millisecond,
		StateDir:         tmpDir,
		DailyByteLimit:   10 * 1024 * 1024,
		MaxItemBytes:     1024 * 1024,
	}

	validator := client.NewURLValidator("www.data.jma.go.jp", false)
	jmaClient := client.NewJMAClient(store, validator, "test", cfg.RequestInterval, cfg.MaxItemBytes, cfg.PollInterval, nil)

	ctrl := NewController(cfg, store, jmaClient, coreClient, validator)

	// Replay spool
	ctrl.replaySpool(context.Background())

	if atomic.LoadInt32(&messageReplayReceived) != 1 {
		t.Fatalf("expected 1 replayed message to core, got %d", messageReplayReceived)
	}

	// Verify spool is deleted after successful replay
	items, err := store.ListSpool()
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 0 {
		t.Fatalf("expected spool cleaned after replay, got %d items", len(items))
	}
}

func TestCoreDroppedMessageRetainsSpool(t *testing.T) {
	tmpDir, err := os.MkdirTemp("", "jma-spool-drop-*")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(tmpDir)

	store, err := state.NewStore(tmpDir, 10*1024*1024)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()

	// Pre-populate spool item
	rawXML := mockTelegramXML
	msgJSON := json.RawMessage(`{"identifier":"20260921012500_0_VXSE53_010000"}`)
	spoolItem := state.SpoolItem{
		ID:         state.SpoolItemKey("https://www.data.jma.go.jp/developer/xml/data/20260921012500_0_VXSE53_010000.xml"),
		ItemURL:    "https://www.data.jma.go.jp/developer/xml/data/20260921012500_0_VXSE53_010000.xml",
		FeedURL:    "https://www.data.jma.go.jp/developer/xml/feed/eqvol.xml",
		FetchedAt:  "2026-09-21T01:25:00Z",
		HTTPStatus: 200,
		RawXML:     &rawXML,
		Message:    msgJSON,
	}
	_ = store.SaveSpool(spoolItem)

	// Mock core returning dropped > 0
	coreServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(map[string]any{
			"received": 1,
			"deduped":  0,
			"written":  0,
			"dropped":  1,
			"message":  "invalid message",
		})
	}))
	defer coreServer.Close()

	coreHTTPClient := core.NewClient(coreServer.URL+"/api/v1", nil)
	coreClient := client.NewCoreClient(coreHTTPClient, nil)

	cfg := &config.Config{
		Feeds:            []string{"https://www.data.jma.go.jp/developer/xml/feed/eqvol.xml"},
		LongFeeds:        []string{"https://www.data.jma.go.jp/developer/xml/feed/eqvol_l.xml"},
		PollInterval:     1 * time.Minute,
		LongPollInterval: 1 * time.Hour,
		RequestInterval:  10 * time.Millisecond,
		StateDir:         tmpDir,
		DailyByteLimit:   10 * 1024 * 1024,
		MaxItemBytes:     1024 * 1024,
	}

	validator := client.NewURLValidator("www.data.jma.go.jp", false)
	jmaClient := client.NewJMAClient(store, validator, "test", cfg.RequestInterval, cfg.MaxItemBytes, cfg.PollInterval, nil)

	ctrl := NewController(cfg, store, jmaClient, coreClient, validator)

	ctrl.replaySpool(context.Background())

	// Spool should RETAIN item because core reported dropped = 1
	items, err := store.ListSpool()
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 1 {
		t.Fatalf("expected spool to retain item on dropped>0, got %d items", len(items))
	}
}

func TestCoreIndexFailureDoesNotCommitValidator(t *testing.T) {
	var jmaServerURL string
	jmaServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/atom+xml")
		w.Header().Set("Last-Modified", "Mon, 21 Sep 2026 01:30:00 GMT")
		w.Header().Set("ETag", `"feed-etag-999"`)
		w.WriteHeader(http.StatusOK)
		body := strings.ReplaceAll(mockAtomFeed, "BASE_URL", jmaServerURL)
		_, _ = w.Write([]byte(body))
	}))
	defer jmaServer.Close()
	jmaServerURL = jmaServer.URL

	// Mock core failing on /index
	coreServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = w.Write([]byte(`{"error":"db connection lost"}`))
	}))
	defer coreServer.Close()

	tmpDir, err := os.MkdirTemp("", "jma-validator-test-*")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(tmpDir)

	parsedJMA, _ := url.Parse(jmaServerURL)
	feedURL := jmaServerURL + "/developer/xml/feed/eqvol.xml"
	cfg := &config.Config{
		Feeds:            []string{feedURL},
		LongFeeds:        []string{},
		PollInterval:     1 * time.Minute,
		LongPollInterval: 1 * time.Hour,
		RequestInterval:  10 * time.Millisecond,
		StateDir:         tmpDir,
		DailyByteLimit:   10 * 1024 * 1024,
		MaxItemBytes:     1024 * 1024,
	}

	store, _ := state.NewStore(tmpDir, cfg.DailyByteLimit)
	defer store.Close()

	validator := client.NewURLValidator(parsedJMA.Hostname(), true)
	jmaClient := client.NewJMAClient(store, validator, "test", cfg.RequestInterval, cfg.MaxItemBytes, cfg.PollInterval, nil)

	coreHTTPClient := core.NewClient(coreServer.URL+"/api/v1", nil)
	coreClient := client.NewCoreClient(coreHTTPClient, nil)

	ctrl := NewController(cfg, store, jmaClient, coreClient, validator)

	// Process feed: core index will fail
	ctrl.processFeed(context.Background(), feedURL, false)

	// Verify that validator was NOT committed to state!
	sch := store.GetFeedSchedule(feedURL)
	if sch.LastModified != "" || sch.ETag != "" {
		t.Fatalf("expected validator NOT saved when core fails, got lm=%s, etag=%s", sch.LastModified, sch.ETag)
	}
}

func TestRetryAfterGlobalBackoff(t *testing.T) {
	rateServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Retry-After", "120")
		w.WriteHeader(http.StatusTooManyRequests)
		_, _ = w.Write([]byte("Rate limit exceeded"))
	}))
	defer rateServer.Close()

	tmpDir, err := os.MkdirTemp("", "jma-retry-test-*")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(tmpDir)

	store, _ := state.NewStore(tmpDir, 10*1024*1024)
	defer store.Close()

	parsed, _ := url.Parse(rateServer.URL)
	validator := client.NewURLValidator(parsed.Hostname(), true)
	jmaClient := client.NewJMAClient(store, validator, "test", 10*time.Millisecond, 1024*1024, time.Minute, nil)

	_, err = jmaClient.FetchFeed(context.Background(), rateServer.URL+"/developer/xml/feed/eqvol.xml")
	if err == nil {
		t.Fatalf("expected 429 error, got nil")
	}

	// Verify global retry was set to ~120s
	remaining, active := jmaClient.CheckGlobalRetry()
	if !active || remaining < 100*time.Second {
		t.Fatalf("expected active global retry > 100s, got active=%v, remaining=%v", active, remaining)
	}
}

func TestDrainPendingLoopsUntilEmpty(t *testing.T) {
	var jmaServerURL string
	var dataCalls int32

	jmaServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&dataCalls, 1)
		w.Header().Set("Content-Type", "application/xml")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(mockTelegramXML))
	}))
	defer jmaServer.Close()
	jmaServerURL = jmaServer.URL

	var pendingCalls int32
	var messageCalls int32

	coreServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		path := r.URL.Path
		switch {
		case strings.HasSuffix(path, "/jma_data/pending"):
			call := atomic.AddInt32(&pendingCalls, 1)
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusOK)
			switch call {
			case 1:
				// Batch 1: two items
				_ = json.NewEncoder(w).Encode(map[string]any{
					"items": []map[string]string{
						{"item_url": jmaServerURL + "/developer/xml/data/item1.xml", "feed_url": jmaServerURL + "/developer/xml/feed/eqvol.xml"},
						{"item_url": jmaServerURL + "/developer/xml/data/item2.xml", "feed_url": jmaServerURL + "/developer/xml/feed/eqvol.xml"},
					},
				})
			case 2:
				// Batch 2: one item
				_ = json.NewEncoder(w).Encode(map[string]any{
					"items": []map[string]string{
						{"item_url": jmaServerURL + "/developer/xml/data/item3.xml", "feed_url": jmaServerURL + "/developer/xml/feed/eqvol.xml"},
					},
				})
			default:
				// Batch 3+: empty queue
				_ = json.NewEncoder(w).Encode(map[string]any{
					"items": []map[string]string{},
				})
			}
		case strings.HasSuffix(path, "/jma_data/messages"):
			atomic.AddInt32(&messageCalls, 1)
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusOK)
			_ = json.NewEncoder(w).Encode(map[string]any{
				"received": 1,
				"deduped":  0,
				"written":  1,
				"dropped":  0,
				"message":  "1 messages written",
			})
		default:
			http.NotFound(w, r)
		}
	}))
	defer coreServer.Close()

	tmpDir, err := os.MkdirTemp("", "jma-drain-test-*")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(tmpDir)

	parsedJMA, _ := url.Parse(jmaServerURL)
	cfg := &config.Config{
		Feeds:            []string{},
		LongFeeds:        []string{},
		PollInterval:     1 * time.Minute,
		LongPollInterval: 1 * time.Hour,
		RequestInterval:  1 * time.Millisecond,
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

	coreHTTPClient := core.NewClient(coreServer.URL+"/api/v1", nil)
	coreClient := client.NewCoreClient(coreHTTPClient, nil)

	ctrl := NewController(cfg, store, jmaClient, coreClient, validator)

	// Execute drainPending with a 5-second deadline
	ctx := context.Background()
	deadline := time.Now().Add(5 * time.Second)
	ctrl.drainPending(ctx, deadline)

	// drainPending should have looped until pending was empty (3 calls to GetPending)
	if pCalls := atomic.LoadInt32(&pendingCalls); pCalls != 3 {
		t.Fatalf("expected 3 pending calls (batch 1, batch 2, empty batch 3), got %d", pCalls)
	}

	// All 3 items should have been fetched and delivered to Core
	if dCalls := atomic.LoadInt32(&dataCalls); dCalls != 3 {
		t.Fatalf("expected 3 data fetches, got %d", dCalls)
	}
	if mCalls := atomic.LoadInt32(&messageCalls); mCalls != 3 {
		t.Fatalf("expected 3 message deliveries to core, got %d", mCalls)
	}
}

func TestTransientFetchFailureReportedToCore(t *testing.T) {
	var jmaServerURL string

	// Upstream JMA server returns transient 500 error
	jmaServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = w.Write([]byte("Internal Server Error"))
	}))
	defer jmaServer.Close()
	jmaServerURL = jmaServer.URL

	var messageCalls int32
	var reportedResult client.JmaFetchResult

	coreServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/jma_data/messages") {
			atomic.AddInt32(&messageCalls, 1)
			body, _ := io.ReadAll(r.Body)
			var env struct {
				Features []client.JmaFetchResult `json:"features"`
			}
			_ = json.Unmarshal(body, &env)
			if len(env.Features) > 0 {
				reportedResult = env.Features[0]
			}

			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusOK)
			// Core acknowledges failure as dropped=1, written=0
			_ = json.NewEncoder(w).Encode(map[string]any{
				"received": 1,
				"deduped":  0,
				"written":  0,
				"dropped":  1,
				"message":  "1 items recorded failed",
			})
			return
		}
		http.NotFound(w, r)
	}))
	defer coreServer.Close()

	tmpDir, err := os.MkdirTemp("", "jma-fail-report-*")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(tmpDir)

	parsedJMA, _ := url.Parse(jmaServerURL)
	cfg := &config.Config{
		Feeds:            []string{},
		LongFeeds:        []string{},
		PollInterval:     1 * time.Minute,
		LongPollInterval: 1 * time.Hour,
		RequestInterval:  1 * time.Millisecond,
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

	coreHTTPClient := core.NewClient(coreServer.URL+"/api/v1", nil)
	coreClient := client.NewCoreClient(coreHTTPClient, nil)

	ctrl := NewController(cfg, store, jmaClient, coreClient, validator)

	itemURL := jmaServerURL + "/developer/xml/data/20260921012500_0_VXSE53_010000.xml"
	feedURL := jmaServerURL + "/developer/xml/feed/eqvol.xml"

	// Trigger single item ingestion that fails with 500
	ctrl.fetchAndIngestItem(context.Background(), itemURL, feedURL)

	// Failure MUST be reported to core via SendMessages
	if atomic.LoadInt32(&messageCalls) != 1 {
		t.Fatalf("expected 1 failure report message to core, got %d", messageCalls)
	}

	if reportedResult.HTTPStatus != 500 {
		t.Fatalf("expected reported HTTPStatus 500, got %d", reportedResult.HTTPStatus)
	}
	if reportedResult.Error == nil || !strings.Contains(*reportedResult.Error, "500") {
		t.Fatalf("expected error string containing 500, got %v", reportedResult.Error)
	}

	// Item must NOT be marked permanently fetched locally since it was a transient error
	if store.IsFetched(itemURL) {
		t.Fatalf("expected transiently failed item NOT to be marked fetched in local store")
	}

	// Spool must be empty (nothing spooled for failed fetch)
	items, err := store.ListSpool()
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 0 {
		t.Fatalf("expected spool to be empty on transient fetch failure, got %d", len(items))
	}
}

func TestControllerRunSleepsWhenQueueEmpty(t *testing.T) {
	tmpDir, err := os.MkdirTemp("", "jma-run-sleep-*")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(tmpDir)

	store, err := state.NewStore(tmpDir, 10*1024*1024)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()

	// Mock core returning empty queue
	coreServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/jma_data/pending") {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusOK)
			_ = json.NewEncoder(w).Encode(map[string]any{"items": []any{}})
			return
		}
		http.NotFound(w, r)
	}))
	defer coreServer.Close()

	cfg := &config.Config{
		Feeds:            []string{},
		LongFeeds:        []string{},
		PollInterval:     500 * time.Millisecond,
		LongPollInterval: 1 * time.Hour,
		RequestInterval:  1 * time.Millisecond,
		StateDir:         tmpDir,
		DailyByteLimit:   10 * 1024 * 1024,
		MaxItemBytes:     1024 * 1024,
		UserAgent:        "matrixwhale-jma-adapter",
	}

	validator := client.NewURLValidator("localhost", true)
	jmaClient := client.NewJMAClient(store, validator, cfg.UserAgent, cfg.RequestInterval, cfg.MaxItemBytes, cfg.PollInterval, nil)

	coreHTTPClient := core.NewClient(coreServer.URL+"/api/v1", nil)
	coreClient := client.NewCoreClient(coreHTTPClient, nil)

	ctrl := NewController(cfg, store, jmaClient, coreClient, validator)

	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()

	done := make(chan struct{})
	go func() {
		ctrl.Run(ctx)
		close(done)
	}()

	select {
	case <-done:
		// Clean exit on context expiration
	case <-time.After(2 * time.Second):
		t.Fatalf("ctrl.Run did not terminate cleanly on context cancel")
	}
}
