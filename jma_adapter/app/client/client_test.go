package client

import (
	"bytes"
	"compress/gzip"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"

	"jma_adapter/state"
	"matrixwhale/adapters/common/core"
)

func TestFloat64JSONFormatting(t *testing.T) {
	type Sample struct {
		Val Float64 `json:"val"`
	}

	// 10.0 should format as 10.0
	s1 := Sample{Val: Float64(10.0)}
	b1, err := json.Marshal(s1)
	if err != nil {
		t.Fatal(err)
	}
	if string(b1) != `{"val":10.0}` {
		t.Fatalf("expected 10.0, got %s", string(b1))
	}

	// 10.5 should format as 10.5
	s2 := Sample{Val: Float64(10.5)}
	b2, err := json.Marshal(s2)
	if err != nil {
		t.Fatal(err)
	}
	if string(b2) != `{"val":10.5}` {
		t.Fatalf("expected 10.5, got %s", string(b2))
	}
}

func TestJMAClientConditional304AndGzip(t *testing.T) {
	var etagSent string
	mockServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		etagSent = r.Header.Get("If-None-Match")
		if etagSent == `"existing-etag"` {
			w.WriteHeader(http.StatusNotModified)
			return
		}

		// Return gzipped body
		w.Header().Set("Content-Type", "application/atom+xml")
		w.Header().Set("Content-Encoding", "gzip")
		w.Header().Set("ETag", `"new-etag"`)
		w.Header().Set("Last-Modified", "Mon, 21 Sep 2026 01:00:00 GMT")
		w.WriteHeader(http.StatusOK)

		var buf bytes.Buffer
		gz := gzip.NewWriter(&buf)
		_, _ = gz.Write([]byte("<feed>sample feed</feed>"))
		_ = gz.Close()
		_, _ = w.Write(buf.Bytes())
	}))
	defer mockServer.Close()

	tmpDir, err := os.MkdirTemp("", "jma-client-test-*")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(tmpDir)

	store, err := state.NewStore(tmpDir, 10*1024*1024)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()

	parsed, _ := url.Parse(mockServer.URL)
	validator := NewURLValidator(parsed.Hostname(), true)
	jmaClient := NewJMAClient(store, validator, "test", 10*time.Millisecond, 1024*1024, time.Minute, nil)

	feedURL := mockServer.URL + "/developer/xml/feed/eqvol.xml"

	// Call 1: fresh fetch (200 OK with gzip)
	res1, err := jmaClient.FetchFeed(context.Background(), feedURL)
	if err != nil {
		t.Fatalf("first fetch failed: %v", err)
	}
	if res1.NotModified {
		t.Fatalf("expected 200 fresh, got notModified")
	}
	if string(res1.Body) != "<feed>sample feed</feed>" {
		t.Fatalf("body mismatch: %s", string(res1.Body))
	}
	if res1.ETag != `"new-etag"` {
		t.Fatalf("etag mismatch: %s", res1.ETag)
	}

	// Durably record validator in state as if core accepted
	_ = store.SaveFeedValidator(feedURL, res1.LastModified, `"existing-etag"`, time.Now())

	// Call 2: conditional fetch -> server answers 304
	res2, err := jmaClient.FetchFeed(context.Background(), feedURL)
	if err != nil {
		t.Fatalf("second fetch failed: %v", err)
	}
	if !res2.NotModified {
		t.Fatalf("expected 304 not modified")
	}
	if etagSent != `"existing-etag"` {
		t.Fatalf("expected If-None-Match sent with existing-etag, got %s", etagSent)
	}
}

func TestJMAClientTypedUpstreamError(t *testing.T) {
	mockServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.Contains(r.URL.Path, "rate-limit") {
			w.Header().Set("Retry-After", "45")
			w.WriteHeader(http.StatusTooManyRequests)
			_, _ = w.Write([]byte("too many requests"))
			return
		}
		if strings.Contains(r.URL.Path, "missing") {
			w.WriteHeader(http.StatusNotFound)
			_, _ = w.Write([]byte("not found"))
			return
		}
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = w.Write([]byte("server error"))
	}))
	defer mockServer.Close()

	tmpDir, err := os.MkdirTemp("", "jma-err-test-*")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(tmpDir)

	store, _ := state.NewStore(tmpDir, 10*1024*1024)
	defer store.Close()

	parsed, _ := url.Parse(mockServer.URL)
	validator := NewURLValidator(parsed.Hostname(), true)
	jmaClient := NewJMAClient(store, validator, "test", 10*time.Millisecond, 1024*1024, time.Minute, nil)

	// 1. Test 429 Retry-After
	_, err = jmaClient.FetchData(context.Background(), mockServer.URL+"/developer/xml/data/rate-limit.xml")
	if err == nil {
		t.Fatalf("expected 429 error, got nil")
	}
	var upErr *UpstreamError
	if !errors.As(err, &upErr) {
		t.Fatalf("expected UpstreamError, got %T: %v", err, err)
	}
	if upErr.StatusCode != 429 || !upErr.HasRetry || upErr.RetryAfter != 45*time.Second {
		t.Fatalf("unexpected upErr fields: %+v", upErr)
	}

	// 2. Test 404 (reset global retry first)
	if err := jmaClient.SetGlobalRetry(time.Time{}); err != nil {
		t.Fatalf("SetGlobalRetry: %v", err)
	}
	_, err = jmaClient.FetchData(context.Background(), mockServer.URL+"/developer/xml/data/missing.xml")
	if err == nil {
		t.Fatalf("expected 404 error, got nil")
	}
	if !errors.As(err, &upErr) || upErr.StatusCode != 404 {
		t.Fatalf("expected 404 UpstreamError, got %v", err)
	}
}

func TestCoreClientValidateAckDropped(t *testing.T) {
	// Mock core returning dropped > 0
	coreServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(map[string]any{
			"received": 1,
			"deduped":  0,
			"written":  0,
			"dropped":  1,
			"message":  "invalid item rejected",
		})
	}))
	defer coreServer.Close()

	coreHTTPClient := core.NewClient(coreServer.URL+"/api/v1", nil)
	coreClient := NewCoreClient(coreHTTPClient, nil)

	results := []JmaFetchResult{
		{
			ItemURL:    "https://www.data.jma.go.jp/developer/xml/data/test.xml",
			FeedURL:    "https://www.data.jma.go.jp/developer/xml/feed/eqvol.xml",
			FetchedAt:  "2026-09-21T01:00:00Z",
			HTTPStatus: 200,
		},
	}
	meta := core.PollMeta{
		FetchedAt:    "2026-09-21T01:00:00Z",
		HTTPStatus:   200,
		FeatureCount: 1,
		Bytes:        100,
	}

	_, err := coreClient.SendMessages(context.Background(), meta, results)
	if err == nil || !strings.Contains(err.Error(), "core dropped 1 features") {
		t.Fatalf("expected core dropped error, got %v", err)
	}
}

func TestJmaMessageContentJSONContract(t *testing.T) {
	// 1. Quake without areas or alerts: must serialize as [] not null
	content := JmaMessageContent{
		Identifier:   "20260920074051_0_VXSE53_270000",
		ControlTitle: "震源・震度に関する情報",
		Status:       "通常",
		InfoType:     "発表",
		Sent:         "2026-09-20T07:40:51Z",
		Areas:        make([]JmaArea, 0),
		Alerts:       make([]JmaAlertItem, 0),
	}

	b, err := json.Marshal(content)
	if err != nil {
		t.Fatalf("marshal failed: %v", err)
	}
	s := string(b)
	if !strings.Contains(s, `"areas":[]`) {
		t.Fatalf("expected areas:[], got %s", s)
	}
	if strings.Contains(s, `"areas":null`) {
		t.Fatalf("areas must never be null: %s", s)
	}
	if !strings.Contains(s, `"alerts":[]`) {
		t.Fatalf("expected alerts:[], got %s", s)
	}
	if strings.Contains(s, `"alerts":null`) {
		t.Fatalf("alerts must never be null: %s", s)
	}
	if strings.Contains(s, "cleared_areas") {
		t.Fatalf("empty cleared_areas must be omitted: %s", s)
	}

	// 2. Weather with cleared areas: must serialize non-empty cleared_areas
	contentWithCleared := JmaMessageContent{
		Identifier:   "20260920164632_0_VPWW54_080000",
		ControlTitle: "気象警報・注意報（Ｈ２７）",
		Status:       "通常",
		InfoType:     "発表",
		Sent:         "2026-09-20T16:46:30Z",
		Areas:        make([]JmaArea, 0),
		Alerts:       make([]JmaAlertItem, 0),
		ClearedAreas: []string{"0822200"},
	}
	b2, err := json.Marshal(contentWithCleared)
	if err != nil {
		t.Fatalf("marshal failed: %v", err)
	}
	s2 := string(b2)
	if !strings.Contains(s2, `"cleared_areas":["0822200"]`) {
		t.Fatalf("expected cleared_areas:[0822200], got %s", s2)
	}
}
