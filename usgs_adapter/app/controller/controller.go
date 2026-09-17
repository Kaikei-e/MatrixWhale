package controller

import (
	"context"
	"log/slog"
	"math/rand"
	"net/http"
	"time"

	"matrixwhale/adapters/common/poll"

	"usgs_adapter/adapter"
)

const (
	minPollDelay = 60 * time.Second
	maxBackoff   = 10 * time.Minute
	maxJitter    = 5 * time.Second
)

func ManageRESTRequest(ctx context.Context) {
	rng := rand.New(rand.NewSource(time.Now().UnixNano()))
	run(ctx, adapter.FetchFeed, adapter.MatrixWhaleAdapter, wait, rng)
}

type fetchFunc func(context.Context, string, string) (adapter.PollResult, error)
type sendFunc func(context.Context, adapter.PollResult) error
type waitFunc func(context.Context, time.Duration) bool

func run(ctx context.Context, fetch fetchFunc, send sendFunc, pause waitFunc, rng *rand.Rand) {
	backfill := true
	var backfillLastModified string
	var lastModified string
	var backoff time.Duration

	for {
		if err := ctx.Err(); err != nil {
			return
		}
		feedURL := adapter.USGSAllDayURL
		validator := lastModified
		if backfill {
			feedURL = adapter.USGSAllWeekURL
			validator = backfillLastModified
		}
		result, err := fetch(ctx, feedURL, validator)
		if err == nil {
			result.Backfill = backfill
			err = send(ctx, result)
		}
		if err != nil {
			backoff = poll.ComputeBackoff(result.Header, backoff, minPollDelay, maxBackoff)
			delay := poll.Jitter(backoff, maxJitter, rng)
			slog.Error("USGS pipeline attempt failed", "error", err, "status", result.HTTPStatus, "next_poll", delay, "backfill", backfill)
			if !pause(ctx, delay) {
				return
			}
			continue
		}

		backoff = 0
		if backfill {
			if result.HTTPStatus != http.StatusNotModified {
				backfillLastModified = result.Header.Get("Last-Modified")
			}
			backfill = false
			slog.Info("USGS startup backfill accepted")
		} else if result.HTTPStatus != http.StatusNotModified {
			lastModified = result.Header.Get("Last-Modified")
		}

		delay := poll.Jitter(poll.ComputeNextPollDelay(result.Header, minPollDelay), maxJitter, rng)
		slog.Info("Next USGS poll scheduled", "status", result.HTTPStatus, "not_modified", result.HTTPStatus == http.StatusNotModified, "next_poll", delay)
		if !pause(ctx, delay) {
			return
		}
	}
}

func wait(ctx context.Context, delay time.Duration) bool {
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-timer.C:
		return true
	}
}
