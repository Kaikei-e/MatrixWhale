package controller

import (
	"context"
	"math/rand"
	"net/http"
	"testing"
	"time"

	"usgs_adapter/adapter"
)

func TestRunRetriesBackfillWithoutAdvancingValidatorOnCoreFailure(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	type request struct {
		url       string
		validator string
	}
	requests := make([]request, 0, 3)
	fetchCount := 0
	fetch := func(_ context.Context, url, validator string) (adapter.PollResult, error) {
		fetchCount++
		backfill := fetchCount < 3
		requests = append(requests, request{url, validator})
		header := http.Header{"Last-Modified": []string{"week-validator"}}
		if !backfill {
			header = http.Header{"Last-Modified": []string{"day-validator"}}
		}
		return adapter.PollResult{FetchedAt: time.Now(), HTTPStatus: http.StatusOK, Header: header, FeedURL: url}, nil
	}

	sendCount := 0
	send := func(_ context.Context, result adapter.PollResult) error {
		sendCount++
		if sendCount == 1 {
			return context.DeadlineExceeded
		}
		if sendCount == 3 {
			cancel()
		}
		if result.Backfill != (sendCount < 3) {
			t.Errorf("backfill = %v on send %d", result.Backfill, sendCount)
		}
		return nil
	}

	run(ctx, fetch, send, func(context.Context, time.Duration) bool { return true }, rand.New(rand.NewSource(1)))

	if len(requests) < 3 {
		t.Fatalf("requests = %d, want at least 3", len(requests))
	}
	if requests[0].url != adapter.USGSAllWeekURL || requests[1].url != adapter.USGSAllWeekURL {
		t.Fatalf("backfill URLs = %q, %q", requests[0].url, requests[1].url)
	}
	if requests[0].validator != "" || requests[1].validator != "" {
		t.Fatalf("validator advanced after failed delivery: %+v", requests)
	}
	if requests[2].url != adapter.USGSAllDayURL || requests[2].validator != "" {
		t.Fatalf("all_day transition = %+v", requests[2])
	}
}
