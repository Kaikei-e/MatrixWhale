package adapter

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"math"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"
)

const defaultMatrixWhaleURL = "http://matrix_whale:6000/api/v1"

type PollMeta struct {
	FetchedAt    string `json:"fetched_at"`
	HTTPStatus   int    `json:"http_status"`
	FeatureCount int    `json:"feature_count"`
	Bytes        int    `json:"bytes"`
	FeedURL      string `json:"feed_url"`
	Backfill     bool   `json:"backfill"`
}

type outboundEnvelope struct {
	PollMeta PollMeta          `json:"poll_meta"`
	Features []json.RawMessage `json:"features"`
}

type matrixWhaleResponse struct {
	Received *int    `json:"received"`
	Deduped  *int    `json:"deduped"`
	Written  *int    `json:"written"`
	Dropped  *int    `json:"dropped"`
	Message  *string `json:"message"`
}

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

	payload, err := json.Marshal(outboundEnvelope{
		PollMeta: PollMeta{
			FetchedAt:    result.FetchedAt.UTC().Format(time.RFC3339),
			HTTPStatus:   result.HTTPStatus,
			FeatureCount: len(features),
			Bytes:        result.Bytes,
			FeedURL:      result.FeedURL,
			Backfill:     result.Backfill,
		},
		Features: features,
	})
	if err != nil {
		return fmt.Errorf("marshal USGS envelope: %w", err)
	}

	baseURL := strings.TrimRight(os.Getenv("MATRIX_WHALE_URL"), "/")
	if baseURL == "" {
		baseURL = defaultMatrixWhaleURL
	}
	target, err := url.JoinPath(baseURL, "usgs_data", "send")
	if err != nil {
		return fmt.Errorf("build Matrix Whale endpoint: %w", err)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, target, bytes.NewReader(payload))
	if err != nil {
		return fmt.Errorf("create Matrix Whale request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := (&http.Client{Timeout: 60 * time.Second}).Do(req)
	if err != nil {
		return fmt.Errorf("send USGS data to Matrix Whale: %w", err)
	}
	defer resp.Body.Close()
	body, err := readLimited(resp.Body, maxResponseBodySize)
	if err != nil {
		return fmt.Errorf("read Matrix Whale response: %w", err)
	}
	if resp.StatusCode < http.StatusOK || resp.StatusCode >= http.StatusMultipleChoices {
		return fmt.Errorf("Matrix Whale request failed with status %d: %s", resp.StatusCode, responseSnippet(body))
	}
	if err := validateMatrixWhaleResponse(body, len(features)); err != nil {
		return err
	}
	slog.Info("Matrix Whale accepted USGS data", "status", resp.Status, "feature_count", len(features))
	return nil
}

func validateMatrixWhaleResponse(body []byte, sentFeatures int) error {
	trimmed := bytes.TrimSpace(body)
	if len(trimmed) == 0 || trimmed[0] != '{' {
		return fmt.Errorf("Matrix Whale response is not a JSON object")
	}
	var response matrixWhaleResponse
	if err := json.Unmarshal(trimmed, &response); err != nil {
		return fmt.Errorf("invalid Matrix Whale response JSON: %w", err)
	}
	if response.Received == nil || response.Deduped == nil || response.Written == nil || response.Dropped == nil || response.Message == nil {
		return fmt.Errorf("Matrix Whale response is missing a required field")
	}
	counts := []*int{response.Received, response.Deduped, response.Written, response.Dropped}
	for _, count := range counts {
		if *count < 0 {
			return fmt.Errorf("Matrix Whale response contains a negative count")
		}
		if *count > sentFeatures {
			return fmt.Errorf("Matrix Whale response count %d exceeds sent feature count %d", *count, sentFeatures)
		}
	}
	if *response.Received != sentFeatures {
		return fmt.Errorf("Matrix Whale received count %d does not match sent feature count %d", *response.Received, sentFeatures)
	}
	if int64(*response.Deduped)+int64(*response.Written)+int64(*response.Dropped) != int64(*response.Received) {
		return fmt.Errorf("Matrix Whale response counts do not sum to received")
	}
	return nil
}

func responseSnippet(body []byte) string {
	if len(body) > 200 {
		body = body[:200]
	}
	return string(body)
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
