package logging

import (
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"

	"matrixwhale/adapters/common/core"
)

func TestCoreHandlerPostsLogEntry(t *testing.T) {
	var received map[string]any
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/logs" {
			t.Errorf("path = %q", r.URL.Path)
		}
		if err := json.NewDecoder(r.Body).Decode(&received); err != nil {
			t.Errorf("decode request: %v", err)
		}
		w.WriteHeader(http.StatusOK)
	}))
	defer server.Close()

	client := core.NewClient(server.URL, http.DefaultClient)
	handler := NewCoreHandler(client, "usgs_adapter")
	logger := slog.New(handler).With("source", "usgs")
	logger.Info("hello", "count", 3)

	if received["msg"] != "hello" || received["level"] != "INFO" {
		t.Fatalf("msg/level = %+v", received)
	}
	if received["service"] != "usgs_adapter" || received["source"] != "usgs" {
		t.Fatalf("service/source = %+v", received)
	}
	if received["count"] != float64(3) {
		t.Fatalf("count = %+v", received["count"])
	}
	if _, ok := received["time"]; !ok {
		t.Fatalf("time missing: %+v", received)
	}
}
