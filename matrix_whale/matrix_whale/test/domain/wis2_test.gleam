import domain/wis2.{
  Bbox, BrokerState, ChannelHealth, Exact, StatusFailing, StatusOk, StatusStale,
}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/time/duration
import gleam/time/timestamp
import gleeunit/should
import message/reciever/models/cap as models_cap
import simplifile

pub fn source_id_test() {
  wis2.source_id("eu-eumetnet-warnings")
  |> should.equal("wis2-eu-eumetnet-warnings")

  wis2.source_id("   jp-jma-synop   ")
  |> should.equal("wis2-jp-jma-synop")
}

pub fn make_source_test() {
  let s1 =
    wis2.make_source(
      "eu-eumetnet-warnings",
      Some("https://creativecommons.org/licenses/by/4.0/"),
    )
  s1.id |> should.equal("wis2-eu-eumetnet-warnings")
  s1.name |> should.equal("WMO WIS2 / eu-eumetnet-warnings")
  s1.attribution_text |> should.equal("WMO WIS2 / eu-eumetnet-warnings")
  s1.priority |> should.equal(70)
  s1.redistributable |> should.equal(False)
  s1.license |> should.equal("https://creativecommons.org/licenses/by/4.0/")

  let s2 = wis2.make_source("eu-eumetnet-warnings", None)
  s2.license |> should.equal("Unknown")

  let s3 = wis2.make_source("eu-eumetnet-warnings", Some("  "))
  s3.license |> should.equal("Unknown")
}

pub fn truncate_to_hour_test() {
  let ts = timestamp.from_unix_seconds_and_nanoseconds(1_700_000_123, 456_000)
  let truncated = wis2.truncate_to_hour(ts)
  let #(sec, nsec) = timestamp.to_unix_seconds_and_nanoseconds(truncated)
  sec |> should.equal(1_700_000_123 / 3600 * 3600)
  nsec |> should.equal(0)
}

pub fn compute_status_test() {
  let now = timestamp.from_unix_seconds_and_nanoseconds(1_727_260_000, 0)
  let one_hour_ago = timestamp.subtract(now, duration.hours(1))
  let five_hours_ago = timestamp.subtract(now, duration.hours(5))
  let seven_hours_ago = timestamp.subtract(now, duration.hours(7))
  let twenty_three_hours_ago = timestamp.subtract(now, duration.hours(23))
  let twenty_five_hours_ago = timestamp.subtract(now, duration.hours(25))

  // Healthy warnings channel
  wis2.compute_status("warnings", 10, 0, 0, 0, Some(one_hour_ago), now)
  |> should.equal(StatusOk)

  // Exactly at boundary or <= 6h
  wis2.compute_status("warnings", 10, 0, 0, 0, Some(five_hours_ago), now)
  |> should.equal(StatusOk)

  // Stale warnings channel (>6h)
  wis2.compute_status("warnings", 10, 0, 0, 0, Some(seven_hours_ago), now)
  |> should.equal(StatusStale)

  // Stale when never received
  wis2.compute_status("warnings", 0, 0, 0, 0, None, now)
  |> should.equal(StatusStale)

  // Trajectory channel healthy up to 24h
  wis2.compute_status(
    "trajectory",
    5,
    0,
    0,
    0,
    Some(twenty_three_hours_ago),
    now,
  )
  |> should.equal(StatusOk)

  // Trajectory channel stale past 24h
  wis2.compute_status(
    "trajectory",
    5,
    0,
    0,
    0,
    Some(twenty_five_hours_ago),
    now,
  )
  |> should.equal(StatusStale)

  // Synop channel stale past 6h
  wis2.compute_status("synop", 100, 0, 0, 0, Some(seven_hours_ago), now)
  |> should.equal(StatusStale)

  // Failing channel: total failures > received / 2
  // 10 received, 5 failed: 5 * 2 = 10, not > 10 -> Ok
  wis2.compute_status("warnings", 10, 2, 2, 1, Some(one_hour_ago), now)
  |> should.equal(StatusOk)

  // 10 received, 6 failed: 6 * 2 = 12 > 10 -> Failing
  wis2.compute_status("warnings", 10, 3, 2, 1, Some(one_hour_ago), now)
  |> should.equal(StatusFailing)

  // Failing takes precedence over Stale
  wis2.compute_status("warnings", 10, 3, 2, 1, Some(seven_hours_ago), now)
  |> should.equal(StatusFailing)

  // 0 received, 0 failures, recent report -> Ok
  wis2.compute_status("warnings", 0, 0, 0, 0, Some(one_hour_ago), now)
  |> should.equal(StatusOk)
}

pub fn decode_real_cap_fixture_test() {
  let assert Ok(cap_json) = simplifile.read("test/fixtures/wis2/1.cap.json")
  let assert Ok(msg) = models_cap.decode_cap_json(cap_json)

  msg.identifier |> should.equal("2.49.0.0.300.0.GR.260925114400.020000009")
  msg.sender |> should.equal("emk@hnms.gr")
  msg.status |> should.equal("Actual")
  msg.msg_type |> should.equal("Update")

  let assert [info_en, _] = msg.info
  info_en.language |> should.equal(Some("en-GB"))
  info_en.event |> should.equal("Moderate Thunderstorm warning")
  let assert [area] = info_en.area
  area.area_desc |> should.equal("West Peloponnisos")
}

pub fn decode_cap_body_test() {
  let body_json =
    "{\"poll_meta\":{\"feed_url\":\"https://example.org/feed\",\"error\":null},\"features\":[{\"notification_id\":\"n1\",\"data_id\":\"d1\",\"topic\":\"origin/a/wis2/eu-eumetnet-warnings/data/core/weather/advisories-warnings\",\"centre_id\":\"eu-eumetnet-warnings\",\"channel\":\"cache\",\"pubtime\":\"2026-09-25T12:00:00Z\",\"fetched_via\":\"cache\",\"download_url\":\"https://example.org/1.xml\",\"raw_xml\":\"\",\"cap\":{\"identifier\":\"id1\",\"sender\":\"s1\",\"sent\":\"2026-09-25T12:00:00Z\",\"status\":\"Actual\",\"msgType\":\"Alert\",\"scope\":\"Public\"},\"area_key\":\"GR001\",\"area_geometry\":\"{\\\"type\\\":\\\"Polygon\\\",\\\"coordinates\\\":[[[21.0,37.0],[22.0,37.0],[22.0,38.0],[21.0,38.0],[21.0,37.0]]]}\"},{\"invalid\":\"feature\"}]}"

  let assert Ok(dyn) = json.parse(body_json, decode.dynamic)
  let assert Ok(#(meta, features, received, dropped)) =
    wis2.decode_cap_body(dyn)

  meta
  |> should.equal(
    Some(wis2.Wis2PollMeta(Some("https://example.org/feed"), None)),
  )
  received |> should.equal(2)
  dropped |> should.equal(1)
  list.length(features) |> should.equal(1)

  let assert [f] = features
  f.notification_id |> should.equal("n1")
  f.data_id |> should.equal("d1")
  f.centre_id |> should.equal("eu-eumetnet-warnings")
  should.be_true(option.is_some(f.cap))
  f.area_key |> should.equal(Some("GR001"))
  f.area_geometry
  |> should.equal(Some(
    "{\"type\":\"Polygon\",\"coordinates\":[[[21.0,37.0],[22.0,37.0],[22.0,38.0],[21.0,38.0],[21.0,37.0]]]}",
  ))
  f.area_precision |> should.equal(Some(Exact))
}

pub fn decode_cap_body_with_json_object_geometry_test() {
  let body_json =
    "{\"features\":[{\"notification_id\":\"n2\",\"data_id\":\"d2\",\"topic\":\"topic\",\"centre_id\":\"eu-eumetnet-warnings\",\"channel\":\"origin\",\"pubtime\":\"2026-09-25T12:00:00Z\",\"fetched_via\":\"origin\",\"raw_xml\":\"\",\"cap\":{\"identifier\":\"id2\",\"sender\":\"s2\",\"sent\":\"2026-09-25T12:00:00Z\",\"status\":\"Actual\",\"msgType\":\"Alert\",\"scope\":\"Public\"},\"area_key\":\"K2\",\"area_geometry\":{\"type\":\"Polygon\",\"coordinates\":[[[1,2],[3,4],[5,6],[1,2]]]}}]}"

  let assert Ok(dyn) = json.parse(body_json, decode.dynamic)
  let assert Ok(#(_, features, received, dropped)) = wis2.decode_cap_body(dyn)

  received |> should.equal(1)
  dropped |> should.equal(0)
  let assert [f] = features
  f.area_key |> should.equal(Some("K2"))
  should.be_true(option.is_some(f.cap))
  should.be_true(option.is_some(f.area_geometry))
  f.area_precision |> should.equal(Some(Exact))
}

pub fn decode_health_body_test() {
  let body_json =
    "{\"poll_meta\":{\"feed_url\":\"mqtt://wis2.example.org\",\"error\":null},\"features\":[{\"centre_id\":\"eu-eumetnet-warnings\",\"kind\":\"warnings\",\"window_start\":\"2026-09-25T10:00:00Z\",\"window_end\":\"2026-09-25T11:00:00Z\",\"received\":15,\"duplicates\":2,\"download_failed\":1,\"decode_failed\":0,\"integrity_failed\":0,\"last_received_at\":\"2026-09-25T10:45:00Z\"}]}"

  let assert Ok(dyn) = json.parse(body_json, decode.dynamic)
  let assert Ok(#(meta, features, received, dropped)) =
    wis2.decode_health_body(dyn)

  meta
  |> should.equal(
    Some(wis2.Wis2PollMeta(Some("mqtt://wis2.example.org"), None)),
  )
  received |> should.equal(1)
  dropped |> should.equal(0)
  let assert [f] = features
  f.centre_id |> should.equal("eu-eumetnet-warnings")
  f.kind |> should.equal("warnings")
  f.received |> should.equal(15)
  f.duplicates |> should.equal(2)
  f.download_failed |> should.equal(1)
  f.last_received_at |> should.equal(Some("2026-09-25T10:45:00Z"))
}

pub fn health_report_json_test() {
  let now = timestamp.from_unix_seconds_and_nanoseconds(1_727_260_000, 0)
  let broker =
    BrokerState(
      url: "mqtt://broker.example.org",
      connected: True,
      last_report_at: Some(now),
      error: None,
    )
  let channel =
    ChannelHealth(
      centre_id: "eu-eumetnet-warnings",
      kind: "warnings",
      received_24h: 100,
      duplicates_24h: 5,
      download_failed_24h: 2,
      decode_failed_24h: 1,
      integrity_failed_24h: 0,
      last_received_at: Some(now),
      status: StatusOk,
    )

  let report_json =
    wis2.health_report_to_json(broker, [channel]) |> json.to_string
  should.be_true(report_json != "")
}

pub fn area_precision_decision_test() {
  // exact replaces bbox or exact; bbox replaces only bbox; anything replaces nothing stored
  wis2.should_replace_area(Exact, None) |> should.equal(True)
  wis2.should_replace_area(Bbox, None) |> should.equal(True)
  wis2.should_replace_area(Exact, Some(Bbox)) |> should.equal(True)
  wis2.should_replace_area(Exact, Some(Exact)) |> should.equal(True)
  wis2.should_replace_area(Bbox, Some(Bbox)) |> should.equal(True)
  wis2.should_replace_area(Bbox, Some(Exact)) |> should.equal(False)

  // Alias check
  wis2.should_replace_area(Exact, Some(Bbox)) |> should.equal(True)
  wis2.should_replace_area(Bbox, Some(Exact)) |> should.equal(False)

  // Treat replaced bbox->exact as a new area
  wis2.is_new_area(Exact, None) |> should.equal(True)
  wis2.is_new_area(Bbox, None) |> should.equal(True)
  wis2.is_new_area(Exact, Some(Bbox)) |> should.equal(True)
  wis2.is_new_area(Exact, Some(Exact)) |> should.equal(False)
  wis2.is_new_area(Bbox, Some(Bbox)) |> should.equal(False)
  wis2.is_new_area(Bbox, Some(Exact)) |> should.equal(False)
}

pub fn area_precision_string_conversion_test() {
  wis2.area_precision_to_string(Exact) |> should.equal("exact")
  wis2.area_precision_to_string(Bbox) |> should.equal("bbox")

  wis2.area_precision_from_string("exact") |> should.equal(Ok(Exact))
  wis2.area_precision_from_string("bbox") |> should.equal(Ok(Bbox))
  wis2.area_precision_from_string(" exact ") |> should.equal(Ok(Exact))
  wis2.area_precision_from_string(" bbox ") |> should.equal(Ok(Bbox))
  wis2.area_precision_from_string("invalid") |> should.equal(Error(Nil))
}

pub fn decode_cap_area_precision_test() {
  // Explicit "exact"
  let json_exact =
    "{\"features\":[{\"notification_id\":\"n1\",\"data_id\":\"d1\",\"topic\":\"t\",\"centre_id\":\"c\",\"channel\":\"cache\",\"pubtime\":\"2026-09-25T12:00:00Z\",\"fetched_via\":\"cache\",\"raw_xml\":\"\",\"area_key\":\"K1\",\"area_geometry\":{\"type\":\"Polygon\",\"coordinates\":[]},\"area_precision\":\"exact\"}]}"
  let assert Ok(dyn_exact) = json.parse(json_exact, decode.dynamic)
  let assert Ok(#(_, [f_exact], 1, 0)) = wis2.decode_cap_body(dyn_exact)
  f_exact.area_precision |> should.equal(Some(Exact))

  // Explicit "bbox"
  let json_bbox =
    "{\"features\":[{\"notification_id\":\"n2\",\"data_id\":\"d2\",\"topic\":\"t\",\"centre_id\":\"c\",\"channel\":\"cache\",\"pubtime\":\"2026-09-25T12:00:00Z\",\"fetched_via\":\"cache\",\"raw_xml\":\"\",\"area_key\":\"K2\",\"area_geometry\":{\"type\":\"Polygon\",\"coordinates\":[]},\"area_precision\":\"bbox\"}]}"
  let assert Ok(dyn_bbox) = json.parse(json_bbox, decode.dynamic)
  let assert Ok(#(_, [f_bbox], 1, 0)) = wis2.decode_cap_body(dyn_bbox)
  f_bbox.area_precision |> should.equal(Some(Bbox))

  // Backward compatibility: null area_precision with area_geometry present -> Some(Exact)
  let json_null =
    "{\"features\":[{\"notification_id\":\"n3\",\"data_id\":\"d3\",\"topic\":\"t\",\"centre_id\":\"c\",\"channel\":\"cache\",\"pubtime\":\"2026-09-25T12:00:00Z\",\"fetched_via\":\"cache\",\"raw_xml\":\"\",\"area_key\":\"K3\",\"area_geometry\":{\"type\":\"Polygon\",\"coordinates\":[]},\"area_precision\":null}]}"
  let assert Ok(dyn_null) = json.parse(json_null, decode.dynamic)
  let assert Ok(#(_, [f_null], 1, 0)) = wis2.decode_cap_body(dyn_null)
  f_null.area_precision |> should.equal(Some(Exact))

  // Backward compatibility: absent area_precision with area_geometry present -> Some(Exact)
  let json_absent =
    "{\"features\":[{\"notification_id\":\"n4\",\"data_id\":\"d4\",\"topic\":\"t\",\"centre_id\":\"c\",\"channel\":\"cache\",\"pubtime\":\"2026-09-25T12:00:00Z\",\"fetched_via\":\"cache\",\"raw_xml\":\"\",\"area_key\":\"K4\",\"area_geometry\":{\"type\":\"Polygon\",\"coordinates\":[]}}]}"
  let assert Ok(dyn_absent) = json.parse(json_absent, decode.dynamic)
  let assert Ok(#(_, [f_absent], 1, 0)) = wis2.decode_cap_body(dyn_absent)
  f_absent.area_precision |> should.equal(Some(Exact))

  // Absent area_precision and absent area_geometry -> None
  let json_no_geom =
    "{\"features\":[{\"notification_id\":\"n5\",\"data_id\":\"d5\",\"topic\":\"t\",\"centre_id\":\"c\",\"channel\":\"cache\",\"pubtime\":\"2026-09-25T12:00:00Z\",\"fetched_via\":\"cache\",\"raw_xml\":\"\"}]}"
  let assert Ok(dyn_no_geom) = json.parse(json_no_geom, decode.dynamic)
  let assert Ok(#(_, [f_no_geom], 1, 0)) = wis2.decode_cap_body(dyn_no_geom)
  f_no_geom.area_precision |> should.equal(None)

  // Null area_precision and absent area_geometry -> None
  let json_null_no_geom =
    "{\"features\":[{\"notification_id\":\"n6\",\"data_id\":\"d6\",\"topic\":\"t\",\"centre_id\":\"c\",\"channel\":\"cache\",\"pubtime\":\"2026-09-25T12:00:00Z\",\"fetched_via\":\"cache\",\"raw_xml\":\"\",\"area_precision\":null}]}"
  let assert Ok(dyn_null_no_geom) =
    json.parse(json_null_no_geom, decode.dynamic)
  let assert Ok(#(_, [f_null_no_geom], 1, 0)) =
    wis2.decode_cap_body(dyn_null_no_geom)
  f_null_no_geom.area_precision |> should.equal(None)

  // Invalid area_precision -> dropped feature
  let json_invalid =
    "{\"features\":[{\"notification_id\":\"n7\",\"data_id\":\"d7\",\"topic\":\"t\",\"centre_id\":\"c\",\"channel\":\"cache\",\"pubtime\":\"2026-09-25T12:00:00Z\",\"fetched_via\":\"cache\",\"raw_xml\":\"\",\"area_precision\":\"unknown\"}]}"
  let assert Ok(dyn_invalid) = json.parse(json_invalid, decode.dynamic)
  let assert Ok(#(_, [], 1, 1)) = wis2.decode_cap_body(dyn_invalid)
}

pub fn make_tc_source_test() {
  let s = wis2.make_tc_source("ecmwf")
  s.id |> should.equal("wis2-ecmwf")
  s.name |> should.equal("WMO WIS2 / ecmwf")
  s.attribution_text |> should.equal("WMO WIS2 / ecmwf")
  s.priority |> should.equal(75)
  s.redistributable |> should.equal(False)
  s.license |> should.equal("Unknown")
}

pub fn decode_tc_tracks_fixtures_test() {
  // Named storm fixture (FAY / 06L)
  let assert Ok(named_json) =
    simplifile.read("test/fixtures/wis2/tc_named.json")
  let envelope_named = "{\"features\":[" <> named_json <> "]}"
  let assert Ok(dyn_named) = json.parse(envelope_named, decode.dynamic)
  let assert Ok(#(meta, [feat_named], 1, 0)) =
    wis2.decode_tc_tracks_body(dyn_named)
  meta |> should.equal(None)
  feat_named.storm_id |> should.equal("06L")
  feat_named.storm_name |> should.equal(Some("FAY"))
  feat_named.centre_id |> should.equal("ecmwf")
  feat_named.originating_centre |> should.equal(98)
  feat_named.analysis_time |> should.equal("2026-09-25T06:00:00Z")
  list.length(feat_named.points) |> should.equal(17)

  let assert Ok(pt0) = list.first(feat_named.points)
  pt0.lead_hours |> should.equal(0)
  pt0.lat |> should.equal(29.8)
  pt0.lon |> should.equal(-42.6)
  pt0.mslp_pa |> should.equal(Some(101_100.0))
  pt0.max_wind_ms |> should.equal(Some(14.4))
  list.length(pt0.wind_radii) |> should.equal(3)

  // Numbered storm fixture (70W)
  let assert Ok(numbered_json) =
    simplifile.read("test/fixtures/wis2/tc_numbered.json")
  let envelope_numbered = "{\"features\":[" <> numbered_json <> "]}"
  let assert Ok(dyn_numbered) = json.parse(envelope_numbered, decode.dynamic)
  let assert Ok(#(_, [feat_numbered], 1, 0)) =
    wis2.decode_tc_tracks_body(dyn_numbered)
  feat_numbered.storm_id |> should.equal("70W")
  feat_numbered.storm_name |> should.equal(None)
  list.length(feat_numbered.points) |> should.equal(24)

  // GeoJSON LineString and BBox helpers
  let linestring_opt = wis2.points_to_linestring_geojson(feat_named.points)
  linestring_opt |> option.is_some |> should.equal(True)

  let bbox_opt = wis2.points_to_bbox(feat_named.points)
  bbox_opt |> option.is_some |> should.equal(True)

  wis2.tc_hazard_source_id("06L", "2026-09-25T06:00:00Z")
  |> should.equal("06L/2026")
}
