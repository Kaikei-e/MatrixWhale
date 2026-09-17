package controller

import (
	"log/slog"
	"math/rand"
	"net/http"
	"sync"
	"time"

	"matrixwhale/adapters/common/poll"

	"noaa_adapter/adapter"
)

const (
	// minPollDelay is the floor for how often we poll /alerts/active; NWS
	// documentation states no recommended cadence, so this stays the
	// conservative value already in use.
	minPollDelay = 30 * time.Second
	maxBackoff   = 10 * time.Minute
	maxJitter    = 5 * time.Second
)

func ManageRESTRequest() {

	wg := sync.WaitGroup{}

	wg.Go(func() {
		var etag, lastModified string
		var backoff time.Duration
		rng := rand.New(rand.NewSource(time.Now().UnixNano()))

		for {
			result, err := adapter.NoaaAlertsAdapter(etag, lastModified)
			if err != nil {
				backoff = poll.ComputeBackoff(result.Header, backoff, minPollDelay, maxBackoff)
				delay := poll.Jitter(backoff, maxJitter, rng)
				slog.Error("Error getting data from NOAA", "error", err, "status", result.HTTPStatus, "next_poll", delay)
				time.Sleep(delay)
				continue
			}
			backoff = 0

			notModified := result.HTTPStatus == http.StatusNotModified
			if !notModified {
				if v := result.Header.Get("ETag"); v != "" {
					etag = v
				}
				if v := result.Header.Get("Last-Modified"); v != "" {
					lastModified = v
				}
			}

			if err := adapter.MatrixWhaleAdapter(result); err != nil {
				slog.Error("Error sending data to Matrix Whale", "error", err)
			}

			delay := poll.Jitter(poll.ComputeNextPollDelay(result.Header, minPollDelay), maxJitter, rng)
			slog.Info("Next NOAA poll scheduled", "status", result.HTTPStatus, "not_modified", notModified, "next_poll", delay)
			time.Sleep(delay)
		}
	})

	wg.Wait()
}
