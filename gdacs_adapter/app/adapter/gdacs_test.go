package adapter

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"
)

func testSince() time.Time {
	return time.Date(2026, 9, 4, 1, 2, 3, 0, time.UTC)
}

func testUntil() time.Time {
	return time.Date(2026, 9, 25, 0, 0, 0, 0, time.UTC)
}

// reads RawQuery directly: Go rejects literal ';' in url.Query().
func rawQueryPairs(t *testing.T, rawQuery string) map[string]string {
	t.Helper()
	pairs := map[string]string{}
	for _, part := range strings.Split(rawQuery, "&") {
		key, value, found := strings.Cut(part, "=")
		if !found {
			t.Fatalf("malformed query segment %q in %q", part, rawQuery)
		}
		pairs[key] = value
	}
	return pairs
}

func TestFetchEventPageSendsExactQueryParamsAndUserAgent(t *testing.T) {
	t.Setenv("GDACS_CONTACT_EMAIL", "ops@example.com")
	var gotPath, gotRawQuery, gotUA string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		gotRawQuery = r.URL.RawQuery
		gotUA = r.Header.Get("User-Agent")
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"type":"FeatureCollection","features":[]}`))
	}))
	defer server.Close()

	_, err := FetchEventPage(context.Background(), server.Client(), server.URL, PrimaryEventListQuery, testSince(), time.Time{}, 1)
	if err != nil {
		t.Fatalf("FetchEventPage: %v", err)
	}

	if !strings.HasSuffix(gotPath, "/"+eventListLatestEndpoint) {
		t.Fatalf("path = %q, want suffix %q", gotPath, eventListLatestEndpoint)
	}
	gotQuery := rawQueryPairs(t, gotRawQuery)
	want := map[string]string{
		"eventlist":    "EQ;TC;FL;VO;WF;DR",
		"alertlevel":   "green;orange;red",
		"datemodified": "2026-09-04T01:02:03",
		"pageSize":     "100",
		"pageNumber":   "1",
		"caller":       "matrixwhale",
	}
	for key, expected := range want {
		if got := gotQuery[key]; got != expected {
			t.Errorf("query[%q] = %q, want %q", key, got, expected)
		}
	}
	for _, removed := range []string{"fromDate", "toDate"} {
		if _, present := gotQuery[removed]; present {
			t.Errorf("query unexpectedly contains %q", removed)
		}
	}
	if gotUA != "gdacs_adapter (ops@example.com)" {
		t.Errorf("User-Agent = %q", gotUA)
	}
}

func TestFetchEventPageSendsTsunamiQueryThroughSearchEndpointWithDateWindow(t *testing.T) {
	var gotPath, gotRawQuery string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		gotRawQuery = r.URL.RawQuery
		w.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()

	if _, err := FetchEventPage(context.Background(), server.Client(), server.URL, TsunamiEventListQuery, testSince(), testUntil(), 1); err != nil {
		t.Fatalf("FetchEventPage: %v", err)
	}

	if !strings.HasSuffix(gotPath, "/"+eventListSearchEndpoint) {
		t.Fatalf("path = %q, want suffix %q", gotPath, eventListSearchEndpoint)
	}
	gotQuery := rawQueryPairs(t, gotRawQuery)
	want := map[string]string{
		"eventlist":  "TS",
		"alertlevel": "green;orange;red",
		"fromDate":   "2026-09-04",
		"toDate":     "2026-09-25",
	}
	for key, expected := range want {
		if got := gotQuery[key]; got != expected {
			t.Errorf("query[%q] = %q, want %q", key, got, expected)
		}
	}
	if _, present := gotQuery["datemodified"]; present {
		t.Error("search query unexpectedly contains datemodified")
	}
}

func TestFetchEventPageParsesFixtureAndMarksNotDoneAtFullPage(t *testing.T) {
	fixture, err := os.ReadFile("testdata/eventlist_map2.json")
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(fixture)
	}))
	defer server.Close()

	page, err := FetchEventPage(context.Background(), server.Client(), server.URL, PrimaryEventListQuery, testSince(), time.Time{}, 1)
	if err != nil {
		t.Fatalf("FetchEventPage: %v", err)
	}
	if len(page.Features) != 6 {
		t.Fatalf("features = %d, want 6", len(page.Features))
	}
	if !page.Done {
		t.Fatal("page of 6 (< pageSize) should be Done")
	}
	if page.HTTPStatus != http.StatusOK {
		t.Fatalf("HTTPStatus = %d", page.HTTPStatus)
	}
}

func TestFetchEventPageNotDoneAtFullPageSize(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var b strings.Builder
		b.WriteString(`{"type":"FeatureCollection","features":[`)
		for i := 0; i < pageSize; i++ {
			if i > 0 {
				b.WriteString(",")
			}
			b.WriteString(`{"type":"Feature","properties":{"eventid":`)
			b.WriteString(strconv.Itoa(i))
			b.WriteString(`}}`)
		}
		b.WriteString(`]}`)
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(b.String()))
	}))
	defer server.Close()

	page, err := FetchEventPage(context.Background(), server.Client(), server.URL, PrimaryEventListQuery, testSince(), time.Time{}, 1)
	if err != nil {
		t.Fatalf("FetchEventPage: %v", err)
	}
	if len(page.Features) != pageSize {
		t.Fatalf("features = %d, want %d", len(page.Features), pageSize)
	}
	if page.Done {
		t.Fatal("a full page should not be marked Done")
	}
}

func TestFetchEventPage204IsDoneWithoutError(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()

	page, err := FetchEventPage(context.Background(), server.Client(), server.URL, PrimaryEventListQuery, testSince(), time.Time{}, 1)
	if err != nil {
		t.Fatalf("204 should not be an error: %v", err)
	}
	if !page.Done || len(page.Features) != 0 {
		t.Fatalf("204 page = %+v, want Done with no features", page)
	}
}

func TestFetchEventPageRejectsNonFeatureCollectionBody(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"message":"Eventtype is required."}`))
	}))
	defer server.Close()

	if _, err := FetchEventPage(context.Background(), server.Client(), server.URL, PrimaryEventListQuery, testSince(), time.Time{}, 1); err == nil {
		t.Fatal("non-FeatureCollection body was accepted")
	}
}

func TestFetchEventPageSurfacesRetryableStatusAndHeader(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Retry-After", "30")
		w.WriteHeader(http.StatusTooManyRequests)
	}))
	defer server.Close()

	page, err := FetchEventPage(context.Background(), server.Client(), server.URL, PrimaryEventListQuery, testSince(), time.Time{}, 1)
	if err == nil {
		t.Fatal("429 status was accepted as success")
	}
	if page.HTTPStatus != http.StatusTooManyRequests {
		t.Fatalf("HTTPStatus = %d, want 429", page.HTTPStatus)
	}
	if page.Header.Get("Retry-After") != "30" {
		t.Fatalf("Retry-After header not preserved: %v", page.Header)
	}
}

func TestFetchEventPageRejectsOversizedBody(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var b strings.Builder
		b.WriteString(`{"type":"FeatureCollection","features":[{"type":"Feature","properties":{"pad":"`)
		b.WriteString(strings.Repeat("x", maxBodyBytes+1))
		b.WriteString(`"}}]}`)
		_, _ = w.Write([]byte(b.String()))
	}))
	defer server.Close()

	if _, err := FetchEventPage(context.Background(), server.Client(), server.URL, PrimaryEventListQuery, testSince(), time.Time{}, 1); err == nil {
		t.Fatal("oversized body was accepted")
	}
}

func TestFetchGeometrySendsExactQueryParams(t *testing.T) {
	var gotQuery map[string][]string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotQuery = map[string][]string(r.URL.Query())
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"type":"FeatureCollection","features":[]}`))
	}))
	defer server.Close()

	_, _, err := FetchGeometry(context.Background(), server.Client(), server.URL, "EQ", 1565193, 1732972)
	if err != nil {
		t.Fatalf("FetchGeometry: %v", err)
	}
	want := map[string]string{"eventtype": "EQ", "eventid": "1565193", "episodeid": "1732972"}
	for key, expected := range want {
		got := gotQuery[key]
		if len(got) != 1 || got[0] != expected {
			t.Errorf("query[%q] = %v, want [%q]", key, got, expected)
		}
	}
}

func TestFetchGeometryReturnsFixtureBody(t *testing.T) {
	fixture, err := os.ReadFile("testdata/geom_eq.json")
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(fixture)
	}))
	defer server.Close()

	body, status, err := FetchGeometry(context.Background(), server.Client(), server.URL, "EQ", 1565193, 1732972)
	if err != nil {
		t.Fatalf("FetchGeometry: %v", err)
	}
	if status != http.StatusOK {
		t.Fatalf("status = %d, want 200", status)
	}
	if len(body) != len(fixture) {
		t.Fatalf("body length = %d, want %d", len(body), len(fixture))
	}
}

func TestFetchGeometry204ReturnsNilWithoutError(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	}))
	defer server.Close()

	body, status, err := FetchGeometry(context.Background(), server.Client(), server.URL, "EQ", 1, 1)
	if err != nil {
		t.Fatalf("204 should not be an error: %v", err)
	}
	if status != http.StatusNoContent || body != nil {
		t.Fatalf("204 result = status %d, body %v, want 204/nil", status, body)
	}
}

func TestFetchGeometryErrorsOnServerFailure(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer server.Close()

	if _, _, err := FetchGeometry(context.Background(), server.Client(), server.URL, "EQ", 1, 1); err == nil {
		t.Fatal("500 status was accepted as success")
	}
}
