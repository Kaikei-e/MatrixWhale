package adapter

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"time"
)

const MatrixWhaleURL = "http://matrix_whale:6000/api/v1"

type PollMeta struct {
	FetchedAt    string `json:"fetched_at"`
	HTTPStatus   int    `json:"http_status"`
	FeatureCount int    `json:"feature_count"`
}

type featureEnvelope struct {
	Features []json.RawMessage `json:"features"`
}

type outboundEnvelope struct {
	PollMeta PollMeta          `json:"poll_meta"`
	Features []json.RawMessage `json:"features"`
}

func MatrixWhaleAdapter(result PollResult) error {
	var parsed featureEnvelope
	if err := json.Unmarshal(result.Body, &parsed); err != nil {
		slog.Error("Error parsing NOAA response features", "error", err)
		return err
	}

	envelope := outboundEnvelope{
		PollMeta: PollMeta{
			FetchedAt:    result.FetchedAt.UTC().Format(time.RFC3339),
			HTTPStatus:   result.HTTPStatus,
			FeatureCount: len(parsed.Features),
		},
		Features: parsed.Features,
	}

	payload, err := json.Marshal(envelope)
	if err != nil {
		slog.Error("Error marshalling envelope", "error", err)
		return err
	}

	targetAPIEndpoint, err := url.JoinPath(MatrixWhaleURL, "noaa_data", "send")
	if err != nil {
		slog.Error("Error joining URL path", "error", err)
		return err
	}

	req, err := http.NewRequest("POST", targetAPIEndpoint, bytes.NewBuffer(payload))
	if err != nil {
		slog.Error("Error creating request", "error", err)
		return err
	}
	req.Header.Set("Content-Type", "application/json")

	slog.Info("Sending data to Matrix Whale", "bytes", len(payload), "feature_count", envelope.PollMeta.FeatureCount)

	client := &http.Client{Timeout: 60 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		slog.Error("Error sending request to Matrix Whale", "error", err)
		return err
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		slog.Error("Error reading response body", "error", err)
		return err
	}

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		snippet := body
		if len(snippet) > 200 {
			snippet = snippet[:200]
		}
		slog.Error("Matrix Whale returned non-2xx status", "status", resp.StatusCode, "body", string(snippet))
		return fmt.Errorf("matrix whale request failed with status %d", resp.StatusCode)
	}

	slog.Info("Matrix Whale response status is " + resp.Status)

	return nil
}
