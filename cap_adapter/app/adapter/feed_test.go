package adapter

import (
	"strings"
	"testing"
)

const sampleRSS2 = `<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0">
  <channel>
    <title>Sample RSS Weather Feed</title>
    <link>https://weather.example.com/rss</link>
    <description>Weather alerts</description>
    <item>
      <title>Flood Warning</title>
      <link>https://weather.example.com/alerts/flood.xml</link>
      <guid>urn:alert:101</guid>
      <pubDate>Mon, 15 Sep 2026 10:00:00 GMT</pubDate>
    </item>
    <item>
      <title>Wind Warning (Guid as URL)</title>
      <link></link>
      <guid>https://weather.example.com/alerts/wind.xml</guid>
      <pubDate>Mon, 15 Sep 2026 11:00:00 GMT</pubDate>
    </item>
    <item>
      <title>Heat Advisory (Enclosure URL)</title>
      <guid>urn:alert:103</guid>
      <enclosure url="https://weather.example.com/alerts/heat.xml" length="1234" type="application/cap+xml" />
      <pubDate>Mon, 15 Sep 2026 12:00:00 GMT</pubDate>
    </item>
    <item>
      <title>Relative Link Alert</title>
      <link>/alerts/relative.xml</link>
      <guid>urn:alert:104</guid>
      <pubDate>Mon, 15 Sep 2026 13:00:00 GMT</pubDate>
    </item>
  </channel>
</rss>`

const sampleMeteoAlarmAtom = `<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <title>MeteoAlarm Alerts</title>
  <id>https://feeds.meteoalarm.org/feeds/meteoalarm-legacy-atom-germany</id>
  <updated>2026-09-17T14:00:00+00:00</updated>
  <entry>
    <id>urn:meteoalarm:de:20260917-001</id>
    <title>Wind Warning Germany</title>
    <updated>2026-09-17T13:45:00+00:00</updated>
    <published>2026-09-17T13:40:00+00:00</published>
    <link rel="alternate" type="text/html" href="https://meteoalarm.org/alert/123.html"/>
    <link rel="related" type="application/cap+xml" href="https://feeds.meteoalarm.org/api/cap/alert-123.xml"/>
  </entry>
  <entry>
    <id>urn:meteoalarm:de:20260917-002</id>
    <title>Relative Atom Link</title>
    <updated>2026-09-17T14:10:00+00:00</updated>
    <link rel="alternate" href="sub/alert-relative.xml"/>
  </entry>
</feed>`

func TestParseFeedRSS(t *testing.T) {
	feedURL := "https://weather.example.com/feed/rss.xml"
	res := ParseFeed(feedURL, []byte(sampleRSS2))
	if res.Format != FormatRSS {
		t.Fatalf("expected format rss, got %s", res.Format)
	}
	if res.Error != "" {
		t.Fatalf("unexpected error: %s", res.Error)
	}
	if len(res.Features) != 4 {
		t.Fatalf("expected 4 features, got %d", len(res.Features))
	}

	// Item 1: link text
	item1 := res.Features[0]
	if item1.CAPURL == nil || *item1.CAPURL != "https://weather.example.com/alerts/flood.xml" {
		t.Errorf("item 1 cap_url expected flood.xml, got %v", item1.CAPURL)
	}
	if item1.Published == nil || *item1.Published != "Mon, 15 Sep 2026 10:00:00 GMT" {
		t.Errorf("item 1 published mismatch: %v", item1.Published)
	}

	// Item 2: guid as URL
	item2 := res.Features[1]
	if item2.CAPURL == nil || *item2.CAPURL != "https://weather.example.com/alerts/wind.xml" {
		t.Errorf("item 2 cap_url expected wind.xml from guid, got %v", item2.CAPURL)
	}

	// Item 3: enclosure url
	item3 := res.Features[2]
	if item3.CAPURL == nil || *item3.CAPURL != "https://weather.example.com/alerts/heat.xml" {
		t.Errorf("item 3 cap_url expected heat.xml from enclosure, got %v", item3.CAPURL)
	}

	// Item 4: relative link resolved against feed URL
	item4 := res.Features[3]
	if item4.CAPURL == nil || *item4.CAPURL != "https://weather.example.com/alerts/relative.xml" {
		t.Errorf("item 4 cap_url expected https://weather.example.com/alerts/relative.xml, got %v", item4.CAPURL)
	}
}

func TestParseFeedAtomMeteoAlarm(t *testing.T) {
	feedURL := "https://feeds.meteoalarm.org/feeds/atom.xml"
	res := ParseFeed(feedURL, []byte(sampleMeteoAlarmAtom))
	if res.Format != FormatAtom {
		t.Fatalf("expected format atom, got %s", res.Format)
	}
	if res.Error != "" {
		t.Fatalf("unexpected error: %s", res.Error)
	}
	if len(res.Features) != 2 {
		t.Fatalf("expected 2 features, got %d", len(res.Features))
	}

	// Entry 1: MeteoAlarm has type="application/cap+xml" next to text/html
	entry1 := res.Features[0]
	if entry1.CAPURL == nil || *entry1.CAPURL != "https://feeds.meteoalarm.org/api/cap/alert-123.xml" {
		t.Errorf("entry 1 should select cap+xml link over html link, got %v", entry1.CAPURL)
	}
	if entry1.Published == nil || *entry1.Published != "2026-09-17T13:40:00+00:00" {
		t.Errorf("entry 1 published should prefer <published> over <updated>, got %v", entry1.Published)
	}

	// Entry 2: relative link resolved
	entry2 := res.Features[1]
	expected := "https://feeds.meteoalarm.org/feeds/sub/alert-relative.xml"
	if entry2.CAPURL == nil || *entry2.CAPURL != expected {
		t.Errorf("entry 2 relative link expected %s, got %v", expected, entry2.CAPURL)
	}
}

func TestParseFeedHTMLBody(t *testing.T) {
	htmlBody := `<!DOCTYPE html><html><head><title>500 Internal Server Error</title></head><body>Error</body></html>`
	res := ParseFeed("https://example.com/feed", []byte(htmlBody))
	if res.Format != FormatOther {
		t.Fatalf("expected format other for HTML, got %s", res.Format)
	}
	if !strings.Contains(res.Error, "html") {
		t.Errorf("expected error to mention html root, got: %s", res.Error)
	}
	if len(res.Features) != 0 {
		t.Errorf("expected empty features on error, got %d", len(res.Features))
	}
}

func TestParseFeedRDFRSS10(t *testing.T) {
	rdfData := `<?xml version="1.0" encoding="UTF-8"?>
<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns="http://purl.org/rss/1.0/">
  <channel rdf:about="https://example.com/channel">
    <title>RDF Feed</title>
    <link>https://example.com/rss</link>
  </channel>
  <item rdf:about="https://example.com/item/1">
    <title>RDF Alert Title</title>
    <link>https://example.com/alerts/rdf-alert.xml</link>
    <description>Heavy snowfall expected</description>
  </item>
</rdf:RDF>`

	res := ParseFeed("https://example.com/rss", []byte(rdfData))
	if res.Error != "" {
		t.Fatalf("ParseFeed failed for RDF 1.0: %v", res.Error)
	}
	if res.Format != FormatRSS {
		t.Fatalf("expected format rss, got %s", res.Format)
	}
	if len(res.Features) != 1 {
		t.Fatalf("expected 1 feature, got %d", len(res.Features))
	}
	f := res.Features[0]
	if f.Title == nil || *f.Title != "RDF Alert Title" {
		t.Errorf("expected Title 'RDF Alert Title', got %v", f.Title)
	}
	if f.CAPURL == nil || *f.CAPURL != "https://example.com/alerts/rdf-alert.xml" {
		t.Errorf("expected CAPURL 'https://example.com/alerts/rdf-alert.xml', got %v", f.CAPURL)
	}
}

func TestParseFeedRSS20DefaultNamespace(t *testing.T) {
	rssData := `<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns="http://backend.userland.com/rss2">
  <channel>
    <title>Default NS Feed</title>
    <link>https://example.com/rss</link>
    <item>
      <title>Default NS Alert Title</title>
      <link>https://example.com/alerts/default-ns.xml</link>
      <guid>urn:alert:default-ns-1</guid>
      <pubDate>Fri, 18 Sep 2026 12:00:00 GMT</pubDate>
    </item>
  </channel>
</rss>`

	res := ParseFeed("https://example.com/rss", []byte(rssData))
	if res.Error != "" {
		t.Fatalf("ParseFeed failed for RSS 2.0 with default namespace: %v", res.Error)
	}
	if res.Format != FormatRSS {
		t.Fatalf("expected format rss, got %s", res.Format)
	}
	if len(res.Features) != 1 {
		t.Fatalf("expected 1 feature, got %d", len(res.Features))
	}
	f := res.Features[0]
	if f.Title == nil || *f.Title != "Default NS Alert Title" {
		t.Errorf("expected Title 'Default NS Alert Title', got %v", f.Title)
	}
	if f.CAPURL == nil || *f.CAPURL != "https://example.com/alerts/default-ns.xml" {
		t.Errorf("expected CAPURL 'https://example.com/alerts/default-ns.xml', got %v", f.CAPURL)
	}
	if f.Published == nil || *f.Published != "Fri, 18 Sep 2026 12:00:00 GMT" {
		t.Errorf("expected Published date, got %v", f.Published)
	}
}

func TestParseFeedAtomMediaTitleNotOverwritingTitle(t *testing.T) {
	atomData := `<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom" xmlns:media="http://search.yahoo.com/mrss/">
  <title>Atom Feed with Media</title>
  <entry>
    <id>urn:atom:entry:1</id>
    <title>Native Atom Title</title>
    <media:title>Media Title Overwrite Attempt</media:title>
    <link rel="alternate" href="https://example.com/alerts/atom-1.xml"/>
  </entry>
  <entry>
    <id>urn:atom:entry:2</id>
    <media:title>Preceding Media Title</media:title>
    <title>Second Native Atom Title</title>
    <link rel="alternate" href="https://example.com/alerts/atom-2.xml"/>
  </entry>
</feed>`

	res := ParseFeed("https://example.com/atom.xml", []byte(atomData))
	if res.Error != "" {
		t.Fatalf("ParseFeed failed for Atom feed with media:title: %v", res.Error)
	}
	if res.Format != FormatAtom {
		t.Fatalf("expected format atom, got %s", res.Format)
	}
	if len(res.Features) != 2 {
		t.Fatalf("expected 2 features, got %d", len(res.Features))
	}
	if res.Features[0].Title == nil || *res.Features[0].Title != "Native Atom Title" {
		t.Errorf("item 1: expected 'Native Atom Title', got %v", res.Features[0].Title)
	}
	if res.Features[1].Title == nil || *res.Features[1].Title != "Second Native Atom Title" {
		t.Errorf("item 2: expected 'Second Native Atom Title', got %v", res.Features[1].Title)
	}
}

func TestRSSItemNamespacedElementsIgnored(t *testing.T) {
	rssWithNamespaces := `<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom" xmlns:media="http://search.yahoo.com/mrss/">
  <channel>
    <title>Namespace Test Feed</title>
    <link>https://example.com/rss</link>
    <item>
      <title>Original Alert Title</title>
      <link>https://example.com/alerts/alert-original.xml</link>
      <atom:link rel="self" href="https://example.com/feed-atom.xml"/>
      <media:title>Media Title Overwrite Attempt</media:title>
      <guid>urn:test:ns1</guid>
      <pubDate>Fri, 18 Sep 2026 12:00:00 GMT</pubDate>
    </item>
    <item>
      <atom:link rel="self" href="https://example.com/feed-first.xml"/>
      <media:title>Preceding Media Title</media:title>
      <title>Second Real Title</title>
      <link>https://example.com/alerts/alert-second.xml</link>
      <guid>urn:test:ns2</guid>
      <pubDate>Fri, 18 Sep 2026 13:00:00 GMT</pubDate>
    </item>
  </channel>
</rss>`

	res := ParseFeed("https://example.com/feed.xml", []byte(rssWithNamespaces))
	if res.Error != "" {
		t.Fatalf("ParseFeed failed: %v", res.Error)
	}
	if len(res.Features) != 2 {
		t.Fatalf("expected 2 features, got %d", len(res.Features))
	}

	// First item: namespaced elements follow no-namespace elements
	item1 := res.Features[0]
	if item1.Title == nil || *item1.Title != "Original Alert Title" {
		t.Errorf("expected Title 'Original Alert Title', got %v", item1.Title)
	}
	if item1.CAPURL == nil || *item1.CAPURL != "https://example.com/alerts/alert-original.xml" {
		t.Errorf("expected CAPURL 'https://example.com/alerts/alert-original.xml', got %v", item1.CAPURL)
	}

	// Second item: namespaced elements precede no-namespace elements
	item2 := res.Features[1]
	if item2.Title == nil || *item2.Title != "Second Real Title" {
		t.Errorf("expected Title 'Second Real Title', got %v", item2.Title)
	}
	if item2.CAPURL == nil || *item2.CAPURL != "https://example.com/alerts/alert-second.xml" {
		t.Errorf("expected CAPURL 'https://example.com/alerts/alert-second.xml', got %v", item2.CAPURL)
	}
}

func TestFeedNonStrictXMLAndEntities(t *testing.T) {
	// Feed containing HTML entity &nbsp; and non-strict unclosed <br> tag
	rssWithEntities := `<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0">
  <channel>
    <title>Entity Feed</title>
    <item>
      <title>Flood&nbsp;Warning</title>
      <link>https://example.com/alerts/flood.xml</link>
      <description>Heavy rain<br>Flash flooding possible</description>
      <guid>urn:test:entity1</guid>
    </item>
  </channel>
</rss>`

	res := ParseFeed("https://example.com/feed.xml", []byte(rssWithEntities))
	if res.Error != "" {
		t.Fatalf("expected feed with &nbsp; to parse successfully, got: %s", res.Error)
	}
	if len(res.Features) != 1 {
		t.Fatalf("expected 1 feature, got %d", len(res.Features))
	}
	expectedTitle := "Flood\u00A0Warning"
	if res.Features[0].Title == nil || *res.Features[0].Title != expectedTitle {
		t.Errorf("expected title %q, got %v", expectedTitle, res.Features[0].Title)
	}
}

func TestFeedJSONAndEmptyBodiesReportedAsNotAnXMLFeed(t *testing.T) {
	testCases := []struct {
		name string
		data []byte
	}{
		{"empty byte slice", []byte{}},
		{"whitespace only", []byte("   \n\t  \r\n")},
		{"json object", []byte(`{"status": "ok", "items": []}`)},
		{"json array", []byte(`[{"id": "1", "url": "https://example.com"}]`)},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			res := ParseFeed("https://example.com/feed", tc.data)
			if res.Format != FormatOther {
				t.Errorf("expected format 'other', got %q", res.Format)
			}
			if res.Error != "not an XML feed" {
				t.Errorf("expected error 'not an XML feed', got %q", res.Error)
			}
			if len(res.Features) != 0 {
				t.Errorf("expected 0 features, got %d", len(res.Features))
			}
		})
	}
}
