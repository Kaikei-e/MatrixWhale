import adapter/streamer
import controller/cap_controller
import controller/wis2_controller
import domain/wis2.{Wis2CapFeature}
import gleam/bit_array
import gleam/bytes_tree
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/option.{None, Some}
import gleam/string
import gleam/time/calendar
import gleam/time/duration
import gleam/time/timestamp
import gleeunit/should
import message/reciever/models/cap as models_cap
import message/reciever/wis2_reciever
import mist
import repository/wis2_writer
import simplifile
import support/test_db
import wisp/simulate

fn load_fixture_cap() -> models_cap.CapMessage {
  let assert Ok(cap_json) = simplifile.read("test/fixtures/wis2/1.cap.json")
  let assert Ok(cap_msg) = models_cap.decode_cap_json(cap_json)
  cap_msg
}

fn read_mist_body(res: response.Response(mist.ResponseData)) -> String {
  let assert mist.Bytes(tree) = res.body
  let assert Ok(text) = bit_array.to_string(bytes_tree.to_bit_array(tree))
  text
}

pub fn wis2_cap_new_alert_with_area_geometry_test() {
  use conn <- test_db.with_test_db
  let ctx = test_db.integration_context(conn)

  let cap_msg = load_fixture_cap()
  let area_poly =
    "{\"type\":\"Polygon\",\"coordinates\":[[[21.0,37.0],[22.0,37.0],[22.0,38.0],[21.0,38.0],[21.0,37.0]]]}"

  let f1 =
    Wis2CapFeature(
      notification_id: "notif-001",
      data_id: "urn:wmo:md:int.wmo.wis::GR-01",
      topic: "origin/a/wis2/eu-eumetnet-warnings/data/core/weather/advisories-warnings",
      centre_id: "eu-eumetnet-warnings",
      channel: "cache",
      pubtime: cap_msg.sent,
      datetime: None,
      license_url: Some("https://creativecommons.org/licenses/by/4.0/"),
      fetched_via: "cache",
      download_url: Some("https://example.org/cap/1.xml"),
      raw_xml: "",
      cap: Some(cap_msg),
      area_key: Some("GR009"),
      area_geometry: Some(area_poly),
      area_precision: Some(wis2.Exact),
    )

  let assert Ok(ack) = wis2_controller.process_cap(None, [f1], 1, 0, ctx)
  ack.written |> should.equal(1)
  ack.deduped |> should.equal(0)
  ack.dropped |> should.equal(0)

  // Verify source was created
  let src_priority =
    test_db.scalar_int(
      conn,
      "SELECT priority FROM sea.source WHERE id = 'wis2-eu-eumetnet-warnings'",
    )
  src_priority |> should.equal(70)

  let src_attr =
    test_db.scalar_text(
      conn,
      "SELECT attribution_text FROM sea.source WHERE id = 'wis2-eu-eumetnet-warnings'",
    )
  src_attr |> should.equal("WMO WIS2 / eu-eumetnet-warnings")

  // Verify alert created with area geometry
  let alert_source =
    test_db.scalar_text(
      conn,
      "SELECT source FROM sea.alert WHERE source_id = '"
        <> cap_msg.sender
        <> ","
        <> cap_msg.identifier
        <> "'",
    )
  alert_source |> should.equal("wis2-eu-eumetnet-warnings")

  let geom_type =
    test_db.scalar_text(
      conn,
      "SELECT ST_GeometryType(geom) FROM sea.alert WHERE source_id = '"
        <> cap_msg.sender
        <> ","
        <> cap_msg.identifier
        <> "'",
    )
  geom_type |> should.equal("ST_MultiPolygon")

  // Verify notification recorded
  let notif_outcome =
    test_db.scalar_text(
      conn,
      "SELECT outcome FROM sea.wis2_notification WHERE data_id = 'urn:wmo:md:int.wmo.wis::GR-01'",
    )
  notif_outcome |> should.equal("written")

  // Verify area stored in sea.wis2_cap_area
  test_db.count(conn, "sea.wis2_cap_area") |> should.equal(1)
}

pub fn wis2_cap_second_area_grows_geometry_test() {
  use conn <- test_db.with_test_db
  let ctx = test_db.integration_context(conn)

  let cap_msg = load_fixture_cap()
  let poly1 =
    "{\"type\":\"Polygon\",\"coordinates\":[[[21.0,37.0],[22.0,37.0],[22.0,38.0],[21.0,38.0],[21.0,37.0]]]}"
  let poly2 =
    "{\"type\":\"Polygon\",\"coordinates\":[[[25.0,37.0],[26.0,37.0],[26.0,38.0],[25.0,38.0],[25.0,37.0]]]}"

  let f1 =
    Wis2CapFeature(
      notification_id: "notif-002a",
      data_id: "urn:wmo:md:int.wmo.wis::GR-02a",
      topic: "origin/a/wis2/eu-eumetnet-warnings/data/core/weather/advisories-warnings",
      centre_id: "eu-eumetnet-warnings",
      channel: "cache",
      pubtime: cap_msg.sent,
      datetime: None,
      license_url: None,
      fetched_via: "cache",
      download_url: None,
      raw_xml: "",
      cap: Some(cap_msg),
      area_key: Some("GR009"),
      area_geometry: Some(poly1),
      area_precision: Some(wis2.Exact),
    )

  let assert Ok(ack1) = wis2_controller.process_cap(None, [f1], 1, 0, ctx)
  ack1.written |> should.equal(1)

  let num_geoms_1 =
    test_db.scalar_int(
      conn,
      "SELECT ST_NumGeometries(geom) FROM sea.alert WHERE source_id = '"
        <> cap_msg.sender
        <> ","
        <> cap_msg.identifier
        <> "'",
    )
  num_geoms_1 |> should.equal(1)

  // Second area arrives for the same CAP message
  let f2 =
    Wis2CapFeature(
      notification_id: "notif-002b",
      data_id: "urn:wmo:md:int.wmo.wis::GR-02b",
      topic: "origin/a/wis2/eu-eumetnet-warnings/data/core/weather/advisories-warnings",
      centre_id: "eu-eumetnet-warnings",
      channel: "cache",
      pubtime: cap_msg.sent,
      datetime: None,
      license_url: None,
      fetched_via: "cache",
      download_url: None,
      raw_xml: "",
      cap: Some(cap_msg),
      area_key: Some("GR010"),
      area_geometry: Some(poly2),
      area_precision: Some(wis2.Exact),
    )

  let assert Ok(ack2) = wis2_controller.process_cap(None, [f2], 1, 0, ctx)
  ack2.written |> should.equal(1)
  ack2.deduped |> should.equal(0)

  // Geometry has grown to 2 distinct polygons in the MultiPolygon
  let num_geoms_2 =
    test_db.scalar_int(
      conn,
      "SELECT ST_NumGeometries(geom) FROM sea.alert WHERE source_id = '"
        <> cap_msg.sender
        <> ","
        <> cap_msg.identifier
        <> "'",
    )
  num_geoms_2 |> should.equal(2)

  test_db.count(conn, "sea.wis2_cap_area") |> should.equal(2)
}

pub fn wis2_cap_same_cap_again_deduped_test() {
  use conn <- test_db.with_test_db
  let ctx = test_db.integration_context(conn)

  let cap_msg = load_fixture_cap()
  let poly =
    "{\"type\":\"Polygon\",\"coordinates\":[[[21.0,37.0],[22.0,37.0],[22.0,38.0],[21.0,38.0],[21.0,37.0]]]}"

  let f1 =
    Wis2CapFeature(
      notification_id: "notif-003a",
      data_id: "urn:wmo:md:int.wmo.wis::GR-03a",
      topic: "origin/a/wis2/eu-eumetnet-warnings/data/core/weather/advisories-warnings",
      centre_id: "eu-eumetnet-warnings",
      channel: "cache",
      pubtime: cap_msg.sent,
      datetime: None,
      license_url: None,
      fetched_via: "cache",
      download_url: None,
      raw_xml: "",
      cap: Some(cap_msg),
      area_key: Some("GR009"),
      area_geometry: Some(poly),
      area_precision: Some(wis2.Exact),
    )

  let assert Ok(ack1) = wis2_controller.process_cap(None, [f1], 1, 0, ctx)
  ack1.written |> should.equal(1)

  // Same CAP with same area_key again
  let f1_dup =
    Wis2CapFeature(
      notification_id: "notif-003b",
      data_id: "urn:wmo:md:int.wmo.wis::GR-03b",
      topic: "origin/a/wis2/eu-eumetnet-warnings/data/core/weather/advisories-warnings",
      centre_id: "eu-eumetnet-warnings",
      channel: "cache",
      pubtime: cap_msg.sent,
      datetime: None,
      license_url: None,
      fetched_via: "cache",
      download_url: None,
      raw_xml: "",
      cap: Some(cap_msg),
      area_key: Some("GR009"),
      area_geometry: Some(poly),
      area_precision: Some(wis2.Exact),
    )

  let assert Ok(ack2) = wis2_controller.process_cap(None, [f1_dup], 1, 0, ctx)
  ack2.written |> should.equal(0)
  ack2.deduped |> should.equal(1)

  let dup_outcome =
    test_db.scalar_text(
      conn,
      "SELECT outcome FROM sea.wis2_notification WHERE data_id = 'urn:wmo:md:int.wmo.wis::GR-03b'",
    )
  dup_outcome |> should.equal("deduped")
}

pub fn wis2_cap_already_present_from_raa_path_geometry_filled_test() {
  use conn <- test_db.with_test_db
  let ctx = test_db.integration_context(conn)

  // 1. Setup RAA registry and ingest CAP without geometry via standard pipeline
  let reg_item =
    models_cap.RegistryItem(
      guid: "urn:oid:2.49.0.0.300.0",
      title: Some("Greece: HNMS"),
      country_iso3: Some("GRC"),
      link: None,
      description: Some("CAP categories: Met"),
      pub_date: None,
      abbrev: Some("hnms"),
      feeds: [
        models_cap.RegistryFeed("https://example.org/raa/rss.xml", Some("en")),
      ],
    )
  let assert Ok(_) = cap_controller.process_registry([reg_item], 1, 0, ctx)

  let cap_msg = load_fixture_cap()
  let alert_key = cap_msg.sender <> "," <> cap_msg.identifier

  let fetch_result =
    models_cap.CapFetchResult(
      cap_url: "https://example.org/raa/100.xml",
      feed_url: "https://example.org/raa/rss.xml",
      fetched_at: cap_msg.sent,
      http_status: 200,
      error: None,
      cap: Some(cap_msg),
      raw_cap_json: Some(cap_msg.raw_json),
      raw_xml: None,
    )

  let assert Ok(ack_raa) =
    cap_controller.process_alerts([fetch_result], None, 1, 0, ctx)
  ack_raa.written |> should.equal(1)

  // Verify alert is present with source = "cap-2.49.0.0.300.0" and NULL geom
  let orig_source =
    test_db.scalar_text(
      conn,
      "SELECT source FROM sea.alert WHERE source_id = '" <> alert_key <> "'",
    )
  orig_source |> should.equal("cap-2.49.0.0.300.0")

  let orig_geom_is_null =
    test_db.scalar_int(
      conn,
      "SELECT CASE WHEN geom IS NULL THEN 1 ELSE 0 END FROM sea.alert WHERE source_id = '"
        <> alert_key
        <> "'",
    )
  orig_geom_is_null |> should.equal(1)

  // 2. Same CAP arrives via WIS2 with an area geometry
  let poly =
    "{\"type\":\"Polygon\",\"coordinates\":[[[21.0,37.0],[22.0,37.0],[22.0,38.0],[21.0,38.0],[21.0,37.0]]]}"

  let wis2_feat =
    Wis2CapFeature(
      notification_id: "notif-raa-100",
      data_id: "urn:wmo:md:int.wmo.wis::GR-RAA-100",
      topic: "origin/a/wis2/eu-eumetnet-warnings/data/core/weather/advisories-warnings",
      centre_id: "eu-eumetnet-warnings",
      channel: "cache",
      pubtime: cap_msg.sent,
      datetime: None,
      license_url: None,
      fetched_via: "cache",
      download_url: None,
      raw_xml: "",
      cap: Some(cap_msg),
      area_key: Some("GR009"),
      area_geometry: Some(poly),
      area_precision: Some(wis2.Exact),
    )

  let assert Ok(ack_wis2) =
    wis2_controller.process_cap(None, [wis2_feat], 1, 0, ctx)
  ack_wis2.written |> should.equal(1)
  ack_wis2.deduped |> should.equal(0)

  // Source remains original RAA source
  let final_source =
    test_db.scalar_text(
      conn,
      "SELECT source FROM sea.alert WHERE source_id = '" <> alert_key <> "'",
    )
  final_source |> should.equal("cap-2.49.0.0.300.0")

  // But geometry is now populated!
  let final_geom_type =
    test_db.scalar_text(
      conn,
      "SELECT ST_GeometryType(geom) FROM sea.alert WHERE source_id = '"
        <> alert_key
        <> "'",
    )
  final_geom_type |> should.equal("ST_MultiPolygon")
}

pub fn wis2_cap_with_own_polygon_wins_test() {
  use conn <- test_db.with_test_db
  let ctx = test_db.integration_context(conn)

  let base_msg = load_fixture_cap()
  let cap_polygon = "37.5,21.5 37.5,21.8 37.8,21.8 37.8,21.5 37.5,21.5"
  let assert [info1, ..rest_info] = base_msg.info
  let assert [area1, ..rest_area] = info1.area
  let area_with_geom = models_cap.CapArea(..area1, polygon: [cap_polygon])
  let info_with_geom =
    models_cap.CapInfo(..info1, area: [area_with_geom, ..rest_area])
  let cap_msg =
    models_cap.CapMessage(..base_msg, identifier: "id-own-geom", info: [
      info_with_geom,
      ..rest_info
    ])

  let wis2_area_poly =
    "{\"type\":\"Polygon\",\"coordinates\":[[[10.0,10.0],[11.0,10.0],[11.0,11.0],[10.0,11.0],[10.0,10.0]]]}"

  let feat =
    Wis2CapFeature(
      notification_id: "notif-own",
      data_id: "urn:wmo:md:int.wmo.wis::GR-OWN",
      topic: "origin/a/wis2/eu-eumetnet-warnings/data/core/weather/advisories-warnings",
      centre_id: "eu-eumetnet-warnings",
      channel: "cache",
      pubtime: cap_msg.sent,
      datetime: None,
      license_url: None,
      fetched_via: "cache",
      download_url: None,
      raw_xml: "",
      cap: Some(cap_msg),
      area_key: Some("GR009"),
      area_geometry: Some(wis2_area_poly),
      area_precision: Some(wis2.Exact),
    )

  let assert Ok(ack) = wis2_controller.process_cap(None, [feat], 1, 0, ctx)
  ack.written |> should.equal(1)

  let min_x =
    test_db.scalar_int(
      conn,
      "SELECT round(ST_XMin(geom))::int FROM sea.alert WHERE source_id = '"
        <> cap_msg.sender
        <> ",id-own-geom'",
    )
  min_x |> should.equal(22)
}

pub fn wis2_health_http_post_and_get_test() {
  use conn <- test_db.with_test_db
  let ctx = test_db.integration_context(conn)

  let now = timestamp.system_time()
  let #(now_sec, _) = timestamp.to_unix_seconds_and_nanoseconds(now)
  let window_start_str =
    timestamp.from_unix_seconds(now_sec - 3600)
    |> timestamp.to_rfc3339(calendar.utc_offset)
  let window_end_str =
    timestamp.from_unix_seconds(now_sec)
    |> timestamp.to_rfc3339(calendar.utc_offset)
  let last_rx_warnings =
    timestamp.from_unix_seconds(now_sec - 300)
    |> timestamp.to_rfc3339(calendar.utc_offset)
  let last_rx_synop =
    timestamp.from_unix_seconds(now_sec - 600)
    |> timestamp.to_rfc3339(calendar.utc_offset)

  let health_body =
    "{\"poll_meta\":{\"feed_url\":\"mqtts://wis2.example.org:8883\",\"error\":null},\"features\":[{\"centre_id\":\"eu-eumetnet-warnings\",\"kind\":\"warnings\",\"window_start\":\""
    <> window_start_str
    <> "\",\"window_end\":\""
    <> window_end_str
    <> "\",\"received\":20,\"duplicates\":2,\"download_failed\":1,\"decode_failed\":0,\"integrity_failed\":0,\"last_received_at\":\""
    <> last_rx_warnings
    <> "\"},{\"centre_id\":\"cn-cma-synop\",\"kind\":\"synop\",\"window_start\":\""
    <> window_start_str
    <> "\",\"window_end\":\""
    <> window_end_str
    <> "\",\"received\":10,\"duplicates\":0,\"download_failed\":6,\"decode_failed\":1,\"integrity_failed\":0,\"last_received_at\":\""
    <> last_rx_synop
    <> "\"}]}"

  // 1. HTTP POST to wis2_data/health receiver
  let post_req =
    simulate.request(http.Post, "/api/v1/wis2_data/health")
    |> simulate.string_body(health_body)
    |> request.set_header("content-type", "application/json")

  let post_resp = wis2_reciever.health_handler(post_req, ctx)
  post_resp.status |> should.equal(200)
  let post_resp_body = simulate.read_body(post_resp)
  string.contains(post_resp_body, "\"written\":2") |> should.equal(True)
  string.contains(post_resp_body, "\"dropped\":0") |> should.equal(True)

  // 2. HTTP GET to /api/v1/wis2/health streamer
  let get_req =
    request.new()
    |> request.set_method(http.Get)
    |> request.set_header("accept", "application/json")

  let get_resp = streamer.wis2_health_response(get_req, ctx)
  get_resp.status |> should.equal(200)
  let body_str = read_mist_body(get_resp)

  // Verify broker shape
  string.contains(body_str, "\"url\":\"mqtts://wis2.example.org:8883\"")
  |> should.equal(True)
  string.contains(body_str, "\"connected\":true") |> should.equal(True)

  // Verify channels shape and status
  string.contains(body_str, "\"centre_id\":\"eu-eumetnet-warnings\"")
  |> should.equal(True)
  string.contains(body_str, "\"status\":\"ok\"") |> should.equal(True)

  string.contains(body_str, "\"centre_id\":\"cn-cma-synop\"")
  |> should.equal(True)
  string.contains(body_str, "\"status\":\"failing\"") |> should.equal(True)
}

pub fn wis2_cleanup_retention_test() {
  use conn <- test_db.with_test_db
  let now = timestamp.system_time()
  let eight_days_ago = timestamp.subtract(now, duration.hours(8 * 24))
  let one_hour_ago = timestamp.subtract(now, duration.hours(1))
  let seven_days_ago = timestamp.subtract(now, duration.hours(7 * 24))

  // Insert old notification
  let assert Ok(Nil) =
    wis2_writer.record_notification(
      "old-notif",
      "n-old",
      "eu-eumetnet-warnings",
      "warnings",
      "topic",
      "cache",
      None,
      eight_days_ago,
      "cache",
      None,
      None,
      None,
      "written",
      conn,
    )

  // Insert recent notification
  let assert Ok(Nil) =
    wis2_writer.record_notification(
      "new-notif",
      "n-new",
      "eu-eumetnet-warnings",
      "warnings",
      "topic",
      "cache",
      None,
      one_hour_ago,
      "cache",
      None,
      None,
      None,
      "written",
      conn,
    )

  test_db.count(conn, "sea.wis2_notification") |> should.equal(2)

  // Cleanup with 7-day cutoff
  let assert Ok(Nil) = wis2_writer.cleanup(seven_days_ago, conn)

  test_db.count(conn, "sea.wis2_notification") |> should.equal(1)
  let remaining_id =
    test_db.scalar_text(conn, "SELECT data_id FROM sea.wis2_notification")
  remaining_id |> should.equal("new-notif")
}

pub fn wis2_cap_area_precision_replacement_test() {
  use conn <- test_db.with_test_db
  let ctx = test_db.integration_context(conn)

  let cap_msg = load_fixture_cap()
  let alert_id = cap_msg.sender <> "," <> cap_msg.identifier

  // Bbox geometry (wider coords: x from 20.0 to 23.0)
  let bbox_poly =
    "{\"type\":\"Polygon\",\"coordinates\":[[[20.0,36.0],[23.0,36.0],[23.0,39.0],[20.0,39.0],[20.0,36.0]]]}"
  // Exact geometry (tighter coords: x from 21.0 to 22.0)
  let exact_poly =
    "{\"type\":\"Polygon\",\"coordinates\":[[[21.0,37.0],[22.0,37.0],[22.0,38.0],[21.0,38.0],[21.0,37.0]]]}"

  // 1. bbox area first
  let f_bbox =
    Wis2CapFeature(
      notification_id: "notif-prec-bbox",
      data_id: "urn:wmo:md:int.wmo.wis::PREC-BBOX-1",
      topic: "origin/a/wis2/eu-eumetnet-warnings/data/core/weather/advisories-warnings",
      centre_id: "eu-eumetnet-warnings",
      channel: "cache",
      pubtime: cap_msg.sent,
      datetime: None,
      license_url: None,
      fetched_via: "cache",
      download_url: None,
      raw_xml: "",
      cap: Some(cap_msg),
      area_key: Some("GR009"),
      area_geometry: Some(bbox_poly),
      area_precision: Some(wis2.Bbox),
    )

  let assert Ok(ack1) = wis2_controller.process_cap(None, [f_bbox], 1, 0, ctx)
  ack1.written |> should.equal(1)
  ack1.deduped |> should.equal(0)

  // Verify stored precision is bbox
  let prec1 =
    test_db.scalar_text(
      conn,
      "SELECT precision FROM sea.wis2_cap_area WHERE area_key = 'GR009'",
    )
  prec1 |> should.equal("bbox")

  // Alert geometry has bbox xmin = 20
  let xmin1 =
    test_db.scalar_int(
      conn,
      "SELECT round(ST_XMin(geom))::int FROM sea.alert WHERE source_id = '"
        <> alert_id
        <> "'",
    )
  xmin1 |> should.equal(20)

  // 2. exact for same key -> geometry updated
  let f_exact =
    Wis2CapFeature(
      notification_id: "notif-prec-exact",
      data_id: "urn:wmo:md:int.wmo.wis::PREC-EXACT-2",
      topic: "origin/a/wis2/eu-eumetnet-warnings/data/core/weather/advisories-warnings",
      centre_id: "eu-eumetnet-warnings",
      channel: "cache",
      pubtime: cap_msg.sent,
      datetime: None,
      license_url: None,
      fetched_via: "cache",
      download_url: None,
      raw_xml: "",
      cap: Some(cap_msg),
      area_key: Some("GR009"),
      area_geometry: Some(exact_poly),
      area_precision: Some(wis2.Exact),
    )

  let assert Ok(ack2) = wis2_controller.process_cap(None, [f_exact], 1, 0, ctx)
  ack2.written |> should.equal(1)
  ack2.deduped |> should.equal(0)

  // Verify stored precision updated to exact
  let prec2 =
    test_db.scalar_text(
      conn,
      "SELECT precision FROM sea.wis2_cap_area WHERE area_key = 'GR009'",
    )
  prec2 |> should.equal("exact")

  // Alert geometry has exact xmin = 21 (geometry updated!)
  let xmin2 =
    test_db.scalar_int(
      conn,
      "SELECT round(ST_XMin(geom))::int FROM sea.alert WHERE source_id = '"
        <> alert_id
        <> "'",
    )
  xmin2 |> should.equal(21)

  // 3. exact first then bbox -> unchanged
  let f_bbox_again =
    Wis2CapFeature(
      notification_id: "notif-prec-bbox-again",
      data_id: "urn:wmo:md:int.wmo.wis::PREC-BBOX-3",
      topic: "origin/a/wis2/eu-eumetnet-warnings/data/core/weather/advisories-warnings",
      centre_id: "eu-eumetnet-warnings",
      channel: "cache",
      pubtime: cap_msg.sent,
      datetime: None,
      license_url: None,
      fetched_via: "cache",
      download_url: None,
      raw_xml: "",
      cap: Some(cap_msg),
      area_key: Some("GR009"),
      area_geometry: Some(bbox_poly),
      area_precision: Some(wis2.Bbox),
    )

  let assert Ok(ack3) =
    wis2_controller.process_cap(None, [f_bbox_again], 1, 0, ctx)
  ack3.written |> should.equal(0)
  ack3.deduped |> should.equal(1)

  // Verify stored precision is STILL exact
  let prec3 =
    test_db.scalar_text(
      conn,
      "SELECT precision FROM sea.wis2_cap_area WHERE area_key = 'GR009'",
    )
  prec3 |> should.equal("exact")

  // Alert geometry is UNCHANGED (xmin remains 21)
  let xmin3 =
    test_db.scalar_int(
      conn,
      "SELECT round(ST_XMin(geom))::int FROM sea.alert WHERE source_id = '"
        <> alert_id
        <> "'",
    )
  xmin3 |> should.equal(21)
}
