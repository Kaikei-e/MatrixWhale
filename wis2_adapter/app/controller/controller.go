package controller

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"matrixwhale/adapters/common/cap"
	"matrixwhale/adapters/common/core"
	"matrixwhale/adapters/common/metrics"
	"matrixwhale/adapters/common/poll"
	"matrixwhale/adapters/common/useragent"

	"wis2_adapter/broker"
	"wis2_adapter/bufr"
	"wis2_adapter/config"
	"wis2_adapter/dedup"
	wis2metrics "wis2_adapter/metrics"
	"wis2_adapter/synop"
	"wis2_adapter/tc"
	"wis2_adapter/wnm"
)

const (
	CapBatchLimit         = 50
	CapBatchFlushInterval = 2 * time.Second
	TCBatchLimit          = 50
	TCBatchFlushInterval  = 2 * time.Second
	ObsBatchLimit         = 500
	ObsBatchFlushInterval = 5 * time.Second
	DefaultObsQueueCap    = 5000
	DefaultInboundCap     = 1000
	DefaultWorkerPoolSize = 16
)

type inboundJob struct {
	topic   string
	payload []byte
}

type TCFeature struct {
	NotificationID    string             `json:"notification_id"`
	DataID            string             `json:"data_id"`
	Topic             string             `json:"topic"`
	CentreID          string             `json:"centre_id"`
	Channel           string             `json:"channel"`
	PubTime           string             `json:"pubtime"`
	FetchedVia        string             `json:"fetched_via"`
	DownloadURL       *string            `json:"download_url"`
	MessageIndex      int                `json:"message_index"`
	OriginatingCentre int                `json:"originating_centre"`
	StormID           string             `json:"storm_id"`
	StormName         *string            `json:"storm_name"`
	EnsembleMember    *int               `json:"ensemble_member"`
	AnalysisTime      string             `json:"analysis_time"`
	Points            []tc.ForecastPoint `json:"points"`
}

type CAPFeature struct {
	NotificationID string        `json:"notification_id"`
	DataID         string        `json:"data_id"`
	Topic          string        `json:"topic"`
	CentreID       string        `json:"centre_id"`
	Channel        string        `json:"channel"`
	PubTime        string        `json:"pubtime"`
	DateTime       *string       `json:"datetime"`
	LicenseURL     *string       `json:"license_url"`
	FetchedVia     string        `json:"fetched_via"`
	DownloadURL    *string       `json:"download_url"`
	RawXML         string        `json:"raw_xml"`
	Cap            *cap.CAPAlert `json:"cap"`
	AreaKey        *string       `json:"area_key"`
	AreaGeometry   any           `json:"area_geometry"`
	AreaPrecision  *string       `json:"area_precision"`
}

type HealthKey struct {
	CentreID string
	Kind     string
}

type HealthCounters struct {
	WindowStart     time.Time
	Received        int
	Duplicates      int
	DownloadFailed  int
	DecodeFailed    int
	IntegrityFailed int
	LastReceivedAt  *time.Time
}

type HealthStats struct {
	mu sync.Mutex
	HealthCounters
}

type Controller struct {
	cfg         config.Config
	coreClient  *core.Client
	broker      broker.Broker
	httpClient  *http.Client
	dedupCache  *dedup.Cache
	downloadSem chan struct{}
	now         func() time.Time
	sleepAfter  func(d time.Duration) <-chan time.Time

	workerPoolSize int
	inboundCap     int
	inboundQueue   chan inboundJob
	droppedInbound atomic.Int64

	healthMu sync.Mutex
	health   map[HealthKey]*HealthStats

	batchMu  sync.Mutex
	capBatch []json.RawMessage

	tcBatchMu sync.Mutex
	tcBatch   []json.RawMessage

	obsBatchMu          sync.Mutex
	obsBatch            []json.RawMessage
	obsQueueCap         int
	droppedObservations atomic.Int64
}

func Run(ctx context.Context) {
	cfg := config.LoadConfig()
	coreClient := core.NewClientFromEnv()
	brokerClient := broker.NewMQTTBroker(cfg)
	httpClient := &http.Client{
		Timeout:   30 * time.Second,
		Transport: metrics.Transport("upstream", nil),
	}
	ctrl := NewController(cfg, coreClient, brokerClient, httpClient, time.Now)
	ctrl.Execute(ctx)
}

func NewController(
	cfg config.Config,
	coreClient *core.Client,
	b broker.Broker,
	httpClient *http.Client,
	now func() time.Time,
) *Controller {
	if httpClient == nil {
		httpClient = &http.Client{
			Timeout:   30 * time.Second,
			Transport: metrics.Transport("upstream", nil),
		}
	}
	if now == nil {
		now = time.Now
	}

	concurrency := cfg.DownloadConcurrency
	if concurrency <= 0 {
		concurrency = 8
	}

	workerPoolSize := DefaultWorkerPoolSize
	if concurrency > 8 {
		workerPoolSize = concurrency * 2
	}
	inboundCap := DefaultInboundCap

	return &Controller{
		cfg:            cfg,
		coreClient:     coreClient,
		broker:         b,
		httpClient:     httpClient,
		dedupCache:     dedup.New(),
		downloadSem:    make(chan struct{}, concurrency),
		now:            now,
		sleepAfter:     func(d time.Duration) <-chan time.Time { return time.After(d) },
		workerPoolSize: workerPoolSize,
		inboundCap:     inboundCap,
		inboundQueue:   make(chan inboundJob, inboundCap),
		health:         make(map[HealthKey]*HealthStats),
		capBatch:       make([]json.RawMessage, 0, CapBatchLimit),
		tcBatch:        make([]json.RawMessage, 0, TCBatchLimit),
		obsBatch:       make([]json.RawMessage, 0, ObsBatchLimit),
		obsQueueCap:    DefaultObsQueueCap,
	}
}

func (c *Controller) SetInboundCap(cap int) {
	c.inboundCap = cap
	c.inboundQueue = make(chan inboundJob, cap)
}

func (c *Controller) SetObsQueueCap(cap int) {
	c.obsBatchMu.Lock()
	defer c.obsBatchMu.Unlock()
	c.obsQueueCap = cap
}

func (c *Controller) DroppedInbound() int64 {
	return c.droppedInbound.Load()
}

func (c *Controller) DroppedObservations() int64 {
	return c.droppedObservations.Load()
}

func (c *Controller) TotalDropped() int64 {
	return c.droppedInbound.Load() + c.droppedObservations.Load()
}

func (c *Controller) SetSleepAfter(fn func(d time.Duration) <-chan time.Time) {
	c.sleepAfter = fn
}

func (c *Controller) Execute(ctx context.Context) {
	slog.Info("Starting WIS2 adapter controller",
		"health_interval", c.cfg.HealthInterval,
		"download_concurrency", c.cfg.DownloadConcurrency,
		"max_download_bytes", c.cfg.MaxDownloadBytes,
	)

	var wg sync.WaitGroup

	// Background worker 1: Broker subscription runner (never blocks on HTTP)
	wg.Add(1)
	go func() {
		defer wg.Done()
		err := c.broker.Run(ctx, func(topic string, payload []byte) {
			select {
			case c.inboundQueue <- inboundJob{topic: topic, payload: payload}:
			default:
				c.droppedInbound.Add(1)
				wis2metrics.RecordDrop("inbound")
				slog.Warn("Inbound queue full, dropped notification", "topic", topic)
			}
		})
		if err != nil && ctx.Err() == nil {
			slog.Error("Broker run loop ended with error", "error", err)
		}
	}()

	// Worker pool processing inbound notifications
	for i := 0; i < c.workerPoolSize; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				select {
				case <-ctx.Done():
					return
				case job := <-c.inboundQueue:
					c.handleMessage(ctx, job.topic, job.payload)
				}
			}
		}()
	}

	// Background worker 2: CAP, TC and Obs batch flush tickers
	wg.Add(1)
	go func() {
		defer wg.Done()
		capTcTicker := time.NewTicker(CapBatchFlushInterval)
		defer capTcTicker.Stop()
		obsTicker := time.NewTicker(ObsBatchFlushInterval)
		defer obsTicker.Stop()
		for {
			select {
			case <-ctx.Done():
				c.flushCapBatch(context.Background())
				c.flushTCBatch(context.Background())
				c.flushObsBatch(context.Background())
				return
			case <-capTcTicker.C:
				c.flushCapBatch(ctx)
				c.flushTCBatch(ctx)
			case <-obsTicker.C:
				c.flushObsBatch(ctx)
			}
		}
	}()

	// Background worker 3: Health reporter ticker (every WIS2_HEALTH_INTERVAL)
	wg.Add(1)
	go func() {
		defer wg.Done()
		interval := c.cfg.HealthInterval
		if interval <= 0 {
			interval = 60 * time.Second
		}
		ticker := time.NewTicker(interval)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				c.reportHealth(context.Background())
				return
			case <-ticker.C:
				c.reportHealth(ctx)
			}
		}
	}()

	wg.Wait()
	slog.Info("WIS2 adapter controller execution finished")
}

func (c *Controller) handleMessage(ctx context.Context, topic string, payload []byte) {
	channel, centreID, kind := wnm.ClassifyTopic(topic)
	wis2metrics.RecordMessage(kind)

	stats := c.getOrCreateHealth(centreID, kind)
	now := c.now()
	stats.recordReceived(now)

	wnmMsg, err := wnm.ParseWNM(payload)
	if err != nil {
		slog.Warn("Failed to parse WNM message JSON", "topic", topic, "error", err)
		stats.recordDecodeFailed()
		return
	}

	if c.dedupCache.CheckOrAdd(wnmMsg.ID, wnmMsg.Properties.DataID) {
		stats.recordDuplicate()
		wis2metrics.RecordDuplicate(kind)
		return
	}

	var data []byte
	var fetchedVia string
	var downloadURL *string

	if wnmMsg.Properties.Content != nil && wnmMsg.Properties.Content.Value != "" {
		cnt := wnmMsg.Properties.Content
		if strings.EqualFold(cnt.Encoding, "base64") {
			decoded, decErr := base64.StdEncoding.DecodeString(cnt.Value)
			if decErr != nil {
				stats.recordDownloadFailed()
				wis2metrics.RecordDownload("payload", "failed")
				return
			}
			data = decoded
		} else {
			data = []byte(cnt.Value)
		}
		fetchedVia = "inline"
	} else {
		// Need to download from links
		select {
		case c.downloadSem <- struct{}{}:
		case <-ctx.Done():
			return
		}

		canonicalLink := wnm.FindCanonicalLink(wnmMsg.Links)
		if canonicalLink != nil && canonicalLink.Href != "" {
			d, dlErr := c.downloadPayload(ctx, canonicalLink.Href)
			if dlErr == nil {
				data = d
				fetchedVia = channel
				u := canonicalLink.Href
				downloadURL = &u
			}
		}

		if data == nil {
			fallbackLinks := wnm.FindDataFallbackLinks(wnmMsg.Links)
			for _, fl := range fallbackLinks {
				d, dlErr := c.downloadPayload(ctx, fl.Href)
				if dlErr == nil {
					data = d
					fetchedVia = channel
					u := fl.Href
					downloadURL = &u
					break
				}
			}
		}

		<-c.downloadSem

		if data == nil {
			stats.recordDownloadFailed()
			wis2metrics.RecordDownload("payload", "failed")
			return
		}
	}

	if wnmMsg.Properties.Integrity != nil {
		if !wnm.CheckIntegrity(data, wnmMsg.Properties.Integrity) {
			stats.recordIntegrityFailed()
			wis2metrics.RecordDownload("payload", "integrity_failed")
			return
		}
	}

	if fetchedVia != "inline" {
		wis2metrics.RecordDownload("payload", "success")
	}

	pubTime, err := wnm.FormatRFC3339(wnmMsg.Properties.PubTime)
	if err != nil {
		pubTime = wnmMsg.Properties.PubTime
	}

	if kind == "warnings" {
		c.handleWarnings(ctx, wnmMsg, topic, centreID, channel, pubTime, fetchedVia, downloadURL, data, stats)
	} else if kind == "trajectory" {
		c.handleTrajectory(ctx, wnmMsg, topic, centreID, channel, pubTime, fetchedVia, downloadURL, data, stats)
	} else if kind == "synop" {
		c.handleSynop(ctx, wnmMsg, topic, centreID, channel, pubTime, fetchedVia, downloadURL, data, stats)
	}
}

func (c *Controller) handleWarnings(
	ctx context.Context,
	wnmMsg *wnm.WNMMessage,
	topic string,
	centreID string,
	channel string,
	pubTime string,
	fetchedVia string,
	downloadURL *string,
	data []byte,
	stats *HealthStats,
) {
	capRes := cap.ParseCAP(data)
	if capRes.Error != nil || capRes.Cap == nil {
		stats.recordDecodeFailed()
		return
	}

	rawXML := string(data)
	if capRes.RawXML != nil {
		rawXML = *capRes.RawXML
	}

	var areaKey *string
	var areaGeom any
	var areaPrecision *string

	geomLink := wnm.FindGeometryLink(wnmMsg.Links)
	if geomLink != nil && geomLink.Href != "" {
		resolvedKey := wnm.ResolveAreaKey(wnmMsg.Properties.ObjectID, geomLink.Href)
		geomBytes, gErr := c.downloadPayload(ctx, geomLink.Href)
		var mp *wnm.MultiPolygonGeometry
		var fErr error
		if gErr == nil {
			mp, fErr = wnm.FlattenToMultiPolygon(geomBytes)
		}

		if gErr == nil && fErr == nil && mp != nil {
			areaGeom = mp
			areaKey = resolvedKey
			prec := "exact"
			areaPrecision = &prec
			wis2metrics.RecordDownload("geometry", "success")
		} else {
			reason := "failed to process geometry"
			if gErr != nil {
				reason = cleanError(gErr).Error()
			} else if fErr != nil {
				reason = fErr.Error()
			} else if mp == nil {
				reason = "empty geometry"
			}

			slog.Warn("Failed to download or parse geometry",
				"reason", reason,
				"centre_id", centreID,
				"data_id", wnmMsg.Properties.DataID,
			)
			wis2metrics.RecordDownload("geometry", "failed")

			// Fall back to WNM's own geometry (Polygon/MultiPolygon, flattened to MultiPolygon)
			if len(wnmMsg.Geometry) > 0 && string(wnmMsg.Geometry) != "null" {
				wnmMp, wnmErr := wnm.FlattenToMultiPolygon(wnmMsg.Geometry)
				if wnmErr == nil && wnmMp != nil {
					areaGeom = wnmMp
					areaKey = resolvedKey
					prec := "bbox"
					areaPrecision = &prec
				}
			}
		}
	}

	var licenseURL *string
	licLink := wnm.FindLicenseLink(wnmMsg.Links)
	if licLink != nil && licLink.Href != "" {
		licenseURL = &licLink.Href
	}

	var dateTime *string
	if wnmMsg.Properties.DateTime != nil && *wnmMsg.Properties.DateTime != "" {
		dt, dtErr := wnm.FormatRFC3339(*wnmMsg.Properties.DateTime)
		if dtErr == nil {
			dateTime = &dt
		} else {
			dateTime = wnmMsg.Properties.DateTime
		}
	}

	feat := CAPFeature{
		NotificationID: wnmMsg.ID,
		DataID:         wnmMsg.Properties.DataID,
		Topic:          topic,
		CentreID:       centreID,
		Channel:        channel,
		PubTime:        pubTime,
		DateTime:       dateTime,
		LicenseURL:     licenseURL,
		FetchedVia:     fetchedVia,
		DownloadURL:    downloadURL,
		RawXML:         rawXML,
		Cap:            capRes.Cap,
		AreaKey:        areaKey,
		AreaGeometry:   areaGeom,
		AreaPrecision:  areaPrecision,
	}

	c.enqueueCAPFeature(ctx, feat)
}

func (c *Controller) handleTrajectory(
	ctx context.Context,
	wnmMsg *wnm.WNMMessage,
	topic string,
	centreID string,
	channel string,
	pubTime string,
	fetchedVia string,
	downloadURL *string,
	data []byte,
	stats *HealthStats,
) {
	if !isBUFR(data) {
		slog.Warn("Payload is not BUFR; rejected as download_failed",
			"centre_id", centreID,
			"data_id", wnmMsg.Properties.DataID,
			"len", len(data),
		)
		stats.recordDownloadFailed()
		wis2metrics.RecordDownload("payload", "failed")
		return
	}

	msgs, errs := bufr.Decode(data)
	if len(msgs) == 0 {
		slog.Warn("No BUFR messages found in payload",
			"centre_id", centreID,
			"data_id", wnmMsg.Properties.DataID,
		)
		stats.recordDecodeFailed()
		return
	}

	hasAnySuccess := false
	for _, err := range errs {
		if err == nil {
			hasAnySuccess = true
			break
		}
	}
	if !hasAnySuccess {
		slog.Warn("All BUFR messages failed to decode",
			"centre_id", centreID,
			"data_id", wnmMsg.Properties.DataID,
		)
		stats.recordDecodeFailed()
		return
	}

	storms := tc.ExtractStorms(msgs)
	if len(storms) == 0 {
		slog.Debug("No storm tracks with valid points extracted",
			"centre_id", centreID,
			"data_id", wnmMsg.Properties.DataID,
		)
		return
	}

	for _, storm := range storms {
		feat := TCFeature{
			NotificationID:    wnmMsg.ID,
			DataID:            wnmMsg.Properties.DataID,
			Topic:             topic,
			CentreID:          centreID,
			Channel:           channel,
			PubTime:           pubTime,
			FetchedVia:        fetchedVia,
			DownloadURL:       downloadURL,
			MessageIndex:      storm.MessageIndex,
			OriginatingCentre: storm.OriginatingCentre,
			StormID:           storm.StormID,
			StormName:         storm.StormName,
			EnsembleMember:    storm.EnsembleMember,
			AnalysisTime:      storm.AnalysisTime,
			Points:            storm.Points,
		}
		c.enqueueTCFeature(ctx, feat)
	}
}

func (c *Controller) handleSynop(
	ctx context.Context,
	wnmMsg *wnm.WNMMessage,
	topic string,
	centreID string,
	channel string,
	pubTime string,
	fetchedVia string,
	downloadURL *string,
	data []byte,
	stats *HealthStats,
) {
	if !isBUFR(data) {
		slog.Warn("Payload is not BUFR; rejected as download_failed",
			"centre_id", centreID,
			"data_id", wnmMsg.Properties.DataID,
			"len", len(data),
		)
		stats.recordDownloadFailed()
		wis2metrics.RecordDownload("payload", "failed")
		return
	}

	msgs, errs := bufr.Decode(data)
	if len(msgs) == 0 {
		slog.Warn("No BUFR messages found in payload",
			"centre_id", centreID,
			"data_id", wnmMsg.Properties.DataID,
		)
		stats.recordDecodeFailed()
		return
	}

	hasAnySuccess := false
	for _, err := range errs {
		if err == nil {
			hasAnySuccess = true
			break
		}
	}
	if !hasAnySuccess {
		slog.Warn("All BUFR messages failed to decode",
			"centre_id", centreID,
			"data_id", wnmMsg.Properties.DataID,
		)
		stats.recordDecodeFailed()
		return
	}

	for _, msg := range msgs {
		features, rejections := synop.ExtractObservations(msg, wnmMsg.Properties.DataID, centreID, pubTime)
		for _, reason := range rejections {
			wis2metrics.RecordSubsetRejected(centreID, reason)
		}
		for _, feat := range features {
			c.enqueueObservationFeature(ctx, feat)
		}
	}
}

func (c *Controller) enqueueCAPFeature(ctx context.Context, feat CAPFeature) {
	b, err := json.Marshal(feat)
	if err != nil {
		slog.Error("Failed to marshal CAP feature", "error", err)
		return
	}

	c.batchMu.Lock()
	c.capBatch = append(c.capBatch, b)
	flushNow := len(c.capBatch) >= CapBatchLimit
	c.batchMu.Unlock()

	if flushNow {
		c.flushCapBatch(ctx)
	}
}

func (c *Controller) flushCapBatch(ctx context.Context) {
	c.batchMu.Lock()
	if len(c.capBatch) == 0 {
		c.batchMu.Unlock()
		return
	}
	batch := c.capBatch
	c.capBatch = make([]json.RawMessage, 0, CapBatchLimit)
	c.batchMu.Unlock()

	meta := core.PollMeta{
		FetchedAt:    c.now().UTC().Format(time.RFC3339),
		HTTPStatus:   200,
		FeatureCount: len(batch),
		FeedURL:      c.broker.CurrentBroker(),
	}

	ack, err := c.coreClient.Send(ctx, "wis2_data/cap", meta, batch)
	if err != nil {
		slog.Error("Failed to send CAP batch to core", "error", err, "count", len(batch))
		return
	}

	if valErr := core.ValidateAck(ack, len(batch)); valErr != nil {
		slog.Error("ValidateAck failed on CAP batch", "error", valErr)
	}
}

func (c *Controller) enqueueTCFeature(ctx context.Context, feat TCFeature) {
	b, err := json.Marshal(feat)
	if err != nil {
		slog.Error("Failed to marshal TC feature", "error", err)
		return
	}

	c.tcBatchMu.Lock()
	c.tcBatch = append(c.tcBatch, b)
	flushNow := len(c.tcBatch) >= TCBatchLimit
	c.tcBatchMu.Unlock()

	if flushNow {
		c.flushTCBatch(ctx)
	}
}

func (c *Controller) flushTCBatch(ctx context.Context) {
	c.tcBatchMu.Lock()
	if len(c.tcBatch) == 0 {
		c.tcBatchMu.Unlock()
		return
	}
	batch := c.tcBatch
	c.tcBatch = make([]json.RawMessage, 0, TCBatchLimit)
	c.tcBatchMu.Unlock()

	meta := core.PollMeta{
		FetchedAt:    c.now().UTC().Format(time.RFC3339),
		HTTPStatus:   200,
		FeatureCount: len(batch),
		FeedURL:      c.broker.CurrentBroker(),
	}

	ack, err := c.coreClient.Send(ctx, "wis2_data/tc_tracks", meta, batch)
	if err != nil {
		slog.Error("Failed to send TC batch to core", "error", err, "count", len(batch))
		return
	}

	if valErr := core.ValidateAck(ack, len(batch)); valErr != nil {
		slog.Error("ValidateAck failed on TC batch", "error", valErr)
	}
}

func (c *Controller) enqueueObservationFeature(ctx context.Context, feat synop.ObservationFeature) {
	b, err := json.Marshal(feat)
	if err != nil {
		slog.Error("Failed to marshal observation feature", "error", err)
		return
	}

	c.obsBatchMu.Lock()
	if len(c.obsBatch) >= c.obsQueueCap {
		excess := len(c.obsBatch) - c.obsQueueCap + 1
		c.obsBatch = c.obsBatch[excess:]
		c.droppedObservations.Add(int64(excess))
		wis2metrics.RecordDrop("observations")
		slog.Warn("Observation queue cap reached, dropped oldest features", "dropped", excess, "total_dropped", c.droppedObservations.Load())
	}
	c.obsBatch = append(c.obsBatch, b)
	flushNow := len(c.obsBatch) >= ObsBatchLimit
	c.obsBatchMu.Unlock()

	if flushNow {
		c.flushObsBatch(ctx)
	}
}

func (c *Controller) FlushObservations(ctx context.Context) {
	c.flushObsBatch(ctx)
}

func (c *Controller) flushObsBatch(ctx context.Context) {
	c.obsBatchMu.Lock()
	if len(c.obsBatch) == 0 {
		c.obsBatchMu.Unlock()
		return
	}
	limit := ObsBatchLimit
	if len(c.obsBatch) < limit {
		limit = len(c.obsBatch)
	}
	batch := c.obsBatch[:limit]
	c.obsBatch = c.obsBatch[limit:]
	c.obsBatchMu.Unlock()

	meta := core.PollMeta{
		FetchedAt:    c.now().UTC().Format(time.RFC3339),
		HTTPStatus:   200,
		FeatureCount: len(batch),
		FeedURL:      c.broker.CurrentBroker(),
	}

	ack, err := c.coreClient.Send(ctx, "wis2_data/observations", meta, batch)
	if err != nil {
		slog.Error("Failed to send observations batch to core", "error", err, "count", len(batch))
		// Keep memory bounded: requeue failed batch at the head, drop oldest if cap exceeded
		c.obsBatchMu.Lock()
		c.obsBatch = append(batch, c.obsBatch...)
		if len(c.obsBatch) > c.obsQueueCap {
			excess := len(c.obsBatch) - c.obsQueueCap
			c.obsBatch = c.obsBatch[excess:]
			c.droppedObservations.Add(int64(excess))
			wis2metrics.RecordDrop("observations")
			slog.Warn("Observation queue cap exceeded while core is down, dropped oldest features", "dropped", excess, "total_dropped", c.droppedObservations.Load())
		}
		c.obsBatchMu.Unlock()
		return
	}

	if valErr := core.ValidateAck(ack, len(batch)); valErr != nil {
		slog.Error("ValidateAck failed on observations batch", "error", valErr)
	}
}

func (c *Controller) reportHealth(ctx context.Context) {
	windowEnd := c.now()

	c.healthMu.Lock()
	type snapshotItem struct {
		key   HealthKey
		stats HealthCounters
	}
	snapshots := make([]snapshotItem, 0, len(c.health))
	for k, s := range c.health {
		s.mu.Lock()
		snap := s.HealthCounters
		s.HealthCounters = HealthCounters{
			WindowStart: windowEnd,
		}
		s.mu.Unlock()

		snapshots = append(snapshots, snapshotItem{key: k, stats: snap})
	}
	c.healthMu.Unlock()

	features := make([]json.RawMessage, 0, len(snapshots))
	for _, item := range snapshots {
		var lastRec *string
		if item.stats.LastReceivedAt != nil {
			v := item.stats.LastReceivedAt.UTC().Format(time.RFC3339)
			lastRec = &v
		}

		feat := map[string]any{
			"centre_id":        item.key.CentreID,
			"kind":             item.key.Kind,
			"window_start":     item.stats.WindowStart.UTC().Format(time.RFC3339),
			"window_end":       windowEnd.UTC().Format(time.RFC3339),
			"received":         item.stats.Received,
			"duplicates":       item.stats.Duplicates,
			"download_failed":  item.stats.DownloadFailed,
			"decode_failed":    item.stats.DecodeFailed,
			"integrity_failed": item.stats.IntegrityFailed,
			"last_received_at": lastRec,
		}

		b, err := json.Marshal(feat)
		if err == nil {
			features = append(features, b)
		}
	}

	var errStr string
	if !c.broker.IsConnected() {
		errStr = c.broker.LastError()
		if errStr == "" {
			errStr = "disconnected"
		}
	}

	meta := core.PollMeta{
		FetchedAt:    windowEnd.UTC().Format(time.RFC3339),
		HTTPStatus:   200,
		FeatureCount: len(features),
		FeedURL:      c.broker.CurrentBroker(),
		Error:        errStr,
	}

	ack, err := c.coreClient.Send(ctx, "wis2_data/health", meta, features)
	if err != nil {
		slog.Error("Failed to send health report to core", "error", err)
		return
	}

	if valErr := core.ValidateAck(ack, len(features)); valErr != nil {
		slog.Error("ValidateAck failed on health report", "error", valErr)
	}
}

func (c *Controller) downloadPayload(ctx context.Context, rawURL string) ([]byte, error) {
	return c.downloadPayloadWithRetry(ctx, rawURL, true)
}

func (c *Controller) downloadPayloadWithRetry(ctx context.Context, rawURL string, allowRetry bool) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
	if err != nil {
		return nil, cleanError(err)
	}
	req.Header.Set("User-Agent", useragent.Build("MatrixWhale-wis2-adapter", "WIS2_CONTACT_EMAIL", "", nil))
	req.Header.Set("Accept", "application/xml, application/cap+xml, application/geo+json, application/json, */*")

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, cleanError(err)
	}
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusTooManyRequests && allowRetry {
		backoff := poll.ComputeBackoff(resp.Header, 0, 50*time.Millisecond, 10*time.Second)
		if d, ok := poll.ParseRetryAfter(resp.Header); ok {
			backoff = d
		}

		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-c.sleepAfter(backoff):
		}

		return c.downloadPayloadWithRetry(ctx, rawURL, false)
	}

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("http error: %d", resp.StatusCode)
	}

	maxBytes := c.cfg.MaxDownloadBytes
	if maxBytes <= 0 {
		maxBytes = 5 * 1024 * 1024
	}

	body, err := readLimited(resp.Body, maxBytes)
	if err != nil {
		return nil, cleanError(err)
	}

	return body, nil
}

func isBUFR(data []byte) bool {
	return len(data) >= 8 && bytes.Contains(data, []byte("BUFR"))
}

func cleanError(err error) error {
	if err == nil {
		return nil
	}
	var urlErr *url.Error
	if errors.As(err, &urlErr) {
		clean := *urlErr
		if u, parseErr := url.Parse(clean.URL); parseErr == nil {
			u.RawQuery = ""
			clean.URL = u.String()
		}
		return &clean
	}
	return err
}

func (c *Controller) getOrCreateHealth(centreID, kind string) *HealthStats {
	key := HealthKey{CentreID: centreID, Kind: kind}
	c.healthMu.Lock()
	defer c.healthMu.Unlock()

	s, ok := c.health[key]
	if !ok {
		s = &HealthStats{
			HealthCounters: HealthCounters{
				WindowStart: c.now(),
			},
		}
		c.health[key] = s
	}
	return s
}

func (s *HealthStats) recordReceived(now time.Time) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.Received++
	s.LastReceivedAt = &now
}

func (s *HealthStats) recordDuplicate() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.Duplicates++
}

func (s *HealthStats) recordDownloadFailed() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.DownloadFailed++
}

func (s *HealthStats) recordDecodeFailed() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.DecodeFailed++
}

func (s *HealthStats) recordIntegrityFailed() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.IntegrityFailed++
}

func readLimited(r io.Reader, limit int64) ([]byte, error) {
	lr := io.LimitReader(r, limit+1)
	b, err := io.ReadAll(lr)
	if err != nil {
		return nil, err
	}
	if int64(len(b)) > limit {
		return nil, fmt.Errorf("size exceeded %d bytes limit", limit)
	}
	return b, nil
}
