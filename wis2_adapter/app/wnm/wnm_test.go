package wnm

import (
	"crypto/sha512"
	"encoding/base64"
	"os"
	"path/filepath"
	"testing"

	"golang.org/x/crypto/sha3"
)

func TestTopicClassification(t *testing.T) {
	tests := []struct {
		topic            string
		expectedChannel  string
		expectedCentreID string
		expectedKind     string
	}{
		{
			topic:            "cache/a/wis2/eu-eumetnet-warnings/data/core/weather/advisories-warnings",
			expectedChannel:  "cache",
			expectedCentreID: "eu-eumetnet-warnings",
			expectedKind:     "warnings",
		},
		{
			topic:            "origin/a/wis2/eu-eumetnet-warnings/data/core/weather/advisories-warnings/some/sub",
			expectedChannel:  "origin",
			expectedCentreID: "eu-eumetnet-warnings",
			expectedKind:     "warnings",
		},
		{
			topic:            "cache/a/wis2/kz-kazhydromet/data/core/weather/surface-based-observations/synop",
			expectedChannel:  "cache",
			expectedCentreID: "kz-kazhydromet",
			expectedKind:     "synop",
		},
		{
			topic:            "cache/a/wis2/ca-eccc-msc/data/core/weather/prediction/forecast/model/deterministic/trajectory",
			expectedChannel:  "cache",
			expectedCentreID: "ca-eccc-msc",
			expectedKind:     "trajectory",
		},
		{
			topic:            "cache/a/wis2/ca-eccc-msc/data/core/weather/prediction/forecast/model/probabilistic/trajectory",
			expectedChannel:  "cache",
			expectedCentreID: "ca-eccc-msc",
			expectedKind:     "other",
		},
		{
			topic:            "other/a/wis2/foo/bar",
			expectedChannel:  "other",
			expectedCentreID: "foo",
			expectedKind:     "other",
		},
	}

	for _, tc := range tests {
		ch, cid, kind := ClassifyTopic(tc.topic)
		if ch != tc.expectedChannel || cid != tc.expectedCentreID || kind != tc.expectedKind {
			t.Errorf("ClassifyTopic(%q) = (%q, %q, %q); expected (%q, %q, %q)",
				tc.topic, ch, cid, kind, tc.expectedChannel, tc.expectedCentreID, tc.expectedKind)
		}
	}
}

func TestParseRealFixtures(t *testing.T) {
	fixtures := []string{
		"../testdata/cache_eu-eumetnet-warnings_wnm.json",
		"../testdata/origin_eu-eumetnet-warnings_wnm.json",
		"../testdata/synop_1_wnm.json",
		"../testdata/synop_2_wnm.json",
	}

	for _, f := range fixtures {
		data, err := os.ReadFile(filepath.Clean(f))
		if err != nil {
			t.Fatalf("failed to read fixture %s: %v", f, err)
		}

		msg, err := ParseWNM(data)
		if err != nil {
			t.Fatalf("failed to parse fixture %s: %v", f, err)
		}

		if msg.ID == "" {
			t.Errorf("expected non-empty ID for %s", f)
		}
		if msg.Properties.DataID == "" {
			t.Errorf("expected non-empty data_id for %s", f)
		}
		if msg.Properties.PubTime == "" {
			t.Errorf("expected non-empty pubtime for %s", f)
		}
	}
}

func TestIntegrityBothMethods(t *testing.T) {
	payload := []byte("hello WIS2 world payload data 12345")

	// 1. sha512 base64
	sum512 := sha512.Sum512(payload)
	b64_512 := base64.StdEncoding.EncodeToString(sum512[:])
	integ512 := &WNMIntegrity{Method: "sha512", Value: b64_512}
	if !CheckIntegrity(payload, integ512) {
		t.Errorf("sha512 base64 match failed")
	}

	// 2. sha3-512 base64
	sumSha3_512 := sha3.Sum512(payload)
	b64_sha3 := base64.StdEncoding.EncodeToString(sumSha3_512[:])
	integSha3 := &WNMIntegrity{Method: "sha3-512", Value: b64_sha3}
	if !CheckIntegrity(payload, integSha3) {
		t.Errorf("sha3-512 base64 match failed")
	}

	// 3. Normalized method name (e.g. SHA3512)
	integSha3Norm := &WNMIntegrity{Method: "SHA3512", Value: b64_sha3}
	if !CheckIntegrity(payload, integSha3Norm) {
		t.Errorf("normalized SHA3512 match failed")
	}

	// 4. Mismatch
	integBad := &WNMIntegrity{Method: "sha512", Value: "invalid-hash-value"}
	if CheckIntegrity(payload, integBad) {
		t.Errorf("expected mismatch for corrupted hash value")
	}

	// 5. Corrupted data
	corrupted := append(payload, byte('X'))
	if CheckIntegrity(corrupted, integ512) {
		t.Errorf("expected mismatch for corrupted payload")
	}

	// 6. Nil or empty integrity should pass
	if !CheckIntegrity(payload, nil) {
		t.Errorf("expected nil integrity to pass")
	}
	if !CheckIntegrity(payload, &WNMIntegrity{}) {
		t.Errorf("expected empty integrity to pass")
	}
}

func TestGeometryFlattening(t *testing.T) {
	// Feature with Polygon
	featurePolygon := `{
		"type": "Feature",
		"geometry": {
			"type": "Polygon",
			"coordinates": [[[20.0, 30.0], [21.0, 30.0], [21.0, 31.0], [20.0, 30.0]]]
		}
	}`
	mp1, err := FlattenToMultiPolygon([]byte(featurePolygon))
	if err != nil || mp1 == nil {
		t.Fatalf("failed to flatten feature polygon: %v", err)
	}
	if mp1.Type != "MultiPolygon" || len(mp1.Coordinates) != 1 {
		t.Fatalf("expected 1 polygon in MultiPolygon, got: %+v", mp1)
	}

	// FeatureCollection with Polygon + MultiPolygon
	fc := `{
		"type": "FeatureCollection",
		"features": [
			{
				"type": "Feature",
				"geometry": {
					"type": "Polygon",
					"coordinates": [[[1.0, 2.0], [3.0, 4.0], [1.0, 2.0]]]
				}
			},
			{
				"type": "Feature",
				"geometry": {
					"type": "MultiPolygon",
					"coordinates": [
						[[[5.0, 6.0], [7.0, 8.0], [5.0, 6.0]]],
						[[[9.0, 10.0], [11.0, 12.0], [9.0, 10.0]]]
					]
				}
			}
		]
	}`
	mp2, err := FlattenToMultiPolygon([]byte(fc))
	if err != nil || mp2 == nil {
		t.Fatalf("failed to flatten FeatureCollection: %v", err)
	}
	if mp2.Type != "MultiPolygon" || len(mp2.Coordinates) != 3 {
		t.Fatalf("expected 3 polygons in MultiPolygon, got %d", len(mp2.Coordinates))
	}

	// Standalone Polygon
	poly := `{
		"type": "Polygon",
		"coordinates": [[[0.0, 0.0], [1.0, 0.0], [1.0, 1.0], [0.0, 0.0]]]
	}`
	mp3, err := FlattenToMultiPolygon([]byte(poly))
	if err != nil || mp3 == nil || len(mp3.Coordinates) != 1 {
		t.Fatalf("failed to flatten standalone Polygon")
	}

	// Standalone MultiPolygon
	mpoly := `{
		"type": "MultiPolygon",
		"coordinates": [
			[[[0.0, 0.0], [1.0, 0.0], [0.0, 0.0]]],
			[[[2.0, 2.0], [3.0, 2.0], [2.0, 2.0]]]
		]
	}`
	mp4, err := FlattenToMultiPolygon([]byte(mpoly))
	if err != nil || mp4 == nil || len(mp4.Coordinates) != 2 {
		t.Fatalf("failed to flatten standalone MultiPolygon")
	}
}

func TestResolveAreaKey(t *testing.T) {
	objID := "area-obj-123"
	href := "https://example.com/api/archive/features/c15c.geojson?X-Redacted=1"

	// ObjectID wins
	k1 := ResolveAreaKey(&objID, href)
	if k1 == nil || *k1 != "area-obj-123" {
		t.Errorf("expected area-obj-123, got: %v", k1)
	}

	// Fallback to path without query
	k2 := ResolveAreaKey(nil, href)
	if k2 == nil || *k2 != "/api/archive/features/c15c.geojson" {
		t.Errorf("expected URL path without query, got: %v", k2)
	}
}

func TestFormatRFC3339(t *testing.T) {
	tsWithOffset := "2026-09-25T11:44:00+00:00"
	formatted, err := FormatRFC3339(tsWithOffset)
	if err != nil {
		t.Fatalf("failed to format: %v", err)
	}
	if formatted != "2026-09-25T11:44:00Z" {
		t.Errorf("expected UTC RFC3339, got: %s", formatted)
	}
}

func TestFindDataFallbackLinks(t *testing.T) {
	links := []WNMLink{
		{Rel: "canonical", Href: "https://example.com/canonical.xml", Type: "application/xml"},
		{Rel: "license", Href: "https://example.com/license", Type: "text/html"},
		{Rel: "geometry", Href: "https://example.com/geom.geojson", Type: "application/geo+json"},
		{Rel: "json", Href: "https://example.com/data.json", Type: "application/json"},
		{Rel: "describedby", Href: "https://example.com/meta", Type: "text/plain"},
		{Rel: "alternate", Href: "https://example.com/bufr.bin", Type: "application/grib"}, // Unreliable type in the wild!
		{Rel: "via", Href: "https://example.com/via.xml", Type: ""},
		{Rel: "xml", Href: "https://example.com/data.xml", Type: "application/xml"},
		{Rel: "alternate", Href: "", Type: "application/xml"}, // Empty href should be skipped
	}

	fallbacks := FindDataFallbackLinks(links)
	if len(fallbacks) != 3 {
		t.Fatalf("expected 3 fallback links, got %d", len(fallbacks))
	}
	if fallbacks[0].Href != "https://example.com/bufr.bin" || fallbacks[0].Type != "application/grib" {
		t.Errorf("expected alternate link with application/grib preserved, got: %+v", fallbacks[0])
	}
	if fallbacks[1].Href != "https://example.com/via.xml" {
		t.Errorf("expected via link, got: %+v", fallbacks[1])
	}
	if fallbacks[2].Href != "https://example.com/data.xml" {
		t.Errorf("expected xml link, got: %+v", fallbacks[2])
	}
}

func TestWNMMessageGeometryParsing(t *testing.T) {
	raw := `{
		"id": "test-geom-notif",
		"type": "Feature",
		"geometry": {
			"type": "Polygon",
			"coordinates": [[[10.0, 20.0], [10.0, 30.0], [20.0, 30.0], [20.0, 20.0], [10.0, 20.0]]]
		},
		"properties": {
			"data_id": "test-data-1",
			"pubtime": "2026-09-25T12:00:00Z"
		}
	}`

	msg, err := ParseWNM([]byte(raw))
	if err != nil {
		t.Fatalf("failed to parse WNM: %v", err)
	}
	if len(msg.Geometry) == 0 {
		t.Fatalf("expected non-empty Geometry in WNM")
	}

	mp, err := FlattenToMultiPolygon(msg.Geometry)
	if err != nil || mp == nil {
		t.Fatalf("failed to flatten WNM geometry: %v", err)
	}
	if mp.Type != "MultiPolygon" || len(mp.Coordinates) != 1 {
		t.Errorf("expected 1 polygon in MultiPolygon, got: %+v", mp)
	}
}
