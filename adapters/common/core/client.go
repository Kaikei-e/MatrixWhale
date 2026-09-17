// Package core is a client for the Matrix Whale (Gleam) core service: it
// posts an adapter's polled features and decodes the core's acknowledgement.
package core

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"
)

const (
	// DefaultBaseURL is used when MATRIX_WHALE_URL is unset, matching the
	// core service's address on the Docker Compose network.
	DefaultBaseURL      = "http://matrix_whale:6000/api/v1"
	maxResponseBodySize = 1 << 20
)

// Client posts adapter data to the Matrix Whale core.
type Client struct {
	baseURL string
	http    *http.Client
}

// NewClientFromEnv builds a Client from MATRIX_WHALE_URL, falling back to
// DefaultBaseURL when unset, with a shared *http.Client sized for the core's
// data-ingest endpoints.
func NewClientFromEnv() *Client {
	base := strings.TrimRight(os.Getenv("MATRIX_WHALE_URL"), "/")
	if base == "" {
		base = DefaultBaseURL
	}
	return NewClient(base, &http.Client{Timeout: 60 * time.Second})
}

// NewClient builds a Client against an explicit base URL and *http.Client.
func NewClient(baseURL string, httpClient *http.Client) *Client {
	return &Client{baseURL: strings.TrimRight(baseURL, "/"), http: httpClient}
}

// BaseURL returns the core's base URL, with no trailing slash.
func (c *Client) BaseURL() string { return c.baseURL }

// PollMeta describes one poll of a source feed, carried alongside the
// features it produced.
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

// Ack is the core's acknowledgement of a Send. Fields are pointers so a
// missing field is distinguishable from a zero value.
type Ack struct {
	Received *int    `json:"received"`
	Deduped  *int    `json:"deduped"`
	Written  *int    `json:"written"`
	Dropped  *int    `json:"dropped"`
	Message  *string `json:"message"`
}

// Send POSTs meta and features as a Matrix Whale envelope to
// {base}/{path} and decodes the response body into an Ack. A non-2xx
// status or a response that isn't a JSON object is an error.
func (c *Client) Send(ctx context.Context, path string, meta PollMeta, features []json.RawMessage) (Ack, error) {
	if features == nil {
		features = []json.RawMessage{}
	}
	payload, err := json.Marshal(outboundEnvelope{PollMeta: meta, Features: features})
	if err != nil {
		return Ack{}, fmt.Errorf("marshal Matrix Whale envelope: %w", err)
	}

	target, err := url.JoinPath(c.baseURL, path)
	if err != nil {
		return Ack{}, fmt.Errorf("build Matrix Whale endpoint: %w", err)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, target, bytes.NewReader(payload))
	if err != nil {
		return Ack{}, fmt.Errorf("create Matrix Whale request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := c.http.Do(req)
	if err != nil {
		return Ack{}, fmt.Errorf("send data to Matrix Whale: %w", err)
	}
	defer resp.Body.Close()

	body, err := readLimited(resp.Body, maxResponseBodySize)
	if err != nil {
		return Ack{}, fmt.Errorf("read Matrix Whale response: %w", err)
	}
	if resp.StatusCode < http.StatusOK || resp.StatusCode >= http.StatusMultipleChoices {
		return Ack{}, fmt.Errorf("Matrix Whale request failed with status %d: %s", resp.StatusCode, responseSnippet(body))
	}

	trimmed := bytes.TrimSpace(body)
	if len(trimmed) == 0 || trimmed[0] != '{' {
		return Ack{}, fmt.Errorf("Matrix Whale response is not a JSON object: %s", responseSnippet(body))
	}
	var ack Ack
	if err := json.Unmarshal(trimmed, &ack); err != nil {
		return Ack{}, fmt.Errorf("invalid Matrix Whale response JSON: %w", err)
	}
	return ack, nil
}

// ValidateAck checks the USGS ack invariant: received must equal sent, and
// deduped+written+dropped must sum to received. Adapters whose core
// endpoint doesn't yet answer this shape should not call ValidateAck.
func ValidateAck(ack Ack, sent int) error {
	if ack.Received == nil || ack.Deduped == nil || ack.Written == nil || ack.Dropped == nil || ack.Message == nil {
		return fmt.Errorf("Matrix Whale response is missing a required field")
	}
	counts := []*int{ack.Received, ack.Deduped, ack.Written, ack.Dropped}
	for _, count := range counts {
		if *count < 0 {
			return fmt.Errorf("Matrix Whale response contains a negative count")
		}
		if *count > sent {
			return fmt.Errorf("Matrix Whale response count %d exceeds sent feature count %d", *count, sent)
		}
	}
	if *ack.Received != sent {
		return fmt.Errorf("Matrix Whale received count %d does not match sent feature count %d", *ack.Received, sent)
	}
	if int64(*ack.Deduped)+int64(*ack.Written)+int64(*ack.Dropped) != int64(*ack.Received) {
		return fmt.Errorf("Matrix Whale response counts do not sum to received")
	}
	return nil
}

func readLimited(r io.Reader, limit int64) ([]byte, error) {
	body, err := io.ReadAll(io.LimitReader(r, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(body)) > limit {
		return nil, fmt.Errorf("response body exceeds %d bytes", limit)
	}
	return body, nil
}

func responseSnippet(body []byte) string {
	if len(body) > 200 {
		body = body[:200]
	}
	return string(body)
}
