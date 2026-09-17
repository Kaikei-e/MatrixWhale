package controller

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"math/rand"
	"testing"
	"time"

	"emsc_adapter/adapter"
)

func alwaysWait(context.Context, time.Duration) bool { return true }

func TestRunPaginatesBackfillWrapsFeaturesAndRetriesWithoutAdvancingOffset(t *testing.T) {
	originalLimit := fdsnPageLimit
	fdsnPageLimit = 1
	defer func() { fdsnPageLimit = originalLimit }()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	pages := [][]json.RawMessage{
		{json.RawMessage(`{"type":"Feature","properties":{"unid":"a"}}`)},
		{json.RawMessage(`{"type":"Feature","properties":{"unid":"b"}}`)},
		{},
	}

	var fetchOffsets []int
	fetch := func(_ context.Context, fdsnURL string, q adapter.FDSNQuery) (adapter.FetchResult, error) {
		fetchOffsets = append(fetchOffsets, q.Offset)
		idx := q.Offset - 1
		if idx >= len(pages) {
			idx = len(pages) - 1
		}
		return adapter.FetchResult{Features: pages[idx], FetchedAt: time.Now(), HTTPStatus: 200, URL: fdsnURL}, nil
	}

	sendAttempts := 0
	var captured [][]json.RawMessage
	send := func(_ context.Context, batch adapter.Batch) error {
		sendAttempts++
		if sendAttempts == 1 {
			return fmt.Errorf("simulated core failure")
		}
		captured = append(captured, batch.Features)
		if len(captured) == len(pages) {
			cancel()
		}
		return nil
	}

	subscribe := func(ctx context.Context, _ string, out chan<- adapter.LiveMessage) error {
		defer close(out)
		<-ctx.Done()
		return ctx.Err()
	}

	cfg := config{websocketURL: "ws://example.invalid", fdsnURL: "https://example.invalid/fdsn", backfillDays: 7}
	run(ctx, cfg, fetch, subscribe, send, alwaysWait, rand.New(rand.NewSource(1)))

	if len(fetchOffsets) != 4 {
		t.Fatalf("fetch calls = %v, want 4", fetchOffsets)
	}
	if fetchOffsets[0] != 1 || fetchOffsets[1] != 1 {
		t.Fatalf("offset advanced after a failed send: %v", fetchOffsets)
	}
	if fetchOffsets[2] != 2 || fetchOffsets[3] != 3 {
		t.Fatalf("offsets after retry = %v, want [.., 2, 3]", fetchOffsets)
	}

	if len(captured) != 3 || len(captured[0]) != 1 || len(captured[1]) != 1 || len(captured[2]) != 0 {
		t.Fatalf("captured batches = %+v", captured)
	}
	var wrapped struct {
		Action string          `json:"action"`
		Data   json.RawMessage `json:"data"`
	}
	if err := json.Unmarshal(captured[0][0], &wrapped); err != nil {
		t.Fatal(err)
	}
	if wrapped.Action != "create" || !bytes.Contains(wrapped.Data, []byte(`"unid":"a"`)) {
		t.Fatalf("wrapped feature = %+v", wrapped)
	}
}

func TestRunReconnectTriggersGapFillWithExpectedUpdatedAfter(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	fetchCalls := 0
	var fetchQueries []adapter.FDSNQuery
	fetch := func(_ context.Context, fdsnURL string, q adapter.FDSNQuery) (adapter.FetchResult, error) {
		fetchCalls++
		fetchQueries = append(fetchQueries, q)
		if fetchCalls == 1 {
			feature := json.RawMessage(`{"type":"Feature","properties":{"lastupdate":"2026-09-18T00:10:00.000000Z"}}`)
			return adapter.FetchResult{Features: []json.RawMessage{feature}, FetchedAt: time.Now(), HTTPStatus: 200, URL: fdsnURL}, nil
		}
		return adapter.FetchResult{Features: []json.RawMessage{}, FetchedAt: time.Now(), HTTPStatus: 200, URL: fdsnURL}, nil
	}

	send := func(context.Context, adapter.Batch) error { return nil }

	subscribeCalls := 0
	subscribe := func(ctx context.Context, _ string, out chan<- adapter.LiveMessage) error {
		defer close(out)
		subscribeCalls++
		if subscribeCalls == 1 {
			return fmt.Errorf("simulated disconnect")
		}
		cancel()
		return ctx.Err()
	}

	cfg := config{websocketURL: "ws://example.invalid", fdsnURL: "https://example.invalid/fdsn", backfillDays: 7}
	run(ctx, cfg, fetch, subscribe, send, alwaysWait, rand.New(rand.NewSource(1)))

	if len(fetchQueries) != 2 {
		t.Fatalf("fetch calls = %d, want 2", len(fetchQueries))
	}
	if fetchQueries[0].UpdatedAfter != "" {
		t.Fatalf("startup backfill updatedafter = %q, want empty", fetchQueries[0].UpdatedAfter)
	}
	want := gapFillUpdatedAfter("2026-09-18T00:10:00.000000Z")
	if want == "" {
		t.Fatal("test setup: gapFillUpdatedAfter returned empty for a valid timestamp")
	}
	if fetchQueries[1].UpdatedAfter != want {
		t.Fatalf("gap-fill updatedafter = %q, want %q", fetchQueries[1].UpdatedAfter, want)
	}
}

func TestGapFillUpdatedAfterSubtractsLookback(t *testing.T) {
	got := gapFillUpdatedAfter("2026-09-18T00:10:00.000000Z")
	want := "2026-09-18T00:05:00Z"
	if got != want {
		t.Fatalf("gapFillUpdatedAfter = %q, want %q", got, want)
	}
}

func TestGapFillUpdatedAfterEmptyWhenNeverObserved(t *testing.T) {
	if got := gapFillUpdatedAfter(""); got != "" {
		t.Fatalf("gapFillUpdatedAfter(\"\") = %q, want empty", got)
	}
}

func TestRunLiveSendFailureRetriesSameBatchWithoutDroppingOrReordering(t *testing.T) {
	originalWait := liveBatchWait
	liveBatchWait = 20 * time.Millisecond
	defer func() { liveBatchWait = originalWait }()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	messages := []adapter.LiveMessage{
		{Raw: json.RawMessage(`{"action":"create","data":{"n":1}}`), LastUpdate: "2026-09-18T00:00:01Z"},
		{Raw: json.RawMessage(`{"action":"create","data":{"n":2}}`), LastUpdate: "2026-09-18T00:00:02Z"},
	}

	fetch := func(_ context.Context, fdsnURL string, q adapter.FDSNQuery) (adapter.FetchResult, error) {
		return adapter.FetchResult{Features: []json.RawMessage{}, FetchedAt: time.Now(), HTTPStatus: 200, URL: fdsnURL}, nil
	}

	subscribeCalls := 0
	subscribe := func(ctx context.Context, _ string, out chan<- adapter.LiveMessage) error {
		defer close(out)
		subscribeCalls++
		if subscribeCalls > 1 {
			<-ctx.Done()
			return ctx.Err()
		}
		for _, m := range messages {
			select {
			case out <- m:
			case <-ctx.Done():
				return ctx.Err()
			}
		}
		<-ctx.Done()
		return ctx.Err()
	}

	sendAttempts := 0
	var sentBatches [][]json.RawMessage
	send := func(_ context.Context, batch adapter.Batch) error {
		if batch.Backfill {
			return nil
		}
		sendAttempts++
		if sendAttempts == 1 {
			return fmt.Errorf("simulated core failure")
		}
		sentBatches = append(sentBatches, batch.Features)
		cancel()
		return nil
	}

	cfg := config{websocketURL: "ws://example.invalid", fdsnURL: "https://example.invalid/fdsn", backfillDays: 7}
	run(ctx, cfg, fetch, subscribe, send, alwaysWait, rand.New(rand.NewSource(1)))

	if sendAttempts < 2 {
		t.Fatalf("send attempts = %d, want at least 2", sendAttempts)
	}
	if len(sentBatches) != 1 || len(sentBatches[0]) != 2 {
		t.Fatalf("sent batches = %+v", sentBatches)
	}
	if !bytes.Equal(sentBatches[0][0], messages[0].Raw) || !bytes.Equal(sentBatches[0][1], messages[1].Raw) {
		t.Fatalf("batch content/order mismatch: %s", sentBatches[0])
	}
}

func TestRunStopsOnContextCancellation(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())

	fetch := func(_ context.Context, fdsnURL string, q adapter.FDSNQuery) (adapter.FetchResult, error) {
		return adapter.FetchResult{Features: []json.RawMessage{}, FetchedAt: time.Now(), HTTPStatus: 200, URL: fdsnURL}, nil
	}
	subscribeStarted := make(chan struct{})
	subscribe := func(ctx context.Context, _ string, out chan<- adapter.LiveMessage) error {
		defer close(out)
		close(subscribeStarted)
		<-ctx.Done()
		return ctx.Err()
	}
	send := func(context.Context, adapter.Batch) error { return nil }

	cfg := config{websocketURL: "ws://example.invalid", fdsnURL: "https://example.invalid/fdsn", backfillDays: 7}
	done := make(chan struct{})
	go func() {
		run(ctx, cfg, fetch, subscribe, send, wait, rand.New(rand.NewSource(1)))
		close(done)
	}()

	select {
	case <-subscribeStarted:
	case <-time.After(time.Second):
		t.Fatal("live subscription never started")
	}

	cancel()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("run did not stop after context cancellation")
	}
}
