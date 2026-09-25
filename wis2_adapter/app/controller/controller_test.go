package controller

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"matrixwhale/adapters/common/core"

	"github.com/prometheus/client_golang/prometheus/testutil"

	"wis2_adapter/broker"
	"wis2_adapter/config"
	wis2metrics "wis2_adapter/metrics"
	"wis2_adapter/wnm"
)

func TestControllerContractAndFlow(t *testing.T) {
	xmlData, err := os.ReadFile(filepath.Join("..", "testdata", "cache_eu-eumetnet-warnings.xml"))
	if err != nil {
		t.Fatalf("failed to read testdata xml: %v", err)
	}

	geometryGeoJSON := `{
		"type": "Feature",
		"geometry": {
			"type": "Polygon",
			"coordinates": [[[21.18, 36.72], [21.18, 38.33], [22.39, 38.33], [22.39, 36.72], [21.18, 36.72]]]
		}
	}`

	upstreamServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/warning.xml":
			w.Header().Set("Content-Type", "application/xml")
			_, _ = w.Write(xmlData)
		case "/feature.geojson":
			w.Header().Set("Content-Type", "application/geo+json")
			_, _ = w.Write([]byte(geometryGeoJSON))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer upstreamServer.Close()

	var capReceivedCount int32
	var capturedCAPFeature CAPFeature
	var featureMu sync.Mutex

	var healthReceivedCount int32
	var allHealthSnapshots []map[string]any
	var capturedHealthMeta core.PollMeta

	coreServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/api/v1/wis2_data/cap":
			var env struct {
				PollMeta core.PollMeta     `json:"poll_meta"`
				Features []json.RawMessage `json:"features"`
			}
			if err := json.NewDecoder(r.Body).Decode(&env); err != nil {
				t.Errorf("failed to decode cap envelope: %v", err)
				w.WriteHeader(http.StatusBadRequest)
				return
			}

			atomic.AddInt32(&capReceivedCount, int32(len(env.Features)))

			for _, rawFeat := range env.Features {
				var feat CAPFeature
				if err := json.Unmarshal(rawFeat, &feat); err != nil {
					t.Errorf("failed to decode CAPFeature: %v", err)
				}
				featureMu.Lock()
				capturedCAPFeature = feat
				featureMu.Unlock()
			}

			ack := fmt.Sprintf(`{"received":%d,"deduped":0,"written":%d,"dropped":0,"message":"ok"}`,
				len(env.Features), len(env.Features))
			_, _ = w.Write([]byte(ack))

		case "/api/v1/wis2_data/health":
			var env struct {
				PollMeta core.PollMeta     `json:"poll_meta"`
				Features []json.RawMessage `json:"features"`
			}
			if err := json.NewDecoder(r.Body).Decode(&env); err != nil {
				t.Errorf("failed to decode health envelope: %v", err)
				w.WriteHeader(http.StatusBadRequest)
				return
			}

			atomic.AddInt32(&healthReceivedCount, 1)

			featureMu.Lock()
			capturedHealthMeta = env.PollMeta
			for _, rf := range env.Features {
				var m map[string]any
				_ = json.Unmarshal(rf, &m)
				allHealthSnapshots = append(allHealthSnapshots, m)
			}
			featureMu.Unlock()

			ack := fmt.Sprintf(`{"received":%d,"deduped":0,"written":%d,"dropped":0,"message":"ok"}`,
				len(env.Features), len(env.Features))
			_, _ = w.Write([]byte(ack))

		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer coreServer.Close()

	cfg := config.Config{
		Brokers:             []string{"mqtts://globalbroker.meteo.fr:8883"},
		Username:            "everyone",
		Password:            "everyone",
		Topics:              []string{"cache/a/wis2/+/data/core/weather/advisories-warnings/#"},
		ContactEmail:        "admin@example.org",
		MaxDownloadBytes:    5 * 1024 * 1024,
		DownloadConcurrency: 4,
		HealthInterval:      100 * time.Millisecond,
	}

	coreClient := core.NewClient(coreServer.URL+"/api/v1", &http.Client{Timeout: 5 * time.Second})
	fakeBroker := broker.NewFakeBroker("mqtts://globalbroker.meteo.fr:8883")
	ctrl := NewController(cfg, coreClient, fakeBroker, &http.Client{Timeout: 5 * time.Second}, time.Now)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	go ctrl.Execute(ctx)

	if err := fakeBroker.WaitRunning(ctx); err != nil {
		t.Fatalf("broker wait running failed: %v", err)
	}

	wnmMsg := wnm.WNMMessage{
		ID:   "c2430368-1e1d-48fd-a541-9d2b99c9d521",
		Type: "Feature",
		Properties: wnm.WNMProperties{
			DataID:   "eu-eumetnet-warnings/6daf7b97-5ad7-424c-b267-2a31338167ef",
			PubTime:  "2026-09-25T11:44:41.694517Z",
			DateTime: ptr("2026-09-25T11:44:00+00:00"),
			ObjectID: ptr("c15c700e-1db2-4639-a5f7-7e7a2b81163c"),
		},
		Links: []wnm.WNMLink{
			{
				Rel:   "license",
				Href:  "https://creativecommons.org/licenses/by/4.0/",
				Type:  "text/html",
				Title: "CC BY 4.0",
			},
			{
				Rel:  "canonical",
				Href: upstreamServer.URL + "/warning.xml",
				Type: "application/xml",
			},
			{
				Rel:  "geometry",
				Href: upstreamServer.URL + "/feature.geojson?X-Redacted=1",
				Type: "application/geo+json",
			},
		},
	}

	wnmBytes, _ := json.Marshal(wnmMsg)
	topic := "cache/a/wis2/eu-eumetnet-warnings/data/core/weather/advisories-warnings"

	fakeBroker.Publish(topic, wnmBytes)

	deadline := time.Now().Add(4 * time.Second)
	for time.Now().Before(deadline) {
		if atomic.LoadInt32(&capReceivedCount) > 0 {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}

	if atomic.LoadInt32(&capReceivedCount) != 1 {
		t.Fatalf("expected 1 CAP feature received by core, got %d", atomic.LoadInt32(&capReceivedCount))
	}

	featureMu.Lock()
	feat := capturedCAPFeature
	featureMu.Unlock()

	if feat.NotificationID != "c2430368-1e1d-48fd-a541-9d2b99c9d521" {
		t.Errorf("notification_id mismatch: %s", feat.NotificationID)
	}
	if feat.DataID != "eu-eumetnet-warnings/6daf7b97-5ad7-424c-b267-2a31338167ef" {
		t.Errorf("data_id mismatch: %s", feat.DataID)
	}
	if feat.Topic != topic {
		t.Errorf("topic mismatch: %s", feat.Topic)
	}
	if feat.CentreID != "eu-eumetnet-warnings" {
		t.Errorf("centre_id mismatch: %s", feat.CentreID)
	}
	if feat.Channel != "cache" {
		t.Errorf("channel mismatch: %s", feat.Channel)
	}
	if feat.LicenseURL == nil || *feat.LicenseURL != "https://creativecommons.org/licenses/by/4.0/" {
		t.Errorf("license_url mismatch: %v", feat.LicenseURL)
	}
	if feat.FetchedVia != "cache" {
		t.Errorf("fetched_via mismatch: %s", feat.FetchedVia)
	}
	if feat.DownloadURL == nil || *feat.DownloadURL != upstreamServer.URL+"/warning.xml" {
		t.Errorf("download_url mismatch: %v", feat.DownloadURL)
	}
	if !strings.Contains(feat.RawXML, `<alert xmlns="urn:oasis:names:tc:emergency:cap:1.2">`) {
		t.Errorf("raw_xml does not contain expected alert xml root")
	}

	if feat.Cap == nil {
		t.Fatalf("expected non-nil Cap parsed object")
	}
	if feat.Cap.CAPVersion != "1.2" {
		t.Errorf("cap.cap_version mismatch: %s", feat.Cap.CAPVersion)
	}
	if feat.Cap.Identifier != "2.49.0.0.300.0.GR.260925114400.020000009" {
		t.Errorf("cap.identifier mismatch: %s", feat.Cap.Identifier)
	}
	if feat.Cap.Sender != "emk@hnms.gr" {
		t.Errorf("cap.sender mismatch: %s", feat.Cap.Sender)
	}
	if len(feat.Cap.Info) != 2 {
		t.Fatalf("cap.info length mismatch: %d", len(feat.Cap.Info))
	}
	if feat.Cap.Info[0].Event != "Moderate Thunderstorm warning" {
		t.Errorf("cap.info[0].event mismatch: %s", feat.Cap.Info[0].Event)
	}

	if feat.AreaKey == nil || *feat.AreaKey != "c15c700e-1db2-4639-a5f7-7e7a2b81163c" {
		t.Errorf("area_key mismatch: %v", feat.AreaKey)
	}
	if feat.AreaGeometry == nil {
		t.Fatalf("expected non-nil area_geometry")
	}
	geomBytes, _ := json.Marshal(feat.AreaGeometry)
	var geomMap map[string]any
	_ = json.Unmarshal(geomBytes, &geomMap)
	if geomMap["type"] != "MultiPolygon" {
		t.Errorf("area_geometry type mismatch: %v", geomMap["type"])
	}
	if feat.AreaPrecision == nil || *feat.AreaPrecision != "exact" {
		t.Errorf("area_precision mismatch: %v", feat.AreaPrecision)
	}

	// 6. Test dedup and duplicate counting: send identical message again
	fakeBroker.Publish(topic, wnmBytes)
	time.Sleep(300 * time.Millisecond)

	if atomic.LoadInt32(&capReceivedCount) != 1 {
		t.Errorf("expected duplicate to not be sent to cap, count: %d", atomic.LoadInt32(&capReceivedCount))
	}

	featureMu.Lock()
	healthMeta := capturedHealthMeta
	snapshots := make([]map[string]any, len(allHealthSnapshots))
	copy(snapshots, allHealthSnapshots)
	featureMu.Unlock()

	if healthMeta.FeedURL != "mqtts://globalbroker.meteo.fr:8883" {
		t.Errorf("health poll_meta.feed_url mismatch: %s", healthMeta.FeedURL)
	}

	foundDuplicateRecord := false
	for _, snap := range snapshots {
		if snap["centre_id"] == "eu-eumetnet-warnings" && snap["kind"] == "warnings" {
			if dup, ok := snap["duplicates"].(float64); ok && dup >= 1 {
				foundDuplicateRecord = true
				break
			}
		}
	}
	if !foundDuplicateRecord {
		t.Errorf("expected at least one health snapshot to record duplicates >= 1, got: %+v", snapshots)
	}
}

func TestControllerIntegrityFailureDropped(t *testing.T) {
	var capCalls int32
	coreServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/api/v1/wis2_data/cap":
			atomic.AddInt32(&capCalls, 1)
			_, _ = w.Write([]byte(`{"received":0,"deduped":0,"written":0,"dropped":0,"message":"ok"}`))
		case "/api/v1/wis2_data/health":
			var env struct {
				Features []json.RawMessage `json:"features"`
			}
			_ = json.NewDecoder(r.Body).Decode(&env)
			ack := fmt.Sprintf(`{"received":%d,"deduped":0,"written":%d,"dropped":0,"message":"ok"}`,
				len(env.Features), len(env.Features))
			_, _ = w.Write([]byte(ack))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer coreServer.Close()

	cfg := config.Config{
		Brokers:             []string{"mqtts://broker:8883"},
		MaxDownloadBytes:    1024 * 1024,
		DownloadConcurrency: 2,
		HealthInterval:      10 * time.Second, // longer interval so it doesn't reset stats during test
	}

	coreClient := core.NewClient(coreServer.URL+"/api/v1", nil)
	fakeBroker := broker.NewFakeBroker("mqtts://broker:8883")
	ctrl := NewController(cfg, coreClient, fakeBroker, nil, time.Now)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	go ctrl.Execute(ctx)
	_ = fakeBroker.WaitRunning(ctx)

	badWNM := wnm.WNMMessage{
		ID:   "bad-integrity-notif",
		Type: "Feature",
		Properties: wnm.WNMProperties{
			DataID:  "data-bad-integ",
			PubTime: "2026-09-25T12:00:00Z",
			Content: &wnm.WNMContent{
				Encoding: "utf-8",
				Value:    "<alert>test</alert>",
			},
			Integrity: &wnm.WNMIntegrity{
				Method: "sha512",
				Value:  "corrupted-hash-value-12345",
			},
		},
	}

	b, _ := json.Marshal(badWNM)
	fakeBroker.Publish("cache/a/wis2/bad-integ/data/core/weather/advisories-warnings", b)

	time.Sleep(200 * time.Millisecond)

	if atomic.LoadInt32(&capCalls) > 0 {
		t.Errorf("expected integrity failure to be dropped, got %d cap calls", atomic.LoadInt32(&capCalls))
	}

	h := ctrl.getOrCreateHealth("bad-integ", "warnings")
	h.mu.Lock()
	integFailed := h.IntegrityFailed
	h.mu.Unlock()

	if integFailed != 1 {
		t.Errorf("expected 1 integrity_failed count in health, got %d", integFailed)
	}
}

func TestControllerBrokerRotation(t *testing.T) {
	brokers := []string{
		"mqtts://b1.example.org:8883",
		"mqtts://b2.example.org:8883",
		"mqtts://b3.example.org:8883",
	}

	rotator := broker.NewRotator(brokers, 10*time.Millisecond, 50*time.Millisecond, 5*time.Millisecond)

	if rotator.Current() != "mqtts://b1.example.org:8883" {
		t.Fatalf("expected b1 initially, got: %s", rotator.Current())
	}

	next, _ := rotator.Rotate()
	if next != "mqtts://b2.example.org:8883" {
		t.Errorf("expected b2 on rotation, got: %s", next)
	}

	next, _ = rotator.Rotate()
	if next != "mqtts://b3.example.org:8883" {
		t.Errorf("expected b3 on rotation, got: %s", next)
	}

	next, _ = rotator.Rotate()
	if next != "mqtts://b1.example.org:8883" {
		t.Errorf("expected b1 on wrap around, got: %s", next)
	}
}

func TestControllerSynopNotSentToCap(t *testing.T) {
	var capCalls int32
	coreServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.URL.Path == "/api/v1/wis2_data/cap" {
			atomic.AddInt32(&capCalls, 1)
		}
		_, _ = w.Write([]byte(`{"received":0,"deduped":0,"written":0,"dropped":0,"message":"ok"}`))
	}))
	defer coreServer.Close()

	cfg := config.Config{
		Brokers:        []string{"mqtts://broker:8883"},
		HealthInterval: 10 * time.Second,
	}

	coreClient := core.NewClient(coreServer.URL+"/api/v1", nil)
	fakeBroker := broker.NewFakeBroker("mqtts://broker:8883")
	ctrl := NewController(cfg, coreClient, fakeBroker, nil, time.Now)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	go ctrl.Execute(ctx)
	_ = fakeBroker.WaitRunning(ctx)

	synopData, err := os.ReadFile(filepath.Join("..", "testdata", "synop_1_wnm.json"))
	if err != nil {
		t.Fatalf("failed to read synop fixture: %v", err)
	}

	fakeBroker.Publish("cache/a/wis2/kz-kazhydromet/data/core/weather/surface-based-observations/synop", synopData)

	time.Sleep(200 * time.Millisecond)

	if atomic.LoadInt32(&capCalls) > 0 {
		t.Errorf("synop message must not be sent to cap endpoint")
	}

	h := ctrl.getOrCreateHealth("kz-kazhydromet", "synop")
	h.mu.Lock()
	rec := h.Received
	h.mu.Unlock()

	if rec != 1 {
		t.Errorf("expected 1 received synop in health, got %d", rec)
	}
}

func TestControllerDecodeFailure(t *testing.T) {
	var capCalls int32
	coreServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.URL.Path == "/api/v1/wis2_data/cap" {
			atomic.AddInt32(&capCalls, 1)
		}
		_, _ = w.Write([]byte(`{"received":0,"deduped":0,"written":0,"dropped":0,"message":"ok"}`))
	}))
	defer coreServer.Close()

	cfg := config.Config{
		Brokers:        []string{"mqtts://broker:8883"},
		HealthInterval: 10 * time.Second,
	}

	coreClient := core.NewClient(coreServer.URL+"/api/v1", nil)
	fakeBroker := broker.NewFakeBroker("mqtts://broker:8883")
	ctrl := NewController(cfg, coreClient, fakeBroker, nil, time.Now)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	go ctrl.Execute(ctx)
	_ = fakeBroker.WaitRunning(ctx)

	nonCAPWNM := wnm.WNMMessage{
		ID:   "non-cap-notif",
		Type: "Feature",
		Properties: wnm.WNMProperties{
			DataID:  "data-non-cap",
			PubTime: "2026-09-25T12:00:00Z",
			Content: &wnm.WNMContent{
				Encoding: "utf-8",
				Value:    "<html><body>Not a CAP alert</body></html>",
			},
		},
	}
	b, _ := json.Marshal(nonCAPWNM)
	fakeBroker.Publish("cache/a/wis2/eu-test/data/core/weather/advisories-warnings", b)

	time.Sleep(200 * time.Millisecond)

	if atomic.LoadInt32(&capCalls) > 0 {
		t.Errorf("non-CAP document must not be sent to core cap endpoint")
	}

	h := ctrl.getOrCreateHealth("eu-test", "warnings")
	h.mu.Lock()
	decodeFailed := h.DecodeFailed
	h.mu.Unlock()

	if decodeFailed != 1 {
		t.Errorf("expected 1 decode_failed in health, got %d", decodeFailed)
	}
}

func ptr(s string) *string {
	return &s
}

func TestGeometryExactPath(t *testing.T) {
	xmlData, err := os.ReadFile(filepath.Join("..", "testdata", "cache_eu-eumetnet-warnings.xml"))
	if err != nil {
		t.Fatalf("failed to read testdata xml: %v", err)
	}

	upstreamServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/warning.xml":
			w.Header().Set("Content-Type", "application/xml")
			_, _ = w.Write(xmlData)
		case "/feature.geojson":
			w.Header().Set("Content-Type", "application/geo+json")
			_, _ = w.Write([]byte(`{
				"type": "Feature",
				"geometry": {
					"type": "Polygon",
					"coordinates": [[[21.0, 36.0], [21.0, 38.0], [22.0, 38.0], [22.0, 36.0], [21.0, 36.0]]]
				}
			}`))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer upstreamServer.Close()

	var receivedCAP CAPFeature
	var receivedCount int32
	coreServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.URL.Path == "/api/v1/wis2_data/cap" {
			var env struct {
				Features []CAPFeature `json:"features"`
			}
			_ = json.NewDecoder(r.Body).Decode(&env)
			if len(env.Features) > 0 {
				receivedCAP = env.Features[0]
				atomic.AddInt32(&receivedCount, int32(len(env.Features)))
			}
			ack := fmt.Sprintf(`{"received":%d,"deduped":0,"written":%d,"dropped":0,"message":"ok"}`,
				len(env.Features), len(env.Features))
			_, _ = w.Write([]byte(ack))
		} else {
			_, _ = w.Write([]byte(`{"received":0,"deduped":0,"written":0,"dropped":0,"message":"ok"}`))
		}
	}))
	defer coreServer.Close()

	cfg := config.Config{
		Brokers:             []string{"mqtts://broker:8883"},
		Topics:              []string{"cache/a/wis2/+/data/core/weather/advisories-warnings/#"},
		DownloadConcurrency: 2,
		HealthInterval:      10 * time.Second,
	}

	coreClient := core.NewClient(coreServer.URL+"/api/v1", nil)
	fakeBroker := broker.NewFakeBroker("mqtts://broker:8883")
	ctrl := NewController(cfg, coreClient, fakeBroker, nil, time.Now)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go ctrl.Execute(ctx)
	_ = fakeBroker.WaitRunning(ctx)

	geomSuccessBefore := testutil.ToFloat64(wis2metrics.DownloadsTotal.WithLabelValues("geometry", "success"))

	msg := wnm.WNMMessage{
		ID:   "exact-path-msg-1",
		Type: "Feature",
		Properties: wnm.WNMProperties{
			DataID:   "exact-data-1",
			PubTime:  "2026-09-25T12:00:00Z",
			ObjectID: ptr("exact-area-key"),
		},
		Links: []wnm.WNMLink{
			{Rel: "canonical", Href: upstreamServer.URL + "/warning.xml"},
			{Rel: "geometry", Href: upstreamServer.URL + "/feature.geojson?sig=123"},
		},
	}
	b, _ := json.Marshal(msg)
	fakeBroker.Publish("cache/a/wis2/eu-test/data/core/weather/advisories-warnings", b)

	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if atomic.LoadInt32(&receivedCount) > 0 {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}

	if atomic.LoadInt32(&receivedCount) != 1 {
		t.Fatalf("expected 1 received CAP, got %d", atomic.LoadInt32(&receivedCount))
	}
	if receivedCAP.AreaPrecision == nil || *receivedCAP.AreaPrecision != "exact" {
		t.Errorf("expected area_precision exact, got %v", receivedCAP.AreaPrecision)
	}
	if receivedCAP.AreaKey == nil || *receivedCAP.AreaKey != "exact-area-key" {
		t.Errorf("expected area_key exact-area-key, got %v", receivedCAP.AreaKey)
	}
	if receivedCAP.AreaGeometry == nil {
		t.Fatalf("expected non-nil area_geometry")
	}

	geomSuccessAfter := testutil.ToFloat64(wis2metrics.DownloadsTotal.WithLabelValues("geometry", "success"))
	if geomSuccessAfter-geomSuccessBefore != 1 {
		t.Errorf("expected downloads_total target=geometry result=success incremented by 1, before=%f after=%f",
			geomSuccessBefore, geomSuccessAfter)
	}
}

func TestGeometryExpired403Fallback(t *testing.T) {
	xmlData, err := os.ReadFile(filepath.Join("..", "testdata", "cache_eu-eumetnet-warnings.xml"))
	if err != nil {
		t.Fatalf("failed to read testdata xml: %v", err)
	}

	upstreamServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/warning.xml":
			w.Header().Set("Content-Type", "application/xml")
			_, _ = w.Write(xmlData)
		case "/expired-feature.geojson":
			// S3 403 AccessDenied "Request has expired"
			w.WriteHeader(http.StatusForbidden)
			_, _ = w.Write([]byte(`<?xml version="1.0" encoding="UTF-8"?><Error><Code>AccessDenied</Code><Message>Request has expired</Message></Error>`))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer upstreamServer.Close()

	var receivedCAP CAPFeature
	var receivedCount int32
	coreServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.URL.Path == "/api/v1/wis2_data/cap" {
			var env struct {
				Features []CAPFeature `json:"features"`
			}
			_ = json.NewDecoder(r.Body).Decode(&env)
			if len(env.Features) > 0 {
				receivedCAP = env.Features[0]
				atomic.AddInt32(&receivedCount, int32(len(env.Features)))
			}
			ack := fmt.Sprintf(`{"received":%d,"deduped":0,"written":%d,"dropped":0,"message":"ok"}`,
				len(env.Features), len(env.Features))
			_, _ = w.Write([]byte(ack))
		} else {
			_, _ = w.Write([]byte(`{"received":0,"deduped":0,"written":0,"dropped":0,"message":"ok"}`))
		}
	}))
	defer coreServer.Close()

	// Capture logs to verify WARN log and that URL query string is NEVER logged
	var logBuf bytes.Buffer
	handler := slog.NewJSONHandler(&logBuf, &slog.HandlerOptions{Level: slog.LevelDebug})
	oldLogger := slog.Default()
	slog.SetDefault(slog.New(handler))
	defer slog.SetDefault(oldLogger)

	cfg := config.Config{
		Brokers:             []string{"mqtts://broker:8883"},
		Topics:              []string{"cache/a/wis2/+/data/core/weather/advisories-warnings/#"},
		DownloadConcurrency: 2,
		HealthInterval:      10 * time.Second,
	}

	coreClient := core.NewClient(coreServer.URL+"/api/v1", nil)
	fakeBroker := broker.NewFakeBroker("mqtts://broker:8883")
	ctrl := NewController(cfg, coreClient, fakeBroker, nil, time.Now)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go ctrl.Execute(ctx)
	_ = fakeBroker.WaitRunning(ctx)

	geomFailedBefore := testutil.ToFloat64(wis2metrics.DownloadsTotal.WithLabelValues("geometry", "failed"))

	presignedQuery := "AWSAccessKeyId=AKIAIOSFODNN7EXAMPLE&Signature=SECRET_vjbyPxybdZaNmGa%2ByT272YEAiv4%3D&Expires=1700000000"
	geometryURL := upstreamServer.URL + "/expired-feature.geojson?" + presignedQuery

	wnmGeometry := `{
		"type": "Polygon",
		"coordinates": [[[21.18, 36.72], [21.18, 38.33], [22.39, 38.33], [22.39, 36.72], [21.18, 36.72]]]
	}`

	msg := wnm.WNMMessage{
		ID:       "expired-geom-msg-1",
		Type:     "Feature",
		Geometry: json.RawMessage(wnmGeometry),
		Properties: wnm.WNMProperties{
			DataID:   "expired-data-id-123",
			PubTime:  "2026-09-25T12:00:00Z",
			ObjectID: ptr("stable-area-key-xyz"),
		},
		Links: []wnm.WNMLink{
			{Rel: "canonical", Href: upstreamServer.URL + "/warning.xml"},
			{Rel: "geometry", Href: geometryURL},
		},
	}
	b, _ := json.Marshal(msg)
	fakeBroker.Publish("cache/a/wis2/eu-eumetnet-warnings/data/core/weather/advisories-warnings", b)

	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if atomic.LoadInt32(&receivedCount) > 0 {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}

	if atomic.LoadInt32(&receivedCount) != 1 {
		t.Fatalf("expected 1 received CAP, got %d", atomic.LoadInt32(&receivedCount))
	}

	// 1. Verify bbox fallback
	if receivedCAP.AreaPrecision == nil || *receivedCAP.AreaPrecision != "bbox" {
		t.Errorf("expected area_precision 'bbox', got %v", receivedCAP.AreaPrecision)
	}
	// 2. Verify same area_key
	if receivedCAP.AreaKey == nil || *receivedCAP.AreaKey != "stable-area-key-xyz" {
		t.Errorf("expected same area_key 'stable-area-key-xyz', got %v", receivedCAP.AreaKey)
	}
	// 3. Verify area_geometry flattened to MultiPolygon from WNM geometry
	if receivedCAP.AreaGeometry == nil {
		t.Fatalf("expected non-nil area_geometry from bbox fallback")
	}
	geomBytes, _ := json.Marshal(receivedCAP.AreaGeometry)
	var geomMap map[string]any
	_ = json.Unmarshal(geomBytes, &geomMap)
	if geomMap["type"] != "MultiPolygon" {
		t.Errorf("area_geometry type mismatch: %v", geomMap["type"])
	}

	// 4. Verify metric
	geomFailedAfter := testutil.ToFloat64(wis2metrics.DownloadsTotal.WithLabelValues("geometry", "failed"))
	if geomFailedAfter-geomFailedBefore != 1 {
		t.Errorf("expected downloads_total target=geometry result=failed incremented by 1, before=%f after=%f",
			geomFailedBefore, geomFailedAfter)
	}

	// 5. Verify WARN log: reason, centre_id, data_id, NO query string
	logged := logBuf.String()
	if !strings.Contains(logged, "WARN") {
		t.Errorf("expected WARN level log, got: %s", logged)
	}
	if !strings.Contains(logged, "403") {
		t.Errorf("expected reason with 403 in log, got: %s", logged)
	}
	if !strings.Contains(logged, "eu-eumetnet-warnings") {
		t.Errorf("expected centre_id in log, got: %s", logged)
	}
	if !strings.Contains(logged, "expired-data-id-123") {
		t.Errorf("expected data_id in log, got: %s", logged)
	}
	// CRITICAL: URL query string must never be logged
	if strings.Contains(logged, "AKIAIOSFODNN7EXAMPLE") || strings.Contains(logged, "SECRET_vjbyPxybdZaNmGa") || strings.Contains(logged, "Expires=1700000000") {
		t.Errorf("SECURITY LEAK: pre-signed URL query string was logged: %s", logged)
	}
}

func TestNoGeometryAtAll(t *testing.T) {
	xmlData, err := os.ReadFile(filepath.Join("..", "testdata", "cache_eu-eumetnet-warnings.xml"))
	if err != nil {
		t.Fatalf("failed to read testdata xml: %v", err)
	}

	upstreamServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/xml")
		_, _ = w.Write(xmlData)
	}))
	defer upstreamServer.Close()

	var receivedCAP CAPFeature
	var receivedRaw json.RawMessage
	var receivedCount int32
	coreServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.URL.Path == "/api/v1/wis2_data/cap" {
			var env struct {
				Features []json.RawMessage `json:"features"`
			}
			_ = json.NewDecoder(r.Body).Decode(&env)
			if len(env.Features) > 0 {
				receivedRaw = env.Features[0]
				_ = json.Unmarshal(env.Features[0], &receivedCAP)
				atomic.AddInt32(&receivedCount, int32(len(env.Features)))
			}
			ack := fmt.Sprintf(`{"received":%d,"deduped":0,"written":%d,"dropped":0,"message":"ok"}`,
				len(env.Features), len(env.Features))
			_, _ = w.Write([]byte(ack))
		} else {
			_, _ = w.Write([]byte(`{"received":0,"deduped":0,"written":0,"dropped":0,"message":"ok"}`))
		}
	}))
	defer coreServer.Close()

	cfg := config.Config{
		Brokers:             []string{"mqtts://broker:8883"},
		Topics:              []string{"cache/a/wis2/+/data/core/weather/advisories-warnings/#"},
		DownloadConcurrency: 2,
		HealthInterval:      10 * time.Second,
	}

	coreClient := core.NewClient(coreServer.URL+"/api/v1", nil)
	fakeBroker := broker.NewFakeBroker("mqtts://broker:8883")
	ctrl := NewController(cfg, coreClient, fakeBroker, nil, time.Now)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go ctrl.Execute(ctx)
	_ = fakeBroker.WaitRunning(ctx)

	msg := wnm.WNMMessage{
		ID:   "no-geom-msg-1",
		Type: "Feature",
		// No geometry
		Properties: wnm.WNMProperties{
			DataID:  "no-geom-data-1",
			PubTime: "2026-09-25T12:00:00Z",
		},
		Links: []wnm.WNMLink{
			{Rel: "canonical", Href: upstreamServer.URL + "/warning.xml"},
			{Rel: "license", Href: "https://example.com/license"},
			// No geometry link
		},
	}
	b, _ := json.Marshal(msg)
	fakeBroker.Publish("cache/a/wis2/eu-test/data/core/weather/advisories-warnings", b)

	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if atomic.LoadInt32(&receivedCount) > 0 {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}

	if atomic.LoadInt32(&receivedCount) != 1 {
		t.Fatalf("expected 1 received CAP, got %d", atomic.LoadInt32(&receivedCount))
	}

	// Verify no area
	if receivedCAP.AreaPrecision != nil {
		t.Errorf("expected nil area_precision, got %v", receivedCAP.AreaPrecision)
	}
	if receivedCAP.AreaKey != nil {
		t.Errorf("expected nil area_key, got %v", receivedCAP.AreaKey)
	}
	if receivedCAP.AreaGeometry != nil {
		t.Errorf("expected nil area_geometry, got %v", receivedCAP.AreaGeometry)
	}

	// Verify JSON contract: null values present
	var jsonMap map[string]any
	if err := json.Unmarshal(receivedRaw, &jsonMap); err != nil {
		t.Fatalf("failed to unmarshal received raw JSON: %v", err)
	}
	if val, ok := jsonMap["area_precision"]; !ok || val != nil {
		t.Errorf("expected area_precision: null in JSON, got %v (exists: %v)", val, ok)
	}
	if val, ok := jsonMap["area_key"]; !ok || val != nil {
		t.Errorf("expected area_key: null in JSON, got %v (exists: %v)", val, ok)
	}
	if val, ok := jsonMap["area_geometry"]; !ok || val != nil {
		t.Errorf("expected area_geometry: null in JSON, got %v (exists: %v)", val, ok)
	}
}

func TestCAPFeatureJSONContractIncludesAreaPrecision(t *testing.T) {
	// 1. Exact
	fExact := CAPFeature{
		NotificationID: "n1",
		DataID:         "d1",
		Topic:          "t1",
		CentreID:       "c1",
		Channel:        "cache",
		PubTime:        "2026-09-25T12:00:00Z",
		FetchedVia:     "cache",
		RawXML:         "<alert></alert>",
		AreaKey:        ptr("area-key-1"),
		AreaGeometry:   map[string]any{"type": "MultiPolygon"},
		AreaPrecision:  ptr("exact"),
	}
	bExact, err := json.Marshal(fExact)
	if err != nil {
		t.Fatalf("marshal failed: %v", err)
	}
	var mExact map[string]any
	_ = json.Unmarshal(bExact, &mExact)
	if mExact["area_precision"] != "exact" {
		t.Errorf("expected area_precision 'exact', got %v", mExact["area_precision"])
	}
	if mExact["area_key"] != "area-key-1" {
		t.Errorf("expected area_key 'area-key-1', got %v", mExact["area_key"])
	}

	// 2. Bbox
	fBbox := CAPFeature{
		NotificationID: "n2",
		DataID:         "d2",
		Topic:          "t2",
		CentreID:       "c2",
		Channel:        "cache",
		PubTime:        "2026-09-25T12:00:00Z",
		FetchedVia:     "cache",
		RawXML:         "<alert></alert>",
		AreaKey:        ptr("area-key-2"),
		AreaGeometry:   map[string]any{"type": "MultiPolygon"},
		AreaPrecision:  ptr("bbox"),
	}
	bBbox, err := json.Marshal(fBbox)
	if err != nil {
		t.Fatalf("marshal failed: %v", err)
	}
	var mBbox map[string]any
	_ = json.Unmarshal(bBbox, &mBbox)
	if mBbox["area_precision"] != "bbox" {
		t.Errorf("expected area_precision 'bbox', got %v", mBbox["area_precision"])
	}

	// 3. Null (no area)
	fNull := CAPFeature{
		NotificationID: "n3",
		DataID:         "d3",
		Topic:          "t3",
		CentreID:       "c3",
		Channel:        "cache",
		PubTime:        "2026-09-25T12:00:00Z",
		FetchedVia:     "cache",
		RawXML:         "<alert></alert>",
	}
	bNull, err := json.Marshal(fNull)
	if err != nil {
		t.Fatalf("marshal failed: %v", err)
	}
	var mNull map[string]any
	_ = json.Unmarshal(bNull, &mNull)
	if val, ok := mNull["area_precision"]; !ok || val != nil {
		t.Errorf("expected area_precision to be null in JSON, got %v (exists: %v)", val, ok)
	}
	if val, ok := mNull["area_key"]; !ok || val != nil {
		t.Errorf("expected area_key to be null in JSON, got %v (exists: %v)", val, ok)
	}
	if val, ok := mNull["area_geometry"]; !ok || val != nil {
		t.Errorf("expected area_geometry to be null in JSON, got %v (exists: %v)", val, ok)
	}

	// Verify all contract fields
	expectedFields := []string{
		"notification_id", "data_id", "topic", "centre_id", "channel",
		"pubtime", "datetime", "license_url", "fetched_via", "download_url",
		"raw_xml", "cap", "area_key", "area_geometry", "area_precision",
	}
	for _, field := range expectedFields {
		if _, ok := mNull[field]; !ok {
			t.Errorf("missing contract field %s in JSON", field)
		}
	}
}

func TestLinkFallbackIgnoringDeclaredType(t *testing.T) {
	xmlData, err := os.ReadFile(filepath.Join("..", "testdata", "cache_eu-eumetnet-warnings.xml"))
	if err != nil {
		t.Fatalf("failed to read testdata xml: %v", err)
	}

	upstreamServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/canonical-fails.xml":
			w.WriteHeader(http.StatusNotFound)
		case "/alternate-data.bin":
			// Serving valid CAP despite non-XML declared type (e.g. application/grib)
			w.Header().Set("Content-Type", "application/grib")
			_, _ = w.Write(xmlData)
		case "/license":
			w.WriteHeader(http.StatusOK)
		case "/archive.json":
			w.WriteHeader(http.StatusOK)
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer upstreamServer.Close()

	var receivedCAP CAPFeature
	var receivedCount int32
	coreServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.URL.Path == "/api/v1/wis2_data/cap" {
			var env struct {
				Features []CAPFeature `json:"features"`
			}
			_ = json.NewDecoder(r.Body).Decode(&env)
			if len(env.Features) > 0 {
				receivedCAP = env.Features[0]
				atomic.AddInt32(&receivedCount, int32(len(env.Features)))
			}
			ack := fmt.Sprintf(`{"received":%d,"deduped":0,"written":%d,"dropped":0,"message":"ok"}`,
				len(env.Features), len(env.Features))
			_, _ = w.Write([]byte(ack))
		} else {
			_, _ = w.Write([]byte(`{"received":0,"deduped":0,"written":0,"dropped":0,"message":"ok"}`))
		}
	}))
	defer coreServer.Close()

	cfg := config.Config{
		Brokers:             []string{"mqtts://broker:8883"},
		Topics:              []string{"cache/a/wis2/+/data/core/weather/advisories-warnings/#"},
		DownloadConcurrency: 2,
		HealthInterval:      10 * time.Second,
	}

	coreClient := core.NewClient(coreServer.URL+"/api/v1", nil)
	fakeBroker := broker.NewFakeBroker("mqtts://broker:8883")
	ctrl := NewController(cfg, coreClient, fakeBroker, nil, time.Now)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go ctrl.Execute(ctx)
	_ = fakeBroker.WaitRunning(ctx)

	msg := wnm.WNMMessage{
		ID:   "type-unreliable-msg-1",
		Type: "Feature",
		Properties: wnm.WNMProperties{
			DataID:  "type-unreliable-data-1",
			PubTime: "2026-09-25T12:00:00Z",
		},
		Links: []wnm.WNMLink{
			{Rel: "canonical", Href: upstreamServer.URL + "/canonical-fails.xml", Type: "application/xml"},
			{Rel: "license", Href: upstreamServer.URL + "/license", Type: "text/html"},
			{Rel: "json", Href: upstreamServer.URL + "/archive.json", Type: "application/json"},
			// Alternate link with declared type application/grib (simulating ECMWF in the wild)
			{Rel: "alternate", Href: upstreamServer.URL + "/alternate-data.bin", Type: "application/grib"},
		},
	}
	b, _ := json.Marshal(msg)
	fakeBroker.Publish("cache/a/wis2/eu-test/data/core/weather/advisories-warnings", b)

	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if atomic.LoadInt32(&receivedCount) > 0 {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}

	if atomic.LoadInt32(&receivedCount) != 1 {
		t.Fatalf("expected 1 received CAP via alternate fallback link, got %d", atomic.LoadInt32(&receivedCount))
	}
	if receivedCAP.DownloadURL == nil || *receivedCAP.DownloadURL != upstreamServer.URL+"/alternate-data.bin" {
		t.Errorf("expected download_url to be alternate link, got %v", receivedCAP.DownloadURL)
	}
	if receivedCAP.Cap == nil {
		t.Fatalf("expected parsed CAP object from alternate link")
	}
}
