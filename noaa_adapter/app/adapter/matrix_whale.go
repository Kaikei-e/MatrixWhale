package adapter

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"time"

	"matrixwhale/adapters/common/core"
)

type featureEnvelope struct {
	Features []json.RawMessage `json:"features"`
}

// MatrixWhaleAdapter forwards a poll result to the Matrix Whale core. A 304
// has no body to decode; forward an empty feature list so the pipeline
// still records the poll (advancing "last fetch" and running the expiry
// sweep) without touching the missing-alert sweep, which is gated on
// http_status == 200.
func MatrixWhaleAdapter(result PollResult) error {
	features := []json.RawMessage{}
	if result.HTTPStatus != http.StatusNotModified {
		var parsed featureEnvelope
		if err := json.Unmarshal(result.Body, &parsed); err != nil {
			slog.Error("Error parsing NOAA response features", "error", err)
			return err
		}
		features = parsed.Features
	}

	meta := core.PollMeta{
		FetchedAt:    result.FetchedAt.UTC().Format(time.RFC3339),
		HTTPStatus:   result.HTTPStatus,
		FeatureCount: len(features),
		Bytes:        result.Bytes,
	}

	slog.Info("Sending data to Matrix Whale", "feature_count", len(features))

	client := core.NewClientFromEnv()
	ack, err := client.Send(context.Background(), "noaa_data/send", meta, features)
	if err != nil {
		slog.Error("Error sending data to Matrix Whale", "error", err)
		return err
	}
	if err := core.ValidateAck(ack, len(features)); err != nil {
		slog.Error("Matrix Whale ack validation failed", "error", err)
		return err
	}

	slog.Info("Matrix Whale accepted NOAA data", "feature_count", len(features))
	return nil
}
