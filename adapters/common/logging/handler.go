// Package logging provides an slog.Handler that ships log records to the
// Matrix Whale core's log ingest endpoint instead of (or in addition to)
// local output.
package logging

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"time"

	"matrixwhale/adapters/common/core"
)

type coreHandler struct {
	url    string
	attrs  []slog.Attr
	client *http.Client
}

// NewCoreHandler returns a slog.Handler that POSTs each record to
// {client.BaseURL()}/logs as {time, level, msg, service, ...attrs}.
func NewCoreHandler(client *core.Client, service string) slog.Handler {
	return &coreHandler{
		url:    client.BaseURL() + "/logs",
		client: &http.Client{Timeout: 5 * time.Second},
		attrs:  []slog.Attr{slog.String("service", service)},
	}
}

func (h *coreHandler) Enabled(context.Context, slog.Level) bool { return true }

func (h *coreHandler) Handle(ctx context.Context, record slog.Record) error {
	entry := map[string]any{
		"time":  record.Time,
		"level": record.Level.String(),
		"msg":   record.Message,
	}
	for _, attr := range h.attrs {
		entry[attr.Key] = attr.Value.Any()
	}
	record.Attrs(func(attr slog.Attr) bool {
		entry[attr.Key] = attr.Value.Any()
		return true
	})

	payload, err := json.Marshal(entry)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, h.url, bytes.NewReader(payload))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := h.client.Do(req)
	if err != nil {
		_, _ = fmt.Fprintln(os.Stderr, "log delivery to Matrix Whale failed:", err)
		return err
	}
	defer resp.Body.Close()
	return nil
}

func (h *coreHandler) WithAttrs(attrs []slog.Attr) slog.Handler {
	all := append(append([]slog.Attr{}, h.attrs...), attrs...)
	return &coreHandler{url: h.url, attrs: all, client: h.client}
}

func (h *coreHandler) WithGroup(_ string) slog.Handler { return h }
