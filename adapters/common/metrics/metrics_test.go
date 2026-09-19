package metrics

import (
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/prometheus/client_golang/prometheus/testutil"
)

type errRoundTripper struct{}

func (errRoundTripper) RoundTrip(*http.Request) (*http.Response, error) {
	return nil, errors.New("network failure")
}

func TestTransportSuccess200(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	defer server.Close()

	client := &http.Client{
		Transport: Transport("upstream", server.Client().Transport),
	}

	cntBefore := testutil.ToFloat64(httpRequestsTotal.WithLabelValues("upstream", "200"))
	tsBefore := testutil.ToFloat64(lastSuccessTimestamp.WithLabelValues("upstream"))

	req, err := http.NewRequest(http.MethodGet, server.URL, nil)
	if err != nil {
		t.Fatal(err)
	}

	resp, err := client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()

	cntAfter := testutil.ToFloat64(httpRequestsTotal.WithLabelValues("upstream", "200"))
	tsAfter := testutil.ToFloat64(lastSuccessTimestamp.WithLabelValues("upstream"))

	if cntAfter-cntBefore != 1 {
		t.Fatalf("expected 200 counter to increment by 1, got %f -> %f", cntBefore, cntAfter)
	}
	if tsAfter <= 0 || tsAfter < tsBefore {
		t.Fatalf("expected last success timestamp to be updated, got %f (before: %f)", tsAfter, tsBefore)
	}
}

func TestTransport304SetsLastSuccess(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNotModified)
	}))
	defer server.Close()

	client := &http.Client{
		Transport: Transport("core", server.Client().Transport),
	}

	cntBefore := testutil.ToFloat64(httpRequestsTotal.WithLabelValues("core", "304"))
	tsBefore := testutil.ToFloat64(lastSuccessTimestamp.WithLabelValues("core"))

	req, err := http.NewRequest(http.MethodGet, server.URL, nil)
	if err != nil {
		t.Fatal(err)
	}

	resp, err := client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()

	cntAfter := testutil.ToFloat64(httpRequestsTotal.WithLabelValues("core", "304"))
	tsAfter := testutil.ToFloat64(lastSuccessTimestamp.WithLabelValues("core"))

	if cntAfter-cntBefore != 1 {
		t.Fatalf("expected 304 counter to increment by 1, got %f -> %f", cntBefore, cntAfter)
	}
	if tsAfter <= 0 || tsAfter < tsBefore {
		t.Fatalf("expected last success timestamp to be updated on 304, got %f (before: %f)", tsAfter, tsBefore)
	}
}

func TestTransport500WithoutLastSuccess(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer server.Close()

	client := &http.Client{
		Transport: Transport("upstream", server.Client().Transport),
	}

	cntBefore := testutil.ToFloat64(httpRequestsTotal.WithLabelValues("upstream", "500"))
	tsBefore := testutil.ToFloat64(lastSuccessTimestamp.WithLabelValues("upstream"))

	req, err := http.NewRequest(http.MethodGet, server.URL, nil)
	if err != nil {
		t.Fatal(err)
	}

	resp, err := client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()

	cntAfter := testutil.ToFloat64(httpRequestsTotal.WithLabelValues("upstream", "500"))
	tsAfter := testutil.ToFloat64(lastSuccessTimestamp.WithLabelValues("upstream"))

	if cntAfter-cntBefore != 1 {
		t.Fatalf("expected 500 counter to increment by 1, got %f -> %f", cntBefore, cntAfter)
	}
	if tsAfter != tsBefore {
		t.Fatalf("expected last success timestamp NOT to change on 500, got %f (before: %f)", tsAfter, tsBefore)
	}
}

func TestTransportErrorCountedAsCodeError(t *testing.T) {
	client := &http.Client{
		Transport: Transport("upstream", errRoundTripper{}),
	}

	cntBefore := testutil.ToFloat64(httpRequestsTotal.WithLabelValues("upstream", "error"))
	tsBefore := testutil.ToFloat64(lastSuccessTimestamp.WithLabelValues("upstream"))

	req, err := http.NewRequest(http.MethodGet, "http://example.local", nil)
	if err != nil {
		t.Fatal(err)
	}

	_, err = client.Do(req)
	if err == nil {
		t.Fatal("expected error from errRoundTripper")
	}

	cntAfter := testutil.ToFloat64(httpRequestsTotal.WithLabelValues("upstream", "error"))
	tsAfter := testutil.ToFloat64(lastSuccessTimestamp.WithLabelValues("upstream"))

	if cntAfter-cntBefore != 1 {
		t.Fatalf("expected error counter to increment by 1, got %f -> %f", cntBefore, cntAfter)
	}
	if tsAfter != tsBefore {
		t.Fatalf("expected last success timestamp NOT to change on transport error, got %f (before: %f)", tsAfter, tsBefore)
	}
}

func TestWebsocketHelpers(t *testing.T) {
	SetWebsocketConnected(true)
	if got := testutil.ToFloat64(wsConnected); got != 1 {
		t.Fatalf("expected wsConnected to be 1, got %f", got)
	}

	SetWebsocketConnected(false)
	if got := testutil.ToFloat64(wsConnected); got != 0 {
		t.Fatalf("expected wsConnected to be 0, got %f", got)
	}

	msgBefore := testutil.ToFloat64(wsMessagesTotal)
	tsBefore := testutil.ToFloat64(lastSuccessTimestamp.WithLabelValues("upstream"))

	RecordWebsocketMessage()

	msgAfter := testutil.ToFloat64(wsMessagesTotal)
	tsAfter := testutil.ToFloat64(lastSuccessTimestamp.WithLabelValues("upstream"))

	if msgAfter-msgBefore != 1 {
		t.Fatalf("expected wsMessagesTotal to increment by 1, got %f -> %f", msgBefore, msgAfter)
	}
	if tsAfter <= 0 || tsAfter < tsBefore {
		t.Fatalf("expected last success timestamp to update on ws message, got %f (before: %f)", tsAfter, tsBefore)
	}
}

func TestServeInvalidAddrDoesNotCrash(t *testing.T) {
	t.Setenv("METRICS_ADDR", "invalid:port:number")
	Serve()
	// Allow goroutine to run and fail without crashing
	time.Sleep(50 * time.Millisecond)
}
