package adapter

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestFetchFeedConditional304(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if got := r.Header.Get("If-Modified-Since"); got != "Wed, 16 Sep 2026 00:00:00 GMT" {
			t.Errorf("If-Modified-Since = %q", got)
		}
		if !strings.Contains(r.Header.Get("Accept"), "application/geo+json") {
			t.Errorf("Accept = %q", r.Header.Get("Accept"))
		}
		w.WriteHeader(http.StatusNotModified)
	}))
	defer server.Close()

	result, err := FetchFeed(context.Background(), server.URL, "Wed, 16 Sep 2026 00:00:00 GMT")
	if err != nil {
		t.Fatal(err)
	}
	if result.HTTPStatus != http.StatusNotModified || result.Bytes != 0 || len(result.Body) != 0 {
		t.Fatalf("304 result = status %d, bytes %d, body %d", result.HTTPStatus, result.Bytes, len(result.Body))
	}
}

func TestFetchFeedValidatesTopLevelOnly(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Last-Modified", "Wed, 16 Sep 2026 00:00:00 GMT")
		_, _ = w.Write([]byte(`{"type":"FeatureCollection","features":[{"type":"not-a-feature","geometry":null}]}`))
	}))
	defer server.Close()

	result, err := FetchFeed(context.Background(), server.URL, "")
	if err != nil {
		t.Fatalf("individual feature should be passed to core validation: %v", err)
	}
	if result.Bytes == 0 || result.FeedURL != server.URL {
		t.Fatalf("result metadata = bytes %d, url %q", result.Bytes, result.FeedURL)
	}
}

func TestFetchFeedRejectsInvalidTopLevelAndOversizedBody(t *testing.T) {
	invalid := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"type":"Feature","features":[]}`))
	}))
	defer invalid.Close()
	if _, err := FetchFeed(context.Background(), invalid.URL, ""); err == nil {
		t.Fatal("invalid top-level GeoJSON was accepted")
	}

	// The production limit is intentionally large enough for all_week, so this
	// test exercises the validator with a smaller local helper instead.
	if _, err := readLimited(strings.NewReader("12345"), 4); err == nil {
		t.Fatal("oversized body was accepted")
	}
}
