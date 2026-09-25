package synop

import (
	"encoding/base64"
	"encoding/json"
	"math"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"wis2_adapter/bufr"
)

func TestExtractObservationsGoldenSamples(t *testing.T) {
	tests := []struct {
		name                 string
		filename             string
		expectFeatures       int
		expectRejected       int
		expectedStationID    string
		expectedStationName  *string
		expectedLat          float64
		expectedLon          float64
		expectedElev         *float64
		expectedObservedAt   string
		expectedWindSpeedMS  *float64
		expectedGustMS       *float64
		expectedGustPeriod   *int
		expectedMSLPPa       *float64
		expectedPrecipCount  int
		expectedPrecipSample *PrecipItem
	}{
		{
			name:                "UK MetOffice (WIGOS ID, 60min gust, positive period)",
			filename:            "synop_uk_metoffice.bufr",
			expectFeatures:      1,
			expectRejected:      0,
			expectedStationID:   "0-826-0-79",
			expectedStationName: ptr("DONNA NOOK NO 2 AUTO"),
			expectedLat:         53.47483,
			expectedLon:         0.15287,
			expectedElev:        ptr(8.0),
			expectedObservedAt:  "2026-09-25T12:00:00Z",
			expectedWindSpeedMS: ptr(5.3),
			expectedGustMS:      ptr(8.2),
			expectedGustPeriod:  intPtr(60),
			expectedMSLPPa:      ptr(101840.0),
			expectedPrecipCount: 0,
		},
		{
			name:                "Singapore MSS (block+station ID, large values)",
			filename:            "synop_sg_mss.bufr",
			expectFeatures:      1,
			expectRejected:      0,
			expectedStationID:   "0-20000-0-48698",
			expectedStationName: ptr("Singapore Changi"),
			expectedLat:         1.3679,
			expectedLon:         103.982,
			expectedElev:        ptr(14.0),
			expectedObservedAt:  "2026-09-25T13:00:00Z",
			expectedWindSpeedMS: ptr(241.1),
			expectedGustMS:      ptr(408.7),
			expectedGustPeriod:  nil,
			expectedMSLPPa:      ptr(101180.0),
			expectedPrecipCount: 1,
			expectedPrecipSample: &PrecipItem{
				PeriodH: 24.0,
				MM:      1469.9,
			},
		},
		{
			name:                "JMA Syowa (block+station ID, no WIGOS)",
			filename:            "synop_jp_jma.bufr",
			expectFeatures:      1,
			expectRejected:      0,
			expectedStationID:   "0-20000-0-89532",
			expectedStationName: ptr("SYOWA"),
			expectedLat:         -69.00527,
			expectedLon:         39.58111,
			expectedElev:        ptr(29.1),
			expectedObservedAt:  "2026-09-25T12:00:00Z",
			expectedWindSpeedMS: ptr(2.1),
			expectedGustMS:      nil,
			expectedGustPeriod:  nil,
			expectedMSLPPa:      ptr(96940.0),
			expectedPrecipCount: 0,
		},
		{
			name:                "MeteoFrance (5 precip periods, 60min gust)",
			filename:            "synop_fr_meteofrance.bufr",
			expectFeatures:      1,
			expectRejected:      0,
			expectedStationID:   "0-20000-0-07586",
			expectedStationName: ptr("CARPENTRAS"),
			expectedLat:         44.08367,
			expectedLon:         5.05833,
			expectedElev:        ptr(98.0),
			expectedObservedAt:  "2026-09-25T12:00:00Z",
			expectedWindSpeedMS: ptr(2.3),
			expectedGustMS:      ptr(5.2),
			expectedGustPeriod:  intPtr(60),
			expectedMSLPPa:      ptr(101820.0),
			expectedPrecipCount: 5,
			expectedPrecipSample: &PrecipItem{
				PeriodH: 1.0,
				MM:      0.0,
			},
		},
		{
			name:                "China CMA (precip 24h + 12h + 6h, 720min gust)",
			filename:            "synop_cn_cma.bufr",
			expectFeatures:      1,
			expectRejected:      0,
			expectedStationID:   "0-20000-0-50353",
			expectedStationName: ptr("HUMA"),
			expectedLat:         51.73,
			expectedLon:         126.63,
			expectedElev:        ptr(175.6),
			expectedObservedAt:  "2026-09-25T06:00:00Z",
			expectedWindSpeedMS: ptr(2.3),
			expectedGustMS:      ptr(5.5),
			expectedGustPeriod:  intPtr(720),
			expectedMSLPPa:      ptr(101470.0),
			expectedPrecipCount: 3,
			expectedPrecipSample: &PrecipItem{
				PeriodH: 24.0,
				MM:      0.0,
			},
		},
		{
			name:                "Brazil INMET (WIGOS ID, 60min gust, 1h precip from 4025)",
			filename:            "synop_br_inmet.bufr",
			expectFeatures:      1,
			expectRejected:      0,
			expectedStationID:   "0-76-0-1600303000000495",
			expectedStationName: ptr("MACAPA"),
			expectedLat:         0.035,
			expectedLon:         -51.08889,
			expectedElev:        ptr(16.6),
			expectedObservedAt:  "2026-09-25T11:00:00Z",
			expectedWindSpeedMS: ptr(2.3),
			expectedGustMS:      ptr(6.4),
			expectedGustPeriod:  intPtr(60),
			expectedMSLPPa:      ptr(101380.0),
			expectedPrecipCount: 1,
			expectedPrecipSample: &PrecipItem{
				PeriodH: 1.0,
				MM:      0.0,
			},
		},
		{
			name:                "Belgidromet Compressed (compressed format, WIGOS ID)",
			filename:            "synop_by_belgidromet_compressed.bufr",
			expectFeatures:      1,
			expectRejected:      0,
			expectedStationID:   "0-20000-0-26554",
			expectedStationName: ptr("VERHNEDVINSK"),
			expectedLat:         55.8192,
			expectedLon:         27.9373,
			expectedElev:        ptr(132.3),
			expectedObservedAt:  "2026-09-25T12:00:00Z",
			expectedWindSpeedMS: ptr(4.0),
			expectedGustMS:      nil,
			expectedGustPeriod:  nil,
			expectedMSLPPa:      ptr(101570.0),
			expectedPrecipCount: 0,
		},
		{
			name:                "Roshydromet (precip 12h, block+station ID)",
			filename:            "synop_ru_roshydromet.bufr",
			expectFeatures:      1,
			expectRejected:      0,
			expectedStationID:   "0-20000-0-21931",
			expectedStationName: ptr("JUBILEJNAJA"),
			expectedLat:         70.7667,
			expectedLon:         136.2167,
			expectedElev:        ptr(24.4),
			expectedObservedAt:  "2026-09-25T09:00:00Z",
			expectedWindSpeedMS: ptr(4.0),
			expectedGustMS:      nil,
			expectedGustPeriod:  nil,
			expectedMSLPPa:      ptr(100370.0),
			expectedPrecipCount: 1,
			expectedPrecipSample: &PrecipItem{
				PeriodH: 12.0,
				MM:      0.0,
			},
		},
		{
			name:           "Kazhydromet Compressed (missing lat/lon -> rejected)",
			filename:       "synop_kz_kazhydromet_compressed.bufr",
			expectFeatures: 0,
			expectRejected: 1,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			path := filepath.Join("..", "bufr", "testdata", tt.filename)
			data, err := os.ReadFile(path)
			if err != nil {
				t.Fatalf("failed to read test file %s: %v", path, err)
			}

			msgs, errs := bufr.Decode(data)
			if len(msgs) == 0 {
				t.Fatalf("no BUFR messages decoded from %s, errs: %v", tt.filename, errs)
			}

			var allFeatures []ObservationFeature
			totalRejected := 0

			for _, msg := range msgs {
				feats, rej := ExtractObservations(msg, "data-id-1", "test-centre", "2026-09-25T12:00:00Z")
				allFeatures = append(allFeatures, feats...)
				totalRejected += len(rej)
			}

			if len(allFeatures) != tt.expectFeatures {
				t.Errorf("features count mismatch: expected %d, got %d", tt.expectFeatures, len(allFeatures))
			}
			if totalRejected != tt.expectRejected {
				t.Errorf("rejected count mismatch: expected %d, got %d", tt.expectRejected, totalRejected)
			}

			if tt.expectFeatures > 0 {
				f := allFeatures[0]
				if f.StationID != tt.expectedStationID {
					t.Errorf("station_id mismatch: expected %s, got %s", tt.expectedStationID, f.StationID)
				}
				if tt.expectedStationName != nil {
					if f.StationName == nil || *f.StationName != *tt.expectedStationName {
						t.Errorf("station_name mismatch: expected %v, got %v", *tt.expectedStationName, f.StationName)
					}
				}
				if !approxEqual(f.Lat, tt.expectedLat) {
					t.Errorf("lat mismatch: expected %f, got %f", tt.expectedLat, f.Lat)
				}
				if !approxEqual(f.Lon, tt.expectedLon) {
					t.Errorf("lon mismatch: expected %f, got %f", tt.expectedLon, f.Lon)
				}
				if tt.expectedElev != nil {
					if f.ElevationM == nil || !approxEqual(*f.ElevationM, *tt.expectedElev) {
						t.Errorf("elevation mismatch: expected %v, got %v", *tt.expectedElev, deref(f.ElevationM))
					}
				}
				if f.ObservedAt != tt.expectedObservedAt {
					t.Errorf("observed_at mismatch: expected %s, got %s", tt.expectedObservedAt, f.ObservedAt)
				}
				if tt.expectedWindSpeedMS != nil {
					if f.WindSpeedMS == nil || !approxEqual(*f.WindSpeedMS, *tt.expectedWindSpeedMS) {
						t.Errorf("wind_speed_ms mismatch: expected %v, got %v", *tt.expectedWindSpeedMS, deref(f.WindSpeedMS))
					}
				}
				if tt.expectedGustMS != nil {
					if f.GustMS == nil || !approxEqual(*f.GustMS, *tt.expectedGustMS) {
						t.Errorf("gust_ms mismatch: expected %v, got %v", *tt.expectedGustMS, deref(f.GustMS))
					}
					if tt.expectedGustPeriod != nil {
						if f.GustPeriodMin == nil || *f.GustPeriodMin != *tt.expectedGustPeriod {
							t.Errorf("gust_period_min mismatch: expected %v, got %v", *tt.expectedGustPeriod, deref(f.GustPeriodMin))
						}
					}
				} else {
					if f.GustMS != nil {
						t.Errorf("expected nil gust_ms, got %v", *f.GustMS)
					}
				}
				if tt.expectedMSLPPa != nil {
					if f.MSLPPa == nil || !approxEqual(*f.MSLPPa, *tt.expectedMSLPPa) {
						t.Errorf("mslp_pa mismatch: expected %v, got %v", *tt.expectedMSLPPa, deref(f.MSLPPa))
					}
				}
				if len(f.Precip) != tt.expectedPrecipCount {
					t.Errorf("precip count mismatch: expected %d, got %d (%+v)", tt.expectedPrecipCount, len(f.Precip), f.Precip)
				}
				if tt.expectedPrecipSample != nil && len(f.Precip) > 0 {
					p0 := f.Precip[0]
					if !approxEqual(p0.PeriodH, tt.expectedPrecipSample.PeriodH) || !approxEqual(p0.MM, tt.expectedPrecipSample.MM) {
						t.Errorf("precip sample mismatch: expected %+v, got %+v", *tt.expectedPrecipSample, p0)
					}
				}

				// Verify JSON contract serialization (nulls not omitted, non-empty contract keys)
				b, err := json.Marshal(f)
				if err != nil {
					t.Fatalf("json.Marshal failed: %v", err)
				}
				var m map[string]any
				if err := json.Unmarshal(b, &m); err != nil {
					t.Fatalf("json.Unmarshal failed: %v", err)
				}
				requiredKeys := []string{
					"data_id", "centre_id", "pubtime", "station_id", "station_name",
					"lat", "lon", "elevation_m", "observed_at", "wind_speed_ms",
					"gust_ms", "gust_period_min", "precip", "mslp_pa",
				}
				for _, k := range requiredKeys {
					if _, ok := m[k]; !ok {
						t.Errorf("missing contract key in JSON: %s", k)
					}
				}
			}
		})
	}
}

func TestExtractObservationSyntheticEdgeCases(t *testing.T) {
	t.Run("WIGOS ID precedence over block+station", func(t *testing.T) {
		values := []bufr.Value{
			valFloat(1125, 0),
			valFloat(1126, 826),
			valFloat(1127, 0),
			valString(1128, "12345"),
			valFloat(1001, 3),
			valFloat(1002, 45),
			valFloat(5001, 10.0),
			valFloat(6001, 20.0),
			valFloat(4001, 2026),
			valFloat(4002, 9),
			valFloat(4003, 25),
			valFloat(4004, 12),
			valFloat(4005, 0),
		}
		feat, ok := ExtractObservation(values, "d", "c", "p")
		if !ok || feat == nil {
			t.Fatalf("expected valid feature")
		}
		if feat.StationID != "0-826-0-12345" {
			t.Errorf("expected WIGOS id, got: %s", feat.StationID)
		}
	})

	t.Run("Block and station 2+3 digit formatting", func(t *testing.T) {
		values := []bufr.Value{
			valFloat(1001, 3),
			valFloat(1002, 45),
			valFloat(5001, 10.0),
			valFloat(6001, 20.0),
			valFloat(4001, 2026),
			valFloat(4002, 9),
			valFloat(4003, 25),
			valFloat(4004, 12),
			valFloat(4005, 0),
		}
		feat, ok := ExtractObservation(values, "d", "c", "p")
		if !ok || feat == nil {
			t.Fatalf("expected valid feature")
		}
		if feat.StationID != "0-20000-0-03045" {
			t.Errorf("expected 0-20000-0-03045, got: %s", feat.StationID)
		}
	})

	t.Run("Missing lat or lon rejected", func(t *testing.T) {
		values := []bufr.Value{
			valFloat(1001, 3),
			valFloat(1002, 45),
			valFloat(5001, 10.0),
			// missing 6001
			valFloat(4001, 2026),
			valFloat(4002, 9),
			valFloat(4003, 25),
			valFloat(4004, 12),
			valFloat(4005, 0),
		}
		feat, ok := ExtractObservation(values, "d", "c", "p")
		if ok || feat != nil {
			t.Errorf("expected rejection when lon is missing")
		}
	})

	t.Run("Missing time rejected", func(t *testing.T) {
		values := []bufr.Value{
			valFloat(1001, 3),
			valFloat(1002, 45),
			valFloat(5001, 10.0),
			valFloat(6001, 20.0),
			valFloat(4001, 2026),
			valFloat(4002, 9),
			// missing day 4003
			valFloat(4004, 12),
			valFloat(4005, 0),
		}
		feat, ok := ExtractObservation(values, "d", "c", "p")
		if ok || feat != nil {
			t.Errorf("expected rejection when time is incomplete")
		}
	})

	t.Run("Missing station_id rejected", func(t *testing.T) {
		values := []bufr.Value{
			valFloat(5001, 10.0),
			valFloat(6001, 20.0),
			valFloat(4001, 2026),
			valFloat(4002, 9),
			valFloat(4003, 25),
			valFloat(4004, 12),
			valFloat(4005, 0),
		}
		feat, ok := ExtractObservation(values, "d", "c", "p")
		if ok || feat != nil {
			t.Errorf("expected rejection when station_id is absent")
		}
	})

	t.Run("Negative time periods converted to positive minutes and hours", func(t *testing.T) {
		values := []bufr.Value{
			valFloat(1001, 12),
			valFloat(1002, 345),
			valFloat(5001, 10.0),
			valFloat(6001, 20.0),
			valFloat(4001, 2026),
			valFloat(4002, 9),
			valFloat(4003, 25),
			valFloat(4004, 12),
			valFloat(4005, 0),
			valFloat(4025, -10.0), // 10 minutes past
			valFloat(11041, 15.5), // gust
			valFloat(4024, -3.0),  // 3 hours past
			valFloat(13011, 25.0), // precip
		}
		feat, ok := ExtractObservation(values, "d", "c", "p")
		if !ok || feat == nil {
			t.Fatalf("expected valid feature")
		}
		if feat.GustMS == nil || *feat.GustMS != 15.5 {
			t.Errorf("gust_ms mismatch: %v", feat.GustMS)
		}
		if feat.GustPeriodMin == nil || *feat.GustPeriodMin != 10 {
			t.Errorf("gust_period_min mismatch: expected 10, got %v", feat.GustPeriodMin)
		}
		if len(feat.Precip) != 1 {
			t.Fatalf("precip count mismatch: %d", len(feat.Precip))
		}
		if feat.Precip[0].PeriodH != 3.0 || feat.Precip[0].MM != 25.0 {
			t.Errorf("precip mismatch: %+v", feat.Precip[0])
		}
	})

	t.Run("Values missing serialize to null in JSON", func(t *testing.T) {
		values := []bufr.Value{
			valFloat(1001, 12),
			valFloat(1002, 345),
			valFloat(5001, 10.0),
			valFloat(6001, 20.0),
			valFloat(4001, 2026),
			valFloat(4002, 9),
			valFloat(4003, 25),
			valFloat(4004, 12),
			valFloat(4005, 0),
		}
		feat, ok := ExtractObservation(values, "d", "c", "p")
		if !ok || feat == nil {
			t.Fatalf("expected valid feature")
		}
		b, err := json.Marshal(feat)
		if err != nil {
			t.Fatalf("marshal failed: %v", err)
		}
		jsonStr := string(b)
		if !strings.Contains(jsonStr, `"station_name":null`) {
			t.Errorf("expected station_name:null, got: %s", jsonStr)
		}
		if !strings.Contains(jsonStr, `"elevation_m":null`) {
			t.Errorf("expected elevation_m:null, got: %s", jsonStr)
		}
		if !strings.Contains(jsonStr, `"wind_speed_ms":null`) {
			t.Errorf("expected wind_speed_ms:null, got: %s", jsonStr)
		}
		if !strings.Contains(jsonStr, `"gust_ms":null`) {
			t.Errorf("expected gust_ms:null, got: %s", jsonStr)
		}
		if !strings.Contains(jsonStr, `"gust_period_min":null`) {
			t.Errorf("expected gust_period_min:null, got: %s", jsonStr)
		}
		if !strings.Contains(jsonStr, `"mslp_pa":null`) {
			t.Errorf("expected mslp_pa:null, got: %s", jsonStr)
		}
		if !strings.Contains(jsonStr, `"precip":[]`) {
			t.Errorf("expected precip:[], got: %s", jsonStr)
		}
	})

	t.Run("Extract from synop_1_wnm.json inline BUFR", func(t *testing.T) {
		path := filepath.Join("..", "testdata", "synop_1_wnm.json")
		b, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("read file failed: %v", err)
		}
		var wnm struct {
			Properties struct {
				DataID  string `json:"data_id"`
				PubTime string `json:"pubtime"`
				Content struct {
					Encoding string `json:"encoding"`
					Value    string `json:"value"`
				} `json:"content"`
			} `json:"properties"`
		}
		if err := json.Unmarshal(b, &wnm); err != nil {
			t.Fatalf("unmarshal wnm failed: %v", err)
		}
		raw, err := base64.StdEncoding.DecodeString(wnm.Properties.Content.Value)
		if err != nil {
			t.Fatalf("base64 decode failed: %v", err)
		}
		msgs, errs := bufr.Decode(raw)
		if len(msgs) == 0 {
			t.Fatalf("bufr.Decode failed: %v", errs)
		}
		feats, rej := ExtractObservations(msgs[0], wnm.Properties.DataID, "kz-kazhydromet", wnm.Properties.PubTime)
		if len(feats) != 1 || len(rej) != 0 {
			t.Fatalf("expected 1 feature, 0 rejected, got feats=%d rej=%d", len(feats), len(rej))
		}
		f := feats[0]
		if f.StationID != "0-20000-0-35793" {
			t.Errorf("station_id mismatch: %s", f.StationID)
		}
		if !approxEqual(f.Lat, 47.2167) || !approxEqual(f.Lon, 73.35) {
			t.Errorf("lat/lon mismatch: %f, %f", f.Lat, f.Lon)
		}
	})
}

func TestSynopExtractionRegressionCyDomAndIlIms(t *testing.T) {
	t.Run("cy-dom sample extraction", func(t *testing.T) {
		data, err := os.ReadFile(filepath.Join("testdata", "cy_dom.bufr"))
		if err != nil {
			t.Fatalf("failed reading testdata cy_dom.bufr: %v", err)
		}
		msgs, errs := bufr.Decode(data)
		if len(msgs) != 1 || errs[0] != nil {
			t.Fatalf("decode failed: msgs=%d, errs=%v", len(msgs), errs)
		}
		if len(msgs[0].Subsets) != 54 {
			t.Fatalf("expected 54 subsets, got %d", len(msgs[0].Subsets))
		}
		feats, rejections := ExtractObservations(msgs[0], "test-cy-id", "cy-dom", "2026-09-25T12:00:00Z")
		if len(rejections) != 0 {
			t.Errorf("expected 0 rejected subsets, got %d: %v", len(rejections), rejections)
		}
		if len(feats) != 54 {
			t.Fatalf("expected 54 extracted features, got %d", len(feats))
		}
		// Verify first feature
		f0 := feats[0]
		if f0.StationID != "0-196-0-01727" {
			t.Errorf("f0 StationID mismatch: got %s, want 0-196-0-01727", f0.StationID)
		}
		if f0.StationName == nil || *f0.StationName != "FANEROMENI" {
			t.Errorf("f0 StationName mismatch: got %v, want FANEROMENI", f0.StationName)
		}
		if !approxEqual(f0.Lat, 34.9116) || !approxEqual(f0.Lon, 33.63006) {
			t.Errorf("f0 Lat/Lon mismatch: got (%f, %f), want (34.9116, 33.63006)", f0.Lat, f0.Lon)
		}
		if f0.ObservedAt != "2026-09-25T11:50:00Z" {
			t.Errorf("f0 ObservedAt mismatch: got %s, want 2026-09-25T11:50:00Z", f0.ObservedAt)
		}
		// Verify second feature
		f1 := feats[1]
		if f1.StationID != "0-196-0-01101" {
			t.Errorf("f1 StationID mismatch: got %s, want 0-196-0-01101", f1.StationID)
		}
		if f1.StationName == nil || *f1.StationName != "AMARGETI" {
			t.Errorf("f1 StationName mismatch: got %v, want AMARGETI", f1.StationName)
		}
		if !approxEqual(f1.Lat, 34.82612) || !approxEqual(f1.Lon, 32.5889) {
			t.Errorf("f1 Lat/Lon mismatch: got (%f, %f), want (34.82612, 32.5889)", f1.Lat, f1.Lon)
		}
	})

	t.Run("il-ims sample extraction", func(t *testing.T) {
		data, err := os.ReadFile(filepath.Join("testdata", "il_ims.bufr"))
		if err != nil {
			t.Fatalf("failed reading testdata il_ims.bufr: %v", err)
		}
		msgs, errs := bufr.Decode(data)
		if len(msgs) != 1 || errs[0] != nil {
			t.Fatalf("decode failed: msgs=%d, errs=%v", len(msgs), errs)
		}
		if len(msgs[0].Subsets) != 82 {
			t.Fatalf("expected 82 subsets, got %d", len(msgs[0].Subsets))
		}
		feats, rejections := ExtractObservations(msgs[0], "test-il-id", "il-ims", "2026-09-25T12:00:00Z")
		if len(rejections) != 0 {
			t.Errorf("expected 0 rejected subsets, got %d: %v", len(rejections), rejections)
		}
		if len(feats) != 82 {
			t.Fatalf("expected 82 extracted features, got %d", len(feats))
		}
		// Verify first feature
		f0 := feats[0]
		if f0.StationID != "0-376-0-511" {
			t.Errorf("f0 StationID mismatch: got %s, want 0-376-0-511", f0.StationID)
		}
		if f0.StationName == nil || *f0.StationName != "Afeq" {
			t.Errorf("f0 StationName mismatch: got %v, want Afeq", f0.StationName)
		}
		if !approxEqual(f0.Lat, 32.8466) || !approxEqual(f0.Lon, 35.1123) {
			t.Errorf("f0 Lat/Lon mismatch: got (%f, %f), want (32.8466, 35.1123)", f0.Lat, f0.Lon)
		}
		if f0.ObservedAt != "2026-09-25T12:00:00Z" {
			t.Errorf("f0 ObservedAt mismatch: got %s, want 2026-09-25T12:00:00Z", f0.ObservedAt)
		}
		if f0.ElevationM == nil || !approxEqual(*f0.ElevationM, 10.0) {
			t.Errorf("f0 ElevationM mismatch: got %v, want 10.0", f0.ElevationM)
		}
	})
}

func valFloat(code int, v float64) bufr.Value {
	return bufr.Value{
		Descriptor: bufr.NewDescriptor(code),
		Float:      &v,
	}
}

func valString(code int, s string) bufr.Value {
	return bufr.Value{
		Descriptor: bufr.NewDescriptor(code),
		String:     &s,
	}
}

func ptr[T any](v T) *T {
	return &v
}

func intPtr(v int) *int {
	return &v
}

func approxEqual(a, b float64) bool {
	return math.Abs(a-b) < 1e-3
}

func deref[T any](p *T) any {
	if p == nil {
		return nil
	}
	return *p
}
