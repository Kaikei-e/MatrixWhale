package adapter

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	"matrixwhale/adapters/common/core"
)

func TestMatrixWhaleAdapterSendsContractAndValidatesResponse(t *testing.T) {
	var received struct {
		PollMeta core.PollMeta     `json:"poll_meta"`
		Features []json.RawMessage `json:"features"`
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v1/usgs_data/send" {
			t.Errorf("path = %q", r.URL.Path)
		}
		if err := json.NewDecoder(r.Body).Decode(&received); err != nil {
			t.Errorf("decode request: %v", err)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"received":2,"deduped":0,"written":2,"dropped":0,"message":"ok"}`))
	}))
	defer server.Close()
	t.Setenv("MATRIX_WHALE_URL", server.URL+"/api/v1")
	t.Setenv("USGS_MIN_MAG", "2.5")

	body := []byte(`{"type":"FeatureCollection","features":[{"type":"Feature","properties":{"mag":2.4}},{"type":"Feature","properties":{"mag":2.5}},{"type":"Feature","properties":{"mag":null}}]}`)
	err := MatrixWhaleAdapter(context.Background(), PollResult{
		Body: body, FetchedAt: time.Date(2026, 9, 17, 0, 0, 0, 0, time.UTC),
		HTTPStatus: http.StatusOK, Bytes: len(body), FeedURL: USGSAllWeekURL, Backfill: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	if received.PollMeta.FeedURL != USGSAllWeekURL || !received.PollMeta.Backfill || received.PollMeta.FeatureCount != 2 || received.PollMeta.Bytes != len(body) {
		t.Fatalf("poll_meta = %+v", received.PollMeta)
	}
	if len(received.Features) != 2 {
		t.Fatalf("feature count = %d, want 2", len(received.Features))
	}
}

func TestFilterFeaturesDefaultsToAllAndKeepsNullMagnitude(t *testing.T) {
	features := []json.RawMessage{
		json.RawMessage(`{"properties":{"mag":2.4}}`),
		json.RawMessage(`{"properties":{"mag":null}}`),
	}
	os.Unsetenv("USGS_MIN_MAG")
	if got := filterFeatures(features, configuredMinMagnitude()); len(got) != 2 {
		t.Fatalf("default filter returned %d features", len(got))
	}
	minimum := 2.5
	if got := filterFeatures(features, &minimum); len(got) != 1 {
		t.Fatalf("minimum filter returned %d features", len(got))
	}
}

func TestMatrixWhaleAdapterRejectsNonObjectResponse(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`[]`))
	}))
	defer server.Close()
	t.Setenv("MATRIX_WHALE_URL", server.URL)
	err := MatrixWhaleAdapter(context.Background(), PollResult{FetchedAt: time.Now(), HTTPStatus: http.StatusNotModified})
	if err == nil {
		t.Fatal("non-object response was accepted")
	}
}
