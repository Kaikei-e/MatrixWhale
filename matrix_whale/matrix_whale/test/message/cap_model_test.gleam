import gleam/dynamic/decode
import gleam/json
import gleam/option.{None, Some}
import gleeunit/should
import message/reciever/models/cap as models_cap

pub fn decode_registry_body_with_dropped_item_test() {
  let json_str =
    "{\"poll_meta\": {\"fetched_at\": \"2026-09-19T10:00:00Z\", \"http_status\": 200, \"feature_count\": 3, \"feed_url\": \"https://alertingauthority.wmo.int/rss.xml\"},
      \"features\": [
        {\"guid\": \"urn:oid:2.49.0.0.288.0\",
         \"title\": \"Ghana: Ghana Meteorological Agency\",
         \"country_iso3\": \"GHA\",
         \"link\": \"https://alertingauthority.wmo.int/authorities.php?recId=318\",
         \"description\": \"A WMO Member [Ghana] identifies … CAP categories:  Met.\",
         \"pub_date\": \"Thu, 17 Sep 2026 05:57:50 +0000\",
         \"abbrev\": \"gmet\",
         \"feeds\": [{\"url\": \"https://www.meteo.gov.gh/api/cap/rss.xml\", \"language\": \"en\"}]},
        {\"guid\": \"\", \"title\": \"Bad Agency\"},
        {\"guid\": \"urn:oid:2.49.0.0.170.0\",
         \"title\": \"Colombia: Instituto de Hidrologia\",
         \"country_iso3\": \"COL\",
         \"feeds\": []}
      ]}"

  let assert Ok(dyn) = json.parse(json_str, decode.dynamic)
  let assert Ok(#(meta, items, received, dropped)) =
    models_cap.decode_registry_body(dyn)

  received |> should.equal(3)
  dropped |> should.equal(1)
  let assert [ghana, colombia] = items
  ghana.guid |> should.equal("urn:oid:2.49.0.0.288.0")
  ghana.country_iso3 |> should.equal(Some("GHA"))
  let assert [feed] = ghana.feeds
  feed.url |> should.equal("https://www.meteo.gov.gh/api/cap/rss.xml")
  feed.language |> should.equal(Some("en"))

  colombia.guid |> should.equal("urn:oid:2.49.0.0.170.0")
  colombia.country_iso3 |> should.equal(Some("COL"))

  let assert Some(m) = meta
  m.http_status |> should.equal(200)
  m.feed_url
  |> should.equal(Some("https://alertingauthority.wmo.int/rss.xml"))
}

pub fn decode_index_body_with_dropped_items_test() {
  let json_str =
    "{\"poll_meta\": {\"fetched_at\": \"2026-09-19T10:05:00Z\", \"http_status\": 200, \"feature_count\": 3, \"format\": \"rss\", \"error\": null},
      \"features\": [
        {\"guid\": \"item-1\", \"title\": \"Alert 1\", \"cap_url\": \"https://example.org/cap/1.xml\", \"published\": \"Thu, 17 Sep 2026 05:00:00 GMT\"},
        {\"guid\": \"item-2\", \"title\": \"Alert 2 No URL\", \"cap_url\": null},
        {\"guid\": \"item-3\", \"title\": \"Alert 3 Non-HTTP\", \"cap_url\": \"ftp://example.org/cap/3.xml\"},
        {\"guid\": \"item-4\", \"title\": \"Alert 4\", \"cap_url\": \"http://example.org/cap/4.xml\", \"published\": \"2026-09-18T12:00:00Z\"}
      ]}"

  let assert Ok(dyn) = json.parse(json_str, decode.dynamic)
  let assert Ok(#(meta, items, received, dropped)) =
    models_cap.decode_index_body(dyn)

  received |> should.equal(4)
  dropped |> should.equal(2)
  let assert [first, second] = items
  first.cap_url |> should.equal("https://example.org/cap/1.xml")
  second.cap_url |> should.equal("http://example.org/cap/4.xml")

  let assert Some(m) = meta
  m.format |> should.equal(Some("rss"))
  m.error |> should.equal(None)
}

pub fn decode_alerts_body_verbatim_cap_and_dropped_test() {
  let json_str =
    "{\"poll_meta\": {\"fetched_at\": \"2026-09-19T10:10:00Z\", \"http_status\": 200, \"feature_count\": 3},
      \"features\": [
        {
          \"cap_url\": \"https://example.org/cap/1.xml\",
          \"feed_url\": \"https://example.org/feed.xml\",
          \"fetched_at\": \"2026-09-19T10:09:50Z\",
          \"http_status\": 200,
          \"error\": null,
          \"cap\": {
            \"cap_version\": \"1.2\",
            \"identifier\": \"id-001\",
            \"sender\": \"test-sender@agency.gov\",
            \"sent\": \"2026-09-19T10:00:00+00:00\",
            \"status\": \"Actual\",
            \"msgType\": \"Alert\",
            \"scope\": \"Public\",
            \"info\": [{
              \"language\": \"en-US\",
              \"category\": [\"Met\"],
              \"event\": \"Wind Advisory\",
              \"urgency\": \"Immediate\",
              \"severity\": \"Moderate\",
              \"certainty\": \"Likely\",
              \"area\": [{
                \"areaDesc\": \"Coastal Area\",
                \"polygon\": [\"10.0,20.0 10.0,25.0 15.0,25.0 15.0,20.0 10.0,20.0\"]
              }]
            }]
          },
          \"raw_xml\": \"<alert>...</alert>\"
        },
        {
          \"cap_url\": \"https://example.org/cap/404.xml\",
          \"feed_url\": \"https://example.org/feed.xml\",
          \"fetched_at\": \"2026-09-19T10:09:51Z\",
          \"http_status\": 404,
          \"error\": \"404 Not Found\",
          \"cap\": null,
          \"raw_xml\": null
        },
        {
          \"cap_url\": \"\",
          \"feed_url\": \"\"
        }
      ]}"

  let assert Ok(dyn) = json.parse(json_str, decode.dynamic)
  let assert Ok(#(_, items, received, dropped)) =
    models_cap.decode_alerts_body(dyn)

  received |> should.equal(3)
  dropped |> should.equal(1)
  let assert [success_item, failed_item] = items

  success_item.cap_url |> should.equal("https://example.org/cap/1.xml")
  success_item.http_status |> should.equal(200)
  let assert Some(cap_msg) = success_item.cap
  cap_msg.identifier |> should.equal("id-001")
  cap_msg.sender |> should.equal("test-sender@agency.gov")
  let assert Some(raw_json_str) = success_item.raw_cap_json
  // Verbatim re-encoded dynamic is non-empty JSON
  should.be_true(raw_json_str != "")
  should.equal(cap_msg.raw_json, raw_json_str)

  failed_item.cap_url |> should.equal("https://example.org/cap/404.xml")
  failed_item.http_status |> should.equal(404)
  failed_item.cap |> should.equal(None)
  failed_item.raw_cap_json |> should.equal(None)
}

pub fn decode_cap_meteoalarm_geocode_only_test() {
  let json_str =
    "{\"cap_version\": \"1.2\",
      \"identifier\": \"2.49.0.0.196.0.2026.09.19.001\",
      \"sender\": \"meteoalarm@cyprus.gov\",
      \"sent\": \"2026-09-19T06:00:00Z\",
      \"status\": \"Actual\",
      \"msgType\": \"Alert\",
      \"scope\": \"Public\",
      \"info\": [{
        \"language\": \"en\",
        \"category\": [\"Met\"],
        \"event\": \"High Temperature Warning\",
        \"urgency\": \"Expected\",
        \"severity\": \"Severe\",
        \"certainty\": \"Likely\",
        \"area\": [{
          \"areaDesc\": \"Nicosia District\",
          \"polygon\": [],
          \"circle\": [],
          \"geocode\": [{\"valueName\": \"WARNCELLID\", \"value\": \"108222000\"}]
        }]
      }]}"

  let assert Ok(msg) = models_cap.decode_cap_json(json_str)
  msg.identifier |> should.equal("2.49.0.0.196.0.2026.09.19.001")
  msg.status |> should.equal("Actual")
  msg.msg_type |> should.equal("Alert")
  let assert [info] = msg.info
  let assert [area] = info.area
  area.area_desc |> should.equal("Nicosia District")
  area.polygon |> should.equal([])
  area.circle |> should.equal([])
  let assert [gc] = area.geocode
  gc.value_name |> should.equal("WARNCELLID")
  gc.value |> should.equal("108222000")
}

pub fn decode_cap_go_adapter_shape_test() {
  // Exact JSON shape emitted by the Go adapter (cap_adapter/app/adapter/cap.go):
  //   cap_version: string (empty ""), altitude/ceiling: *string (numeric strings),
  //   size: *int64 (integer in JSON), empty arrays [], null scalar pointers.
  let json_str =
    "{\"cap_version\":\"\",
      \"identifier\":\"2.49.0.0.288.0.2026.09.19.001\",
      \"sender\":\"gmet@ghana.gov\",
      \"sent\":\"2026-09-19T08:00:00+00:00\",
      \"status\":\"Actual\",
      \"msgType\":\"Alert\",
      \"source\":null,
      \"scope\":\"Public\",
      \"restriction\":null,
      \"addresses\":null,
      \"code\":[],
      \"note\":null,
      \"references\":null,
      \"incidents\":null,
      \"info\":[{
        \"language\":\"en\",
        \"category\":[\"Met\"],
        \"event\":\"Thunderstorm Warning\",
        \"responseType\":[],
        \"urgency\":\"Immediate\",
        \"severity\":\"Severe\",
        \"certainty\":\"Likely\",
        \"audience\":null,
        \"eventCode\":[],
        \"effective\":null,
        \"onset\":null,
        \"expires\":\"2026-09-19T20:00:00+00:00\",
        \"senderName\":\"Ghana Met Agency\",
        \"headline\":\"Severe thunderstorm warning\",
        \"description\":null,
        \"instruction\":null,
        \"web\":null,
        \"contact\":null,
        \"parameter\":[],
        \"resource\":[{
          \"resourceDesc\":\"Advisory PDF\",
          \"mimeType\":\"application/pdf\",
          \"size\":1234,
          \"uri\":\"https://example.com/advisory.pdf\",
          \"digest\":null
        }],
        \"area\":[{
          \"areaDesc\":\"Greater Accra\",
          \"polygon\":[],
          \"circle\":[],
          \"geocode\":[{\"valueName\":\"ISO3166-2\",\"value\":\"GH-AA\"}],
          \"altitude\":\"0.0\",
          \"ceiling\":\"900\"
        }]
      }]}"

  let assert Ok(msg) = models_cap.decode_cap_json(json_str)

  // cap_version: empty string decoded as Some("")
  msg.cap_version |> should.equal(Some(""))

  msg.identifier |> should.equal("2.49.0.0.288.0.2026.09.19.001")
  msg.sender |> should.equal("gmet@ghana.gov")
  msg.status |> should.equal("Actual")
  msg.msg_type |> should.equal("Alert")
  msg.source |> should.equal(None)
  msg.code |> should.equal([])
  msg.references |> should.equal(None)

  let assert [info] = msg.info
  info.language |> should.equal(Some("en"))
  info.event |> should.equal("Thunderstorm Warning")
  info.response_type |> should.equal([])
  info.audience |> should.equal(None)
  info.description |> should.equal(None)
  info.parameter |> should.equal([])

  // Resource: integer size 1234 → Some(1234)
  let assert [res] = info.resource
  res.resource_desc |> should.equal("Advisory PDF")
  res.size |> should.equal(Some(1234))
  res.mime_type |> should.equal(Some("application/pdf"))
  res.uri |> should.equal(Some("https://example.com/advisory.pdf"))
  res.digest |> should.equal(None)

  // Area: altitude/ceiling as numeric strings, empty polygon/circle arrays
  let assert [area] = info.area
  area.area_desc |> should.equal("Greater Accra")
  area.polygon |> should.equal([])
  area.circle |> should.equal([])
  // altitude "0.0" and ceiling "900" decoded as Option(String)
  area.altitude |> should.equal(Some("0.0"))
  area.ceiling |> should.equal(Some("900"))
  let assert [geocode] = area.geocode
  geocode.value_name |> should.equal("ISO3166-2")
  geocode.value |> should.equal("GH-AA")
}

pub fn lenient_size_decoder_test() {
  // Integer size
  let json_int =
    "{\"cap_version\":\"\",\"identifier\":\"sz-int\",\"sender\":\"s@x.gov\",\"sent\":\"2026-09-19T10:00:00Z\",\"status\":\"Actual\",\"msgType\":\"Alert\",\"scope\":\"Public\",\"info\":[{\"event\":\"E\",\"urgency\":\"U\",\"severity\":\"S\",\"certainty\":\"C\",\"resource\":[{\"resourceDesc\":\"R\",\"size\":5678}]}]}"
  let assert Ok(m1) = models_cap.decode_cap_json(json_int)
  let assert [i1] = m1.info
  let assert [r1] = i1.resource
  r1.size |> should.equal(Some(5678))

  // Numeric string size
  let json_str_size =
    "{\"cap_version\":\"\",\"identifier\":\"sz-str\",\"sender\":\"s@x.gov\",\"sent\":\"2026-09-19T10:00:00Z\",\"status\":\"Actual\",\"msgType\":\"Alert\",\"scope\":\"Public\",\"info\":[{\"event\":\"E\",\"urgency\":\"U\",\"severity\":\"S\",\"certainty\":\"C\",\"resource\":[{\"resourceDesc\":\"R\",\"size\":\"999\"}]}]}"
  let assert Ok(m2) = models_cap.decode_cap_json(json_str_size)
  let assert [i2] = m2.info
  let assert [r2] = i2.resource
  r2.size |> should.equal(Some(999))

  // Non-numeric string → None
  let json_bad_size =
    "{\"cap_version\":\"\",\"identifier\":\"sz-bad\",\"sender\":\"s@x.gov\",\"sent\":\"2026-09-19T10:00:00Z\",\"status\":\"Actual\",\"msgType\":\"Alert\",\"scope\":\"Public\",\"info\":[{\"event\":\"E\",\"urgency\":\"U\",\"severity\":\"S\",\"certainty\":\"C\",\"resource\":[{\"resourceDesc\":\"R\",\"size\":\"not-a-number\"}]}]}"
  let assert Ok(m3) = models_cap.decode_cap_json(json_bad_size)
  let assert [i3] = m3.info
  let assert [r3] = i3.resource
  r3.size |> should.equal(None)
}
