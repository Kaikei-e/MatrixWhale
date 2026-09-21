package client

import (
	"context"
	"encoding/json"
	"fmt"
	"math"
	"net/http"
	"strconv"
	"strings"
	"time"

	"matrixwhale/adapters/common/core"
	"matrixwhale/adapters/common/metrics"
)

// Float64 formats floats to always include a decimal point (e.g. 10.0 instead of 10),
// ensuring strict compatibility with Gleam/BEAM decode.float.
type Float64 float64

func (f Float64) MarshalJSON() ([]byte, error) {
	v := float64(f)
	if math.IsNaN(v) || math.IsInf(v, 0) {
		return []byte("null"), nil
	}
	s := strconv.FormatFloat(v, 'f', -1, 64)
	if !strings.Contains(s, ".") {
		s += ".0"
	}
	return []byte(s), nil
}

// Data transfer structures matching MatrixWhale Core (jma.gleam)

type JmaIndexItem struct {
	ItemURL   string  `json:"item_url"`
	FeedURL   string  `json:"feed_url"`
	GUID      *string `json:"guid,omitempty"`
	Title     *string `json:"title,omitempty"`
	Published *string `json:"published,omitempty"`
}

type PendingItem struct {
	ItemURL string `json:"item_url"`
	FeedURL string `json:"feed_url"`
}

type pendingResponse struct {
	Items []PendingItem `json:"items"`
}

type JmaArea struct {
	AreaName string `json:"area_name"`
	Geocode  string `json:"geocode"`
}

type JmaAlertItem struct {
	LifecycleKey string  `json:"lifecycle_key"`
	AreaName     string  `json:"area_name"`
	Geocode      string  `json:"geocode"`
	Event        string  `json:"event"`
	Category     *string `json:"category,omitempty"`
	Status       string  `json:"status"`
	Severity     string  `json:"severity"`
	Urgency      string  `json:"urgency"`
	Certainty    string  `json:"certainty"`
}

type JmaEarthquake struct {
	OriginTime    string   `json:"origin_time"`
	Latitude      *Float64 `json:"latitude,omitempty"`
	Longitude     *Float64 `json:"longitude,omitempty"`
	DepthKM       *Float64 `json:"depth_km,omitempty"`
	Magnitude     *Float64 `json:"magnitude,omitempty"`
	MagnitudeType *string  `json:"magnitude_type,omitempty"`
	Place         *string  `json:"place,omitempty"`
	MaxIntensity  *string  `json:"max_intensity,omitempty"`
}

type JmaMessageContent struct {
	Identifier   string         `json:"identifier"`
	ControlTitle string         `json:"control_title"`
	Status       string         `json:"status"`
	InfoType     string         `json:"info_type"`
	EventID      *string        `json:"event_id,omitempty"`
	SeriesKey    *string        `json:"series_key,omitempty"`
	Sent         string         `json:"sent"`
	Effective    *string        `json:"effective,omitempty"`
	Expires      *string        `json:"expires,omitempty"`
	Headline     *string        `json:"headline,omitempty"`
	Description  *string        `json:"description,omitempty"`
	Areas        []JmaArea      `json:"areas"`
	Alerts       []JmaAlertItem `json:"alerts"`
	ClearedAreas []string       `json:"cleared_areas,omitempty"`
	Earthquake   *JmaEarthquake `json:"earthquake,omitempty"`
}

type JmaFetchResult struct {
	ItemURL    string             `json:"item_url"`
	FeedURL    string             `json:"feed_url"`
	FetchedAt  string             `json:"fetched_at"`
	HTTPStatus int                `json:"http_status"`
	Error      *string            `json:"error,omitempty"`
	RawXML     *string            `json:"raw_xml,omitempty"`
	Message    *JmaMessageContent `json:"message,omitempty"`
}

// CoreClient wraps interaction with the MatrixWhale backend.
type CoreClient struct {
	coreClient *core.Client
	httpClient *http.Client
}

// NewCoreClient builds a client for communicating with MatrixWhale Core.
func NewCoreClient(coreClient *core.Client, httpClient *http.Client) *CoreClient {
	if httpClient == nil {
		httpClient = &http.Client{
			Timeout:   30 * time.Second,
			Transport: metrics.Transport("core", nil),
		}
	}
	return &CoreClient{
		coreClient: coreClient,
		httpClient: httpClient,
	}
}

// SendIndex posts discovered feed entries to /api/v1/jma_data/index for deduplication.
func (c *CoreClient) SendIndex(ctx context.Context, meta core.PollMeta, items []JmaIndexItem) (core.Ack, error) {
	rawFeatures := make([]json.RawMessage, 0, len(items))
	for _, item := range items {
		b, err := json.Marshal(item)
		if err != nil {
			return core.Ack{}, fmt.Errorf("marshal index item: %w", err)
		}
		rawFeatures = append(rawFeatures, b)
	}

	ack, err := c.coreClient.Send(ctx, "jma_data/index", meta, rawFeatures)
	if err != nil {
		return ack, err
	}
	if err := core.ValidateAck(ack, len(items)); err != nil {
		return ack, err
	}
	return ack, nil
}

// GetPending fetches up to limit pending item URLs awaiting download.
func (c *CoreClient) GetPending(ctx context.Context, limit int) ([]PendingItem, error) {
	if limit <= 0 {
		limit = 50
	}
	target := c.coreClient.BaseURL() + "/jma_data/pending?limit=" + strconv.Itoa(limit)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, target, nil)
	if err != nil {
		return nil, fmt.Errorf("create pending request: %w", err)
	}
	req.Header.Set("Accept", "application/json")

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("get pending items: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("get pending returned status %d", resp.StatusCode)
	}

	var res pendingResponse
	if err := json.NewDecoder(resp.Body).Decode(&res); err != nil {
		return nil, fmt.Errorf("decode pending response: %w", err)
	}

	return res.Items, nil
}

// SendMessages posts parsed telegrams and raw XML to /api/v1/jma_data/messages, verifying ack.
func (c *CoreClient) SendMessages(ctx context.Context, meta core.PollMeta, results []JmaFetchResult) (core.Ack, error) {
	rawFeatures := make([]json.RawMessage, 0, len(results))
	for _, res := range results {
		b, err := json.Marshal(res)
		if err != nil {
			return core.Ack{}, fmt.Errorf("marshal fetch result: %w", err)
		}
		rawFeatures = append(rawFeatures, b)
	}

	ack, err := c.coreClient.Send(ctx, "jma_data/messages", meta, rawFeatures)
	if err != nil {
		return ack, err
	}

	if err := core.ValidateAck(ack, len(results)); err != nil {
		return ack, err
	}

	if ack.Dropped != nil && *ack.Dropped > 0 {
		hasValidTelegram := false
		for _, res := range results {
			if res.Error == nil && res.HTTPStatus == 200 {
				hasValidTelegram = true
				break
			}
		}
		if hasValidTelegram {
			return ack, fmt.Errorf("core dropped %d features: %s", *ack.Dropped, *ack.Message)
		}
	}

	return ack, nil
}
