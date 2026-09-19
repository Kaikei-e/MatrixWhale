package adapter

import (
	"encoding/json"
	"strings"
	"testing"
)

const sampleRAAXML = `<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0"
     xmlns:iso="http://www.itu.int/tML/tML-ISO-3166"
     xmlns:raa="http://www.oid-info.com/get/2.49.0"
     xmlns:cap="urn:oasis:names:tc:emergency:cap:1.1"
     xmlns:georss="http://www.georss.org/georss">
  <channel>
    <title>WMO Register of Alerting Authorities</title>
    <link>https://alertingauthority.wmo.int/</link>
    <description>Official register of alerting authorities</description>
    <item>
      <title>Ghana: Ghana Meteorological Agency</title>
      <iso:countrycode>GHA</iso:countrycode>
      <link>https://alertingauthority.wmo.int/authorities.php?recId=318</link>
      <description>A WMO Member [Ghana] identifies … CAP categories:  Met.</description>
      <pubDate>Thu, 17 Sep 2026 05:57:50 +0000</pubDate>
      <guid>urn:oid:2.49.0.0.288.0</guid>
      <author>personal@meteo.gov.gh</author>
      <raa:authorityAbbrev>gmet</raa:authorityAbbrev>
      <raa:capAlertFeed xml:lang="en">https://www.meteo.gov.gh/api/cap/rss.xml</raa:capAlertFeed>
    </item>
    <item>
      <title>Colombia: Instituto de Hidrología, Meteorología y Estudios Ambientales</title>
      <iso:countrycode>COL</iso:countrycode>
      <link>https://alertingauthority.wmo.int/authorities.php?recId=170</link>
      <description>A WMO Member [Colombia] identifies …</description>
      <pubDate>Wed, 16 Sep 2026 12:00:00 +0000</pubDate>
      <guid>urn:oid:2.49.0.0.170.0</guid>
      <author>confidential@ideam.gov.co</author>
      <raa:authorityAbbrev>ideam</raa:authorityAbbrev>
    </item>
    <item>
      <title>Cyprus: Department of Meteorology</title>
      <iso:countrycode>CYP</iso:countrycode>
      <link>https://alertingauthority.wmo.int/authorities.php?recId=196</link>
      <description>A WMO Member [Cyprus] identifies …</description>
      <pubDate>Tue, 15 Sep 2026 08:30:00 +0000</pubDate>
      <guid>urn:oid:2.49.0.0.196.0</guid>
      <author>admin@dom.gov.cy</author>
      <raa:authorityAbbrev>dom</raa:authorityAbbrev>
      <raa:capAlertFeed xml:lang="en">https://www.dom.gov.cy/cap/en.xml</raa:capAlertFeed>
      <raa:capAlertFeed xml:lang="el">https://www.dom.gov.cy/cap/el.xml</raa:capAlertFeed>
    </item>
  </channel>
</rss>`

func TestParseRAA(t *testing.T) {
	features, err := ParseRAA([]byte(sampleRAAXML))
	if err != nil {
		t.Fatalf("ParseRAA error: %v", err)
	}
	if len(features) != 3 {
		t.Fatalf("expected 3 features, got %d", len(features))
	}

	// 1. Ghana item: 1 feed with lang="en"
	ghana := features[0]
	if ghana.GUID == nil || *ghana.GUID != "urn:oid:2.49.0.0.288.0" {
		t.Errorf("expected Ghana GUID, got %v", ghana.GUID)
	}
	if ghana.Title == nil || *ghana.Title != "Ghana: Ghana Meteorological Agency" {
		t.Errorf("expected Ghana title, got %v", ghana.Title)
	}
	if ghana.CountryISO3 == nil || *ghana.CountryISO3 != "GHA" {
		t.Errorf("expected GHA countrycode, got %v", ghana.CountryISO3)
	}
	if ghana.Abbrev == nil || *ghana.Abbrev != "gmet" {
		t.Errorf("expected abbrev gmet, got %v", ghana.Abbrev)
	}
	if len(ghana.Feeds) != 1 {
		t.Fatalf("expected 1 feed for Ghana, got %d", len(ghana.Feeds))
	}
	if ghana.Feeds[0].URL != "https://www.meteo.gov.gh/api/cap/rss.xml" {
		t.Errorf("expected Ghana feed URL, got %s", ghana.Feeds[0].URL)
	}
	if ghana.Feeds[0].Language == nil || *ghana.Feeds[0].Language != "en" {
		t.Errorf("expected Ghana feed lang 'en', got %v", ghana.Feeds[0].Language)
	}

	// 2. Colombia item: 0 feeds, must have empty slice
	colombia := features[1]
	if colombia.GUID == nil || *colombia.GUID != "urn:oid:2.49.0.0.170.0" {
		t.Errorf("expected Colombia GUID, got %v", colombia.GUID)
	}
	if colombia.CountryISO3 == nil || *colombia.CountryISO3 != "COL" {
		t.Errorf("expected COL countrycode, got %v", colombia.CountryISO3)
	}
	if len(colombia.Feeds) != 0 {
		t.Errorf("expected 0 feeds for Colombia, got %d", len(colombia.Feeds))
	}

	// 3. Cyprus item: 2 feeds with different languages (en and el)
	cyprus := features[2]
	if cyprus.CountryISO3 == nil || *cyprus.CountryISO3 != "CYP" {
		t.Errorf("expected CYP countrycode, got %v", cyprus.CountryISO3)
	}
	if len(cyprus.Feeds) != 2 {
		t.Fatalf("expected 2 feeds for Cyprus, got %d", len(cyprus.Feeds))
	}
	if cyprus.Feeds[0].Language == nil || *cyprus.Feeds[0].Language != "en" {
		t.Errorf("expected first feed lang 'en', got %v", cyprus.Feeds[0].Language)
	}
	if cyprus.Feeds[1].Language == nil || *cyprus.Feeds[1].Language != "el" {
		t.Errorf("expected second feed lang 'el', got %v", cyprus.Feeds[1].Language)
	}

	// Verify JSON encoding: feeds: [] for Colombia, never author
	jsonBytes, err := json.Marshal(features)
	if err != nil {
		t.Fatalf("marshal features: %v", err)
	}
	jsonStr := string(jsonBytes)

	if strings.Contains(jsonStr, "personal@meteo.gov.gh") ||
		strings.Contains(jsonStr, "confidential@ideam.gov.co") ||
		strings.Contains(jsonStr, `"author":`) {
		t.Errorf("JSON output must never contain author or personal email: %s", jsonStr)
	}
	if !strings.Contains(jsonStr, `"feeds":[]`) {
		t.Errorf("Colombia must have feeds encoded as [], got: %s", jsonStr)
	}
}
