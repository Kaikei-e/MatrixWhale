package adapter

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"context"

	"matrixwhale/adapters/common/core"
)

func TestSendEventsPostsContractAndValidatesAck(t *testing.T) {
	var received struct {
		PollMeta core.PollMeta     `json:"poll_meta"`
		Features []json.RawMessage `json:"features"`
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v1/gdacs_data/send" {
			t.Errorf("path = %q", r.URL.Path)
		}
		if err := json.NewDecoder(r.Body).Decode(&received); err != nil {
			t.Errorf("decode request: %v", err)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"received":2,"deduped":0,"written":2,"dropped":0,"message":"ok"}`))
	}))
	defer server.Close()

	mw := NewMatrixWhaleAdapter(core.NewClient(server.URL+"/api/v1", server.Client()))
	features := []json.RawMessage{json.RawMessage(`{"a":1}`), json.RawMessage(`{"a":2}`)}
	meta := core.PollMeta{FeedURL: "https://gdacs/x", Backfill: true, FeatureCount: 2}

	if err := mw.SendEvents(context.Background(), meta, features); err != nil {
		t.Fatalf("SendEvents: %v", err)
	}
	if !received.PollMeta.Backfill || len(received.Features) != 2 {
		t.Fatalf("poll_meta/features sent = %+v", received)
	}
}

func TestSendEventsRejectsUnbalancedAck(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"received":0,"deduped":0,"written":0,"dropped":0,"message":"ok"}`))
	}))
	defer server.Close()

	mw := NewMatrixWhaleAdapter(core.NewClient(server.URL, server.Client()))
	features := []json.RawMessage{json.RawMessage(`{"a":1}`)}
	if err := mw.SendEvents(context.Background(), core.PollMeta{}, features); err == nil {
		t.Fatal("ack with received=0 for one sent feature was accepted")
	}
}

func TestPendingGeometryDecodesEpisodesAndLimit(t *testing.T) {
	var gotPath, gotQuery string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		gotQuery = r.URL.RawQuery
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"episodes":[{"eventtype":"EQ","eventid":1565193,"episodeid":1732972},{"eventtype":"TC","eventid":9,"episodeid":11}]}`))
	}))
	defer server.Close()

	mw := NewMatrixWhaleAdapter(core.NewClient(server.URL+"/api/v1", server.Client()))
	entries, err := mw.PendingGeometry(context.Background(), 20)
	if err != nil {
		t.Fatalf("PendingGeometry: %v", err)
	}
	if gotPath != "/api/v1/gdacs_data/geometry/pending" {
		t.Fatalf("path = %q", gotPath)
	}
	if gotQuery != "limit=20" {
		t.Fatalf("query = %q, want limit=20", gotQuery)
	}
	if len(entries) != 2 || entries[0].EventType != "EQ" || entries[0].EventID != 1565193 || entries[0].EpisodeID != 1732972 {
		t.Fatalf("entries = %+v", entries)
	}
}

func TestPendingGeometryErrorsOnNonSuccessStatus(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer server.Close()

	mw := NewMatrixWhaleAdapter(core.NewClient(server.URL, server.Client()))
	if _, err := mw.PendingGeometry(context.Background(), 20); err == nil {
		t.Fatal("500 status was accepted as success")
	}
}

func TestSendGeometryEncodesEntriesIncludingNullGeometry(t *testing.T) {
	var received struct {
		Features []json.RawMessage `json:"features"`
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v1/gdacs_data/geometry" {
			t.Errorf("path = %q", r.URL.Path)
		}
		if err := json.NewDecoder(r.Body).Decode(&received); err != nil {
			t.Errorf("decode request: %v", err)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"received":2,"deduped":0,"written":2,"dropped":0,"message":"ok"}`))
	}))
	defer server.Close()

	mw := NewMatrixWhaleAdapter(core.NewClient(server.URL+"/api/v1", server.Client()))
	entries := []GeometryResult{
		{EventType: "EQ", EventID: 1565193, EpisodeID: 1732972, HTTPStatus: 200, Geometry: json.RawMessage(`{"type":"FeatureCollection","features":[]}`)},
		{EventType: "TC", EventID: 9, EpisodeID: 11, HTTPStatus: 204, Geometry: nil},
	}
	if err := mw.SendGeometry(context.Background(), core.PollMeta{}, entries); err != nil {
		t.Fatalf("SendGeometry: %v", err)
	}
	if len(received.Features) != 2 {
		t.Fatalf("features sent = %d, want 2", len(received.Features))
	}
	var second map[string]json.RawMessage
	if err := json.Unmarshal(received.Features[1], &second); err != nil {
		t.Fatalf("decode second entry: %v", err)
	}
	if string(second["geometry"]) != "null" {
		t.Fatalf("geometry = %s, want null", second["geometry"])
	}
	if string(second["http_status"]) != "204" {
		t.Fatalf("http_status = %s, want 204", second["http_status"])
	}
}
