package controller

import (
	"context"
	"encoding/json"
	"log/slog"
	"math/rand"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"matrixwhale/adapters/common/core"
	"matrixwhale/adapters/common/poll"

	"gdacs_adapter/adapter"
)

const (
	DefaultPollInterval       = 5 * time.Minute
	DefaultBackfillDays       = 14
	DefaultMinRequestInterval = 10 * time.Second

	geometryBatchSize = 10
	pendingLimit      = 20

	searchForwardDays = 7

	minBackoff = 30 * time.Second
	maxBackoff = 10 * time.Minute
	maxJitter  = 5 * time.Second

	maxPageAttempts = 3
)

type config struct {
	apiURL             string
	backfillDays       int
	pollInterval       time.Duration
	minRequestInterval time.Duration
}

func loadConfig() config {
	cfg := config{
		apiURL:             adapter.DefaultAPIURL,
		backfillDays:       DefaultBackfillDays,
		pollInterval:       DefaultPollInterval,
		minRequestInterval: DefaultMinRequestInterval,
	}
	if v := strings.TrimSpace(os.Getenv("GDACS_API_URL")); v != "" {
		cfg.apiURL = v
	}
	if v := strings.TrimSpace(os.Getenv("GDACS_BACKFILL_DAYS")); v != "" {
		if days, err := strconv.Atoi(v); err == nil && days > 0 {
			cfg.backfillDays = days
		} else {
			slog.Warn("GDACS_BACKFILL_DAYS is invalid; using default", "value", v, "default", DefaultBackfillDays)
		}
	}
	if v := strings.TrimSpace(os.Getenv("GDACS_POLL_INTERVAL")); v != "" {
		if d, err := time.ParseDuration(v); err == nil && d > 0 {
			cfg.pollInterval = d
		} else {
			slog.Warn("GDACS_POLL_INTERVAL is invalid; using default", "value", v, "default", DefaultPollInterval)
		}
	}
	if v := strings.TrimSpace(os.Getenv("GDACS_MIN_REQUEST_INTERVAL")); v != "" {
		if d, err := time.ParseDuration(v); err == nil && d > 0 {
			cfg.minRequestInterval = d
		} else {
			slog.Warn("GDACS_MIN_REQUEST_INTERVAL is invalid; using default", "value", v, "default", DefaultMinRequestInterval)
		}
	}
	return cfg
}

func computeSince(cfg config, backfill bool, now time.Time) time.Time {
	if backfill {
		return now.AddDate(0, 0, -cfg.backfillDays)
	}
	return now.Add(-3 * cfg.pollInterval)
}

type tickWindow struct {
	query        adapter.EventListQuery
	since, until time.Time
}

func tickWindows(cfg config, backfill bool, tick time.Time) []tickWindow {
	return []tickWindow{
		{adapter.PrimaryEventListQuery, computeSince(cfg, backfill, tick), time.Time{}},
		{adapter.TsunamiEventListQuery, tick.AddDate(0, 0, -cfg.backfillDays), tick.AddDate(0, 0, searchForwardDays)},
	}
}

type (
	fetchPageFunc     func(ctx context.Context, client *http.Client, baseURL string, query adapter.EventListQuery, since, until time.Time, pageNumber int) (adapter.EventPage, error)
	fetchGeometryFunc func(ctx context.Context, client *http.Client, baseURL, eventtype string, eventid, episodeid int64) (json.RawMessage, int, error)
	sendEventsFunc    func(ctx context.Context, meta core.PollMeta, features []json.RawMessage) error
	pendingFunc       func(ctx context.Context, limit int) ([]adapter.GeometryPendingEntry, error)
	sendGeometryFunc  func(ctx context.Context, meta core.PollMeta, entries []adapter.GeometryResult) error
	waitFunc          func(ctx context.Context, delay time.Duration) bool
)

func Run(ctx context.Context) {
	cfg := loadConfig()
	limiter := adapter.NewLimiter(cfg.minRequestInterval)
	httpClient := &http.Client{Timeout: 60 * time.Second}
	mw := adapter.NewMatrixWhaleAdapter(core.NewClientFromEnv())
	rng := rand.New(rand.NewSource(time.Now().UnixNano()))
	run(ctx, cfg, limiter, httpClient, adapter.FetchEventPage, adapter.FetchGeometry, mw.SendEvents, mw.PendingGeometry, mw.SendGeometry, wait, rng, time.Now)
}

func run(ctx context.Context, cfg config, limiter *adapter.Limiter, httpClient *http.Client,
	fetchPage fetchPageFunc, fetchGeom fetchGeometryFunc,
	sendEvents sendEventsFunc, fetchPending pendingFunc, sendGeom sendGeometryFunc,
	pause waitFunc, rng *rand.Rand, now func() time.Time,
) {
	backfill := true
	for {
		if ctx.Err() != nil {
			return
		}
		tick := now()
		if !pollTick(ctx, cfg, backfill, tick, limiter, httpClient, fetchPage, sendEvents, pause, rng) {
			return
		}
		backfill = false

		deadline := tick.Add(cfg.pollInterval)
		if !drainGeometry(ctx, cfg, limiter, httpClient, fetchGeom, fetchPending, sendGeom, pause, rng, now, deadline) {
			return
		}

		delay := deadline.Sub(now())
		if delay < 0 {
			delay = 0
		}
		if !pause(ctx, delay) {
			return
		}
	}
}

func pollTick(ctx context.Context, cfg config, backfill bool, tick time.Time, limiter *adapter.Limiter, httpClient *http.Client, fetchPage fetchPageFunc, sendEvents sendEventsFunc, pause waitFunc, rng *rand.Rand) bool {
	for _, w := range tickWindows(cfg, backfill, tick) {
		if !pollAllPages(ctx, cfg, w.query, w.since, w.until, backfill, limiter, httpClient, fetchPage, sendEvents, pause, rng) {
			return false
		}
	}
	return true
}

func pollAllPages(ctx context.Context, cfg config, query adapter.EventListQuery, since, until time.Time, backfill bool, limiter *adapter.Limiter, httpClient *http.Client, fetchPage fetchPageFunc, sendEvents sendEventsFunc, pause waitFunc, rng *rand.Rand) bool {
	pageNumber := 1
	var backoff time.Duration
	attempts := 0
	for {
		if ctx.Err() != nil {
			return false
		}
		if err := limiter.Wait(ctx); err != nil {
			return false
		}
		page, err := fetchPage(ctx, httpClient, cfg.apiURL, query, since, until, pageNumber)
		limiter.Done()
		if err != nil {
			if isNonRetryableStatus(page.HTTPStatus) {
				slog.Error("GDACS event list request rejected; abandoning query for this tick", "error", err, "eventlist", query.EventList, "page", pageNumber, "status", page.HTTPStatus)
				return true
			}
			attempts++
			if attempts >= maxPageAttempts {
				slog.Error("GDACS event list fetch failed repeatedly; abandoning query for this tick", "error", err, "eventlist", query.EventList, "page", pageNumber, "attempts", attempts)
				return true
			}
			backoff = poll.ComputeBackoff(page.Header, backoff, minBackoff, maxBackoff)
			delay := poll.Jitter(backoff, maxJitter, rng)
			slog.Error("GDACS event list fetch failed", "error", err, "eventlist", query.EventList, "page", pageNumber, "attempt", attempts, "next_retry", delay)
			if !pause(ctx, delay) {
				return false
			}
			continue
		}
		attempts = 0
		backoff = 0

		meta := core.PollMeta{
			FetchedAt:    time.Now().UTC().Format(time.RFC3339),
			HTTPStatus:   page.HTTPStatus,
			FeatureCount: len(page.Features),
			Bytes:        page.Bytes,
			FeedURL:      page.URL,
			Backfill:     backfill,
		}
		if sendErr := sendEvents(ctx, meta, page.Features); sendErr != nil {
			slog.Error("GDACS event page delivery to core failed; resuming next tick", "error", sendErr, "eventlist", query.EventList, "page", pageNumber)
			return true
		}
		slog.Info("GDACS event page accepted", "eventlist", query.EventList, "page", pageNumber, "count", len(page.Features), "done", page.Done, "backfill", backfill)
		if page.Done {
			return true
		}
		pageNumber++
	}
}

// treats any 4xx but 429 as terminal, so a persistent 404 can't wedge the retry loop.
func isNonRetryableStatus(status int) bool {
	return status >= 400 && status < 500 && status != http.StatusTooManyRequests
}

func drainGeometry(ctx context.Context, cfg config, limiter *adapter.Limiter, httpClient *http.Client,
	fetchGeom fetchGeometryFunc, fetchPending pendingFunc, sendGeom sendGeometryFunc,
	pause waitFunc, rng *rand.Rand, now func() time.Time, deadline time.Time,
) bool {
	for now().Before(deadline) {
		if ctx.Err() != nil {
			return false
		}
		entries, err := fetchPending(ctx, pendingLimit)
		if err != nil {
			slog.Error("GDACS pending-geometry lookup failed; resuming next tick", "error", err)
			return true
		}
		if len(entries) == 0 {
			return true
		}

		results := make([]adapter.GeometryResult, 0, geometryBatchSize)
		for _, entry := range entries {
			if ctx.Err() != nil {
				return false
			}
			if !now().Before(deadline) {
				break
			}
			geometry, status, ok := fetchGeometryWithRetry(ctx, limiter, httpClient, cfg.apiURL, entry, fetchGeom, pause, rng)
			if !ok {
				return ctx.Err() == nil
			}
			results = append(results, adapter.GeometryResult{
				EventType: entry.EventType, EventID: entry.EventID, EpisodeID: entry.EpisodeID,
				HTTPStatus: status, Geometry: geometry,
			})
			if len(results) == geometryBatchSize {
				if !flushGeometry(ctx, sendGeom, &results) {
					return true
				}
			}
		}
		if !flushGeometry(ctx, sendGeom, &results) {
			return true
		}
	}
	return true
}

func fetchGeometryWithRetry(ctx context.Context, limiter *adapter.Limiter, httpClient *http.Client, apiURL string, entry adapter.GeometryPendingEntry, fetchGeom fetchGeometryFunc, pause waitFunc, rng *rand.Rand) (json.RawMessage, int, bool) {
	var backoff time.Duration
	for {
		if ctx.Err() != nil {
			return nil, 0, false
		}
		if err := limiter.Wait(ctx); err != nil {
			return nil, 0, false
		}
		geometry, status, err := fetchGeom(ctx, httpClient, apiURL, entry.EventType, entry.EventID, entry.EpisodeID)
		limiter.Done()
		if err == nil {
			return geometry, status, true
		}
		backoff = poll.ComputeBackoff(nil, backoff, minBackoff, maxBackoff)
		delay := poll.Jitter(backoff, maxJitter, rng)
		slog.Error("GDACS geometry fetch failed", "error", err, "eventtype", entry.EventType, "eventid", entry.EventID, "episodeid", entry.EpisodeID, "next_retry", delay)
		if !pause(ctx, delay) {
			return nil, 0, false
		}
	}
}

func flushGeometry(ctx context.Context, sendGeom sendGeometryFunc, results *[]adapter.GeometryResult) bool {
	if len(*results) == 0 {
		return true
	}
	meta := core.PollMeta{FetchedAt: time.Now().UTC().Format(time.RFC3339), FeatureCount: len(*results)}
	err := sendGeom(ctx, meta, *results)
	*results = (*results)[:0]
	if err != nil {
		slog.Error("GDACS geometry delivery to core failed; resuming next tick", "error", err)
		return false
	}
	return true
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
