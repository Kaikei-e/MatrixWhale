package controller

import (
	"context"
	"log/slog"
	"math/rand"
	"os"
	"strconv"
	"strings"
	"time"

	"matrixwhale/adapters/common/poll"

	"emsc_adapter/adapter"
)

const (
	minBackoff      = 5 * time.Second
	maxBackoff      = 10 * time.Minute
	maxJitter       = 5 * time.Second
	liveChannelSize = 1000
	liveBatchSize   = 100
	gapFillLookback = 5 * time.Minute
)

// fdsnPageLimit and liveBatchWait are package-level vars, not consts, so
// tests can shrink them to keep pagination and time-based flush fast.
var (
	fdsnPageLimit = 20000
	liveBatchWait = 500 * time.Millisecond
)

type config struct {
	websocketURL string
	fdsnURL      string
	backfillDays int
}

func loadConfig() config {
	cfg := config{
		websocketURL: adapter.DefaultWebSocketURL,
		fdsnURL:      adapter.DefaultFDSNURL,
		backfillDays: adapter.DefaultBackfillDays,
	}
	if v := strings.TrimSpace(os.Getenv("EMSC_WEBSOCKET_URL")); v != "" {
		cfg.websocketURL = v
	}
	if v := strings.TrimSpace(os.Getenv("EMSC_FDSN_URL")); v != "" {
		cfg.fdsnURL = v
	}
	if v := strings.TrimSpace(os.Getenv("EMSC_BACKFILL_DAYS")); v != "" {
		if days, err := strconv.Atoi(v); err == nil && days > 0 {
			cfg.backfillDays = days
		} else {
			slog.Warn("EMSC_BACKFILL_DAYS is invalid; using default", "value", v, "default", adapter.DefaultBackfillDays)
		}
	}
	return cfg
}

type fetchFunc func(ctx context.Context, fdsnURL string, query adapter.FDSNQuery) (adapter.FetchResult, error)
type subscribeFunc func(ctx context.Context, wsURL string, out chan<- adapter.LiveMessage) error
type sendFunc func(ctx context.Context, batch adapter.Batch) error
type waitFunc func(ctx context.Context, delay time.Duration) bool

// Run starts the EMSC pipeline: a startup backfill over the last
// EMSC_BACKFILL_DAYS, then the live WebSocket subscription, reconnecting
// with a gap-fill query whenever the connection drops.
func Run(ctx context.Context) {
	rng := rand.New(rand.NewSource(time.Now().UnixNano()))
	run(ctx, loadConfig(), adapter.FetchBackfillPage, adapter.Subscribe, adapter.MatrixWhaleAdapter, wait, rng)
}

func run(ctx context.Context, cfg config, fetch fetchFunc, subscribe subscribeFunc, send sendFunc, pause waitFunc, rng *rand.Rand) {
	var maxLastUpdate string
	if !runFDSNSync(ctx, cfg, "", fetch, send, pause, rng, &maxLastUpdate) {
		return
	}
	slog.Info("EMSC startup backfill complete", "last_update", maxLastUpdate)

	var backoff time.Duration
	for {
		if ctx.Err() != nil {
			return
		}
		err := runLive(ctx, cfg, subscribe, send, pause, rng, &maxLastUpdate)
		if ctx.Err() != nil {
			return
		}

		backoff = poll.ComputeBackoff(nil, backoff, minBackoff, maxBackoff)
		delay := poll.Jitter(backoff, maxJitter, rng)
		slog.Error("EMSC websocket disconnected; reconnecting", "error", err, "next_attempt", delay)
		if !pause(ctx, delay) {
			return
		}

		if !runFDSNSync(ctx, cfg, gapFillUpdatedAfter(maxLastUpdate), fetch, send, pause, rng, &maxLastUpdate) {
			return
		}
		backoff = 0
	}
}

// runFDSNSync paginates an FDSN query (the startup backfill when
// updatedAfter is empty, otherwise a reconnect gap-fill) and POSTs each page
// as one backfill batch. A failed fetch or send is retried with backoff
// without advancing the offset; maxLastUpdate only advances once a page is
// accepted. It reports whether ctx is still live when it returns.
func runFDSNSync(ctx context.Context, cfg config, updatedAfter string, fetch fetchFunc, send sendFunc, pause waitFunc, rng *rand.Rand, maxLastUpdate *string) bool {
	now := time.Now().UTC()
	start := now.Add(-time.Duration(cfg.backfillDays) * 24 * time.Hour)

	offset := 0
	var backoff time.Duration
	for {
		if ctx.Err() != nil {
			return false
		}
		query := adapter.FDSNQuery{
			Start:        start,
			End:          now,
			OrderBy:      "time-asc",
			Limit:        fdsnPageLimit,
			Offset:       offset,
			UpdatedAfter: updatedAfter,
		}
		result, err := fetch(ctx, cfg.fdsnURL, query)
		if err == nil {
			var batch adapter.Batch
			batch, err = adapter.BackfillBatch(result)
			if err == nil {
				err = send(ctx, batch)
			}
		}
		if err != nil {
			backoff = poll.ComputeBackoff(nil, backoff, minBackoff, maxBackoff)
			delay := poll.Jitter(backoff, maxJitter, rng)
			slog.Error("EMSC FDSN sync attempt failed", "error", err, "offset", offset, "next_retry", delay)
			if !pause(ctx, delay) {
				return false
			}
			continue
		}

		backoff = 0
		if lastUpdate := adapter.MaxLastUpdateOfFeatures(result.Features); lastUpdate > *maxLastUpdate {
			*maxLastUpdate = lastUpdate
		}
		count := len(result.Features)
		slog.Info("EMSC FDSN page accepted", "offset", offset, "count", count, "gap_fill", updatedAfter != "")
		if count < fdsnPageLimit {
			return true
		}
		offset += fdsnPageLimit
	}
}

// runLive subscribes to the live WebSocket feed, batches incoming messages,
// and sends each batch to the core, retrying a failed send with backoff
// without dropping or reordering it. It returns once the subscription ends
// (error or clean close); the caller decides whether to reconnect.
func runLive(ctx context.Context, cfg config, subscribe subscribeFunc, send sendFunc, pause waitFunc, rng *rand.Rand, maxLastUpdate *string) error {
	raw := make(chan adapter.LiveMessage, liveChannelSize)
	batches := make(chan []adapter.LiveMessage)
	subErr := make(chan error, 1)

	go func() { subErr <- subscribe(ctx, cfg.websocketURL, raw) }()

	batcherDone := make(chan struct{})
	go func() {
		adapter.Batcher{Size: liveBatchSize, MaxWait: liveBatchWait}.Run(ctx, raw, batches)
		close(batcherDone)
	}()

	var backoff time.Duration
	for batch := range batches {
		for {
			err := send(ctx, adapter.LiveBatch(batch, cfg.websocketURL))
			if err == nil {
				backoff = 0
				if lastUpdate := adapter.MaxLastUpdateOfMessages(batch); lastUpdate > *maxLastUpdate {
					*maxLastUpdate = lastUpdate
				}
				slog.Info("EMSC live batch accepted", "count", len(batch))
				break
			}
			backoff = poll.ComputeBackoff(nil, backoff, minBackoff, maxBackoff)
			delay := poll.Jitter(backoff, maxJitter, rng)
			slog.Error("EMSC live batch delivery failed", "error", err, "count", len(batch), "next_retry", delay)
			if !pause(ctx, delay) {
				<-batcherDone
				<-subErr
				return ctx.Err()
			}
		}
	}
	<-batcherDone
	return <-subErr
}

// gapFillUpdatedAfter returns lastUpdate minus a lookback window, in
// RFC3339 form, or "" if lastUpdate hasn't been observed yet.
func gapFillUpdatedAfter(lastUpdate string) string {
	if lastUpdate == "" {
		return ""
	}
	t, err := time.Parse(time.RFC3339Nano, lastUpdate)
	if err != nil {
		return ""
	}
	return t.Add(-gapFillLookback).UTC().Format(time.RFC3339Nano)
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
