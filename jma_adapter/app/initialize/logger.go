package initialize

import (
	"context"
	"log/slog"
	"net/http"
	"time"

	"matrixwhale/adapters/common/core"
	"matrixwhale/adapters/common/logging"
)

// InitLogger initializes the structured slog logger reporting to MatrixWhale core.
// It quietly probes Core health first to eliminate startup connection burst noise.
func InitLogger() {
	coreClient := core.NewClientFromEnv()

	// Quietly probe core readiness for up to 10 seconds to avoid connection refused noise.
	// We probe the health endpoint without logging on transient failure.
	healthURL := coreClient.BaseURL() + "/health"
	httpClient := &http.Client{Timeout: 2 * time.Second}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	for {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, healthURL, nil)
		if err == nil {
			resp, err := httpClient.Do(req)
			if err == nil {
				_ = resp.Body.Close()
				if resp.StatusCode >= 200 && resp.StatusCode < 300 {
					break
				}
			}
		}

		select {
		case <-ctx.Done():
			// Timeout reached; proceed to initialize handler anyway
			break
		case <-time.After(250 * time.Millisecond):
		}

		if ctx.Err() != nil {
			break
		}
	}

	handler := logging.NewCoreHandler(coreClient, "jma_adapter")
	slog.SetDefault(slog.New(handler).With("source", "jma"))
	slog.Info("The JMA Adapter Logger initialized")
}
