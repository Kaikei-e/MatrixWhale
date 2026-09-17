package controller

import (
	"log/slog"
	"noaa_adapter/adapter"
	"sync"
	"time"
)

const minPollDelay = 30 * time.Second

func ManageRESTRequest() {

	wg := sync.WaitGroup{}
	wg.Add(1)

	go func() {
		defer wg.Done()
		for {
			result, err := adapter.NoaaAlertsAdapter()
			if err != nil {
				slog.Error("Error getting data from NOAA", "error", err)
				time.Sleep(minPollDelay)
				continue
			}

			if err := adapter.MatrixWhaleAdapter(result); err != nil {
				slog.Error("Error sending data to Matrix Whale", "error", err)
			}

			delay := adapter.ComputeNextPollDelay(result.Header, minPollDelay)
			slog.Info("Next NOAA poll scheduled", "delay", delay)
			time.Sleep(delay)
		}
	}()

	wg.Wait()
}
