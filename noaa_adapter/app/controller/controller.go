package controller

import (
	"log/slog"
	"noaa_adapter/adapter"
	"sync"
	"time"
)

func ManageRESTRequest() {

	wg := sync.WaitGroup{}
	wg.Add(1)

	go func() {
		defer wg.Done()
		for {
			data, err := adapter.NoaaAlertsAdapter()
			if err != nil {
				slog.Error("Error getting data from NOAA", "error", err)
			}

			// trimmedData, err := TrimNoaaData(data)
			// if err != nil {
			// 	slog.Error("Error trimming data", "error", err)
			// }

			err = adapter.MatrixWhaleAdapter(data)
			if err != nil {
				slog.Error("Error sending data to Matrix Whale", "error", err)
			}
			time.Sleep(60 * time.Second)
		}
	}()

	wg.Wait()
}
