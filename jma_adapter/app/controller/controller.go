package controller

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"math/rand"
	"sync"
	"time"

	"jma_adapter/client"
	"jma_adapter/config"
	"jma_adapter/parser"
	"jma_adapter/state"
	"matrixwhale/adapters/common/core"
)

const (
	MaxDeliveryAttempts = 5
)

// Controller manages feed polling, hourly gap recovery, pending worker, and spool replay.
type Controller struct {
	cfg        *config.Config
	store      *state.Store
	jmaClient  *client.JMAClient
	coreClient *client.CoreClient
	validator  *client.URLValidator
	rng        *rand.Rand

	fatalMu  sync.RWMutex
	fatalErr error
}

// NewController builds a new Controller instance using configured feed lists.
func NewController(
	cfg *config.Config,
	store *state.Store,
	jmaClient *client.JMAClient,
	coreClient *client.CoreClient,
	validator *client.URLValidator,
) *Controller {
	return &Controller{
		cfg:        cfg,
		store:      store,
		jmaClient:  jmaClient,
		coreClient: coreClient,
		validator:  validator,
		rng:        rand.New(rand.NewSource(time.Now().UnixNano())),
	}
}

func (c *Controller) setFatal(err error) {
	if err == nil {
		return
	}
	c.fatalMu.Lock()
	defer c.fatalMu.Unlock()
	if c.fatalErr == nil {
		c.fatalErr = err
		slog.Error("FATAL: State persistence failure encountered, latching controller to halt all upstream requests", "err", err)
	}
}

func (c *Controller) isFatal() bool {
	c.fatalMu.RLock()
	defer c.fatalMu.RUnlock()
	return c.fatalErr != nil
}

func (c *Controller) FatalError() error {
	c.fatalMu.RLock()
	defer c.fatalMu.RUnlock()
	return c.fatalErr
}

// Run executes the main adapter lifecycle until ctx is cancelled.
func (c *Controller) Run(ctx context.Context) {
	slog.Info("Starting JMA adapter controller",
		"poll_interval", c.cfg.PollInterval,
		"request_interval", c.cfg.RequestInterval,
		"daily_limit", c.cfg.DailyByteLimit,
	)

	// Phase 1: Replay any uncommitted spooled items from previous crashes or outages
	c.replaySpool(ctx)

	// Phase 2: Main polling and draining loop with deadline-based cycle scheduling
	for {
		if ctx.Err() != nil {
			slog.Info("Controller shutting down gracefully")
			return
		}

		if c.isFatal() {
			slog.Error("Controller halted due to fatal state latch", "err", c.FatalError())
			return
		}

		cycleStart := time.Now()
		cycleDeadline := cycleStart.Add(c.cfg.PollInterval)

		c.pollCycleWithDeadline(ctx, cycleDeadline)

		if ctx.Err() != nil {
			slog.Info("Controller shutting down gracefully")
			return
		}

		remaining := cycleDeadline.Sub(time.Now())
		if remaining > 0 {
			slog.Debug("Cycle finished early, sleeping until next cycle", "sleep", remaining)
			timer := time.NewTimer(remaining)
			select {
			case <-ctx.Done():
				timer.Stop()
				slog.Info("Controller shutting down gracefully")
				return
			case <-timer.C:
			}
		}
	}
}

// replaySpool sends persisted spool files from disk to core in bounded 1-item deliveries.
func (c *Controller) replaySpool(ctx context.Context) {
	if c.isFatal() {
		return
	}

	items, err := c.store.ListSpool()
	if err != nil {
		slog.Error("Failed to list spool files, latching fatal", "err", err)
		c.setFatal(err)
		return
	}
	if len(items) == 0 {
		return
	}

	slog.Info("Replaying spooled telegrams to core in bounded independent batches", "count", len(items))

	for _, item := range items {
		select {
		case <-ctx.Done():
			return
		default:
		}

		if c.isFatal() {
			return
		}

		// Quarantine ONLY permanently malformed local spool items
		if item.ItemURL == "" {
			slog.Error("Malformed local spool item without ItemURL, quarantining", "id", item.ID)
			if qErr := c.store.QuarantineSpool(item.ID, "malformed local spool item without ItemURL"); qErr != nil {
				c.setFatal(qErr)
				return
			}
			continue
		}

		var msg *client.JmaMessageContent
		if len(item.Message) > 0 {
			var parsed client.JmaMessageContent
			if uErr := json.Unmarshal(item.Message, &parsed); uErr != nil {
				slog.Error("Corrupt local spool JSON, quarantining", "url", item.ItemURL, "err", uErr)
				if qErr := c.store.QuarantineSpool(item.ItemURL, "corrupt local spool JSON: "+uErr.Error()); qErr != nil {
					c.setFatal(qErr)
					return
				}
				if mErr := c.store.MarkFetched(item.ItemURL); mErr != nil {
					c.setFatal(mErr)
					return
				}
				continue
			}
			msg = &parsed
		}

		result := client.JmaFetchResult{
			ItemURL:    item.ItemURL,
			FeedURL:    item.FeedURL,
			FetchedAt:  item.FetchedAt,
			HTTPStatus: item.HTTPStatus,
			Error:      item.Error,
			RawXML:     item.RawXML,
			Message:    msg,
		}

		meta := core.PollMeta{
			FetchedAt:    time.Now().UTC().Format(time.RFC3339),
			HTTPStatus:   item.HTTPStatus,
			FeatureCount: 1,
			Bytes:        0,
			Backfill:     true,
		}

		// Deliver each item independently to prevent one malformed item from blocking valid items
		_, err := c.coreClient.SendMessages(ctx, meta, []client.JmaFetchResult{result})
		if err != nil {
			item.DeliveryAttempts++
			now := time.Now()
			item.LastAttemptAt = &now
			if sErr := c.store.SaveSpool(item); sErr != nil {
				slog.Error("Failed to persist updated spool delivery attempts, latching fatal", "url", item.ItemURL, "err", sErr)
				c.setFatal(sErr)
				return
			}
			slog.Warn("Core rejected spooled message, retaining durable spool indefinitely for polite retry", "url", item.ItemURL, "attempts", item.DeliveryAttempts, "err", err)
			// Core is unreachable or failing; pause further replays this cycle
			return
		}

		// ACQUISITION INVARIANT: Never delete spool before durable fetched history!
		if err := c.store.MarkFetched(item.ItemURL); err != nil {
			slog.Error("Failed to mark fetched after core delivery, latching fatal", "url", item.ItemURL, "err", err)
			c.setFatal(err)
			return
		}
		if err := c.store.DeleteSpool(item.ItemURL); err != nil {
			slog.Error("Failed to delete spool after core delivery, latching fatal", "url", item.ItemURL, "err", err)
			c.setFatal(err)
			return
		}
		slog.Debug("Successfully delivered spooled item to core", "url", item.ItemURL)
	}
}

// pollCycle executes a single cycle with a default deadline computed from PollInterval.
func (c *Controller) pollCycle(ctx context.Context) {
	deadline := time.Now().Add(c.cfg.PollInterval)
	c.pollCycleWithDeadline(ctx, deadline)
}

// pollCycleWithDeadline executes spool replay, high-frequency feeds, hourly long feeds, and queue draining.
func (c *Controller) pollCycleWithDeadline(ctx context.Context, deadline time.Time) {
	cycleStart := time.Now()
	slog.Info("Poll cycle started",
		"time", cycleStart.Format(time.RFC3339),
		"deadline", deadline.Format(time.RFC3339),
		"bytes_used", c.store.GetBytesUsed(),
		"daily_limit", c.cfg.DailyByteLimit,
	)

	// 1. Replay spool every cycle before new acquisition.
	// Spool replay delivers local items to Core and must run even if upstream Retry-After is active.
	c.replaySpool(ctx)

	if c.isFatal() {
		slog.Error("Poll cycle aborted due to fatal state persistence latch", "err", c.FatalError())
		return
	}

	// Gate upstream HTTP acquisition behind global backoff
	if now := time.Now(); now.Before(c.store.GetGlobalBackoffUntil()) {
		slog.Info("Upstream global backoff active, skipping upstream acquisition", "until", c.store.GetGlobalBackoffUntil())
		return
	}

	// 2. High-Frequency Feeds before backlog
	for _, feedURL := range c.cfg.Feeds {
		if c.isFatal() || ctx.Err() != nil {
			return
		}
		c.processFeed(ctx, feedURL, false)
	}

	// 3. Hourly Long-Term Feed Gap Recovery
	for _, feedURL := range c.cfg.LongFeeds {
		if c.isFatal() || ctx.Err() != nil {
			return
		}
		c.processFeed(ctx, feedURL, true)
	}

	if c.isFatal() || ctx.Err() != nil {
		return
	}

	// 4. Drain pending items from Core until deadline
	c.drainPending(ctx, deadline)

	slog.Info("Poll cycle completed",
		"duration", time.Since(cycleStart).String(),
		"bytes_used", c.store.GetBytesUsed(),
		"daily_limit", c.cfg.DailyByteLimit,
	)
}

// processFeed polls a single feed, submits new index items, and commits validators only upon core ack.
func (c *Controller) processFeed(ctx context.Context, feedURL string, isLongFeed bool) {
	if c.isFatal() {
		return
	}

	floor := c.cfg.PollInterval
	if isLongFeed {
		floor = c.cfg.LongPollInterval
	}

	sch := c.store.GetFeedSchedule(feedURL)
	now := time.Now()
	if now.Before(sch.NextAllowedAt) {
		slog.Debug("Feed poll skipped due to active backoff/interval schedule", "feed_url", feedURL, "until", sch.NextAllowedAt)
		return
	}

	// Persist planned minimum BEFORE request: ensures crash doesn't cause rapid restart duplicate
	plannedNext := now.Add(floor)
	if err := c.store.RecordFeedAttempt(feedURL, now, plannedNext); err != nil {
		slog.Error("Failed to persist planned feed attempt, latching fatal", "err", err)
		c.setFatal(err)
		return
	}

	if now.Before(c.store.GetGlobalBackoffUntil()) {
		slog.Info("Global backoff active, skipping feed request", "feed_url", feedURL)
		return
	}

	res, err := c.jmaClient.FetchFeed(ctx, feedURL)
	if err != nil {
		// Quota pause: normal pause, do not latch fatal; permits day rollover
		if errors.Is(err, state.ErrDailyByteLimitExceeded) {
			slog.Info("Daily byte limit reached, skipping feed poll", "feed_url", feedURL)
			return
		}
		// Critical state persistence error: latch fatal and stop
		if errors.Is(err, client.ErrStatePersistenceFailed) || errors.Is(err, state.ErrStatePersistenceFailed) {
			slog.Error("Critical state persistence error during feed fetch, latching fatal", "feed_url", feedURL, "err", err)
			c.setFatal(err)
			return
		}

		slog.Warn("Feed fetch failed", "feed_url", feedURL, "err", err)
		consecutive := sch.ConsecutiveErrors + 1
		var backoff time.Duration
		if res != nil && res.HasRetry {
			backoff = res.RetryAfter + c.positiveJitter(2*time.Second)
		} else {
			backoff = c.computeExponentialBackoff(floor, consecutive)
		}
		// Enforce max(floor, backoff) so short Retry-After cannot shrink the floor
		if backoff < floor {
			backoff = floor + c.positiveJitter(2*time.Second)
		}
		nextAllowed := time.Now().Add(backoff)
		if pErr := c.store.RecordFeedFailure(feedURL, time.Now(), nextAllowed, consecutive); pErr != nil {
			slog.Error("Failed to record feed failure schedule, latching fatal", "err", pErr)
			c.setFatal(pErr)
			return
		}
		return
	}

	if res.NotModified {
		slog.Debug("Feed not modified (304)", "feed_url", feedURL)
		delay := floor
		if res.NextDelay > delay {
			delay = res.NextDelay
		}
		if res.HasRetry && res.RetryAfter > delay {
			delay = res.RetryAfter
		}
		nextAllowed := time.Now().Add(delay)
		if pErr := c.store.RecordFeedSuccess(feedURL, nextAllowed); pErr != nil {
			slog.Error("Failed to record feed success schedule, latching fatal", "err", pErr)
			c.setFatal(pErr)
			return
		}
		return
	}

	// Parse Atom entries
	entries, err := parser.ParseAtomFeed(feedURL, res.Body, c.validator)
	if err != nil {
		slog.Warn("Failed to parse Atom feed XML", "feed_url", feedURL, "err", err)
		delay := floor
		if res.NextDelay > delay {
			delay = res.NextDelay
		}
		if pErr := c.store.RecordFeedSuccess(feedURL, time.Now().Add(delay)); pErr != nil {
			slog.Error("Failed to record feed schedule on parse error, latching fatal", "err", pErr)
			c.setFatal(pErr)
		}
		return
	}

	// Filter out already fetched or spooled URLs
	var newItems []client.JmaIndexItem
	for _, entry := range entries {
		if !c.store.IsFetched(entry.ItemURL) && !c.store.HasSpool(entry.ItemURL) {
			newItems = append(newItems, entry)
		}
	}

	slog.Info("Parsed Atom feed", "feed_url", feedURL, "total_entries", len(entries), "new_items", len(newItems))

	if len(newItems) > 0 {
		meta := core.PollMeta{
			FetchedAt:    time.Now().UTC().Format(time.RFC3339),
			HTTPStatus:   200,
			FeatureCount: len(newItems),
			Bytes:        len(res.Body),
			FeedURL:      feedURL,
			Backfill:     isLongFeed,
		}

		ack, err := c.coreClient.SendIndex(ctx, meta, newItems)
		if err != nil {
			slog.Warn("Core rejected feed index, falling back to immediate direct acquisition", "feed_url", feedURL, "err", err)
			for _, item := range newItems {
				c.fetchAndIngestItem(ctx, item.ItemURL, item.FeedURL)
			}
			delay := floor
			if res.NextDelay > delay {
				delay = res.NextDelay
			}
			if pErr := c.store.RecordFeedSuccess(feedURL, time.Now().Add(delay)); pErr != nil {
				slog.Error("Failed to record feed schedule on core index rejection, latching fatal", "err", pErr)
				c.setFatal(pErr)
			}
			return
		}
		slog.Info("Core acknowledged feed index", "feed_url", feedURL, "ack", ack)
	}

	// Commit validator only when core index is durably accepted or feed had no new items
	if res.LastModified != "" || res.ETag != "" {
		if err := c.store.SaveFeedValidator(feedURL, res.LastModified, res.ETag, time.Now()); err != nil {
			slog.Error("Failed to save feed validator, latching fatal", "err", err)
			c.setFatal(err)
			return
		}
	}

	delay := floor
	if res.NextDelay > delay {
		delay = res.NextDelay
	}
	if res.HasRetry && res.RetryAfter > delay {
		delay = res.RetryAfter
	}
	nextAllowed := time.Now().Add(delay)
	if err := c.store.RecordFeedSuccess(feedURL, nextAllowed); err != nil {
		slog.Error("Failed to record feed success schedule, latching fatal", "err", err)
		c.setFatal(err)
		return
	}
}

// drainPending repeatedly drains pending XML documents from Core until empty or deadline is reached.
func (c *Controller) drainPending(ctx context.Context, deadline time.Time) {
	if c.isFatal() {
		return
	}
	if time.Now().Before(c.store.GetGlobalBackoffUntil()) {
		slog.Info("Global backoff active, skipping pending queue drain", "until", c.store.GetGlobalBackoffUntil())
		return
	}

	totalDrained := 0
	defer func() {
		if totalDrained > 0 {
			slog.Info("Completed pending queue drain",
				"items_drained", totalDrained,
				"bytes_used", c.store.GetBytesUsed(),
				"daily_limit", c.cfg.DailyByteLimit,
			)
		}
	}()

	seenInDrain := make(map[string]bool)

	for time.Now().Before(deadline) {
		if ctx.Err() != nil || c.isFatal() {
			return
		}

		if time.Now().Before(c.store.GetGlobalBackoffUntil()) {
			slog.Info("Global backoff triggered during intake, halting pending drain", "until", c.store.GetGlobalBackoffUntil())
			return
		}

		pending, err := c.coreClient.GetPending(ctx, 50)
		if err != nil {
			slog.Warn("Failed to get pending items from core", "err", err)
			return
		}
		if len(pending) == 0 {
			slog.Debug("Pending queue is empty")
			return
		}

		slog.Info("Retrieved pending items to fetch from JMA", "depth", len(pending), "total_drained", totalDrained)

		newItemsOrFirstSeen := 0

		for _, item := range pending {
			select {
			case <-ctx.Done():
				return
			default:
			}

			if c.isFatal() {
				slog.Error("Halting pending queue processing due to fatal state latch", "err", c.FatalError())
				return
			}

			if time.Now().Before(c.store.GetGlobalBackoffUntil()) {
				slog.Info("Global backoff triggered during queue intake, halting pending queue")
				return
			}

			// Invariant: track items seen in this specific drain cycle to prevent spinning
			// on transient failures or core outages where the same items are repeatedly returned.
			if !seenInDrain[item.ItemURL] {
				seenInDrain[item.ItemURL] = true
				newItemsOrFirstSeen++
			} else {
				// We have already seen this item in THIS drain cycle.
				continue
			}

			// Invariant: never re-fetch an item that is already in local spool,
			// or already in durable fetched history.
			if c.store.HasSpool(item.ItemURL) || c.store.IsFetched(item.ItemURL) {
				continue
			}

			c.fetchAndIngestItem(ctx, item.ItemURL, item.FeedURL)
			totalDrained++

			if c.isFatal() {
				slog.Error("Halting pending queue processing due to fatal state latch after item", "err", c.FatalError(), "url", item.ItemURL)
				return
			}
		}

		// If we didn't see any new URLs in this batch (meaning all returned items
		// were already processed in earlier iterations of THIS drain cycle), we are
		// spinning on the same queue front. Stop draining.
		if newItemsOrFirstSeen == 0 {
			slog.Debug("No new items seen in pending batch; exiting drain cycle", "batch_size", len(pending))
			return
		}
	}
}

func (c *Controller) fetchAndIngestItem(ctx context.Context, itemURL, feedURL string) {
	if c.isFatal() {
		return
	}

	nowStr := time.Now().UTC().Format(time.RFC3339)
	dataRes, err := c.jmaClient.FetchData(ctx, itemURL)
	if err != nil {
		slog.Warn("Failed to fetch data document from JMA", "url", itemURL, "err", err)

		// Quota pause: normal pause, do not treat as fatal corruption; permits day rollover
		if errors.Is(err, state.ErrDailyByteLimitExceeded) {
			slog.Info("Daily byte limit reached, pausing pending intake", "url", itemURL, "bytes_used", c.store.GetBytesUsed())
			return
		}

		// State persistence failure: abort acquisition immediately and latch fatal
		if errors.Is(err, client.ErrStatePersistenceFailed) || errors.Is(err, state.ErrStatePersistenceFailed) {
			slog.Error("Critical state persistence error during data fetch, latching fatal", "err", err)
			c.setFatal(err)
			return
		}

		var upErr *client.UpstreamError
		if errors.As(err, &upErr) {
			// Terminal 400, 404, 410: persist terminal outcome before report/retries; no re-download loop
			if upErr.StatusCode == 400 || upErr.StatusCode == 404 || upErr.StatusCode == 410 {
				errStr := upErr.Error()
				spoolItem := state.SpoolItem{
					ID:         state.SpoolItemKey(itemURL),
					ItemURL:    itemURL,
					FeedURL:    feedURL,
					FetchedAt:  nowStr,
					HTTPStatus: upErr.StatusCode,
					Error:      &errStr,
				}
				if sErr := c.store.SaveSpool(spoolItem); sErr != nil {
					slog.Error("Failed to save terminal spool item, latching fatal", "err", sErr)
					c.setFatal(sErr)
					return
				}
				if mErr := c.store.MarkFetched(itemURL); mErr != nil {
					slog.Error("Failed to mark terminal URL fetched, latching fatal", "err", mErr)
					c.setFatal(mErr)
					return
				}

				meta := core.PollMeta{
					FetchedAt:    nowStr,
					HTTPStatus:   upErr.StatusCode,
					FeatureCount: 1,
					Bytes:        0,
				}
				fetchResult := client.JmaFetchResult{
					ItemURL:    itemURL,
					FeedURL:    feedURL,
					FetchedAt:  nowStr,
					HTTPStatus: upErr.StatusCode,
					Error:      &errStr,
				}
				if _, sendErr := c.coreClient.SendMessages(ctx, meta, []client.JmaFetchResult{fetchResult}); sendErr == nil {
					if dErr := c.store.DeleteSpool(itemURL); dErr != nil {
						slog.Error("Failed to delete terminal spool item after core delivery, latching fatal", "err", dErr)
						c.setFatal(dErr)
						return
					}
				} else {
					spoolItem.DeliveryAttempts++
					now := time.Now()
					spoolItem.LastAttemptAt = &now
					if sErr := c.store.SaveSpool(spoolItem); sErr != nil {
						slog.Error("Failed to persist updated terminal spool delivery attempts, latching fatal", "url", itemURL, "err", sErr)
						c.setFatal(sErr)
						return
					}
				}
				return
			}
		}

		// Transient failure (HTTP 403, 429, 5xx, or network/timeout/connection error):
		// Report the failure outcome to Core so sea.jma_item transitions to state='failed'
		// with incremented attempts and last_attempt_at backoff, preventing queue blockage.
		statusCode := 0
		if upErr != nil {
			statusCode = upErr.StatusCode
		}
		errStr := err.Error()
		meta := core.PollMeta{
			FetchedAt:    nowStr,
			HTTPStatus:   statusCode,
			FeatureCount: 1,
			Bytes:        0,
		}
		fetchResult := client.JmaFetchResult{
			ItemURL:    itemURL,
			FeedURL:    feedURL,
			FetchedAt:  nowStr,
			HTTPStatus: statusCode,
			Error:      &errStr,
		}
		if _, sendErr := c.coreClient.SendMessages(ctx, meta, []client.JmaFetchResult{fetchResult}); sendErr != nil {
			slog.Warn("Failed to report transient fetch failure to core", "url", itemURL, "err", sendErr)
		} else {
			slog.Info("Reported transient item failure to core for retry backoff", "url", itemURL, "status", statusCode)
		}
		return
	}

	rawBytes := dataRes.Body
	rawXMLStr := string(rawBytes)

	// Parse XML telegram into canonical message model
	msg, parseErr := parser.ParseTelegram(itemURL, rawBytes)
	var errPtr *string
	if parseErr != nil {
		slog.Warn("Failed to parse JMAXML telegram; will record error outcome without refetching", "url", itemURL, "err", parseErr)
		e := parseErr.Error()
		errPtr = &e
	}

	// Prepare SpoolItem
	var msgJSON json.RawMessage
	if msg != nil {
		b, mErr := json.Marshal(msg)
		if mErr != nil {
			slog.Warn("Failed to marshal message struct to JSON, recording raw error", "err", mErr)
			e := mErr.Error()
			errPtr = &e
		} else {
			msgJSON = b
		}
	}

	spoolItem := state.SpoolItem{
		ID:         state.SpoolItemKey(itemURL),
		ItemURL:    itemURL,
		FeedURL:    feedURL,
		FetchedAt:  nowStr,
		HTTPStatus: 200,
		RawXML:     &rawXMLStr,
		Error:      errPtr,
		Message:    msgJSON,
	}

	// ACQUISITION INVARIANT:
	// 1. Successful downloaded response durably spooled BEFORE any core call
	if err := c.store.SaveSpool(spoolItem); err != nil {
		slog.Error("Failed to persist to durable spool, latching fatal", "url", itemURL, "err", err)
		c.setFatal(err)
		return
	}

	// 2. URL marked fetched BEFORE any core call (guarantees core outage cannot trigger redownload)
	if err := c.store.MarkFetched(itemURL); err != nil {
		slog.Error("Failed to mark URL fetched in durable history, latching fatal", "url", itemURL, "err", err)
		c.setFatal(err)
		return
	}

	fetchResult := client.JmaFetchResult{
		ItemURL:    itemURL,
		FeedURL:    feedURL,
		FetchedAt:  nowStr,
		HTTPStatus: 200,
		Error:      errPtr,
		RawXML:     &rawXMLStr,
		Message:    msg,
	}

	meta := core.PollMeta{
		FetchedAt:    nowStr,
		HTTPStatus:   200,
		FeatureCount: 1,
		Bytes:        len(rawBytes),
	}

	// 3. Deliver to core
	_, err = c.coreClient.SendMessages(ctx, meta, []client.JmaFetchResult{fetchResult})
	if err != nil {
		spoolItem.DeliveryAttempts++
		now := time.Now()
		spoolItem.LastAttemptAt = &now
		if sErr := c.store.SaveSpool(spoolItem); sErr != nil {
			slog.Error("Failed to persist updated spool delivery attempts, latching fatal", "url", itemURL, "err", sErr)
			c.setFatal(sErr)
			return
		}
		slog.Warn("Core rejected message ingestion, spool retained for future replay", "url", itemURL, "attempts", spoolItem.DeliveryAttempts, "err", err)
		return
	}

	// Core confirmed durable ingestion: delete spool item (MarkFetched was already durable)
	if err := c.store.DeleteSpool(itemURL); err != nil {
		slog.Error("Failed to delete spool file after core delivery, latching fatal", "url", itemURL, "err", err)
		c.setFatal(err)
		return
	}
	slog.Info("Successfully ingested telegram into core", "url", itemURL)
}

func (c *Controller) computeExponentialBackoff(floor time.Duration, consecutiveErrors int) time.Duration {
	if consecutiveErrors <= 1 {
		return floor + c.positiveJitter(2*time.Second)
	}
	shift := consecutiveErrors
	if shift > 6 {
		shift = 6
	}
	backoff := floor * time.Duration(1<<shift)
	maxBackoff := 6 * time.Hour
	if backoff > maxBackoff {
		backoff = maxBackoff
	}
	return backoff + c.positiveJitter(2*time.Second)
}

func (c *Controller) positiveJitter(maxJitter time.Duration) time.Duration {
	if maxJitter <= 0 {
		return 0
	}
	return time.Duration(c.rng.Int63n(int64(maxJitter)))
}
