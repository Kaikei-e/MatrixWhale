package adapter

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"matrixwhale/adapters/common/core"
)

func TestMatrixWhaleAdapterSendsEnvelopeAndValidatesAck(t *testing.T) {
	var received struct {
		PollMeta core.PollMeta     `json:"poll_meta"`
		Features []json.RawMessage `json:"features"`
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v1/noaa_data/send" {
			t.Errorf("path = %q", r.URL.Path)
		}
		if err := json.NewDecoder(r.Body).Decode(&received); err != nil {
			t.Errorf("decode request: %v", err)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"received":1,"deduped":0,"written":1,"dropped":0,"message":"1 new, 0 updated, 0 ended"}`))
	}))
	defer server.Close()
	t.Setenv("MATRIX_WHALE_URL", server.URL+"/api/v1")

	body := []byte(`{"features":[{"type":"Feature","properties":{"event":"Test"}}]}`)
	err := MatrixWhaleAdapter(PollResult{
		Body:       body,
		FetchedAt:  time.Date(2026, 9, 18, 0, 0, 0, 0, time.UTC),
		HTTPStatus: http.StatusOK,
		Bytes:      len(body),
	})
	if err != nil {
		t.Fatal(err)
	}
	if received.PollMeta.FeatureCount != 1 || received.PollMeta.Bytes != len(body) {
		t.Fatalf("poll_meta = %+v", received.PollMeta)
	}
	if len(received.Features) != 1 {
		t.Fatalf("feature count = %d, want 1", len(received.Features))
	}
}

func TestMatrixWhaleAdapterSurfacesAckValidationFailure(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		// received does not match the sent feature count: ValidateAck must reject this.
		_, _ = w.Write([]byte(`{"received":5,"deduped":0,"written":1,"dropped":0,"message":"bad"}`))
	}))
	defer server.Close()
	t.Setenv("MATRIX_WHALE_URL", server.URL)

	body := []byte(`{"features":[{"type":"Feature","properties":{"event":"Test"}}]}`)
	err := MatrixWhaleAdapter(PollResult{
		Body:       body,
		FetchedAt:  time.Now(),
		HTTPStatus: http.StatusOK,
		Bytes:      len(body),
	})
	if err == nil {
		t.Fatal("ack validation failure was not surfaced as an error")
	}
}

func TestMatrixWhaleAdapterNotModifiedSendsEmptyFeatures(t *testing.T) {
	var received struct {
		Features []json.RawMessage `json:"features"`
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if err := json.NewDecoder(r.Body).Decode(&received); err != nil {
			t.Errorf("decode request: %v", err)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"received":0,"deduped":0,"written":0,"dropped":0,"message":"0 new, 0 updated, 0 ended"}`))
	}))
	defer server.Close()
	t.Setenv("MATRIX_WHALE_URL", server.URL)

	err := MatrixWhaleAdapter(PollResult{FetchedAt: time.Now(), HTTPStatus: http.StatusNotModified})
	if err != nil {
		t.Fatal(err)
	}
	if len(received.Features) != 0 {
		t.Fatalf("feature count = %d, want 0", len(received.Features))
	}
}
