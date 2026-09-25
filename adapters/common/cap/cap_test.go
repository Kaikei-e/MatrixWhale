package cap

import (
	"encoding/json"
	"strings"
	"testing"
)

const cap12XML = `<?xml version="1.0" encoding="UTF-8"?>
<alert xmlns="urn:oasis:names:tc:emergency:cap:1.2">
  <identifier>TRI-2026-001</identifier>
  <sender>weather@met.example.org</sender>
  <sent>2026-09-17T12:00:00-04:00</sent>
  <status>Actual</status>
  <msgType>Alert</msgType>
  <scope>Public</scope>
  <info>
    <category>Met</category>
    <event>Flash Flood</event>
    <urgency>Immediate</urgency>
    <severity>Severe</severity>
    <certainty>Observed</certainty>
    <area>
      <areaDesc>Northern Coast</areaDesc>
      <polygon>10.5,-61.5 10.6,-61.4 10.5,-61.4 10.5,-61.5</polygon>
      <circle>10.55,-61.45 15.0</circle>
      <geocode>
        <valueName>SAME</valueName>
        <value>001002</value>
      </geocode>
    </area>
  </info>
  <Signature xmlns="http://www.w3.org/2000/09/xmldsig#">
    <SignedInfo><CanonicalizationMethod Algorithm="http://www.w3.org/TR/2001/REC-xml-c14n-20010315"/></SignedInfo>
    <SignatureValue>dummySignatureValue</SignatureValue>
  </Signature>
</alert>`

const cap11XML = `<?xml version="1.0" encoding="UTF-8"?>
<alert xmlns="urn:oasis:names:tc:emergency:cap:1.1">
  <identifier>CAP-11-TEST</identifier>
  <sender>agency@alerts.gov</sender>
  <sent>2026-09-17T12:00:00Z</sent>
  <status>Actual</status>
  <msgType>Alert</msgType>
  <scope>Public</scope>
  <info>
    <category>Safety</category>
    <event>Industrial Fire</event>
    <urgency>Immediate</urgency>
    <severity>Extreme</severity>
    <certainty>Likely</certainty>
    <area>
      <areaDesc>Port District</areaDesc>
    </area>
  </info>
</alert>`

const capNoNamespaceXML = `<?xml version="1.0" encoding="UTF-8"?>
<alert>
  <identifier>NO-NS-001</identifier>
  <sender>local@authority.gov</sender>
  <sent>2026-09-17T10:00:00Z</sent>
  <status>Actual</status>
  <msgType>Alert</msgType>
  <scope>Public</scope>
  <info>
    <category>Other</category>
    <event>Road Closure</event>
    <urgency>Past</urgency>
    <severity>Minor</severity>
    <certainty>Observed</certainty>
    <area>
      <areaDesc>Highway 10</areaDesc>
    </area>
  </info>
</alert>`

const multiInfoXML = `<?xml version="1.0" encoding="UTF-8"?>
<alert xmlns="urn:oasis:names:tc:emergency:cap:1.2">
  <identifier>MULTI-INFO-001</identifier>
  <sender>bilingual@meteo.gov</sender>
  <sent>2026-09-17T08:00:00Z</sent>
  <status>Actual</status>
  <msgType>Alert</msgType>
  <scope>Public</scope>
  <info>
    <language>en</language>
    <category>Met</category>
    <event>Gale Warning</event>
    <urgency>Expected</urgency>
    <severity>Moderate</severity>
    <certainty>Likely</certainty>
    <area><areaDesc>Coastal waters</areaDesc></area>
  </info>
  <info>
    <language>fr</language>
    <category>Met</category>
    <event>Avis de coup de vent</event>
    <urgency>Expected</urgency>
    <severity>Moderate</severity>
    <certainty>Likely</certainty>
    <area><areaDesc>Eaux côtières</areaDesc></area>
  </info>
</alert>`

const iso88591XML = "<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?>\n" +
	"<alert xmlns=\"urn:oasis:names:tc:emergency:cap:1.2\">\n" +
	"  <identifier>ISO-TEST</identifier>\n" +
	"  <sender>spain@aemet.es</sender>\n" +
	"  <sent>2026-09-17T14:00:00+02:00</sent>\n" +
	"  <status>Actual</status>\n" +
	"  <msgType>Alert</msgType>\n" +
	"  <scope>Public</scope>\n" +
	"  <info>\n" +
	"    <category>Met</category>\n" +
	"    <event>Tormentas el\xe9ctricas</event>\n" +
	"    <urgency>Immediate</urgency>\n" +
	"    <severity>Severe</severity>\n" +
	"    <certainty>Likely</certainty>\n" +
	"    <area><areaDesc>Regi\xf3n Sur</areaDesc></area>\n" +
	"  </info>\n" +
	"</alert>"

func TestParseCAPVersions(t *testing.T) {
	// CAP 1.2
	res12 := ParseCAP([]byte(cap12XML))
	if res12.Error != nil {
		t.Fatalf("unexpected error parsing CAP 1.2: %v", *res12.Error)
	}
	if res12.Cap == nil || res12.Cap.CAPVersion != "1.2" {
		t.Fatalf("expected cap_version '1.2', got %+v", res12.Cap)
	}
	if res12.Cap.Identifier != "TRI-2026-001" {
		t.Errorf("identifier mismatch: %s", res12.Cap.Identifier)
	}

	// CAP 1.1
	res11 := ParseCAP([]byte(cap11XML))
	if res11.Error != nil {
		t.Fatalf("unexpected error parsing CAP 1.1: %v", *res11.Error)
	}
	if res11.Cap == nil || res11.Cap.CAPVersion != "1.1" {
		t.Fatalf("expected cap_version '1.1', got %+v", res11.Cap)
	}

	// No namespace
	resNoNS := ParseCAP([]byte(capNoNamespaceXML))
	if resNoNS.Error != nil {
		t.Fatalf("unexpected error parsing CAP no NS: %v", *resNoNS.Error)
	}
	if resNoNS.Cap == nil || resNoNS.Cap.CAPVersion != "" {
		t.Fatalf("expected empty cap_version, got %q", resNoNS.Cap.CAPVersion)
	}
}

func TestParseCAPWithUTF8BOM(t *testing.T) {
	bomData := append([]byte("\xef\xbb\xbf"), []byte(cap12XML)...)
	res := ParseCAP(bomData)
	if res.Error != nil {
		t.Fatalf("unexpected error parsing CAP with BOM: %v", *res.Error)
	}
	if res.Cap == nil || res.Cap.Identifier != "TRI-2026-001" {
		t.Fatalf("expected parsed alert, got %+v", res.Cap)
	}
}

func TestParseCAPWithISO88591(t *testing.T) {
	res := ParseCAP([]byte(iso88591XML))
	if res.Error != nil {
		t.Fatalf("unexpected error parsing ISO-8859-1 CAP: %v", *res.Error)
	}
	if res.Cap == nil || res.Cap.Identifier != "ISO-TEST" {
		t.Fatalf("expected parsed alert, got %+v", res.Cap)
	}
	if len(res.Cap.Info) != 1 {
		t.Fatalf("expected 1 info, got %d", len(res.Cap.Info))
	}
	if !strings.Contains(res.Cap.Info[0].Event, "Tormentas el") {
		t.Errorf("expected decoded event name, got %s", res.Cap.Info[0].Event)
	}
}

func TestParseCAPMultiInfo(t *testing.T) {
	res := ParseCAP([]byte(multiInfoXML))
	if res.Error != nil {
		t.Fatalf("unexpected error parsing multi-info: %v", *res.Error)
	}
	if res.Cap == nil || len(res.Cap.Info) != 2 {
		t.Fatalf("expected 2 info elements, got %d", len(res.Cap.Info))
	}
	if *res.Cap.Info[0].Language != "en" || *res.Cap.Info[1].Language != "fr" {
		t.Errorf("languages mismatch: %v, %v", res.Cap.Info[0].Language, res.Cap.Info[1].Language)
	}
}

func TestParseCAPGeometryAndGeocode(t *testing.T) {
	res := ParseCAP([]byte(cap12XML))
	if res.Error != nil {
		t.Fatalf("unexpected error: %v", *res.Error)
	}
	info := res.Cap.Info[0]
	if len(info.Area) != 1 {
		t.Fatalf("expected 1 area, got %d", len(info.Area))
	}
	area := info.Area[0]
	if len(area.Polygon) != 1 || area.Polygon[0] != "10.5,-61.5 10.6,-61.4 10.5,-61.4 10.5,-61.5" {
		t.Errorf("polygon mismatch: %v", area.Polygon)
	}
	if len(area.Circle) != 1 || area.Circle[0] != "10.55,-61.45 15.0" {
		t.Errorf("circle mismatch: %v", area.Circle)
	}
	if len(area.Geocode) != 1 || area.Geocode[0].ValueName != "SAME" || area.Geocode[0].Value != "001002" {
		t.Errorf("geocode mismatch: %+v", area.Geocode)
	}
}

func TestParseCAPNonAlertRoot(t *testing.T) {
	htmlData := `<!DOCTYPE html><html><body><h1>Service Unavailable</h1></body></html>`
	res := ParseCAP([]byte(htmlData))
	if res.Cap != nil {
		t.Errorf("expected nil cap for html root, got %+v", res.Cap)
	}
	if res.Error == nil || !strings.Contains(*res.Error, "not a CAP alert: root") || !strings.Contains(*res.Error, "html") {
		t.Errorf("expected error mentioning not a CAP alert and html root, got: %v", res.Error)
	}
	if res.RawXML == nil || !strings.Contains(*res.RawXML, "Service Unavailable") {
		t.Errorf("expected raw_xml to be preserved, got %v", res.RawXML)
	}
}

func TestCAPJSONEncodingListsVsNull(t *testing.T) {
	res := ParseCAP([]byte(capNoNamespaceXML))
	if res.Error != nil {
		t.Fatalf("unexpected error: %v", *res.Error)
	}

	jsonBytes, err := json.Marshal(res.Cap)
	if err != nil {
		t.Fatalf("marshal error: %v", err)
	}
	var rawMap map[string]any
	if err := json.Unmarshal(jsonBytes, &rawMap); err != nil {
		t.Fatalf("unmarshal error: %v", err)
	}

	if val, ok := rawMap["source"]; !ok || val != nil {
		t.Errorf("expected source to be null, got %v", val)
	}
	if val, ok := rawMap["note"]; !ok || val != nil {
		t.Errorf("expected note to be null, got %v", val)
	}
	if val, ok := rawMap["references"]; !ok || val != nil {
		t.Errorf("expected references to be null, got %v", val)
	}

	if val, ok := rawMap["code"]; !ok {
		t.Errorf("code field missing")
	} else if list, isList := val.([]any); !isList || len(list) != 0 {
		t.Errorf("expected code to be [], got %v", val)
	}

	infoList, ok := rawMap["info"].([]any)
	if !ok || len(infoList) != 1 {
		t.Fatalf("expected 1 info element in JSON, got %v", rawMap["info"])
	}
	infoMap := infoList[0].(map[string]any)

	if val, ok := infoMap["language"]; !ok || val != nil {
		t.Errorf("expected info.language to be null, got %v", val)
	}
	if val, ok := infoMap["headline"]; !ok || val != nil {
		t.Errorf("expected info.headline to be null, got %v", val)
	}

	if val, ok := infoMap["responseType"]; !ok {
		t.Errorf("responseType field missing")
	} else if list, isList := val.([]any); !isList || len(list) != 0 {
		t.Errorf("expected responseType to be [], got %v", val)
	}
	if val, ok := infoMap["eventCode"]; !ok {
		t.Errorf("eventCode field missing")
	} else if list, isList := val.([]any); !isList || len(list) != 0 {
		t.Errorf("expected eventCode to be [], got %v", val)
	}
	if val, ok := infoMap["resource"]; !ok {
		t.Errorf("resource field missing")
	} else if list, isList := val.([]any); !isList || len(list) != 0 {
		t.Errorf("expected resource to be [], got %v", val)
	}

	areaList, ok := infoMap["area"].([]any)
	if !ok || len(areaList) != 1 {
		t.Fatalf("expected 1 area element, got %v", infoMap["area"])
	}
	areaMap := areaList[0].(map[string]any)
	if val, ok := areaMap["polygon"]; !ok {
		t.Errorf("polygon field missing")
	} else if list, isList := val.([]any); !isList || len(list) != 0 {
		t.Errorf("expected polygon to be [], got %v", val)
	}
	if val, ok := areaMap["altitude"]; !ok || val != nil {
		t.Errorf("expected altitude to be null, got %v", val)
	}
}

func TestParseCAPTranscodeISO88591ToUTF8(t *testing.T) {
	res := ParseCAP([]byte(iso88591XML))
	if res.Error != nil {
		t.Fatalf("unexpected error parsing ISO-8859-1 CAP: %v", *res.Error)
	}
	if res.Cap == nil {
		t.Fatal("expected non-nil Cap alert")
	}
	if res.RawXML == nil {
		t.Fatal("expected non-nil RawXML")
	}
	raw := *res.RawXML

	if !strings.Contains(raw, `encoding="UTF-8"`) {
		t.Errorf("expected raw_xml to have encoding=\"UTF-8\", got: %s", raw)
	}
	if strings.Contains(strings.ToUpper(raw), "ISO-8859-1") {
		t.Errorf("raw_xml should no longer mention ISO-8859-1, got: %s", raw)
	}

	expectedUTF8Word := "eléctricas"
	if !strings.Contains(raw, expectedUTF8Word) {
		t.Errorf("expected raw_xml to contain %q in UTF-8, got: %s", expectedUTF8Word, raw)
	}
	if strings.Contains(raw, "\xe9") {
		t.Errorf("raw_xml should not contain raw 0xe9 byte")
	}

	if len(res.Cap.Info) != 1 || res.Cap.Info[0].Event != "Tormentas eléctricas" {
		t.Errorf("unexpected decoded event: %+v", res.Cap.Info)
	}
}

func TestCAPNonStrictXMLAndEntities(t *testing.T) {
	capWithEntities := `<?xml version="1.0" encoding="UTF-8"?>
<alert xmlns="urn:oasis:names:tc:emergency:cap:1.2">
  <identifier>ENT-001</identifier>
  <sender>weather@alerts.org</sender>
  <sent>2026-09-17T12:00:00Z</sent>
  <status>Actual</status>
  <msgType>Alert</msgType>
  <scope>Public</scope>
  <info>
    <category>Met</category>
    <event>Severe&nbsp;Thunderstorm</event>
    <urgency>Immediate</urgency>
    <severity>Severe</severity>
    <certainty>Observed</certainty>
    <area>
      <areaDesc>Northern&nbsp;Coast</areaDesc>
    </area>
  </info>
</alert>`

	res := ParseCAP([]byte(capWithEntities))
	if res.Error != nil {
		t.Fatalf("expected CAP with &nbsp; to parse without error, got: %v", *res.Error)
	}
	if res.Cap == nil || len(res.Cap.Info) != 1 {
		t.Fatalf("expected 1 info, got %+v", res.Cap)
	}
	expectedEvent := "Severe\u00A0Thunderstorm"
	if res.Cap.Info[0].Event != expectedEvent {
		t.Errorf("expected event %q, got %q", expectedEvent, res.Cap.Info[0].Event)
	}
	expectedArea := "Northern\u00A0Coast"
	if len(res.Cap.Info[0].Area) != 1 || res.Cap.Info[0].Area[0].AreaDesc != expectedArea {
		t.Errorf("expected areaDesc %q, got %+v", expectedArea, res.Cap.Info[0].Area)
	}
}

func TestParseCAPWithMetaTagInsideInfo(t *testing.T) {
	capWithMeta := `<?xml version="1.0" encoding="UTF-8"?>
<alert xmlns="urn:oasis:names:tc:emergency:cap:1.2">
  <identifier>META-TEST-001</identifier>
  <sender>weather@alerts.org</sender>
  <sent>2026-09-17T12:00:00Z</sent>
  <status>Actual</status>
  <msgType>Alert</msgType>
  <scope>Public</scope>
  <info>
    <category>Met</category>
    <event>Severe Thunderstorm</event>
    <urgency>Immediate</urgency>
    <severity>Severe</severity>
    <certainty>Observed</certainty>
    <meta>custom metadata value</meta>
    <area>
      <areaDesc>Northern Coast</areaDesc>
      <polygon>10.5,-61.5 10.6,-61.4 10.5,-61.4 10.5,-61.5</polygon>
    </area>
  </info>
</alert>`

	res := ParseCAP([]byte(capWithMeta))
	if res.Error != nil {
		t.Fatalf("expected CAP with <meta> tag to parse without error, got: %v", *res.Error)
	}
	if res.Cap == nil || len(res.Cap.Info) != 1 {
		t.Fatalf("expected 1 info element, got %+v", res.Cap)
	}
	info := res.Cap.Info[0]
	if len(info.Area) != 1 {
		t.Fatalf("expected 1 area element preserved after <meta>, got %d", len(info.Area))
	}
	if info.Area[0].AreaDesc != "Northern Coast" {
		t.Errorf("expected areaDesc 'Northern Coast', got %q", info.Area[0].AreaDesc)
	}
}

func TestToUTF8DoesNotTranscodeBodyEncodingText(t *testing.T) {
	docWithBodyEncoding := `<?xml version="1.0" encoding="UTF-8"?>
<alert xmlns="urn:oasis:names:tc:emergency:cap:1.2">
  <identifier>ENC-BODY-001</identifier>
  <sender>weather@alerts.org</sender>
  <sent>2026-09-17T12:00:00Z</sent>
  <status>Actual</status>
  <msgType>Alert</msgType>
  <scope>Public</scope>
  <info>
    <category>Other</category>
    <event>Configuration Note</event>
    <urgency>Unknown</urgency>
    <severity>Unknown</severity>
    <certainty>Unknown</certainty>
    <description>External source configured with encoding="ISO-8859-1" setting</description>
  </info>
</alert>`

	res := ParseCAP([]byte(docWithBodyEncoding))
	if res.Error != nil {
		t.Fatalf("unexpected error parsing CAP with body encoding text: %v", *res.Error)
	}
	if res.Cap == nil || len(res.Cap.Info) != 1 {
		t.Fatalf("expected 1 info element, got %+v", res.Cap)
	}
	expectedDesc := `External source configured with encoding="ISO-8859-1" setting`
	if res.Cap.Info[0].Description == nil || *res.Cap.Info[0].Description != expectedDesc {
		t.Errorf("expected description %q, got %v", expectedDesc, res.Cap.Info[0].Description)
	}

	rawFragment := []byte(`<note>Document with encoding="ISO-8859-1" text</note>`)
	out, err := toUTF8(rawFragment)
	if err != nil {
		t.Fatalf("toUTF8 failed: %v", err)
	}
	if string(out) != string(rawFragment) {
		t.Errorf("expected fragment unchanged, got: %s", string(out))
	}
}
