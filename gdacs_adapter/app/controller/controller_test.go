package controller

import (
	"context"
	"encoding/json"
	"errors"
	"math/rand"
	"net/http"
	"os"
	"testing"
	"time"

	"matrixwhale/adapters/common/core"

	"gdacs_adapter/adapter"
)

func fixedRNG() *rand.Rand { return rand.New(rand.NewSource(1)) }

func alwaysPause(ctx context.Context, _ time.Duration) bool { return ctx.Err() == nil }

func TestLoadConfigDefaults(t *testing.T) {
	for _, key := range []string{"GDACS_API_URL", "GDACS_BACKFILL_DAYS", "GDACS_POLL_INTERVAL", "GDACS_MIN_REQUEST_INTERVAL"} {
		os.Unsetenv(key)
	}
	cfg := loadConfig()
	if cfg.apiURL != adapter.DefaultAPIURL {
		t.Errorf("apiURL = %q", cfg.apiURL)
	}
	if cfg.backfillDays != DefaultBackfillDays || DefaultBackfillDays != 14 {
		t.Errorf("backfillDays = %d, want 14", cfg.backfillDays)
	}
	if cfg.pollInterval != DefaultPollInterval || DefaultPollInterval != 5*time.Minute {
		t.Errorf("pollInterval = %v, want 5m", cfg.pollInterval)
	}
	if cfg.minRequestInterval != DefaultMinRequestInterval || DefaultMinRequestInterval != 10*time.Second {
		t.Errorf("minRequestInterval = %v, want 10s", cfg.minRequestInterval)
	}
}

func TestLoadConfigParsesOverridesAndFallsBackOnInvalid(t *testing.T) {
	t.Setenv("GDACS_API_URL", "https://example.test/api")
	t.Setenv("GDACS_BACKFILL_DAYS", "30")
	t.Setenv("GDACS_POLL_INTERVAL", "not-a-duration")
	t.Setenv("GDACS_MIN_REQUEST_INTERVAL", "1s")

	cfg := loadConfig()
	if cfg.apiURL != "https://example.test/api" {
		t.Errorf("apiURL = %q", cfg.apiURL)
	}
	if cfg.backfillDays != 30 {
		t.Errorf("backfillDays = %d, want 30", cfg.backfillDays)
	}
	if cfg.pollInterval != DefaultPollInterval {
		t.Errorf("invalid GDACS_POLL_INTERVAL did not fall back to default: %v", cfg.pollInterval)
	}
	if cfg.minRequestInterval != time.Second {
		t.Errorf("minRequestInterval = %v, want 1s", cfg.minRequestInterval)
	}
}

func TestComputeSinceBackfillUsesBackfillDays(t *testing.T) {
	now := time.Date(2026, 9, 18, 12, 0, 0, 0, time.UTC)
	cfg := config{backfillDays: 14, pollInterval: 5 * time.Minute}
	since := computeSince(cfg, true, now)
	if want := time.Date(2026, 9, 4, 12, 0, 0, 0, time.UTC); !since.Equal(want) {
		t.Errorf("since = %v, want %v", since, want)
	}
}

func TestComputeSinceSteadyStateUsesThreePollIntervals(t *testing.T) {
	now := time.Date(2026, 9, 18, 12, 0, 0, 0, time.UTC)
	cfg := config{backfillDays: 14, pollInterval: 5 * time.Minute}
	since := computeSince(cfg, false, now)
	if want := now.Add(-15 * time.Minute); !since.Equal(want) {
		t.Errorf("since = %v, want %v", since, want)
	}
}

func TestTickWindowsPairsPrimaryWithSinceAndTsunamiWithSearchWindow(t *testing.T) {
	now := time.Date(2026, 9, 18, 12, 0, 0, 0, time.UTC)
	cfg := config{backfillDays: 14, pollInterval: 5 * time.Minute}
	windows := tickWindows(cfg, false, now)

	if len(windows) != 2 {
		t.Fatalf("tickWindows returned %d entries, want 2", len(windows))
	}
	primary := windows[0]
	if primary.query.EventList != adapter.EventTypesPrimary {
		t.Errorf("windows[0].query.EventList = %q, want %q", primary.query.EventList, adapter.EventTypesPrimary)
	}
	if want := computeSince(cfg, false, now); !primary.since.Equal(want) {
		t.Errorf("primary.since = %v, want %v", primary.since, want)
	}

	tsunami := windows[1]
	if tsunami.query.EventList != adapter.EventTypesTsunami {
		t.Errorf("windows[1].query.EventList = %q, want %q", tsunami.query.EventList, adapter.EventTypesTsunami)
	}
	if want := now.AddDate(0, 0, -14); !tsunami.since.Equal(want) {
		t.Errorf("tsunami.since = %v, want %v", tsunami.since, want)
	}
	if want := now.AddDate(0, 0, searchForwardDays); !tsunami.until.Equal(want) {
		t.Errorf("tsunami.until = %v, want %v", tsunami.until, want)
	}
}

func TestPollAllPagesPagesUntilDoneWithBackfillFlag(t *testing.T) {
	var fetchedPages []int
	fetchPage := func(_ context.Context, _ *http.Client, _ string, _ adapter.EventListQuery, _, _ time.Time, pageNumber int) (adapter.EventPage, error) {
		fetchedPages = append(fetchedPages, pageNumber)
		if pageNumber == 1 {
			return adapter.EventPage{Features: make([]json.RawMessage, 2), HTTPStatus: 200}, nil
		}
		return adapter.EventPage{Features: make([]json.RawMessage, 1), HTTPStatus: 200, Done: true}, nil
	}

	var sentBackfill []bool
	var sentCounts []int
	sendEvents := func(_ context.Context, meta core.PollMeta, features []json.RawMessage) error {
		sentBackfill = append(sentBackfill, meta.Backfill)
		sentCounts = append(sentCounts, len(features))
		return nil
	}

	pauseCalled := false
	pause := func(context.Context, time.Duration) bool { pauseCalled = true; return true }

	limiter := adapter.NewLimiter(0)
	ok := pollAllPages(context.Background(), config{apiURL: "http://x"}, adapter.PrimaryEventListQuery, time.Now(), time.Time{}, true, limiter, &http.Client{}, fetchPage, sendEvents, pause, fixedRNG())

	if !ok {
		t.Fatal("pollAllPages returned false with a live context")
	}
	if len(fetchedPages) != 2 || fetchedPages[0] != 1 || fetchedPages[1] != 2 {
		t.Fatalf("fetchedPages = %v, want [1 2]", fetchedPages)
	}
	if len(sentBackfill) != 2 || !sentBackfill[0] || !sentBackfill[1] {
		t.Fatalf("sentBackfill = %v, want [true true]", sentBackfill)
	}
	if len(sentCounts) != 2 || sentCounts[0] != 2 || sentCounts[1] != 1 {
		t.Fatalf("sentCounts = %v, want [2 1]", sentCounts)
	}
	if pauseCalled {
		t.Fatal("pause should not be called when every fetch/send succeeds")
	}
}

func TestPollAllPagesRetriesFetchFailureWithBackoff(t *testing.T) {
	calls := 0
	fetchPage := func(_ context.Context, _ *http.Client, _ string, _ adapter.EventListQuery, _, _ time.Time, pageNumber int) (adapter.EventPage, error) {
		calls++
		if calls == 1 {
			return adapter.EventPage{HTTPStatus: 503, Header: http.Header{}}, context.DeadlineExceeded
		}
		return adapter.EventPage{Done: true, HTTPStatus: 200}, nil
	}
	sendCalls := 0
	sendEvents := func(context.Context, core.PollMeta, []json.RawMessage) error { sendCalls++; return nil }

	var pauseDelays []time.Duration
	pause := func(_ context.Context, d time.Duration) bool { pauseDelays = append(pauseDelays, d); return true }

	limiter := adapter.NewLimiter(0)
	ok := pollAllPages(context.Background(), config{}, adapter.PrimaryEventListQuery, time.Now(), time.Time{}, false, limiter, &http.Client{}, fetchPage, sendEvents, pause, fixedRNG())

	if !ok {
		t.Fatal("pollAllPages returned false with a live context")
	}
	if calls != 2 {
		t.Fatalf("fetchPage calls = %d, want 2 (retry then succeed)", calls)
	}
	if sendCalls != 1 {
		t.Fatalf("sendEvents calls = %d, want 1", sendCalls)
	}
	if len(pauseDelays) != 1 || pauseDelays[0] < minBackoff || pauseDelays[0] >= minBackoff+maxJitter {
		t.Fatalf("pauseDelays = %v, want one delay in [%v, %v)", pauseDelays, minBackoff, minBackoff+maxJitter)
	}
}

func TestPollAllPagesRetriesAfter429ThenSucceeds(t *testing.T) {
	calls := 0
	fetchPage := func(_ context.Context, _ *http.Client, _ string, _ adapter.EventListQuery, _, _ time.Time, pageNumber int) (adapter.EventPage, error) {
		calls++
		if calls == 1 {
			return adapter.EventPage{HTTPStatus: http.StatusTooManyRequests, Header: http.Header{}}, errors.New("too many requests")
		}
		return adapter.EventPage{Done: true, HTTPStatus: 200}, nil
	}
	sendCalls := 0
	sendEvents := func(context.Context, core.PollMeta, []json.RawMessage) error { sendCalls++; return nil }
	var pauseDelays []time.Duration
	pause := func(_ context.Context, d time.Duration) bool { pauseDelays = append(pauseDelays, d); return true }

	limiter := adapter.NewLimiter(0)
	ok := pollAllPages(context.Background(), config{}, adapter.PrimaryEventListQuery, time.Now(), time.Time{}, false, limiter, &http.Client{}, fetchPage, sendEvents, pause, fixedRNG())

	if !ok {
		t.Fatal("pollAllPages returned false with a live context")
	}
	if calls != 2 {
		t.Fatalf("fetchPage calls = %d, want 2 (retry after 429, then succeed)", calls)
	}
	if sendCalls != 1 {
		t.Fatalf("sendEvents calls = %d, want 1", sendCalls)
	}
	if len(pauseDelays) != 1 {
		t.Fatalf("pauseDelays = %v, want 1 retry pause", pauseDelays)
	}
}

func TestPollAllPagesAbandonsQueryAfterMaxAttemptsOn503(t *testing.T) {
	calls := 0
	fetchPage := func(_ context.Context, _ *http.Client, _ string, _ adapter.EventListQuery, _, _ time.Time, pageNumber int) (adapter.EventPage, error) {
		calls++
		return adapter.EventPage{HTTPStatus: 503, Header: http.Header{}}, errors.New("service unavailable")
	}
	sendCalls := 0
	sendEvents := func(context.Context, core.PollMeta, []json.RawMessage) error { sendCalls++; return nil }
	var pauseDelays []time.Duration
	pause := func(_ context.Context, d time.Duration) bool { pauseDelays = append(pauseDelays, d); return true }

	limiter := adapter.NewLimiter(0)
	ok := pollAllPages(context.Background(), config{}, adapter.PrimaryEventListQuery, time.Now(), time.Time{}, false, limiter, &http.Client{}, fetchPage, sendEvents, pause, fixedRNG())

	if !ok {
		t.Fatal("pollAllPages returned false with a live context")
	}
	if calls != maxPageAttempts {
		t.Fatalf("fetchPage calls = %d, want %d (abandon after maxPageAttempts)", calls, maxPageAttempts)
	}
	if len(pauseDelays) != maxPageAttempts-1 {
		t.Fatalf("pauseDelays = %v, want %d (one retry wait between each attempt)", pauseDelays, maxPageAttempts-1)
	}
	if sendCalls != 0 {
		t.Fatalf("sendEvents calls = %d, want 0 (every attempt failed)", sendCalls)
	}
}

func TestPollAllPagesAbandonsImmediatelyOnNonRetryable4xx(t *testing.T) {
	calls := 0
	fetchPage := func(_ context.Context, _ *http.Client, _ string, _ adapter.EventListQuery, _, _ time.Time, pageNumber int) (adapter.EventPage, error) {
		calls++
		return adapter.EventPage{HTTPStatus: http.StatusNotFound}, errors.New("not found")
	}
	sendCalls := 0
	sendEvents := func(context.Context, core.PollMeta, []json.RawMessage) error { sendCalls++; return nil }
	pauseCalled := false
	pause := func(context.Context, time.Duration) bool { pauseCalled = true; return true }

	limiter := adapter.NewLimiter(0)
	ok := pollAllPages(context.Background(), config{}, adapter.PrimaryEventListQuery, time.Now(), time.Time{}, false, limiter, &http.Client{}, fetchPage, sendEvents, pause, fixedRNG())

	if !ok {
		t.Fatal("pollAllPages returned false with a live context")
	}
	if calls != 1 {
		t.Fatalf("fetchPage calls = %d, want 1 (no retry on a non-retryable 4xx)", calls)
	}
	if sendCalls != 0 {
		t.Fatalf("sendEvents calls = %d, want 0", sendCalls)
	}
	if pauseCalled {
		t.Fatal("a non-retryable 4xx should not pause/retry")
	}
}

func TestPollTickAbandonsQueryOn404ButStillRunsNextQuery(t *testing.T) {
	var gotEventLists []string
	fetchPage := func(_ context.Context, _ *http.Client, _ string, query adapter.EventListQuery, _, _ time.Time, pageNumber int) (adapter.EventPage, error) {
		gotEventLists = append(gotEventLists, query.EventList)
		if query.EventList == adapter.EventTypesPrimary {
			return adapter.EventPage{HTTPStatus: http.StatusNotFound}, errors.New("not found")
		}
		return adapter.EventPage{Done: true, HTTPStatus: 200}, nil
	}
	sendCalls := 0
	sendEvents := func(context.Context, core.PollMeta, []json.RawMessage) error { sendCalls++; return nil }
	pauseCalled := false
	pause := func(context.Context, time.Duration) bool { pauseCalled = true; return true }

	limiter := adapter.NewLimiter(0)
	cfg := config{apiURL: "http://x", backfillDays: 14, pollInterval: time.Minute}
	ok := pollTick(context.Background(), cfg, true, time.Now(), limiter, &http.Client{}, fetchPage, sendEvents, pause, fixedRNG())

	if !ok {
		t.Fatal("pollTick returned false with a live context")
	}
	if sendCalls != 1 {
		t.Fatalf("sendEvents calls = %d, want 1 (only the tsunami query's page sends; the 404'd primary query never does)", sendCalls)
	}
	if pauseCalled {
		t.Fatal("a non-retryable 4xx should not pause/retry")
	}
	want := []string{adapter.EventTypesPrimary, adapter.EventTypesTsunami}
	if len(gotEventLists) != 2 || gotEventLists[0] != want[0] || gotEventLists[1] != want[1] {
		t.Fatalf("eventLists = %v, want %v (the tsunami query still ran)", gotEventLists, want)
	}
}

func TestPollAllPagesAbandonsTickOnCoreSendFailure(t *testing.T) {
	fetchCalls := 0
	fetchPage := func(_ context.Context, _ *http.Client, _ string, _ adapter.EventListQuery, _, _ time.Time, pageNumber int) (adapter.EventPage, error) {
		fetchCalls++
		return adapter.EventPage{HTTPStatus: 200}, nil
	}
	sendCalls := 0
	sendEvents := func(context.Context, core.PollMeta, []json.RawMessage) error {
		sendCalls++
		return context.DeadlineExceeded
	}
	pauseCalled := false
	pause := func(context.Context, time.Duration) bool { pauseCalled = true; return true }

	limiter := adapter.NewLimiter(0)
	ok := pollAllPages(context.Background(), config{}, adapter.PrimaryEventListQuery, time.Now(), time.Time{}, false, limiter, &http.Client{}, fetchPage, sendEvents, pause, fixedRNG())

	if !ok {
		t.Fatal("a core send failure should not signal context death")
	}
	if fetchCalls != 1 || sendCalls != 1 {
		t.Fatalf("fetchCalls=%d sendCalls=%d, want 1 and 1 (abandon rest of tick)", fetchCalls, sendCalls)
	}
	if pauseCalled {
		t.Fatal("a core error should move on to the next tick without a backoff pause")
	}
}

func entryFixture(n int) []adapter.GeometryPendingEntry {
	entries := make([]adapter.GeometryPendingEntry, n)
	for i := range entries {
		entries[i] = adapter.GeometryPendingEntry{EventType: "EQ", EventID: int64(i), EpisodeID: int64(i)}
	}
	return entries
}

func TestDrainGeometryBatchesPendingIntoGroupsOfTen(t *testing.T) {
	pendingCalls := 0
	fetchPending := func(context.Context, int) ([]adapter.GeometryPendingEntry, error) {
		pendingCalls++
		if pendingCalls == 1 {
			return entryFixture(12), nil
		}
		return nil, nil
	}
	var fetchedIDs []int64
	fetchGeom := func(_ context.Context, _ *http.Client, _ string, _ string, eventid, _ int64) (json.RawMessage, int, error) {
		fetchedIDs = append(fetchedIDs, eventid)
		return json.RawMessage(`{"type":"FeatureCollection"}`), 200, nil
	}
	var batchSizes []int
	sendGeom := func(_ context.Context, _ core.PollMeta, entries []adapter.GeometryResult) error {
		batchSizes = append(batchSizes, len(entries))
		return nil
	}

	limiter := adapter.NewLimiter(0)
	now := time.Now()
	ok := drainGeometry(context.Background(), config{}, limiter, &http.Client{}, fetchGeom, fetchPending, sendGeom, alwaysPause, fixedRNG(), func() time.Time { return now }, now.Add(time.Hour))

	if !ok {
		t.Fatal("drainGeometry returned false with a live context")
	}
	if len(fetchedIDs) != 12 {
		t.Fatalf("fetched %d geometries, want 12", len(fetchedIDs))
	}
	for i, id := range fetchedIDs {
		if id != int64(i) {
			t.Fatalf("fetch order = %v, want ascending 0..11", fetchedIDs)
		}
	}
	if len(batchSizes) != 2 || batchSizes[0] != 10 || batchSizes[1] != 2 {
		t.Fatalf("batchSizes = %v, want [10 2]", batchSizes)
	}
	if pendingCalls != 2 {
		t.Fatalf("pendingCalls = %d, want 2 (drain then empty)", pendingCalls)
	}
}

func TestDrainGeometryStopsImmediatelyWhenDeadlineHasPassed(t *testing.T) {
	pendingCalled := false
	fetchPending := func(context.Context, int) ([]adapter.GeometryPendingEntry, error) {
		pendingCalled = true
		return nil, nil
	}
	now := time.Now()
	limiter := adapter.NewLimiter(0)
	ok := drainGeometry(context.Background(), config{}, limiter, &http.Client{}, nil, fetchPending, nil, alwaysPause, fixedRNG(), func() time.Time { return now }, now)

	if !ok {
		t.Fatal("drainGeometry returned false with a live context")
	}
	if pendingCalled {
		t.Fatal("pending should never be queried once the deadline has passed")
	}
}

func TestDrainGeometryRetriesFetchFailureThenSucceeds(t *testing.T) {
	pendingCalls := 0
	fetchPending := func(context.Context, int) ([]adapter.GeometryPendingEntry, error) {
		pendingCalls++
		if pendingCalls == 1 {
			return entryFixture(1), nil
		}
		return nil, nil
	}
	fetchCalls := 0
	fetchGeom := func(context.Context, *http.Client, string, string, int64, int64) (json.RawMessage, int, error) {
		fetchCalls++
		if fetchCalls == 1 {
			return nil, 0, context.DeadlineExceeded
		}
		return json.RawMessage(`{"type":"FeatureCollection"}`), 200, nil
	}
	sendCalls := 0
	sendGeom := func(context.Context, core.PollMeta, []adapter.GeometryResult) error { sendCalls++; return nil }
	var pauseDelays []time.Duration
	pause := func(_ context.Context, d time.Duration) bool { pauseDelays = append(pauseDelays, d); return true }

	limiter := adapter.NewLimiter(0)
	now := time.Now()
	ok := drainGeometry(context.Background(), config{}, limiter, &http.Client{}, fetchGeom, fetchPending, sendGeom, pause, fixedRNG(), func() time.Time { return now }, now.Add(time.Hour))

	if !ok {
		t.Fatal("drainGeometry returned false with a live context")
	}
	if fetchCalls != 2 {
		t.Fatalf("fetchCalls = %d, want 2 (retry then succeed)", fetchCalls)
	}
	if sendCalls != 1 {
		t.Fatalf("sendCalls = %d, want 1", sendCalls)
	}
	if len(pauseDelays) != 1 || pauseDelays[0] < minBackoff {
		t.Fatalf("pauseDelays = %v, want one delay >= %v", pauseDelays, minBackoff)
	}
}

func TestDrainGeometryAbandonsTickOnPendingLookupError(t *testing.T) {
	fetchPending := func(context.Context, int) ([]adapter.GeometryPendingEntry, error) {
		return nil, context.DeadlineExceeded
	}
	fetchGeomCalled := false
	fetchGeom := func(context.Context, *http.Client, string, string, int64, int64) (json.RawMessage, int, error) {
		fetchGeomCalled = true
		return nil, 0, nil
	}
	now := time.Now()
	limiter := adapter.NewLimiter(0)
	ok := drainGeometry(context.Background(), config{}, limiter, &http.Client{}, fetchGeom, fetchPending, nil, alwaysPause, fixedRNG(), func() time.Time { return now }, now.Add(time.Hour))

	if !ok {
		t.Fatal("a core error should not signal context death")
	}
	if fetchGeomCalled {
		t.Fatal("geometry should not be fetched once the pending lookup itself failed")
	}
}

func TestDrainGeometryAbandonsTickOnSendGeometryError(t *testing.T) {
	pendingCalls := 0
	fetchPending := func(context.Context, int) ([]adapter.GeometryPendingEntry, error) {
		pendingCalls++
		return entryFixture(3), nil
	}
	fetchGeom := func(context.Context, *http.Client, string, string, int64, int64) (json.RawMessage, int, error) {
		return json.RawMessage(`{"type":"FeatureCollection"}`), 200, nil
	}
	sendGeom := func(context.Context, core.PollMeta, []adapter.GeometryResult) error { return context.DeadlineExceeded }

	now := time.Now()
	limiter := adapter.NewLimiter(0)
	ok := drainGeometry(context.Background(), config{}, limiter, &http.Client{}, fetchGeom, fetchPending, sendGeom, alwaysPause, fixedRNG(), func() time.Time { return now }, now.Add(time.Hour))

	if !ok {
		t.Fatal("a core error should not signal context death")
	}
	if pendingCalls != 1 {
		t.Fatalf("pendingCalls = %d, want 1 (abandon after the failed flush)", pendingCalls)
	}
}

func TestRunSetsBackfillOnlyOnFirstTick(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	fetchPage := func(_ context.Context, _ *http.Client, _ string, _ adapter.EventListQuery, _, _ time.Time, _ int) (adapter.EventPage, error) {
		return adapter.EventPage{Done: true, HTTPStatus: 200}, nil
	}
	var sentBackfill []bool
	sendEvents := func(_ context.Context, meta core.PollMeta, _ []json.RawMessage) error {
		sentBackfill = append(sentBackfill, meta.Backfill)
		return nil
	}
	fetchPending := func(context.Context, int) ([]adapter.GeometryPendingEntry, error) { return nil, nil }
	sendGeom := func(context.Context, core.PollMeta, []adapter.GeometryResult) error { return nil }
	fetchGeom := func(context.Context, *http.Client, string, string, int64, int64) (json.RawMessage, int, error) {
		return nil, 0, nil
	}

	pauseCalls := 0
	pause := func(context.Context, time.Duration) bool {
		pauseCalls++
		if pauseCalls >= 3 {
			cancel()
			return false
		}
		return true
	}

	limiter := adapter.NewLimiter(0)
	cfg := config{apiURL: "http://x", backfillDays: 14, pollInterval: time.Minute, minRequestInterval: 0}
	run(ctx, cfg, limiter, &http.Client{}, fetchPage, fetchGeom, sendEvents, fetchPending, sendGeom, pause, fixedRNG(), time.Now)

	if len(sentBackfill) < 4 {
		t.Fatalf("sentBackfill = %v, want at least 4 sends (2 ticks)", sentBackfill)
	}
	if !sentBackfill[0] || !sentBackfill[1] {
		t.Fatal("first tick's sends should have Backfill = true")
	}
	for i, backfill := range sentBackfill[2:] {
		if backfill {
			t.Fatalf("send %d after the first tick still had Backfill = true", i+2)
		}
	}
}

func TestRunQueriesPrimaryThenTsunamiEventListEachTick(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	var gotEventLists []string
	fetchPage := func(_ context.Context, _ *http.Client, _ string, query adapter.EventListQuery, _, _ time.Time, _ int) (adapter.EventPage, error) {
		gotEventLists = append(gotEventLists, query.EventList)
		return adapter.EventPage{Done: true, HTTPStatus: 200}, nil
	}
	sendEvents := func(context.Context, core.PollMeta, []json.RawMessage) error { return nil }
	fetchPending := func(context.Context, int) ([]adapter.GeometryPendingEntry, error) { return nil, nil }
	sendGeom := func(context.Context, core.PollMeta, []adapter.GeometryResult) error { return nil }
	fetchGeom := func(context.Context, *http.Client, string, string, int64, int64) (json.RawMessage, int, error) {
		return nil, 0, nil
	}
	pause := func(context.Context, time.Duration) bool { cancel(); return false }

	limiter := adapter.NewLimiter(0)
	cfg := config{apiURL: "http://x", backfillDays: 14, pollInterval: time.Minute, minRequestInterval: 0}
	run(ctx, cfg, limiter, &http.Client{}, fetchPage, fetchGeom, sendEvents, fetchPending, sendGeom, pause, fixedRNG(), time.Now)

	want := []string{adapter.EventTypesPrimary, adapter.EventTypesTsunami}
	if len(gotEventLists) != 2 || gotEventLists[0] != want[0] || gotEventLists[1] != want[1] {
		t.Fatalf("eventLists = %v, want %v", gotEventLists, want)
	}
}
