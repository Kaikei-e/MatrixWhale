package adapter_test

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"

	"emsc_adapter/adapter"
)

func TestBuildFDSNURLIncludesExpectedParams(t *testing.T) {
	start := time.Date(2026, 9, 11, 0, 0, 0, 0, time.UTC)
	end := time.Date(2026, 9, 18, 0, 0, 0, 0, time.UTC)

	got, err := adapter.BuildFDSNURL("https://www.seismicportal.eu/fdsnws/event/1/query", adapter.FDSNQuery{
		Start: start, End: end, OrderBy: "time-asc", Limit: 20000, Offset: 40000,
	})
	if err != nil {
		t.Fatal(err)
	}
	u, err := url.Parse(got)
	if err != nil {
		t.Fatal(err)
	}
	q := u.Query()
	if q.Get("format") != "json" {
		t.Errorf("format = %q", q.Get("format"))
	}
	if q.Get("starttime") != start.Format(time.RFC3339) {
		t.Errorf("starttime = %q", q.Get("starttime"))
	}
	if q.Get("endtime") != end.Format(time.RFC3339) {
		t.Errorf("endtime = %q", q.Get("endtime"))
	}
	if q.Get("orderby") != "time-asc" || q.Get("limit") != "20000" || q.Get("offset") != "40000" {
		t.Errorf("orderby/limit/offset = %q/%q/%q", q.Get("orderby"), q.Get("limit"), q.Get("offset"))
	}
	if q.Get("updatedafter") != "" {
		t.Errorf("updatedafter = %q, want empty", q.Get("updatedafter"))
	}
}

func TestBuildFDSNURLIncludesUpdatedAfterWhenSet(t *testing.T) {
	got, err := adapter.BuildFDSNURL("https://www.seismicportal.eu/fdsnws/event/1/query", adapter.FDSNQuery{
		Start: time.Now(), End: time.Now(), UpdatedAfter: "2026-09-18T00:05:00Z",
	})
	if err != nil {
		t.Fatal(err)
	}
	u, _ := url.Parse(got)
	if got := u.Query().Get("updatedafter"); got != "2026-09-18T00:05:00Z" {
		t.Errorf("updatedafter = %q", got)
	}
}

func TestFetchBackfillPageParsesFeatureCollection(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("offset") != "5" {
			t.Errorf("offset = %q", r.URL.Query().Get("offset"))
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"type":"FeatureCollection","metadata":{"count":1},"features":[{"type":"Feature","properties":{"unid":"a"}}]}`))
	}))
	defer server.Close()

	result, err := adapter.FetchBackfillPage(context.Background(), server.URL, adapter.FDSNQuery{
		Start: time.Now().Add(-time.Hour), End: time.Now(), OrderBy: "time-asc", Limit: 20000, Offset: 5,
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(result.Features) != 1 || result.HTTPStatus != http.StatusOK || result.Bytes == 0 || result.URL == "" {
		t.Fatalf("result = %+v", result)
	}
}

func TestFetchBackfillPageHandlesEmptyNoData(t *testing.T) {
	for _, status := range []int{http.StatusNoContent, http.StatusNotFound} {
		server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.WriteHeader(status)
		}))
		result, err := adapter.FetchBackfillPage(context.Background(), server.URL, adapter.FDSNQuery{
			Start: time.Now(), End: time.Now(), Limit: 20000,
		})
		server.Close()
		if err != nil {
			t.Fatalf("status %d: %v", status, err)
		}
		if len(result.Features) != 0 || result.HTTPStatus != status {
			t.Fatalf("status %d: result = %+v", status, result)
		}
	}
}

func TestFetchBackfillPageRejectsErrorStatus(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer server.Close()

	if _, err := adapter.FetchBackfillPage(context.Background(), server.URL, adapter.FDSNQuery{
		Start: time.Now(), End: time.Now(), Limit: 20000,
	}); err == nil {
		t.Fatal("500 response was accepted")
	}
}

func TestSubscribeForwardsRawMessagesAndParsesLastUpdate(t *testing.T) {
	const message = `{"action":"create","data":{"type":"Feature","properties":{"lastupdate":"2026-09-18T00:00:00.000000Z","unid":"a"}}}`
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, err := websocket.Accept(w, r, nil)
		if err != nil {
			return
		}
		defer conn.CloseNow()
		if err := conn.Write(r.Context(), websocket.MessageText, []byte(message)); err != nil {
			return
		}
		<-r.Context().Done()
	}))
	defer server.Close()
	wsURL := "ws" + strings.TrimPrefix(server.URL, "http")

	out := make(chan adapter.LiveMessage, 1)
	ctx, cancel := context.WithCancel(context.Background())
	errCh := make(chan error, 1)
	go func() { errCh <- adapter.Subscribe(ctx, wsURL, out) }()

	select {
	case got := <-out:
		if string(got.Raw) != message {
			t.Errorf("raw = %s", got.Raw)
		}
		if got.LastUpdate != "2026-09-18T00:00:00.000000Z" {
			t.Errorf("last_update = %q", got.LastUpdate)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("message was not forwarded")
	}

	cancel()
	select {
	case <-errCh:
	case <-time.After(5 * time.Second):
		t.Fatal("Subscribe did not return after cancellation")
	}
	if _, ok := <-out; ok {
		t.Fatal("out was not closed")
	}
}

func TestSubscribeReturnsErrorOnDial(t *testing.T) {
	out := make(chan adapter.LiveMessage, 1)
	err := adapter.Subscribe(context.Background(), "ws://127.0.0.1:1/no-such-server", out)
	if err == nil {
		t.Fatal("dial to a closed port was accepted")
	}
	if _, ok := <-out; ok {
		t.Fatal("out was not closed")
	}
}

func TestMaxLastUpdateOfFeaturesAndMessages(t *testing.T) {
	features := []json.RawMessage{
		json.RawMessage(`{"properties":{"lastupdate":"2026-09-18T00:00:01Z"}}`),
		json.RawMessage(`{"properties":{"lastupdate":"2026-09-18T00:00:03Z"}}`),
		json.RawMessage(`not json`),
	}
	if got := adapter.MaxLastUpdateOfFeatures(features); got != "2026-09-18T00:00:03Z" {
		t.Errorf("MaxLastUpdateOfFeatures = %q", got)
	}

	messages := []adapter.LiveMessage{
		{LastUpdate: "2026-09-18T00:00:02Z"},
		{LastUpdate: "2026-09-18T00:00:05Z"},
		{LastUpdate: "2026-09-18T00:00:01Z"},
	}
	if got := adapter.MaxLastUpdateOfMessages(messages); got != "2026-09-18T00:00:05Z" {
		t.Errorf("MaxLastUpdateOfMessages = %q", got)
	}

	if got := adapter.MaxLastUpdateOfFeatures(nil); got != "" {
		t.Errorf("MaxLastUpdateOfFeatures(nil) = %q", got)
	}
}
