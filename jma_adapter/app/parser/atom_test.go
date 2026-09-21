package parser

import (
	"errors"
	"strings"
	"testing"

	"jma_adapter/client"
)

// Official portal source feed sample (data.jma.go.jp Atom 1.0)
const sampleAtomXML = `<?xml version="1.0" encoding="utf-8"?>
<!-- 気象庁防災情報XMLをもとにMatrixWhaleがテスト用に抜粋・加工。編集責任：MatrixWhale。 -->
<!-- 原データ取得元URL: https://www.data.jma.go.jp/developer/xml/feed/eqvol.xml -->
<feed xmlns="http://www.w3.org/2005/Atom" lang="ja">
  <title>高頻度（地震火山）</title>
  <subtitle>JMAXML publishing feed</subtitle>
  <updated>2026-09-21T00:03:07+09:00</updated>
  <id>https://www.data.jma.go.jp/developer/xml/feed/eqvol.xml#short_1789916587</id>
  <entry>
    <title>噴火に関する火山観測報</title>
    <id>https://www.data.jma.go.jp/developer/xml/data/20260920150214_0_VFVO52_400000.xml</id>
    <updated>2026-09-20T15:02:14Z</updated>
    <author>
      <name>福岡管区気象台　鹿児島地方気象台</name>
    </author>
    <link type="application/xml" href="https://www.data.jma.go.jp/developer/xml/data/20260920150214_0_VFVO52_400000.xml"/>
    <content type="text">【火山名　桜島　噴火に関する火山観測報】</content>
  </entry>
  <entry>
    <title>震源・震度に関する情報</title>
    <id>https://www.data.jma.go.jp/developer/xml/data/20260920074051_0_VXSE53_270000.xml</id>
    <updated>2026-09-20T07:40:00Z</updated>
    <link type="application/xml" href="https://www.data.jma.go.jp/developer/xml/data/20260920074051_0_VXSE53_270000.xml"/>
  </entry>
  <!-- Duplicate entry with same URL -->
  <entry>
    <title>震源・震度に関する情報 (Duplicate)</title>
    <id>https://www.data.jma.go.jp/developer/xml/data/20260920074051_0_VXSE53_270000.xml</id>
    <updated>2026-09-20T07:40:00Z</updated>
    <link type="application/xml" href="https://www.data.jma.go.jp/developer/xml/data/20260920074051_0_VXSE53_270000.xml"/>
  </entry>
  <entry>
    <title>Malicious External Entry</title>
    <id>https://evil.com/fake.xml</id>
    <link type="application/xml" href="https://evil.com/fake.xml"/>
  </entry>
</feed>`

func TestParseAtomFeed(t *testing.T) {
	v := client.NewURLValidator("www.data.jma.go.jp", false)
	feedURL := "https://www.data.jma.go.jp/developer/xml/feed/eqvol.xml"

	items, err := ParseAtomFeed(feedURL, []byte(sampleAtomXML), v)
	if err != nil {
		t.Fatalf("ParseAtomFeed failed: %v", err)
	}

	// 2 items expected: evil.com is filtered out by URLValidator, duplicate item is deduplicated!
	if len(items) != 2 {
		t.Fatalf("expected 2 items after filtering and deduplication, got %d", len(items))
	}

	if items[0].ItemURL != "https://www.data.jma.go.jp/developer/xml/data/20260920150214_0_VFVO52_400000.xml" {
		t.Fatalf("item 0 URL mismatch: %s", items[0].ItemURL)
	}
	if *items[0].Title != "噴火に関する火山観測報" {
		t.Fatalf("item 0 title mismatch: %s", *items[0].Title)
	}
	if *items[0].Published != "2026-09-20T15:02:14Z" {
		t.Fatalf("item 0 published mismatch: %s", *items[0].Published)
	}

	if items[1].ItemURL != "https://www.data.jma.go.jp/developer/xml/data/20260920074051_0_VXSE53_270000.xml" {
		t.Fatalf("item 1 URL mismatch: %s", items[1].ItemURL)
	}
}

func TestParseAtomFeedSecurityAndValidation(t *testing.T) {
	v := client.NewURLValidator("www.data.jma.go.jp", false)
	feedURL := "https://www.data.jma.go.jp/developer/xml/feed/eqvol.xml"

	// 1. Missing or invalid Atom namespace
	badNsXML := strings.Replace(sampleAtomXML, `xmlns="http://www.w3.org/2005/Atom"`, `xmlns="http://wrong.namespace/"`, 1)
	if _, err := ParseAtomFeed(feedURL, []byte(badNsXML), v); !errors.Is(err, ErrUnsupportedNamespace) {
		t.Fatalf("expected ErrUnsupportedNamespace, got %v", err)
	}

	// 2. DTD / Entity rejection
	dtdXML := `<?xml version="1.0"?><!DOCTYPE feed [<!ENTITY xxe "evil">]><feed xmlns="http://www.w3.org/2005/Atom"></feed>`
	if _, err := ParseAtomFeed(feedURL, []byte(dtdXML), v); !errors.Is(err, ErrDisallowedDTD) {
		t.Fatalf("expected ErrDisallowedDTD, got %v", err)
	}

	// 3. Trailing root element rejection
	trailingXML := sampleAtomXML + "<ExtraRoot/>"
	if _, err := ParseAtomFeed(feedURL, []byte(trailingXML), v); !errors.Is(err, ErrTrailingRootElement) {
		t.Fatalf("expected ErrTrailingRootElement, got %v", err)
	}

	// 4. Malformed XML rejection
	if _, err := ParseAtomFeed(feedURL, []byte("<not-feed></not-feed>"), v); err == nil {
		t.Fatalf("expected error on non-feed XML, got nil")
	}
}
