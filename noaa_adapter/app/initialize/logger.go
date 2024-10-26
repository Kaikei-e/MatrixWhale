package initialize

import (
	"bytes"
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
)

type LogSender struct {
	url   string
	attrs []slog.Attr
	group string
}

func (h *LogSender) Enabled(ctx context.Context, level slog.Level) bool {
	return true
}

func (h *LogSender) Handle(ctx context.Context, record slog.Record) error {
	attrs := append([]slog.Attr{}, h.attrs...)
	record.Attrs(func(a slog.Attr) bool {
		attrs = append(attrs, a)
		return true
	})

	logEntry := map[string]interface{}{
		"time":  record.Time,
		"level": record.Level.String(),
		"msg":   record.Message,
	}

	for _, attr := range attrs {
		logEntry[attr.Key] = attr.Value.Any()
	}

	logData, err := json.Marshal(logEntry)
	if err != nil {
		return err
	}

	req, err := http.NewRequestWithContext(ctx, "POST", h.url, bytes.NewBuffer(logData))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")

	client := &http.Client{}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	return nil
}

func (h *LogSender) WithAttrs(attrs []slog.Attr) slog.Handler {
	newAttrs := append(h.attrs, attrs...)
	return &LogSender{
		url:   h.url,
		attrs: newAttrs,
		group: h.group,
	}
}

func (h *LogSender) WithGroup(name string) slog.Handler {
	return &LogSender{
		url:   h.url,
		attrs: h.attrs,
		group: name,
	}
}

func InitLogger() {
	handler := &LogSender{url: "http://matrix_whale:6000/api/v1/logs"}

	slog.SetDefault(slog.New(handler).With("service", "noaa_adapter"))
	slog.Info("The NOAA Adapter Logger initialized")
}
