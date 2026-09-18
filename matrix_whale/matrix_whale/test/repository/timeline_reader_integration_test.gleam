// Opt-in PostgreSQL integration tests. See test/support/test_db.gleam for
// the shared harness; MATRIX_WHALE_TEST_DATABASE_URL must be set to a
// disposable, dedicated database.
import domain/earthquake
import domain/timeline
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleeunit/should
import intake/record
import message/reciever/models/earthquake_feature
import pog
import repository/earthquake_writer
import repository/timeline_reader
import support/test_db

const tie_ts = "2026-06-01 00:00:00+00"

const newer_ts = "2026-06-01 01:00:00+00"

const older_ts = "2026-05-31 23:00:00+00"

const much_older_ts = "2026-05-31 22:00:00+00"

const much_older_ts2 = "2026-05-31 21:00:00+00"

type Seed {
  Seed(
    e1: String,
    e2: String,
    e3: String,
    e4: String,
    h1: String,
    h2: String,
    h3: String,
    h4: String,
    a1: String,
    a2: String,
    a3: String,
  )
}

pub fn timeline_orders_by_first_seen_at_kind_and_key_desc_integration_test() {
  test_db.with_test_db(fn(conn) {
    let seed = seed(conn)
    let assert Ok(page) = timeline_reader.page(default_query(), conn)
    keys_of(page.items)
    |> should.equal([
      seed.a3,
      seed.h4,
      seed.h1,
      seed.e1,
      seed.a1,
      seed.a2,
      seed.h2,
    ])
    page.next_cursor |> should.equal(None)
  })
}

pub fn timeline_pagination_visits_every_row_exactly_once_integration_test() {
  test_db.with_test_db(fn(conn) {
    let seed = seed(conn)
    let expected = [
      seed.a3,
      seed.h4,
      seed.h1,
      seed.e1,
      seed.a1,
      seed.a2,
      seed.h2,
    ]
    collect_all(query_with_limit(2), conn, [])
    |> should.equal(expected)
  })
}

pub fn timeline_kinds_filter_returns_only_requested_kinds_integration_test() {
  test_db.with_test_db(fn(conn) {
    let seed = seed(conn)
    let query = timeline.Query(..default_query(), kinds: [timeline.Hazard])
    let assert Ok(page) = timeline_reader.page(query, conn)
    keys_of(page.items) |> should.equal([seed.h4, seed.h1, seed.h2])
  })
}

pub fn timeline_minmag_all_includes_low_and_null_magnitude_integration_test() {
  test_db.with_test_db(fn(conn) {
    let seed = seed(conn)
    let query =
      timeline.Query(
        ..default_query(),
        kinds: [timeline.Earthquake],
        minmag: earthquake.AllMagnitudes,
      )
    let assert Ok(page) = timeline_reader.page(query, conn)
    keys_of(page.items) |> should.equal([seed.e1, seed.e2, seed.e3])
  })
}

pub fn timeline_min_severity_filters_by_rank_integration_test() {
  test_db.with_test_db(fn(conn) {
    let seed = seed(conn)
    let query =
      timeline.Query(..default_query(), min_severity: Some(timeline.Severe))
    let assert Ok(page) = timeline_reader.page(query, conn)
    keys_of(page.items) |> should.equal([seed.a3, seed.h4, seed.h1, seed.a1])
  })
}

pub fn timeline_excludes_gdacs_earthquake_hazard_and_deleted_earthquake_integration_test() {
  test_db.with_test_db(fn(conn) {
    let seed = seed(conn)
    let query =
      timeline.Query(..default_query(), minmag: earthquake.AllMagnitudes)
    let assert Ok(page) = timeline_reader.page(query, conn)
    let keys = keys_of(page.items)
    list.contains(keys, seed.h3) |> should.equal(False)
    list.contains(keys, seed.e4) |> should.equal(False)
  })
}

pub fn timeline_marks_ended_alert_and_noncurrent_hazard_integration_test() {
  test_db.with_test_db(fn(conn) {
    let seed = seed(conn)
    let assert Ok(page) = timeline_reader.page(default_query(), conn)
    ended_of(page.items, seed.a3) |> should.equal(True)
    ended_of(page.items, seed.h2) |> should.equal(True)
    ended_of(page.items, seed.a1) |> should.equal(False)
    ended_of(page.items, seed.h1) |> should.equal(False)
  })
}

pub fn timeline_severity_matches_domain_mapping_integration_test() {
  test_db.with_test_db(fn(conn) {
    let seed = seed(conn)
    let query =
      timeline.Query(..default_query(), minmag: earthquake.AllMagnitudes)
    let assert Ok(page) = timeline_reader.page(query, conn)
    severity_of(page.items, seed.e1) |> should.equal(timeline.Moderate)
    severity_of(page.items, seed.e2) |> should.equal(timeline.Unknown)
    severity_of(page.items, seed.e3) |> should.equal(timeline.Minor)
    severity_of(page.items, seed.h1) |> should.equal(timeline.Severe)
    severity_of(page.items, seed.h4) |> should.equal(timeline.Extreme)
    severity_of(page.items, seed.h2) |> should.equal(timeline.Minor)
    severity_of(page.items, seed.a1) |> should.equal(timeline.Severe)
    severity_of(page.items, seed.a2) |> should.equal(timeline.Minor)
    severity_of(page.items, seed.a3) |> should.equal(timeline.Extreme)
  })
}

fn default_query() -> timeline.Query {
  timeline.Query(
    limit: 50,
    before: None,
    kinds: [timeline.Earthquake, timeline.Hazard, timeline.Alert],
    minmag: earthquake.Minimum(2.5),
    min_severity: None,
  )
}

fn query_with_limit(limit: Int) -> timeline.Query {
  timeline.Query(..default_query(), limit:)
}

fn collect_all(
  query: timeline.Query,
  conn: pog.Connection,
  acc: List(String),
) -> List(String) {
  let assert Ok(page) = timeline_reader.page(query, conn)
  let acc = list.append(acc, keys_of(page.items))
  case page.next_cursor {
    None -> acc
    Some(cursor) -> {
      let assert Ok(before) = timeline.decode_cursor(cursor)
      collect_all(timeline.Query(..query, before: Some(before)), conn, acc)
    }
  }
}

fn keys_of(items: List(timeline.TimelineItem)) -> List(String) {
  list.map(items, fn(item) { item.key })
}

fn ended_of(items: List(timeline.TimelineItem), key: String) -> Bool {
  let assert Ok(item) = list.find(items, fn(item) { item.key == key })
  item.ended
}

fn severity_of(
  items: List(timeline.TimelineItem),
  key: String,
) -> timeline.Severity {
  let assert Ok(item) = list.find(items, fn(item) { item.key == key })
  item.severity
}

fn seed(conn: pog.Connection) -> Seed {
  let now = test_db.now_ms()
  let e1 = create_earthquake(conn, "tl-e1", now, Some(5.0), None, tie_ts)
  let e2 = create_earthquake(conn, "tl-e2", now, None, None, much_older_ts)
  let e3 =
    create_earthquake(conn, "tl-e3", now, Some(1.0), None, much_older_ts2)
  let e4 =
    create_earthquake(conn, "tl-e4", now, Some(5.0), Some("deleted"), tie_ts)

  create_hazard(conn, "TC-100", "tropical_cyclone", "severe", True, tie_ts)
  create_hazard(conn, "FL-100", "flood", "minor", False, older_ts)
  create_hazard(conn, "EQ-100", "earthquake", "extreme", True, tie_ts)
  create_hazard(conn, "VO-100", "volcano", "extreme", True, tie_ts)

  create_alert(conn, "urn:oid:2.49.0.1.840.0.sev1", "Severe", False, tie_ts)
  create_alert(conn, "urn:oid:2.49.0.1.840.0.min1", "Minor", False, tie_ts)
  create_alert(conn, "urn:oid:2.49.0.1.840.0.ext1", "Extreme", True, newer_ts)

  Seed(
    e1: timeline.earthquake_key(e1),
    e2: timeline.earthquake_key(e2),
    e3: timeline.earthquake_key(e3),
    e4: timeline.earthquake_key(e4),
    h1: timeline.hazard_key("gdacs", "TC-100"),
    h2: timeline.hazard_key("gdacs", "FL-100"),
    h3: timeline.hazard_key("gdacs", "EQ-100"),
    h4: timeline.hazard_key("gdacs", "VO-100"),
    a1: timeline.alert_key("urn:oid:2.49.0.1.840.0.sev1"),
    a2: timeline.alert_key("urn:oid:2.49.0.1.840.0.min1"),
    a3: timeline.alert_key("urn:oid:2.49.0.1.840.0.ext1"),
  )
}

fn create_earthquake(
  conn: pog.Connection,
  id: String,
  now: Int,
  mag: Option(Float),
  status: Option(String),
  first_seen_at: String,
) -> Int {
  let feature =
    earthquake_feature.IncomingEarthquake(
      source_id: id,
      ids: [id],
      sources: ["us"],
      net: Some("us"),
      code: Some(id),
      mag:,
      mag_type: Some("ml"),
      time: now,
      updated: now,
      place: Some("Test place " <> id),
      title: Some("Test title " <> id),
      status:,
      type_: Some("earthquake"),
      tsunami: None,
      sig: None,
      alert: None,
      mmi: None,
      cdi: None,
      felt: None,
      nst: None,
      dmin: None,
      rms: None,
      gap: None,
      url: None,
      detail: None,
      lon: 139.0,
      lat: 35.0,
      depth: Some(10.0),
      raw: "{\"type\":\"Feature\",\"id\":\"" <> id <> "\"}",
    )
  let incoming =
    record.Incoming(
      key: record.Key("usgs", id),
      revision: now,
      payload: feature,
    )
  let assert Ok(written) = earthquake_writer.write_batch([incoming], now, conn)
  let assert [view] = written.result.events.new
  test_db.exec(
    conn,
    "UPDATE sea.event SET first_seen_at = '"
      <> first_seen_at
      <> "'::timestamptz WHERE id = "
      <> int.to_string(view.event.id),
  )
  view.event.id
}

fn create_hazard(
  conn: pog.Connection,
  source_id: String,
  hazard_type: String,
  cap_severity: String,
  is_current: Bool,
  first_seen_at: String,
) -> Nil {
  test_db.exec(
    conn,
    "INSERT INTO sea.hazard (source, source_id, episode_count, hazard_type, hazard_codes, alert_level, cap_severity, estimate_type, title, countries, external_ids, onset_at, onset_at_ms, modified_at, modified_at_ms, is_current, centroid, first_seen_at, last_seen_at) VALUES ('gdacs', '"
      <> source_id
      <> "', 1, '"
      <> hazard_type
      <> "', ARRAY['glide:TEST'], 'orange', '"
      <> cap_severity
      <> "', 'primary', 'Test hazard "
      <> source_id
      <> "', ARRAY['IDN'], ARRAY[]::text[], now(), 0, now(), 0, "
      <> bool_sql(is_current)
      <> ", ST_SetSRID(ST_MakePoint(105.0, -8.0), 4326), '"
      <> first_seen_at
      <> "'::timestamptz, now())",
  )
}

fn create_alert(
  conn: pog.Connection,
  id: String,
  severity: String,
  ended: Bool,
  first_seen_at: String,
) -> Nil {
  let ended_sql = case ended {
    True -> "now()"
    False -> "NULL"
  }
  test_db.exec(
    conn,
    "INSERT INTO sea.alert (id, event, severity, urgency, certainty, area_desc, first_seen_at, last_seen_at, ended_at) VALUES ('"
      <> id
      <> "', 'Test Event', '"
      <> severity
      <> "', 'Immediate', 'Observed', 'Test Area', '"
      <> first_seen_at
      <> "'::timestamptz, now(), "
      <> ended_sql
      <> ")",
  )
}

fn bool_sql(value: Bool) -> String {
  case value {
    True -> "true"
    False -> "false"
  }
}
