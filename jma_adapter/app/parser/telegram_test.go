package parser

import (
	"encoding/json"
	"errors"
	"math"
	"os"
	"strings"
	"testing"
)

func TestParseISO6709(t *testing.T) {
	// Standard earthquake decimal degrees + depth
	lat, lon, depth, hasDepth, err := ParseISO6709("+35.68+139.76-10000/")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if math.Abs(lat-35.68) > 1e-4 || math.Abs(lon-139.76) > 1e-4 {
		t.Fatalf("lat/lon mismatch: %f, %f", lat, lon)
	}
	if !hasDepth || math.Abs(depth-10.0) > 1e-4 {
		t.Fatalf("depth mismatch: %f, expected 10.0km", depth)
	}

	// Degree and decimal minutes format from volcanic/quake report
	lat, lon, depth, hasDepth, err = ParseISO6709("+3135.55+13039.40-1117/")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	expectedLat := 31.0 + (35.55 / 60.0)
	expectedLon := 130.0 + (39.40 / 60.0)
	if math.Abs(lat-expectedLat) > 1e-4 || math.Abs(lon-expectedLon) > 1e-4 {
		t.Fatalf("deg/min lat/lon mismatch: got %f, %f, expected %f, %f", lat, lon, expectedLat, expectedLon)
	}
	if !hasDepth || math.Abs(depth-1.117) > 1e-4 {
		t.Fatalf("depth mismatch: %f", depth)
	}

	// Integer degree-minutes format (lat: 35 deg 30 min, lon: 139 deg 45 min)
	lat, lon, _, _, err = ParseISO6709("+3530+13945-5000/")
	if err != nil {
		t.Fatalf("unexpected error on integer deg-min: %v", err)
	}
	if math.Abs(lat-35.5) > 1e-4 || math.Abs(lon-(139.0+45.0/60.0)) > 1e-4 {
		t.Fatalf("integer deg/min mismatch: %f, %f", lat, lon)
	}

	// Minutes >= 60 rejected
	if _, _, _, _, err := ParseISO6709("+3560+13945-5000/"); !errors.Is(err, ErrInvalidCoordinates) {
		t.Fatalf("expected ErrInvalidCoordinates for minutes == 60, got %v", err)
	}
	if _, _, _, _, err := ParseISO6709("+3530+13965-5000/"); !errors.Is(err, ErrInvalidCoordinates) {
		t.Fatalf("expected ErrInvalidCoordinates for lon minutes >= 60, got %v", err)
	}

	// Surface depth -0/
	lat, lon, depth, hasDepth, err = ParseISO6709("+35.0+140.0-0/")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !hasDepth || depth != 0.0 {
		t.Fatalf("surface depth mismatch: %f", depth)
	}

	// Positive hypocenter altitude rejected (never fabricate 0 depth)
	if _, _, _, _, err := ParseISO6709("+35.0+140.0+1000/"); !errors.Is(err, ErrInvalidCoordinates) {
		t.Fatalf("expected ErrInvalidCoordinates for positive altitude, got %v", err)
	}

	// Out of range coordinates
	if _, _, _, _, err := ParseISO6709("+95.0+140.0-10000/"); !errors.Is(err, ErrInvalidCoordinates) {
		t.Fatalf("expected ErrInvalidCoordinates for lat > 90, got %v", err)
	}
	if _, _, _, _, err := ParseISO6709("+35.0+200.0-10000/"); !errors.Is(err, ErrInvalidCoordinates) {
		t.Fatalf("expected ErrInvalidCoordinates for lon > 180, got %v", err)
	}

	// Malformed strings
	if _, _, _, _, err := ParseISO6709("garbage"); !errors.Is(err, ErrInvalidCoordinates) {
		t.Fatalf("expected ErrInvalidCoordinates for garbage, got %v", err)
	}
}

func TestParseEarthquakeOfficialFixture(t *testing.T) {
	fixtureBytes, err := os.ReadFile("testdata/vxse53_earthquake.xml")
	if err != nil {
		t.Fatalf("read testdata/vxse53_earthquake.xml failed: %v", err)
	}

	url := "https://www.data.jma.go.jp/developer/xml/data/20260920074051_0_VXSE53_270000.xml"
	msg, err := ParseTelegram(url, fixtureBytes)
	if err != nil {
		t.Fatalf("ParseTelegram failed: %v", err)
	}

	if msg.Identifier != "20260920074051_0_VXSE53_270000" {
		t.Fatalf("identifier mismatch: %s", msg.Identifier)
	}
	if msg.Status != "通常" {
		t.Fatalf("status mismatch: %s", msg.Status)
	}
	if msg.Sent != "2026-09-20T07:40:51Z" {
		t.Fatalf("sent timestamp mismatch: %s", msg.Sent)
	}
	if msg.SeriesKey == nil || *msg.SeriesKey != "震源・震度に関する情報:大阪管区気象台:通常:20260920163732" {
		t.Fatalf("series_key mismatch: %v", msg.SeriesKey)
	}
	if msg.Earthquake == nil {
		t.Fatalf("expected earthquake populated, got nil")
	}
	if *msg.Earthquake.Place != "奄美大島近海" {
		t.Fatalf("place mismatch: %s", *msg.Earthquake.Place)
	}
	if math.Abs(float64(*msg.Earthquake.Latitude)-27.6) > 1e-4 {
		t.Fatalf("latitude mismatch: %f", *msg.Earthquake.Latitude)
	}
	if math.Abs(float64(*msg.Earthquake.Longitude)-128.8) > 1e-4 {
		t.Fatalf("longitude mismatch: %f", *msg.Earthquake.Longitude)
	}
	if *msg.Earthquake.DepthKM != 10.0 {
		t.Fatalf("depth mismatch: %f", *msg.Earthquake.DepthKM)
	}
	if *msg.Earthquake.Magnitude != 2.6 {
		t.Fatalf("magnitude mismatch: %f", *msg.Earthquake.Magnitude)
	}
	if *msg.Earthquake.MaxIntensity != "1" {
		t.Fatalf("max_intensity mismatch: %s", *msg.Earthquake.MaxIntensity)
	}

	jsonBytes, err := json.Marshal(msg.Earthquake)
	if err != nil {
		t.Fatalf("marshal earthquake: %v", err)
	}
	if !strings.Contains(string(jsonBytes), `"depth_km":10.0`) {
		t.Fatalf("expected depth_km formatted with decimal point: %s", string(jsonBytes))
	}

	// Message-level wire JSON verification: official earthquake without Head.Information
	// must serialize areas:[] and alerts:[], NEVER areas:null or alerts:null
	msgBytes, err := json.Marshal(msg)
	if err != nil {
		t.Fatalf("marshal message: %v", err)
	}
	msgStr := string(msgBytes)
	if !strings.Contains(msgStr, `"areas":[]`) {
		t.Fatalf("expected areas:[] on earthquake, got: %s", msgStr)
	}
	if strings.Contains(msgStr, `"areas":null`) {
		t.Fatalf("areas must never serialize to null: %s", msgStr)
	}
	if !strings.Contains(msgStr, `"alerts":[]`) {
		t.Fatalf("expected alerts:[] on earthquake, got: %s", msgStr)
	}
	if strings.Contains(msgStr, `"alerts":null`) {
		t.Fatalf("alerts must never serialize to null: %s", msgStr)
	}
	if strings.Contains(msgStr, "cleared_areas") {
		t.Fatalf("cleared_areas must be omitted on earthquake: %s", msgStr)
	}
}

func TestParseWeatherOfficialFixture(t *testing.T) {
	fixtureBytes, err := os.ReadFile("testdata/vpww54_weather.xml")
	if err != nil {
		t.Fatalf("read testdata/vpww54_weather.xml failed: %v", err)
	}

	url := "https://www.data.jma.go.jp/developer/xml/data/20260920164632_0_VPWW54_080000.xml"
	msg, err := ParseTelegram(url, fixtureBytes)
	if err != nil {
		t.Fatalf("ParseTelegram failed: %v", err)
	}

	if msg.Status != "通常" {
		t.Fatalf("status mismatch: %s", msg.Status)
	}

	// ValidDateTime mapped to Expires
	if msg.Expires == nil || *msg.Expires != "2026-09-21T07:00:00+09:00" {
		t.Fatalf("expires mismatch: %v", msg.Expires)
	}

	// Check alerts count: 6 alert items in municipal tier (excluding 1 '発表警報・注意報はなし' placeholder)
	if len(msg.Alerts) != 6 {
		t.Fatalf("expected 6 alerts, got %d", len(msg.Alerts))
	}

	seriesKey := *msg.SeriesKey

	// Alert 0: 水戸市 大雨注意報 (継続, Moderate)
	a0 := msg.Alerts[0]
	expectedKey0 := seriesKey + ":0820100:大雨"
	if a0.LifecycleKey != expectedKey0 || a0.Event != "大雨注意報" || a0.Status != "継続" || a0.Severity != "Moderate" {
		t.Fatalf("alert 0 mismatch: %+v (expected key %s)", a0, expectedKey0)
	}

	// Alert 1: 水戸市 雷注意報 (継続, Moderate)
	a1 := msg.Alerts[1]
	expectedKey1 := seriesKey + ":0820100:雷"
	if a1.LifecycleKey != expectedKey1 || a1.Event != "雷注意報" || a1.Status != "継続" || a1.Severity != "Moderate" {
		t.Fatalf("alert 1 mismatch: %+v", a1)
	}

	// Alert 2: 日立市 大雨注意報 (発表, Moderate)
	a2 := msg.Alerts[2]
	expectedKey2 := seriesKey + ":0820200:大雨"
	if a2.LifecycleKey != expectedKey2 || a2.Event != "大雨注意報" || a2.Status != "発表" || a2.Severity != "Moderate" {
		t.Fatalf("alert 2 mismatch: %+v", a2)
	}

	// Alert 3: 土浦市 大雨注意報 (警報から注意報 transition -> Severity Moderate, stable key matches original warning)
	a3 := msg.Alerts[3]
	expectedKey3 := seriesKey + ":0820300:大雨"
	if a3.LifecycleKey != expectedKey3 || a3.Event != "大雨注意報" || a3.Status != "警報から注意報" || a3.Severity != "Moderate" {
		t.Fatalf("alert 3 mismatch: %+v (expected key %s)", a3, expectedKey3)
	}

	// Alert 4: 取手市 大雨警報 (発表, Severe)
	a4 := msg.Alerts[4]
	expectedKey4 := seriesKey + ":0821700:大雨"
	if a4.LifecycleKey != expectedKey4 || a4.Event != "大雨警報" || a4.Status != "発表" || a4.Severity != "Severe" {
		t.Fatalf("alert 4 mismatch: %+v", a4)
	}

	// Alert 5: つくば市 洪水注意報 (解除, Moderate)
	a5 := msg.Alerts[5]
	expectedKey5 := seriesKey + ":0822000:洪水"
	if a5.LifecycleKey != expectedKey5 || a5.Event != "洪水注意報" || a5.Status != "解除" || a5.Severity != "Moderate" {
		t.Fatalf("alert 5 mismatch: %+v", a5)
	}

	// Verifies that '発表警報・注意報はなし' for 鹿嶋市 was completely excluded from alerts
	for _, a := range msg.Alerts {
		if strings.Contains(a.Event, "はなし") || strings.Contains(a.Status, "はなし") {
			t.Fatalf("found placeholder alert in alerts list: %+v", a)
		}
	}

	// Verifies ClearedAreas: 鹿嶋市 (0822200) was marked in ClearedAreas
	if len(msg.ClearedAreas) != 1 || msg.ClearedAreas[0] != "0822200" {
		t.Fatalf("expected ClearedAreas [0822200], got %v", msg.ClearedAreas)
	}

	// Check JSON serialization of ClearedAreas
	jsonBytes, err := json.Marshal(msg)
	if err != nil {
		t.Fatalf("marshal message: %v", err)
	}
	jsonStr := string(jsonBytes)
	if !strings.Contains(jsonStr, `"cleared_areas":["0822200"]`) {
		t.Fatalf("expected cleared_areas in JSON: %s", jsonStr)
	}
}

func TestClearedAreasConflictAvoidance(t *testing.T) {
	// If a municipality has BOTH an active alert and a no-warning marker,
	// the parser must avoid marking it cleared to prevent clearing active alerts
	conflictXML := `<?xml version="1.0" encoding="UTF-8"?>
<Report xmlns="http://xml.kishou.go.jp/jmaxml1/">
<Control>
<Title>気象警報・注意報（Ｈ２７）</Title>
<DateTime>2026-09-20T16:46:30Z</DateTime>
<Status>通常</Status>
<EditorialOffice>水戸地方気象台</EditorialOffice>
<PublishingOffice>水戸地方気象台</PublishingOffice>
</Control>
<Head xmlns="http://xml.kishou.go.jp/jmaxml1/informationBasis1/">
<Title>茨城県気象警報・注意報</Title>
<ReportDateTime>2026-09-21T01:46:00+09:00</ReportDateTime>
<InfoType>発表</InfoType>
<InfoKind>気象警報・注意報</InfoKind>
<Headline><Text>テスト</Text></Headline>
</Head>
<Body xmlns="http://xml.kishou.go.jp/jmaxml1/body/meteorology1/">
<Warning type="気象警報・注意報（市町村等）">
<Item>
<Kind><Name>大雨警報</Name><Code>03</Code><Status>発表</Status></Kind>
<Area><Name>鹿嶋市</Name><Code>0822200</Code></Area>
</Item>
<Item>
<Kind><Name>発表警報・注意報はなし</Name><Code>00</Code><Status>発表警報・注意報はなし</Status></Kind>
<Area><Name>鹿嶋市</Name><Code>0822200</Code></Area>
</Item>
<Item>
<Kind><Name>発表警報・注意報はなし</Name><Code>00</Code><Status>発表警報・注意報はなし</Status></Kind>
<Area><Name>潮来市</Name><Code>0822300</Code></Area>
</Item>
</Warning>
</Body>
</Report>`

	url := "https://www.data.jma.go.jp/developer/xml/data/20260920164632_0_VPWW54_080000.xml"
	msg, err := ParseTelegram(url, []byte(conflictXML))
	if err != nil {
		t.Fatalf("ParseTelegram failed on conflict XML: %v", err)
	}

	// 鹿嶋市 (0822200) has an active alert, so it must NOT be cleared!
	// 潮来市 (0822300) has only no-warning, so it MUST be cleared.
	if len(msg.ClearedAreas) != 1 || msg.ClearedAreas[0] != "0822300" {
		t.Fatalf("expected ClearedAreas [0822300] with 0822200 avoided, got %v", msg.ClearedAreas)
	}
	if len(msg.Alerts) != 1 || msg.Alerts[0].Geocode != "0822200" {
		t.Fatalf("expected 1 alert for 0822200, got %+v", msg.Alerts)
	}
}

func TestSecurityAndValidation(t *testing.T) {
	validXML, _ := os.ReadFile("testdata/vxse53_earthquake.xml")
	url := "https://www.data.jma.go.jp/developer/xml/data/20260920074051_0_VXSE53_270000.xml"

	// 1. DTD / Entity rejection
	dtdXML := strings.Replace(string(validXML), `<?xml version="1.0" encoding="UTF-8"?>`, `<?xml version="1.0"?><!DOCTYPE Report [<!ENTITY xxe "attack">]>`, 1)
	if _, err := ParseTelegram(url, []byte(dtdXML)); !errors.Is(err, ErrDisallowedDTD) {
		t.Fatalf("expected ErrDisallowedDTD, got %v", err)
	}

	// 2. Trailing root element rejection
	trailingXML := string(validXML) + "<ExtraRoot/>"
	if _, err := ParseTelegram(url, []byte(trailingXML)); !errors.Is(err, ErrTrailingRootElement) {
		t.Fatalf("expected ErrTrailingRootElement, got %v", err)
	}

	// 3. Missing Control.Status rejection (never default to 通常)
	noStatusXML := strings.Replace(string(validXML), "<Status>通常</Status>", "<Status></Status>", 1)
	if _, err := ParseTelegram(url, []byte(noStatusXML)); !errors.Is(err, ErrMissingStatus) {
		t.Fatalf("expected ErrMissingStatus, got %v", err)
	}

	// 4. Invalid root namespace rejection
	badNsXML := strings.Replace(string(validXML), `xmlns="http://xml.kishou.go.jp/jmaxml1/"`, `xmlns="http://wrong.namespace/"`, 1)
	if _, err := ParseTelegram(url, []byte(badNsXML)); !errors.Is(err, ErrUnsupportedNamespace) && !errors.Is(err, ErrInvalidRootElement) {
		t.Fatalf("expected namespace or root element error, got %v", err)
	}

	// 5. Invalid DateTime rejection
	badDateXML := strings.Replace(string(validXML), `<DateTime>2026-09-20T07:40:51Z</DateTime>`, `<DateTime>not-a-date</DateTime>`, 1)
	if _, err := ParseTelegram(url, []byte(badDateXML)); !errors.Is(err, ErrInvalidDateTime) {
		t.Fatalf("expected ErrInvalidDateTime, got %v", err)
	}

	// 6. Unsupported datum rejection (Tokyo datum in datum or type attr)
	tokyoDatumXML := strings.Replace(string(validXML), `<jmx_eb:Coordinate`, `<jmx_eb:Coordinate datum="日本測地系"`, 1)
	if _, err := ParseTelegram(url, []byte(tokyoDatumXML)); !errors.Is(err, ErrUnsupportedDatum) {
		t.Fatalf("expected ErrUnsupportedDatum, got %v", err)
	}
	tokyoTypeXML := strings.Replace(string(validXML), `<jmx_eb:Coordinate`, `<jmx_eb:Coordinate type="日本測地系"`, 1)
	if _, err := ParseTelegram(url, []byte(tokyoTypeXML)); !errors.Is(err, ErrUnsupportedDatum) {
		t.Fatalf("expected ErrUnsupportedDatum, got %v", err)
	}

	// 7. Unknown explicit datum rejection
	unknownDatumXML := strings.Replace(string(validXML), `<jmx_eb:Coordinate`, `<jmx_eb:Coordinate datum="MarsDatum2026"`, 1)
	if _, err := ParseTelegram(url, []byte(unknownDatumXML)); !errors.Is(err, ErrUnsupportedDatum) {
		t.Fatalf("expected ErrUnsupportedDatum for unknown datum, got %v", err)
	}
}

func TestBodylessCancellationAndDrill(t *testing.T) {
	validWeather, _ := os.ReadFile("testdata/vpww54_weather.xml")
	url := "https://www.data.jma.go.jp/developer/xml/data/20260920164632_0_VPWW54_080000.xml"

	// Bodyless cancellation: InfoType == 取消
	cancelXML := strings.Replace(string(validWeather), "<InfoType>発表</InfoType>", "<InfoType>取消</InfoType>", 1)
	msg, err := ParseTelegram(url, []byte(cancelXML))
	if err != nil {
		t.Fatalf("cancel parse failed: %v", err)
	}
	if msg.InfoType != "取消" {
		t.Fatalf("expected InfoType 取消, got %s", msg.InfoType)
	}
	if len(msg.Alerts) != 0 {
		t.Fatalf("expected alerts to remain empty for bodyless cancellation, got %d", len(msg.Alerts))
	}
	if len(msg.ClearedAreas) != 0 {
		t.Fatalf("expected ClearedAreas empty on bodyless cancellation, got %v", msg.ClearedAreas)
	}
	if msg.SeriesKey == nil || *msg.SeriesKey == "" {
		t.Fatalf("expected SeriesKey retained on cancellation, got nil")
	}

	// Drill / Training status: raw metadata retained, no live models, no cleared areas
	drillXML := strings.Replace(string(validWeather), "<Status>通常</Status>", "<Status>訓練</Status>", 1)
	dMsg, err := ParseTelegram(url, []byte(drillXML))
	if err != nil {
		t.Fatalf("drill parse failed: %v", err)
	}
	if dMsg.Status != "訓練" {
		t.Fatalf("expected status 訓練, got %s", dMsg.Status)
	}
	if len(dMsg.Alerts) != 0 {
		t.Fatalf("expected alerts empty for drill, got %d", len(dMsg.Alerts))
	}
	if len(dMsg.ClearedAreas) != 0 {
		t.Fatalf("expected cleared areas empty for drill, got %v", dMsg.ClearedAreas)
	}

	// R06 phenomenon warning bulletin: raw metadata retained, 0 normalized alerts, no cleared areas
	r06XML := strings.Replace(string(validWeather), "<Title>気象警報・注意報（Ｈ２７）</Title>", "<Title>気象警報・注意報（Ｒ０６）（大雨）</Title>", 1)
	r06Msg, err := ParseTelegram(url, []byte(r06XML))
	if err != nil {
		t.Fatalf("r06 parse failed: %v", err)
	}
	if len(r06Msg.Alerts) != 0 {
		t.Fatalf("expected 0 normalized alerts for unfamiliar R06 schema, got %d", len(r06Msg.Alerts))
	}
	if len(r06Msg.ClearedAreas) != 0 {
		t.Fatalf("expected cleared areas empty for unfamiliar R06 schema, got %v", r06Msg.ClearedAreas)
	}
}
