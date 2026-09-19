// Package adapter fetches EMSC earthquake data (FDSN backfill queries and
// the real-time WebSocket feed) and forwards it to the Matrix Whale core.
package adapter

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"strconv"
	"time"

	"github.com/coder/websocket"

	"matrixwhale/adapters/common/metrics"
	"matrixwhale/adapters/common/useragent"
)

var defaultHTTPClient = &http.Client{
	Timeout:   60 * time.Second,
	Transport: metrics.Transport("upstream", nil),
}

const (
	DefaultWebSocketURL = "wss://www.seismicportal.eu/standing_order/websocket"
	DefaultFDSNURL      = "https://www.seismicportal.eu/fdsnws/event/1/query"
	DefaultBackfillDays = 7

	pingInterval    = 15 * time.Second
	maxFDSNBodySize = 64 << 20
)

// FDSNQuery describes one request to the EMSC FDSN event webservice.
type FDSNQuery struct {
	Start        time.Time
	End          time.Time
	OrderBy      string
	Limit        int
	Offset       int
	UpdatedAfter string
}

// FetchResult is one FDSN response: bare GeoJSON Feature objects, not yet
// wrapped in the {action, data} envelope the core expects.
type FetchResult struct {
	Features   []json.RawMessage
	FetchedAt  time.Time
	HTTPStatus int
	Bytes      int
	URL        string
}

// LiveMessage is one decoded WebSocket message, kept as the raw bytes
// received (already in the core's {action, data} envelope shape) alongside
// the feature's lastupdate timestamp for gap-fill bookkeeping.
type LiveMessage struct {
	Raw        json.RawMessage
	LastUpdate string
}

type wsEnvelope struct {
	Action string          `json:"action"`
	Data   json.RawMessage `json:"data"`
}

type featureProperties struct {
	Properties struct {
		LastUpdate string `json:"lastupdate"`
	} `json:"properties"`
}

// BuildFDSNURL builds an FDSN event webservice query URL from q.
func BuildFDSNURL(base string, q FDSNQuery) (string, error) {
	u, err := url.Parse(base)
	if err != nil {
		return "", fmt.Errorf("parse EMSC FDSN URL: %w", err)
	}
	values := u.Query()
	values.Set("format", "json")
	values.Set("starttime", q.Start.UTC().Format(time.RFC3339))
	values.Set("endtime", q.End.UTC().Format(time.RFC3339))
	if q.OrderBy != "" {
		values.Set("orderby", q.OrderBy)
	}
	if q.Limit > 0 {
		values.Set("limit", strconv.Itoa(q.Limit))
	}
	values.Set("offset", strconv.Itoa(q.Offset))
	if q.UpdatedAfter != "" {
		values.Set("updatedafter", q.UpdatedAfter)
	}
	u.RawQuery = values.Encode()
	return u.String(), nil
}

// FetchBackfillPage runs one FDSN event query and returns its bare Feature
// objects. A 204 or 404 (the documented "no data" responses) is not an
// error; it yields a FetchResult with no features.
func FetchBackfillPage(ctx context.Context, fdsnURL string, q FDSNQuery) (FetchResult, error) {
	target, err := BuildFDSNURL(fdsnURL, q)
	if err != nil {
		return FetchResult{}, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, target, nil)
	if err != nil {
		return FetchResult{}, err
	}
	req.Header.Set("User-Agent", userAgent())
	req.Header.Set("Accept", "application/json")

	res, err := defaultHTTPClient.Do(req)
	if err != nil {
		return FetchResult{}, err
	}
	defer res.Body.Close()

	body, readErr := readLimited(res.Body, maxFDSNBodySize)
	result := FetchResult{
		FetchedAt:  time.Now().UTC(),
		HTTPStatus: res.StatusCode,
		Bytes:      len(body),
		URL:        target,
	}
	if readErr != nil {
		return result, readErr
	}
	if res.StatusCode == http.StatusNoContent || res.StatusCode == http.StatusNotFound {
		result.Features = []json.RawMessage{}
		return result, nil
	}
	if res.StatusCode < http.StatusOK || res.StatusCode >= http.StatusMultipleChoices {
		return result, fmt.Errorf("EMSC FDSN request failed with status %d", res.StatusCode)
	}

	var collection struct {
		Features []json.RawMessage `json:"features"`
	}
	if err := json.Unmarshal(body, &collection); err != nil {
		return result, fmt.Errorf("invalid EMSC FDSN response: %w", err)
	}
	result.Features = collection.Features
	if result.Features == nil {
		result.Features = []json.RawMessage{}
	}
	slog.Info("EMSC FDSN response", "status", res.StatusCode, "bytes", len(body), "features", len(result.Features), "offset", q.Offset)
	return result, nil
}

// Subscribe dials the EMSC WebSocket feed, pings it every 15s, and forwards
// decoded messages to out until ctx is done or the connection fails. It
// always closes out before returning, mirroring the channel-ownership
// convention expected by Batcher.Run.
func Subscribe(ctx context.Context, wsURL string, out chan<- LiveMessage) error {
	defer close(out)

	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		return fmt.Errorf("dial EMSC websocket: %w", err)
	}
	defer conn.CloseNow()

	metrics.SetWebsocketConnected(true)
	defer metrics.SetWebsocketConnected(false)

	pingCtx, stopPing := context.WithCancel(ctx)
	defer stopPing()
	go pingLoop(pingCtx, conn)

	for {
		_, data, err := conn.Read(ctx)
		if err != nil {
			if ctx.Err() != nil {
				return ctx.Err()
			}
			return fmt.Errorf("read EMSC websocket: %w", err)
		}
		metrics.RecordWebsocketMessage()
		message, parseErr := parseLiveMessage(data)
		if parseErr != nil {
			slog.Warn("dropping unparseable EMSC message", "error", parseErr)
			continue
		}
		select {
		case out <- message:
		case <-ctx.Done():
			return ctx.Err()
		}
	}
}

// pingLoop sends the client-initiated pings EMSC expects; the server never
// pings first, so a failed ping is our only signal a dead connection needs
// closing to unblock the Read loop.
func pingLoop(ctx context.Context, conn *websocket.Conn) {
	ticker := time.NewTicker(pingInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			pingCtx, cancel := context.WithTimeout(ctx, pingInterval)
			err := conn.Ping(pingCtx)
			cancel()
			if err != nil {
				conn.CloseNow()
				return
			}
		}
	}
}

func parseLiveMessage(raw []byte) (LiveMessage, error) {
	var envelope wsEnvelope
	if err := json.Unmarshal(raw, &envelope); err != nil {
		return LiveMessage{}, err
	}
	if envelope.Action == "" || len(envelope.Data) == 0 {
		return LiveMessage{}, fmt.Errorf("EMSC message missing action or data")
	}
	var meta featureProperties
	_ = json.Unmarshal(envelope.Data, &meta)
	return LiveMessage{Raw: json.RawMessage(raw), LastUpdate: meta.Properties.LastUpdate}, nil
}

// MaxLastUpdateOfFeatures returns the lexicographically greatest
// properties.lastupdate among bare FDSN features (RFC3339 timestamps sort
// lexicographically), or "" if none parse.
func MaxLastUpdateOfFeatures(features []json.RawMessage) string {
	max := ""
	for _, raw := range features {
		var meta featureProperties
		if err := json.Unmarshal(raw, &meta); err != nil {
			continue
		}
		if meta.Properties.LastUpdate > max {
			max = meta.Properties.LastUpdate
		}
	}
	return max
}

// MaxLastUpdateOfMessages returns the greatest LastUpdate among messages.
func MaxLastUpdateOfMessages(messages []LiveMessage) string {
	max := ""
	for _, m := range messages {
		if m.LastUpdate > max {
			max = m.LastUpdate
		}
	}
	return max
}

func userAgent() string {
	return useragent.Build("MatrixWhale/1.0", "EMSC_CONTACT_EMAIL", "", nil)
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
