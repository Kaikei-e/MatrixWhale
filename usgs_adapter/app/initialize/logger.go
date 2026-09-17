package initialize

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"strings"
	"time"
)

type LogSender struct {
	url    string
	attrs  []slog.Attr
	client *http.Client
}

func (h *LogSender) Enabled(context.Context, slog.Level) bool { return true }

func (h *LogSender) Handle(ctx context.Context, record slog.Record) error {
	entry := map[string]any{"time": record.Time, "level": record.Level.String(), "msg": record.Message}
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
		_, _ = fmt.Fprintln(os.Stderr, "usgs_adapter log delivery failed:", err)
		return err
	}
	defer resp.Body.Close()
	return nil
}

func (h *LogSender) WithAttrs(attrs []slog.Attr) slog.Handler {
	all := append(append([]slog.Attr{}, h.attrs...), attrs...)
	return &LogSender{url: h.url, attrs: all, client: h.client}
}

func (h *LogSender) WithGroup(_ string) slog.Handler { return h }

func InitLogger() {
	base := strings.TrimRight(os.Getenv("MATRIX_WHALE_URL"), "/")
	if base == "" {
		base = "http://matrix_whale:6000/api/v1"
	}
	handler := &LogSender{
		url:    base + "/logs",
		client: &http.Client{Timeout: 5 * time.Second},
	}
	slog.SetDefault(slog.New(handler).With("service", "usgs_adapter", "source", "usgs"))
	slog.Info("The USGS Adapter Logger initialized")
}
