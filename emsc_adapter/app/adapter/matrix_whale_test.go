package adapter_test

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"matrixwhale/adapters/common/core"

	"emsc_adapter/adapter"
)

func TestMatrixWhaleAdapterSendsEnvelopeShapeAndPollMeta(t *testing.T) {
	var received struct {
		PollMeta core.PollMeta     `json:"poll_meta"`
		Features []json.RawMessage `json:"features"`
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v1/emsc_data/send" {
			t.Errorf("path = %q", r.URL.Path)
		}
		if err := json.NewDecoder(r.Body).Decode(&received); err != nil {
			t.Errorf("decode request: %v", err)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"received":1,"deduped":0,"written":1,"dropped":0,"message":"ok"}`))
	}))
	defer server.Close()
	t.Setenv("MATRIX_WHALE_URL", server.URL+"/api/v1")

	raw := json.RawMessage(`{"action":"update","data":{"type":"Feature","properties":{"unid":"20260918_0000001"}}}`)
	fetchedAt := time.Date(2026, 9, 18, 0, 0, 0, 0, time.UTC)

	err := adapter.MatrixWhaleAdapter(context.Background(), adapter.Batch{
		Features:   []json.RawMessage{raw},
		FetchedAt:  fetchedAt,
		HTTPStatus: http.StatusOK,
		Bytes:      len(raw),
		FeedURL:    "wss://www.seismicportal.eu/standing_order/websocket",
		Backfill:   false,
	})
	if err != nil {
		t.Fatal(err)
	}
	if received.PollMeta.FeedURL != "wss://www.seismicportal.eu/standing_order/websocket" {
		t.Errorf("feed_url = %q", received.PollMeta.FeedURL)
	}
	if received.PollMeta.Backfill {
		t.Error("backfill = true, want false")
	}
	if received.PollMeta.FeatureCount != 1 || received.PollMeta.Bytes != len(raw) || received.PollMeta.HTTPStatus != http.StatusOK {
		t.Errorf("poll_meta = %+v", received.PollMeta)
	}
	if len(received.Features) != 1 || !bytes.Equal(received.Features[0], raw) {
		t.Errorf("features = %s, want %s untouched", received.Features, raw)
	}
}

func TestMatrixWhaleAdapterRejectsNonObjectResponse(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`[]`))
	}))
	defer server.Close()
	t.Setenv("MATRIX_WHALE_URL", server.URL)

	err := adapter.MatrixWhaleAdapter(context.Background(), adapter.Batch{FetchedAt: time.Now(), HTTPStatus: http.StatusOK})
	if err == nil {
		t.Fatal("non-object response was accepted")
	}
}

func TestMatrixWhaleAdapterAckValidationFailureReturnsError(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"received":5,"deduped":0,"written":1,"dropped":0,"message":"mismatch"}`))
	}))
	defer server.Close()
	t.Setenv("MATRIX_WHALE_URL", server.URL+"/api/v1")

	batch := adapter.Batch{
		Features:   []json.RawMessage{json.RawMessage(`{"action":"create","data":{}}`)},
		FetchedAt:  time.Now(),
		HTTPStatus: http.StatusOK,
		FeedURL:    "https://www.seismicportal.eu/fdsnws/event/1/query",
		Backfill:   true,
	}
	if err := adapter.MatrixWhaleAdapter(context.Background(), batch); err == nil {
		t.Fatal("ack with mismatched counts was accepted")
	}
}

func TestBackfillBatchWrapsFeaturesAsCreate(t *testing.T) {
	feature := json.RawMessage(`{"type":"Feature","properties":{"unid":"x"}}`)
	result := adapter.FetchResult{
		Features: []json.RawMessage{feature}, FetchedAt: time.Now(), HTTPStatus: http.StatusOK, Bytes: 42, URL: "https://example/fdsn",
	}

	batch, err := adapter.BackfillBatch(result)
	if err != nil {
		t.Fatal(err)
	}
	if !batch.Backfill || batch.Bytes != 42 || batch.FeedURL != result.URL || len(batch.Features) != 1 {
		t.Fatalf("batch = %+v", batch)
	}

	var wrapped struct {
		Action string          `json:"action"`
		Data   json.RawMessage `json:"data"`
	}
	if err := json.Unmarshal(batch.Features[0], &wrapped); err != nil {
		t.Fatal(err)
	}
	if wrapped.Action != "create" || !bytes.Equal(wrapped.Data, feature) {
		t.Fatalf("wrapped = %+v", wrapped)
	}
}

func TestLiveBatchSumsBytesPreservesOrderAndForwardsRaw(t *testing.T) {
	m1 := adapter.LiveMessage{Raw: json.RawMessage(`{"action":"create","data":{"n":1}}`)}
	m2 := adapter.LiveMessage{Raw: json.RawMessage(`{"action":"delete","data":{"n":2}}`)}

	batch := adapter.LiveBatch([]adapter.LiveMessage{m1, m2}, "wss://www.seismicportal.eu/standing_order/websocket")
	if batch.Backfill {
		t.Error("live batch marked as backfill")
	}
	if batch.HTTPStatus != http.StatusOK {
		t.Errorf("http_status = %d, want 200", batch.HTTPStatus)
	}
	if batch.Bytes != len(m1.Raw)+len(m2.Raw) {
		t.Errorf("bytes = %d, want %d", batch.Bytes, len(m1.Raw)+len(m2.Raw))
	}
	if len(batch.Features) != 2 || !bytes.Equal(batch.Features[0], m1.Raw) || !bytes.Equal(batch.Features[1], m2.Raw) {
		t.Fatalf("features order/content mismatch: %s", batch.Features)
	}
}
