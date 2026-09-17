// Opt-in PostgreSQL integration tests. See test/support/test_db.gleam for
// the shared harness; MATRIX_WHALE_TEST_DATABASE_URL must be set to a
// disposable, dedicated database.
import gleam/dict
import gleam/list
import gleam/option.{type Option}
import gleam/string
import gleam/time/timestamp
import gleeunit/should
import intake/record
import message/reciever/models/noaa
import repository/alert_writer
import support/test_db

pub fn new_alert_is_written_as_new_integration_test() {
  test_db.with_test_db(fn(conn) {
    let feature = sample_feature("alert-new", option.Some(sent_a))
    let assert Ok(written) =
      alert_writer.write_batch(
        [incoming(feature)],
        True,
        ["alert-new"],
        timestamp.system_time(),
        conn,
      )
    written.new |> should.equal(1)
    test_db.count(conn, "sea.alert") |> should.equal(1)
  })
}

pub fn identical_sent_replay_is_unchanged_and_touches_last_seen_at_integration_test() {
  test_db.with_test_db(fn(conn) {
    let feature = sample_feature("alert-same", option.Some(sent_a))

    let assert Ok(_) =
      alert_writer.write_batch(
        [incoming(feature)],
        True,
        ["alert-same"],
        timestamp.system_time(),
        conn,
      )
    let first_seen_ms = last_seen_ms(conn, "alert-same")

    let assert Ok(written) =
      alert_writer.write_batch(
        [incoming(feature)],
        True,
        ["alert-same"],
        timestamp.system_time(),
        conn,
      )
    written.new |> should.equal(0)
    written.updated |> should.equal(0)
    written.unchanged |> should.equal(1)
    { last_seen_ms(conn, "alert-same") >= first_seen_ms } |> should.equal(True)
  })
}

pub fn newer_sent_is_updated_integration_test() {
  test_db.with_test_db(fn(conn) {
    let assert Ok(_) =
      alert_writer.write_batch(
        [incoming(sample_feature("alert-newer", option.Some(sent_a)))],
        True,
        ["alert-newer"],
        timestamp.system_time(),
        conn,
      )

    let assert Ok(written) =
      alert_writer.write_batch(
        [incoming(sample_feature("alert-newer", option.Some(sent_b)))],
        True,
        ["alert-newer"],
        timestamp.system_time(),
        conn,
      )
    written.new |> should.equal(0)
    written.updated |> should.equal(1)
  })
}

pub fn older_sent_is_stale_and_row_untouched_integration_test() {
  test_db.with_test_db(fn(conn) {
    let assert Ok(_) =
      alert_writer.write_batch(
        [incoming(sample_feature("alert-stale", option.Some(sent_b)))],
        True,
        ["alert-stale"],
        timestamp.system_time(),
        conn,
      )

    let assert Ok(written) =
      alert_writer.write_batch(
        [incoming(sample_feature("alert-stale", option.Some(sent_a)))],
        True,
        ["alert-stale"],
        timestamp.system_time(),
        conn,
      )
    written.updated |> should.equal(0)
    written.stale |> should.equal(1)
    test_db.scalar_text(
      conn,
      "SELECT sent::text FROM sea.alert WHERE id='alert-stale'",
    )
    |> string.contains("01:00:00")
    |> should.equal(True)
  })
}

pub fn ended_alert_reappearing_is_revived_and_reported_as_updated_integration_test() {
  test_db.with_test_db(fn(conn) {
    let feature = sample_feature("alert-revive", option.Some(sent_a))
    let assert Ok(_) =
      alert_writer.write_batch(
        [incoming(feature)],
        True,
        ["alert-revive"],
        timestamp.system_time(),
        conn,
      )

    // Simulate a later poll where this alert is absent: the missing sweep
    // ends it.
    let assert Ok(_) =
      alert_writer.write_batch([], True, [], timestamp.system_time(), conn)
    is_ended(conn, "alert-revive") |> should.equal(True)

    // It reappears in a poll with the same sent value it had before ending.
    let assert Ok(written) =
      alert_writer.write_batch(
        [incoming(feature)],
        True,
        ["alert-revive"],
        timestamp.system_time(),
        conn,
      )
    written.updated |> should.equal(0)
    list.length(written.result.updated) |> should.equal(1)
    is_ended(conn, "alert-revive") |> should.equal(False)
  })
}

pub fn run_ended_sweep_true_ends_missing_alerts_integration_test() {
  test_db.with_test_db(fn(conn) {
    let assert Ok(_) =
      alert_writer.write_batch(
        [incoming(sample_feature("alert-missing", option.Some(sent_a)))],
        True,
        ["alert-missing"],
        timestamp.system_time(),
        conn,
      )

    let assert Ok(written) =
      alert_writer.write_batch([], True, [], timestamp.system_time(), conn)
    list.length(written.result.ended) |> should.equal(1)
    is_ended(conn, "alert-missing") |> should.equal(True)
  })
}

pub fn run_ended_sweep_false_does_not_end_missing_alerts_integration_test() {
  test_db.with_test_db(fn(conn) {
    let assert Ok(_) =
      alert_writer.write_batch(
        [incoming(sample_feature("alert-keep", option.Some(sent_a)))],
        True,
        ["alert-keep"],
        timestamp.system_time(),
        conn,
      )

    let assert Ok(written) =
      alert_writer.write_batch([], False, [], timestamp.system_time(), conn)
    list.length(written.result.ended) |> should.equal(0)
    is_ended(conn, "alert-keep") |> should.equal(False)
  })
}

const sent_a = "2026-09-18T00:00:00Z"

const sent_b = "2026-09-18T01:00:00Z"

fn incoming(
  feature: noaa.FeatureElement,
) -> record.Incoming(noaa.FeatureElement) {
  record.Incoming(
    key: record.Key("noaa", feature.id),
    revision: noaa.sent_revision_ms(feature.properties),
    payload: feature,
  )
}

fn sample_feature(id: String, sent: Option(String)) -> noaa.FeatureElement {
  noaa.FeatureElement(
    id: id,
    type_: "Feature",
    geometry: option.None,
    properties: noaa.Properties(
      id: option.None,
      type_: option.None,
      properties_id: option.None,
      area_desc: "Test Area",
      geocode: noaa.Geocode(same: [], ugc: []),
      affected_zones: [],
      references: [],
      sent: sent,
      effective: "2026-09-18T00:00:00Z",
      onset: option.None,
      expires: "2031-01-01T00:00:00Z",
      ends: option.None,
      status: noaa.Actual,
      message_type: option.None,
      category: noaa.Met,
      severity: noaa.Minor,
      certainty: noaa.Observed,
      urgency: noaa.Immediate,
      event: "Test Event",
      sender: noaa.Sender("test-sender"),
      sender_name: option.None,
      headline: option.None,
      description: option.None,
      instruction: option.None,
      response: noaa.None,
      parameters: dict.new(),
      replaced_by: option.None,
      replaced_at: option.None,
    ),
  )
}

fn last_seen_ms(conn, id: String) -> Int {
  test_db.scalar_int(
    conn,
    "SELECT (extract(epoch from last_seen_at) * 1000)::bigint FROM sea.alert WHERE id='"
      <> id
      <> "'",
  )
}

fn is_ended(conn, id: String) -> Bool {
  test_db.scalar_text(
    conn,
    "SELECT (ended_at IS NOT NULL)::text FROM sea.alert WHERE id='" <> id <> "'",
  )
  == "true"
}
