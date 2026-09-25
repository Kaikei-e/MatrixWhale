import adapter/streamer
import controller/wis2_controller
import domain/cap
import domain/wis2.{type Wis2TcFeature, Wis2TcFeature}
import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/time/duration
import gleam/time/timestamp
import gleeunit/should
import message/reciever/wis2_reciever
import mist
import repository/wis2_writer
import simplifile
import support/test_db
import wisp/simulate

fn load_named_tc() -> Wis2TcFeature {
  let assert Ok(content) = simplifile.read("test/fixtures/wis2/tc_named.json")
  let assert Ok(feature) = json.parse(content, wis2.tc_feature_decoder())
  feature
}

fn load_numbered_tc() -> Wis2TcFeature {
  let assert Ok(content) =
    simplifile.read("test/fixtures/wis2/tc_numbered.json")
  let assert Ok(feature) = json.parse(content, wis2.tc_feature_decoder())
  feature
}

fn read_mist_body(res: response.Response(mist.ResponseData)) -> String {
  let assert mist.Bytes(tree) = res.body
  let assert Ok(text) = bit_array.to_string(bytes_tree.to_bit_array(tree))
  text
}

pub fn wis2_tc_named_unmatched_storm_creates_hazard_test() {
  use conn <- test_db.with_test_db
  let ctx = test_db.integration_context(conn)

  let feature = load_named_tc()

  let assert Ok(ack) =
    wis2_controller.process_tc_tracks(None, [feature], 1, 0, ctx)
  ack.written |> should.equal(1)
  ack.deduped |> should.equal(0)
  ack.dropped |> should.equal(0)

  let priority =
    test_db.scalar_int(
      conn,
      "SELECT priority FROM sea.source WHERE id = 'wis2-ecmwf'",
    )
  priority |> should.equal(75)

  let attr =
    test_db.scalar_text(
      conn,
      "SELECT attribution_text FROM sea.source WHERE id = 'wis2-ecmwf'",
    )
  attr |> should.equal("WMO WIS2 / ecmwf")

  test_db.count(conn, "sea.wis2_tc_track") |> should.equal(1)
  let matched_source =
    test_db.scalar_text(
      conn,
      "SELECT matched_hazard_source FROM sea.wis2_tc_track WHERE storm_id = '06L'",
    )
  matched_source |> should.equal("wis2-ecmwf")

  let matched_source_id =
    test_db.scalar_text(
      conn,
      "SELECT matched_hazard_source_id FROM sea.wis2_tc_track WHERE storm_id = '06L'",
    )
  matched_source_id |> should.equal("06L/2026")

  test_db.count(conn, "sea.hazard") |> should.equal(1)
  let hazard_title =
    test_db.scalar_text(
      conn,
      "SELECT title FROM sea.hazard WHERE source = 'wis2-ecmwf' AND source_id = '06L/2026'",
    )
  hazard_title |> should.equal("FAY")

  let detail_resp =
    streamer.hazard_detail_response("wis2-ecmwf", "06L/2026", ctx)
  detail_resp.status |> should.equal(200)
  let body = read_mist_body(detail_resp)
  string.contains(body, "forecast_tracks") |> should.equal(True)
  string.contains(body, "06L") |> should.equal(True)
  string.contains(body, "wind_radii") |> should.equal(True)
}

pub fn wis2_tc_gdacs_present_same_name_matched_test() {
  use conn <- test_db.with_test_db
  let ctx = test_db.integration_context(conn)

  test_db.exec(
    conn,
    "INSERT INTO sea.source (id, name, homepage, license, attribution_text, redistributable, priority)
     VALUES ('gdacs', 'GDACS', NULL, 'Open', 'GDACS', true, 100)
     ON CONFLICT (id) DO NOTHING",
  )
  test_db.exec(
    conn,
    "INSERT INTO sea.hazard
       (source, source_id, episode_count, hazard_type, hazard_codes, alert_level,
        cap_severity, estimate_type, title, countries, external_ids,
        onset_at, onset_at_ms, modified_at, modified_at_ms, is_current,
        centroid, first_seen_at, last_seen_at)
     VALUES
       ('gdacs', 'TC-1000123', 1, 'tropical_cyclone', ARRAY['glide:TC'], 'orange',
        'severe', 'primary', 'Tropical Cyclone Fay', ARRAY['BMU'], ARRAY[]::text[],
        to_timestamp(1790316000), 1790316000000, to_timestamp(1790316000), 1790316000000,
        true, ST_SetSRID(ST_MakePoint(-42.6, 29.8), 4326), now(), now())",
  )

  let feature = load_named_tc()

  let assert Ok(ack) =
    wis2_controller.process_tc_tracks(None, [feature], 1, 0, ctx)
  ack.written |> should.equal(1)
  ack.deduped |> should.equal(0)

  let numbered_feature =
    Wis2TcFeature(
      ..feature,
      data_id: "urn:wmo:md:ecmwf:tc::71L-2026092506",
      notification_id: "notif-tc-71L",
      storm_id: "71L",
      storm_name: Some("71L"),
    )

  let assert Ok(ack_num) =
    wis2_controller.process_tc_tracks(None, [numbered_feature], 1, 0, ctx)
  ack_num.written |> should.equal(1)
  ack_num.deduped |> should.equal(0)

  test_db.count(conn, "sea.wis2_tc_track") |> should.equal(2)

  let matched_source =
    test_db.scalar_text(
      conn,
      "SELECT matched_hazard_source FROM sea.wis2_tc_track WHERE storm_id = '06L'",
    )
  matched_source |> should.equal("gdacs")

  let matched_source_id =
    test_db.scalar_text(
      conn,
      "SELECT matched_hazard_source_id FROM sea.wis2_tc_track WHERE storm_id = '06L'",
    )
  matched_source_id |> should.equal("TC-1000123")

  let matched_source_num =
    test_db.scalar_text(
      conn,
      "SELECT matched_hazard_source FROM sea.wis2_tc_track WHERE storm_id = '71L'",
    )
  matched_source_num |> should.equal("gdacs")

  let matched_source_id_num =
    test_db.scalar_text(
      conn,
      "SELECT matched_hazard_source_id FROM sea.wis2_tc_track WHERE storm_id = '71L'",
    )
  matched_source_id_num |> should.equal("TC-1000123")

  // Numbered disturbance distance-matched to GDACS hazard never creates or keeps its own hazard
  test_db.count(conn, "sea.hazard") |> should.equal(1)
  test_db.count(conn, "sea.hazard WHERE source = 'wis2-ecmwf'")
  |> should.equal(0)
  test_db.scalar_int(
    conn,
    "SELECT count(*) FROM sea.hazard WHERE source_id LIKE '71L%'",
  )
  |> should.equal(0)

  // Repository returns all runs of the latest analysis_time per centre for the hazard
  let assert Ok(tracks) =
    wis2_writer.latest_forecast_tracks_for_hazard("gdacs", "TC-1000123", conn)
  list.length(tracks) |> should.equal(2)

  // Detail response shows only the named one
  let detail_resp = streamer.hazard_detail_response("gdacs", "TC-1000123", ctx)
  detail_resp.status |> should.equal(200)
  let body = read_mist_body(detail_resp)
  string.contains(body, "forecast_tracks") |> should.equal(True)
  string.contains(body, "ecmwf") |> should.equal(True)
  string.contains(body, "06L") |> should.equal(True)
  string.contains(body, "FAY") |> should.equal(True)
  string.contains(body, "71L") |> should.equal(False)
}

pub fn wis2_tc_gdacs_numbered_run_first_then_named_test() {
  use conn <- test_db.with_test_db
  let ctx = test_db.integration_context(conn)

  test_db.exec(
    conn,
    "INSERT INTO sea.source (id, name, homepage, license, attribution_text, redistributable, priority)
     VALUES ('gdacs', 'GDACS', NULL, 'Open', 'GDACS', true, 100)
     ON CONFLICT (id) DO NOTHING",
  )
  test_db.exec(
    conn,
    "INSERT INTO sea.hazard
       (source, source_id, episode_count, hazard_type, hazard_codes, alert_level,
        cap_severity, estimate_type, title, countries, external_ids,
        onset_at, onset_at_ms, modified_at, modified_at_ms, is_current,
        centroid, first_seen_at, last_seen_at)
     VALUES
       ('gdacs', 'TC-1000123', 1, 'tropical_cyclone', ARRAY['glide:TC'], 'orange',
        'severe', 'primary', 'Tropical Cyclone Fay', ARRAY['BMU'], ARRAY[]::text[],
        to_timestamp(1790316000), 1790316000000, to_timestamp(1790316000), 1790316000000,
        true, ST_SetSRID(ST_MakePoint(-42.6, 29.8), 4326), now(), now())",
  )

  let named_feature = load_named_tc()
  let numbered_feature =
    Wis2TcFeature(
      ..named_feature,
      data_id: "urn:wmo:md:ecmwf:tc::71L-2026092506",
      notification_id: "notif-tc-71L",
      storm_id: "71L",
      storm_name: Some("71L"),
    )

  // 1. Numbered run arrives first, distance-matches GDACS hazard
  let assert Ok(ack1) =
    wis2_controller.process_tc_tracks(None, [numbered_feature], 1, 0, ctx)
  ack1.written |> should.equal(1)

  // Numbered run never creates or keeps its own hazard
  test_db.count(conn, "sea.hazard") |> should.equal(1)
  test_db.count(conn, "sea.hazard WHERE source = 'wis2-ecmwf'")
  |> should.equal(0)
  test_db.scalar_int(
    conn,
    "SELECT count(*) FROM sea.hazard WHERE source_id LIKE '71L%'",
  )
  |> should.equal(0)

  // 2. Named run arrives second, matches GDACS hazard by name
  let assert Ok(ack2) =
    wis2_controller.process_tc_tracks(None, [named_feature], 1, 0, ctx)
  ack2.written |> should.equal(1)

  test_db.count(conn, "sea.wis2_tc_track") |> should.equal(2)
  test_db.count(conn, "sea.hazard") |> should.equal(1)

  // Detail response shows only the named one
  let detail_resp = streamer.hazard_detail_response("gdacs", "TC-1000123", ctx)
  detail_resp.status |> should.equal(200)
  let body = read_mist_body(detail_resp)
  string.contains(body, "forecast_tracks") |> should.equal(True)
  string.contains(body, "ecmwf") |> should.equal(True)
  string.contains(body, "06L") |> should.equal(True)
  string.contains(body, "FAY") |> should.equal(True)
  string.contains(body, "71L") |> should.equal(False)
}

pub fn wis2_tc_unnamed_storm_stored_only_test() {
  use conn <- test_db.with_test_db
  let ctx = test_db.integration_context(conn)

  let feature = load_numbered_tc()

  let assert Ok(ack) =
    wis2_controller.process_tc_tracks(None, [feature], 1, 0, ctx)
  ack.written |> should.equal(1)
  ack.deduped |> should.equal(0)

  test_db.count(conn, "sea.wis2_tc_track") |> should.equal(1)
  let storm_id =
    test_db.scalar_text(
      conn,
      "SELECT storm_id FROM sea.wis2_tc_track WHERE storm_id = '70W'",
    )
  storm_id |> should.equal("70W")

  let has_matched =
    test_db.scalar_int(
      conn,
      "SELECT count(*) FROM sea.wis2_tc_track WHERE matched_hazard_source IS NOT NULL",
    )
  has_matched |> should.equal(0)

  test_db.count(conn, "sea.hazard") |> should.equal(0)
}

pub fn wis2_tc_newer_run_replaces_shown_track_test() {
  use conn <- test_db.with_test_db
  let ctx = test_db.integration_context(conn)

  let run1 = load_named_tc()
  let assert Ok(run1_ts) = cap.parse_rfc3339(run1.analysis_time)
  let #(run1_sec, run1_nano) =
    timestamp.to_unix_seconds_and_nanoseconds(run1_ts)
  let run1_analysis_time_ms = run1_sec * 1000 + run1_nano / 1_000_000

  let assert Ok(ack1) =
    wis2_controller.process_tc_tracks(None, [run1], 1, 0, ctx)
  ack1.written |> should.equal(1)

  let initial_onset_at_ms =
    test_db.scalar_int(
      conn,
      "SELECT onset_at_ms FROM sea.hazard WHERE source = 'wis2-ecmwf' AND source_id = '06L/2026'",
    )
  let initial_episode_count =
    test_db.scalar_int(
      conn,
      "SELECT episode_count FROM sea.hazard WHERE source = 'wis2-ecmwf' AND source_id = '06L/2026'",
    )
  let initial_modified_at_ms =
    test_db.scalar_int(
      conn,
      "SELECT modified_at_ms FROM sea.hazard WHERE source = 'wis2-ecmwf' AND source_id = '06L/2026'",
    )
  let initial_geometry =
    test_db.scalar_text(
      conn,
      "SELECT ST_AsGeoJSON(primary_geometry) FROM sea.hazard WHERE source = 'wis2-ecmwf' AND source_id = '06L/2026'",
    )

  process.sleep(10)

  let run2_points = list.drop(run1.points, 1)
  let run2 =
    Wis2TcFeature(
      ..run1,
      data_id: "urn:wmo:md:ecmwf:tc::06L-2026092512",
      analysis_time: "2026-09-25T12:00:00Z",
      points: run2_points,
    )

  let assert Ok(ack2) =
    wis2_controller.process_tc_tracks(None, [run2], 1, 0, ctx)
  ack2.written |> should.equal(1)

  test_db.count(conn, "sea.wis2_tc_track") |> should.equal(2)

  let assert Ok(tracks) =
    wis2_writer.latest_forecast_tracks_for_hazard(
      "wis2-ecmwf",
      "06L/2026",
      conn,
    )
  tracks |> should.not_equal([])
  let assert [latest] = tracks
  latest.analysis_time |> should.equal("2026-09-25T12:00:00Z")

  let detail_resp =
    streamer.hazard_detail_response("wis2-ecmwf", "06L/2026", ctx)
  let body = read_mist_body(detail_resp)
  string.contains(body, "2026-09-25T12:00:00Z") |> should.equal(True)

  let hazard_onset_at_ms =
    test_db.scalar_int(
      conn,
      "SELECT onset_at_ms FROM sea.hazard WHERE source = 'wis2-ecmwf' AND source_id = '06L/2026'",
    )
  let hazard_episode_count =
    test_db.scalar_int(
      conn,
      "SELECT episode_count FROM sea.hazard WHERE source = 'wis2-ecmwf' AND source_id = '06L/2026'",
    )
  let hazard_modified_at_ms =
    test_db.scalar_int(
      conn,
      "SELECT modified_at_ms FROM sea.hazard WHERE source = 'wis2-ecmwf' AND source_id = '06L/2026'",
    )
  let hazard_geometry =
    test_db.scalar_text(
      conn,
      "SELECT ST_AsGeoJSON(primary_geometry) FROM sea.hazard WHERE source = 'wis2-ecmwf' AND source_id = '06L/2026'",
    )
  let assert Some(expected_run2_geom) =
    wis2.points_to_linestring_geojson(run2_points)
  let geom_matches =
    test_db.scalar_int(
      conn,
      "SELECT count(*) FROM sea.hazard WHERE source = 'wis2-ecmwf' AND source_id = '06L/2026' AND ST_Equals(primary_geometry, ST_SetSRID(ST_GeomFromGeoJSON('"
        <> expected_run2_geom
        <> "'), 4326))",
    )

  hazard_onset_at_ms |> should.equal(run1_analysis_time_ms)
  hazard_onset_at_ms |> should.equal(initial_onset_at_ms)
  hazard_episode_count |> should.equal(initial_episode_count)
  hazard_episode_count |> should.equal(1)
  { hazard_modified_at_ms > initial_modified_at_ms } |> should.equal(True)
  geom_matches |> should.equal(1)
  hazard_geometry |> should.not_equal(initial_geometry)
  string.contains(hazard_geometry, "-42.3,30.1") |> should.equal(True)
  string.contains(hazard_geometry, "-42.6,29.8") |> should.equal(False)
  string.contains(initial_geometry, "-42.6,29.8") |> should.equal(True)
}

pub fn wis2_tc_resend_same_run_deduped_test() {
  use conn <- test_db.with_test_db
  let ctx = test_db.integration_context(conn)

  let feature = load_named_tc()

  let assert Ok(ack1) =
    wis2_controller.process_tc_tracks(None, [feature], 1, 0, ctx)
  ack1.written |> should.equal(1)
  ack1.deduped |> should.equal(0)

  let assert Ok(ack2) =
    wis2_controller.process_tc_tracks(None, [feature], 1, 0, ctx)
  ack2.written |> should.equal(0)
  ack2.deduped |> should.equal(1)

  test_db.count(conn, "sea.wis2_tc_track") |> should.equal(1)
}

pub fn wis2_tc_later_run_matches_gdacs_ends_own_hazard_test() {
  use conn <- test_db.with_test_db
  let ctx = test_db.integration_context(conn)

  let run1 = load_named_tc()

  // 1. Initial run creates own hazard
  let assert Ok(ack1) =
    wis2_controller.process_tc_tracks(None, [run1], 1, 0, ctx)
  ack1.written |> should.equal(1)

  let own_current_before =
    test_db.scalar_text(
      conn,
      "SELECT is_current::text FROM sea.hazard WHERE source = 'wis2-ecmwf' AND source_id = '06L/2026'",
    )
  own_current_before |> should.equal("true")

  // 2. GDACS TC appears with matching name
  test_db.exec(
    conn,
    "INSERT INTO sea.source (id, name, homepage, license, attribution_text, redistributable, priority)
     VALUES ('gdacs', 'GDACS', NULL, 'Open', 'GDACS', true, 100)
     ON CONFLICT (id) DO NOTHING",
  )
  test_db.exec(
    conn,
    "INSERT INTO sea.hazard
       (source, source_id, episode_count, hazard_type, hazard_codes, alert_level,
        cap_severity, estimate_type, title, countries, external_ids,
        onset_at, onset_at_ms, modified_at, modified_at_ms, is_current,
        centroid, first_seen_at, last_seen_at)
     VALUES
       ('gdacs', 'TC-1000123', 1, 'tropical_cyclone', ARRAY['glide:TC'], 'orange',
        'severe', 'primary', 'Tropical Cyclone Fay', ARRAY['BMU'], ARRAY[]::text[],
        to_timestamp(1790316000), 1790316000000, to_timestamp(1790316000), 1790316000000,
        true, ST_SetSRID(ST_MakePoint(-42.6, 29.8), 4326), now(), now())",
  )

  // 3. Newer run arrives and matches GDACS
  let run2 =
    Wis2TcFeature(
      ..run1,
      data_id: "urn:wmo:md:ecmwf:tc::06L-2026092512",
      analysis_time: "2026-09-25T12:00:00Z",
    )
  let assert Ok(ack2) =
    wis2_controller.process_tc_tracks(None, [run2], 1, 0, ctx)
  ack2.written |> should.equal(1)

  // Own hazard was ended
  let own_current_after =
    test_db.scalar_text(
      conn,
      "SELECT is_current::text FROM sea.hazard WHERE source = 'wis2-ecmwf' AND source_id = '06L/2026'",
    )
  own_current_after |> should.equal("false")

  // Older and newer tracks now both point to GDACS
  let matched_sources =
    test_db.scalar_int(
      conn,
      "SELECT count(*) FROM sea.wis2_tc_track WHERE matched_hazard_source = 'gdacs' AND matched_hazard_source_id = 'TC-1000123'",
    )
  matched_sources |> should.equal(2)
}

pub fn wis2_tc_retention_cleanup_test() {
  use conn <- test_db.with_test_db

  let now = timestamp.system_time()
  let eight_days_ago = timestamp.subtract(now, duration.hours(24 * 8))
  let seven_days_ago = timestamp.subtract(now, duration.hours(24 * 7))

  let feature = load_named_tc()

  test_db.exec(
    conn,
    "INSERT INTO sea.source (id, name, homepage, license, attribution_text, redistributable, priority)
     VALUES ('wis2-ecmwf', 'ECMWF', NULL, 'Open', 'WMO WIS2 / ecmwf', true, 75)
     ON CONFLICT (id) DO NOTHING",
  )

  let assert Ok(analysis_ts1) = cap.parse_rfc3339("2026-09-17T06:00:00Z")
  let assert Ok(analysis_ts2) = cap.parse_rfc3339("2026-09-25T06:00:00Z")

  let assert Ok(Nil) =
    wis2_writer.write_tc_track(
      Wis2TcFeature(..feature, analysis_time: "2026-09-17T06:00:00Z"),
      "wis2-ecmwf",
      analysis_ts1,
      None,
      None,
      eight_days_ago,
      conn,
    )

  let assert Ok(Nil) =
    wis2_writer.write_tc_track(
      Wis2TcFeature(..feature, analysis_time: "2026-09-25T06:00:00Z"),
      "wis2-ecmwf",
      analysis_ts2,
      None,
      None,
      now,
      conn,
    )

  test_db.count(conn, "sea.wis2_tc_track") |> should.equal(2)

  let assert Ok(Nil) = wis2_writer.cleanup(seven_days_ago, conn)

  test_db.count(conn, "sea.wis2_tc_track") |> should.equal(1)
  let remaining_time =
    test_db.scalar_text(
      conn,
      "SELECT to_char(analysis_time AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"') FROM sea.wis2_tc_track",
    )
  remaining_time |> should.equal("2026-09-25T06:00:00Z")
}

pub fn wis2_tc_receiver_handler_test() {
  use conn <- test_db.with_test_db
  let ctx = test_db.integration_context(conn)

  let assert Ok(raw_json) = simplifile.read("test/fixtures/wis2/tc_named.json")
  let envelope = "{\"features\":[" <> raw_json <> "]}"

  let req =
    simulate.request(http.Post, "/api/v1/wis2_data/tc_tracks")
    |> simulate.string_body(envelope)
    |> request.set_header("content-type", "application/json")
  let res = wis2_reciever.tc_tracks_handler(req, ctx)
  res.status |> should.equal(200)

  let body = simulate.read_body(res)
  string.contains(body, "\"written\":1") |> should.equal(True)
  string.contains(body, "\"deduped\":0") |> should.equal(True)
}

pub fn wis2_tc_non_tc_hazard_detail_has_no_forecast_tracks_test() {
  use conn <- test_db.with_test_db
  let ctx = test_db.integration_context(conn)

  test_db.exec(
    conn,
    "INSERT INTO sea.source (id, name, homepage, license, attribution_text, redistributable, priority)
     VALUES ('gdacs', 'GDACS', NULL, 'Open', 'GDACS', true, 100)
     ON CONFLICT (id) DO NOTHING",
  )
  test_db.exec(
    conn,
    "INSERT INTO sea.hazard
       (source, source_id, episode_count, hazard_type, hazard_codes, alert_level,
        cap_severity, estimate_type, title, countries, external_ids,
        onset_at, onset_at_ms, modified_at, modified_at_ms, is_current,
        centroid, first_seen_at, last_seen_at)
     VALUES
       ('gdacs', 'EQ-99999', 1, 'earthquake', ARRAY['glide:EQ'], 'green',
        'minor', 'primary', 'Test Earthquake', ARRAY['JPN'], ARRAY[]::text[],
        to_timestamp(1790316000), 1790316000000, to_timestamp(1790316000), 1790316000000,
        true, ST_SetSRID(ST_MakePoint(140.0, 36.0), 4326), now(), now())",
  )

  let detail_resp = streamer.hazard_detail_response("gdacs", "EQ-99999", ctx)
  detail_resp.status |> should.equal(200)
  let body = read_mist_body(detail_resp)
  string.contains(body, "hazard") |> should.equal(True)
  string.contains(body, "forecast_tracks") |> should.equal(False)
}
