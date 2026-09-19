package metrics

import (
	"errors"
	"log/slog"
	"net/http"
	"os"
	"strconv"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

var (
	httpRequestsTotal = promauto.NewCounterVec(
		prometheus.CounterOpts{
			Name: "matrixwhale_adapter_http_requests_total",
			Help: "Total HTTP requests made by the adapter.",
		},
		[]string{"peer", "code"},
	)

	httpRequestDuration = promauto.NewHistogramVec(
		prometheus.HistogramOpts{
			Name:    "matrixwhale_adapter_http_request_duration_seconds",
			Help:    "HTTP request duration in seconds.",
			Buckets: prometheus.DefBuckets,
		},
		[]string{"peer"},
	)

	lastSuccessTimestamp = promauto.NewGaugeVec(
		prometheus.GaugeOpts{
			Name: "matrixwhale_adapter_last_success_timestamp_seconds",
			Help: "Unix timestamp in seconds of the last successful request or message.",
		},
		[]string{"peer"},
	)

	wsConnected = promauto.NewGauge(
		prometheus.GaugeOpts{
			Name: "matrixwhale_adapter_websocket_connected",
			Help: "WebSocket connection status (1 while subscribed, 0 otherwise).",
		},
	)

	wsMessagesTotal = promauto.NewCounter(
		prometheus.CounterOpts{
			Name: "matrixwhale_adapter_websocket_messages_total",
			Help: "Total WebSocket messages received by the adapter.",
		},
	)
)

type transport struct {
	peer string
	next http.RoundTripper
}

// Transport wraps next (or http.DefaultTransport if nil) with Prometheus metrics
// for the given peer ("upstream" or "core").
func Transport(peer string, next http.RoundTripper) http.RoundTripper {
	if next == nil {
		next = http.DefaultTransport
	}
	return &transport{
		peer: peer,
		next: next,
	}
}

func (t *transport) RoundTrip(req *http.Request) (*http.Response, error) {
	start := time.Now()
	resp, err := t.next.RoundTrip(req)
	duration := time.Since(start).Seconds()
	httpRequestDuration.WithLabelValues(t.peer).Observe(duration)

	if err != nil {
		httpRequestsTotal.WithLabelValues(t.peer, "error").Inc()
		return resp, err
	}

	code := strconv.Itoa(resp.StatusCode)
	httpRequestsTotal.WithLabelValues(t.peer, code).Inc()

	if (resp.StatusCode >= 200 && resp.StatusCode < 300) || resp.StatusCode == http.StatusNotModified {
		lastSuccessTimestamp.WithLabelValues(t.peer).SetToCurrentTime()
	}

	return resp, nil
}

// SetWebsocketConnected sets the websocket_connected gauge (1 while subscribed, 0 otherwise).
func SetWebsocketConnected(connected bool) {
	if connected {
		wsConnected.Set(1)
	} else {
		wsConnected.Set(0)
	}
}

// RecordWebsocketMessage increments the websocket_messages_total counter and updates
// last_success_timestamp_seconds for the "upstream" peer.
func RecordWebsocketMessage() {
	wsMessagesTotal.Inc()
	lastSuccessTimestamp.WithLabelValues("upstream").SetToCurrentTime()
}

// Serve starts, in a goroutine, an HTTP server on env METRICS_ADDR (default :2112)
// serving /metrics with promhttp.Handler(). It logs via slog and does not crash
// the adapter if listening fails.
func Serve() {
	addr := os.Getenv("METRICS_ADDR")
	if addr == "" {
		addr = ":2112"
	}

	mux := http.NewServeMux()
	mux.Handle("/metrics", promhttp.Handler())

	server := &http.Server{
		Addr:    addr,
		Handler: mux,
	}

	go func() {
		slog.Info("starting metrics server", "addr", addr)
		if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			slog.Error("metrics server failed", "addr", addr, "error", err)
		}
	}()
}
