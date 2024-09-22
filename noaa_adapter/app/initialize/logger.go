package initialize

import (
	"bytes"
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
)

type LogSender struct {
	url string
}

func (h *LogSender) Enabled(ctx context.Context, level slog.Level) bool {
	return true
}

func (h *LogSender) Handle(ctx context.Context, record slog.Record) error {
	logData, err := json.Marshal(record)
	if err != nil {
		return err
	}

	req, err := http.NewRequestWithContext(ctx, "POST", h.url, bytes.NewBuffer(logData))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Content-Encoding", "gzip")

	client := &http.Client{}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	return nil
}

func (h *LogSender) WithAttrs(attrs []slog.Attr) slog.Handler {
	return h
}

func (h *LogSender) WithGroup(name string) slog.Handler {
	return h
}

func InitLogger() {
	handler := &LogSender{url: "http://localhost:6000/logs"}

	slog.SetDefault(slog.New(handler).With("service", "noaa_adapter"))
	slog.Info("The Logger initialized")
}
