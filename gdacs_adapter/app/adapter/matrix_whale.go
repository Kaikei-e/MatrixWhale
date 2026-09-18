package adapter

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"strconv"
	"time"

	"matrixwhale/adapters/common/core"
)

const maxResponseBodySize = 1 << 20

type MatrixWhaleAdapter struct {
	client *core.Client
	http   *http.Client
}

func NewMatrixWhaleAdapter(client *core.Client) *MatrixWhaleAdapter {
	return &MatrixWhaleAdapter{client: client, http: &http.Client{Timeout: 30 * time.Second}}
}

func (a *MatrixWhaleAdapter) SendEvents(ctx context.Context, meta core.PollMeta, features []json.RawMessage) error {
	ack, err := a.client.Send(ctx, "gdacs_data/send", meta, features)
	if err != nil {
		return err
	}
	if err := core.ValidateAck(ack, len(features)); err != nil {
		return err
	}
	slog.Info("Matrix Whale accepted GDACS event data", "feature_count", len(features), "backfill", meta.Backfill)
	return nil
}

type GeometryPendingEntry struct {
	EventType string `json:"eventtype"`
	EventID   int64  `json:"eventid"`
	EpisodeID int64  `json:"episodeid"`
}

type GeometryResult struct {
	EventType  string          `json:"eventtype"`
	EventID    int64           `json:"eventid"`
	EpisodeID  int64           `json:"episodeid"`
	HTTPStatus int             `json:"http_status"`
	Geometry   json.RawMessage `json:"geometry"`
}

func (a *MatrixWhaleAdapter) PendingGeometry(ctx context.Context, limit int) ([]GeometryPendingEntry, error) {
	target := a.client.BaseURL() + "/gdacs_data/geometry/pending?limit=" + strconv.Itoa(limit)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, target, nil)
	if err != nil {
		return nil, fmt.Errorf("build pending-geometry request: %w", err)
	}
	req.Header.Set("Accept", "application/json")

	res, err := a.http.Do(req)
	if err != nil {
		return nil, fmt.Errorf("fetch pending geometry from Matrix Whale: %w", err)
	}
	defer res.Body.Close()

	body, err := readLimited(res.Body, maxResponseBodySize)
	if err != nil {
		return nil, fmt.Errorf("read pending-geometry response: %w", err)
	}
	if res.StatusCode < http.StatusOK || res.StatusCode >= http.StatusMultipleChoices {
		return nil, fmt.Errorf("pending-geometry request failed with status %d", res.StatusCode)
	}

	var parsed struct {
		Episodes []GeometryPendingEntry `json:"episodes"`
	}
	if err := json.Unmarshal(body, &parsed); err != nil {
		return nil, fmt.Errorf("invalid pending-geometry response: %w", err)
	}
	return parsed.Episodes, nil
}

func (a *MatrixWhaleAdapter) SendGeometry(ctx context.Context, meta core.PollMeta, entries []GeometryResult) error {
	features := make([]json.RawMessage, len(entries))
	for i, entry := range entries {
		raw, err := json.Marshal(entry)
		if err != nil {
			return fmt.Errorf("marshal GDACS geometry entry: %w", err)
		}
		features[i] = raw
	}

	ack, err := a.client.Send(ctx, "gdacs_data/geometry", meta, features)
	if err != nil {
		return err
	}
	if err := core.ValidateAck(ack, len(entries)); err != nil {
		return err
	}
	slog.Info("Matrix Whale accepted GDACS geometry", "count", len(entries))
	return nil
}
