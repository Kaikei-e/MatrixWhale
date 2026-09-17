package adapter

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"time"

	"matrixwhale/adapters/common/core"
)

// Batch is one unit of data ready to POST to the Matrix Whale core: either
// one FDSN backfill/gap-fill page or one live WebSocket batch.
type Batch struct {
	Features   []json.RawMessage
	FetchedAt  time.Time
	HTTPStatus int
	Bytes      int
	FeedURL    string
	Backfill   bool
}

type wrappedFeature struct {
	Action string          `json:"action"`
	Data   json.RawMessage `json:"data"`
}

// WrapCreate wraps a bare FDSN GeoJSON Feature in the {action, data}
// envelope the core expects, so backfill and live messages share one
// decoder on the core side.
func WrapCreate(feature json.RawMessage) (json.RawMessage, error) {
	wrapped, err := json.Marshal(wrappedFeature{Action: "create", Data: feature})
	if err != nil {
		return nil, fmt.Errorf("wrap EMSC feature: %w", err)
	}
	return wrapped, nil
}

// BackfillBatch turns one FDSN page into a Batch, wrapping every bare
// feature as a "create" action.
func BackfillBatch(result FetchResult) (Batch, error) {
	features := make([]json.RawMessage, len(result.Features))
	for i, feature := range result.Features {
		wrapped, err := WrapCreate(feature)
		if err != nil {
			return Batch{}, err
		}
		features[i] = wrapped
	}
	return Batch{
		Features:   features,
		FetchedAt:  result.FetchedAt,
		HTTPStatus: result.HTTPStatus,
		Bytes:      result.Bytes,
		FeedURL:    result.URL,
		Backfill:   true,
	}, nil
}

// LiveBatch turns a batch of WebSocket messages into a Batch. Messages are
// already in the core's envelope shape, so they are forwarded untouched.
func LiveBatch(messages []LiveMessage, wsURL string) Batch {
	features := make([]json.RawMessage, len(messages))
	bytes := 0
	for i, m := range messages {
		features[i] = m.Raw
		bytes += len(m.Raw)
	}
	return Batch{
		Features:   features,
		FetchedAt:  time.Now().UTC(),
		HTTPStatus: http.StatusOK,
		Bytes:      bytes,
		FeedURL:    wsURL,
		Backfill:   false,
	}
}

// MatrixWhaleAdapter POSTs batch to the core's EMSC ingest endpoint and
// validates the acknowledgement.
func MatrixWhaleAdapter(ctx context.Context, batch Batch) error {
	meta := core.PollMeta{
		FetchedAt:    batch.FetchedAt.UTC().Format(time.RFC3339),
		HTTPStatus:   batch.HTTPStatus,
		FeatureCount: len(batch.Features),
		Bytes:        batch.Bytes,
		FeedURL:      batch.FeedURL,
		Backfill:     batch.Backfill,
	}

	ack, err := core.NewClientFromEnv().Send(ctx, "emsc_data/send", meta, batch.Features)
	if err != nil {
		return err
	}
	if err := core.ValidateAck(ack, len(batch.Features)); err != nil {
		return err
	}
	slog.Info("Matrix Whale accepted EMSC data", "feature_count", len(batch.Features), "backfill", batch.Backfill)
	return nil
}
