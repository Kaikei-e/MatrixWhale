package adapter

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"math"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"matrixwhale/adapters/common/core"
)

type featureMagnitude struct {
	Properties struct {
		Mag *float64 `json:"mag"`
	} `json:"properties"`
}

func MatrixWhaleAdapter(ctx context.Context, result PollResult) error {
	features := []json.RawMessage{}
	if result.HTTPStatus != http.StatusNotModified {
		var parsed struct {
			Features []json.RawMessage `json:"features"`
		}
		if err := json.Unmarshal(result.Body, &parsed); err != nil {
			return fmt.Errorf("parse USGS response features: %w", err)
		}
		features = filterFeatures(parsed.Features, configuredMinMagnitude())
	}

	meta := core.PollMeta{
		FetchedAt:    result.FetchedAt.UTC().Format(time.RFC3339),
		HTTPStatus:   result.HTTPStatus,
		FeatureCount: len(features),
		Bytes:        result.Bytes,
		FeedURL:      result.FeedURL,
		Backfill:     result.Backfill,
	}

	ack, err := core.NewClientFromEnv().Send(ctx, "usgs_data/send", meta, features)
	if err != nil {
		return err
	}
	if err := core.ValidateAck(ack, len(features)); err != nil {
		return err
	}
	slog.Info("Matrix Whale accepted USGS data", "feature_count", len(features))
	return nil
}

func configuredMinMagnitude() *float64 {
	value := strings.TrimSpace(os.Getenv("USGS_MIN_MAG"))
	if value == "" {
		return nil
	}
	minimum, err := strconv.ParseFloat(value, 64)
	if err != nil || math.IsNaN(minimum) || math.IsInf(minimum, 0) {
		slog.Warn("USGS_MIN_MAG is invalid; retaining all features", "value", value, "error", err)
		return nil
	}
	return &minimum
}

func filterFeatures(features []json.RawMessage, minimum *float64) []json.RawMessage {
	if minimum == nil {
		return features
	}
	filtered := make([]json.RawMessage, 0, len(features))
	for _, raw := range features {
		var feature featureMagnitude
		if err := json.Unmarshal(raw, &feature); err != nil {
			filtered = append(filtered, raw)
			continue
		}
		if feature.Properties.Mag != nil && *feature.Properties.Mag < *minimum {
			continue
		}
		filtered = append(filtered, raw)
	}
	return filtered
}
