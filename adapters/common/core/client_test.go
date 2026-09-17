package core

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestClientSendPostsEnvelopeAndDecodesAck(t *testing.T) {
	var received struct {
		PollMeta PollMeta          `json:"poll_meta"`
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

	client := NewClient(server.URL+"/api/v1", &http.Client{})
	features := []json.RawMessage{json.RawMessage(`{"a":1}`), json.RawMessage(`{"a":2}`)}
	meta := PollMeta{FetchedAt: "2026-09-17T00:00:00Z", HTTPStatus: 200, FeatureCount: 2, Bytes: 42, FeedURL: "https://example/all_week.geojson", Backfill: true}

	ack, err := client.Send(context.Background(), "usgs_data/send", meta, features)
	if err != nil {
		t.Fatal(err)
	}
	if received.PollMeta.FeedURL != meta.FeedURL || !received.PollMeta.Backfill || received.PollMeta.Bytes != meta.Bytes || len(received.Features) != 2 {
		t.Fatalf("poll_meta/features sent = %+v", received)
	}
	if err := ValidateAck(ack, len(features)); err != nil {
		t.Fatalf("ValidateAck: %v", err)
	}
}

func TestClientSendRejectsUndecodableResponse(t *testing.T) {
	tests := []struct {
		name string
		body string
	}{
		{name: "non-object", body: `[]`},
		{name: "wrong field type", body: `{"received":"1","deduped":0,"written":1,"dropped":0,"message":"ok"}`},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				_, _ = w.Write([]byte(tt.body))
			}))
			defer server.Close()

			client := NewClient(server.URL, &http.Client{})
			if _, err := client.Send(context.Background(), "usgs_data/send", PollMeta{}, nil); err == nil {
				t.Fatal("undecodable response was accepted")
			}
		})
	}
}

func TestClientSendRejectsNonSuccessStatus(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = w.Write([]byte("boom"))
	}))
	defer server.Close()

	client := NewClient(server.URL, &http.Client{})
	if _, err := client.Send(context.Background(), "usgs_data/send", PollMeta{}, nil); err == nil {
		t.Fatal("non-2xx response was accepted")
	}
}

func TestValidateAckRejectsMalformedAcknowledgements(t *testing.T) {
	tests := []struct {
		name string
		body string
	}{
		{name: "empty object", body: `{}`},
		{name: "error object", body: `{"error":"failed"}`},
		{name: "missing message", body: `{"received":1,"deduped":0,"written":1,"dropped":0}`},
		{name: "negative count", body: `{"received":1,"deduped":-1,"written":1,"dropped":1,"message":"ok"}`},
		{name: "wrong received", body: `{"received":0,"deduped":0,"written":1,"dropped":0,"message":"ok"}`},
		{name: "sum mismatch", body: `{"received":2,"deduped":0,"written":1,"dropped":0,"message":"ok"}`},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var ack Ack
			if err := json.Unmarshal([]byte(tt.body), &ack); err != nil {
				t.Fatalf("unmarshal fixture: %v", err)
			}
			if err := ValidateAck(ack, 1); err == nil {
				t.Fatal("malformed acknowledgement was accepted")
			}
		})
	}
}

func TestValidateAckAcceptsBalancedCounts(t *testing.T) {
	var ack Ack
	if err := json.Unmarshal([]byte(`{"received":3,"deduped":1,"written":2,"dropped":0,"message":"ok"}`), &ack); err != nil {
		t.Fatal(err)
	}
	if err := ValidateAck(ack, 3); err != nil {
		t.Fatalf("ValidateAck rejected a valid ack: %v", err)
	}
}
