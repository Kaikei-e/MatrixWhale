// Opt-in PostgreSQL integration tests. See test/support/test_db.gleam for
// the shared harness; MATRIX_WHALE_TEST_DATABASE_URL must be set to a
// disposable, dedicated database.
import domain/alert
import gleam/dict
import gleam/list
import gleam/option.{type Option}
import gleam/time/calendar
import gleam/time/duration
import gleam/time/timestamp
import gleeunit/should
import intake/record
import message/reciever/models/noaa
import repository/alert_writer
import support/test_db

pub fn new_alert_is_written_as_new_integration_test() {
  test_db.with_test_db(fn(conn) {
    let now = timestamp.system_time()
    let feature = sample_feature("alert-new", option.Some(sent_a_str(now)), now)
    let assert Ok(written) =
      alert_writer.write_batch(
        [incoming(feature)],
        True,
        ["alert-new"],
        now,
        conn,
      )
    written.new |> should.equal(1)
    test_db.count(conn, "sea.alert") |> should.equal(1)
  })
}

pub fn identical_sent_replay_is_unchanged_and_touches_last_seen_at_integration_test() {
  test_db.with_test_db(fn(conn) {
    let now = timestamp.system_time()
    let feature =
      sample_feature("alert-same", option.Some(sent_a_str(now)), now)

    let assert Ok(_) =
      alert_writer.write_batch(
        [incoming(feature)],
        True,
        ["alert-same"],
        now,
        conn,
      )
    let first_seen_ms = last_seen_ms(conn, "alert-same")

    let assert Ok(written) =
      alert_writer.write_batch(
        [incoming(feature)],
        True,
        ["alert-same"],
        now,
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
    let now = timestamp.system_time()
    let assert Ok(_) =
      alert_writer.write_batch(
        [
          incoming(sample_feature(
            "alert-newer",
            option.Some(sent_a_str(now)),
            now,
          )),
        ],
        True,
        ["alert-newer"],
        now,
        conn,
      )

    let assert Ok(written) =
      alert_writer.write_batch(
        [
          incoming(sample_feature(
            "alert-newer",
            option.Some(sent_b_str(now)),
            now,
          )),
        ],
        True,
        ["alert-newer"],
        now,
        conn,
      )
    written.new |> should.equal(0)
    written.updated |> should.equal(1)
  })
}

pub fn older_sent_is_stale_and_row_untouched_integration_test() {
  test_db.with_test_db(fn(conn) {
    let now =
      timestamp.from_unix_seconds(
        timestamp.to_unix_seconds_and_nanoseconds(timestamp.system_time()).0,
      )
    let a = sent_a_str(now)
    let b = sent_b_str(now)
    let assert Ok(_) =
      alert_writer.write_batch(
        [incoming(sample_feature("alert-stale", option.Some(b), now))],
        True,
        ["alert-stale"],
        now,
        conn,
      )

    let assert Ok(written) =
      alert_writer.write_batch(
        [incoming(sample_feature("alert-stale", option.Some(a), now))],
        True,
        ["alert-stale"],
        now,
        conn,
      )
    written.updated |> should.equal(0)
    written.stale |> should.equal(1)
    test_db.scalar_text(
      conn,
      "SELECT (sent = '"
        <> b
        <> "'::timestamptz)::text FROM sea.alert WHERE source='noaa' AND source_id='alert-stale'",
    )
    |> should.equal("true")
  })
}

pub fn ended_alert_reappearing_is_revived_and_reported_as_updated_integration_test() {
  test_db.with_test_db(fn(conn) {
    let now = timestamp.system_time()
    let feature =
      sample_feature("alert-revive", option.Some(sent_a_str(now)), now)
    let assert Ok(_) =
      alert_writer.write_batch(
        [incoming(feature)],
        True,
        ["alert-revive"],
        now,
        conn,
      )

    // Simulate a later poll where this alert is absent: the missing sweep
    // ends it.
    let assert Ok(_) = alert_writer.write_batch([], True, [], now, conn)
    is_ended(conn, "alert-revive") |> should.equal(True)

    // It reappears in a poll with the same sent value it had before ending.
    let assert Ok(written) =
      alert_writer.write_batch(
        [incoming(feature)],
        True,
        ["alert-revive"],
        now,
        conn,
      )
    written.updated |> should.equal(0)
    list.length(written.result.updated) |> should.equal(1)
    is_ended(conn, "alert-revive") |> should.equal(False)
  })
}

pub fn run_ended_sweep_true_ends_missing_alerts_integration_test() {
  test_db.with_test_db(fn(conn) {
    let now = timestamp.system_time()
    let assert Ok(_) =
      alert_writer.write_batch(
        [
          incoming(sample_feature(
            "alert-missing",
            option.Some(sent_a_str(now)),
            now,
          )),
        ],
        True,
        ["alert-missing"],
        now,
        conn,
      )

    let assert Ok(written) = alert_writer.write_batch([], True, [], now, conn)
    list.length(written.result.ended) |> should.equal(1)
    is_ended(conn, "alert-missing") |> should.equal(True)
  })
}

pub fn run_ended_sweep_false_does_not_end_missing_alerts_integration_test() {
  test_db.with_test_db(fn(conn) {
    let now = timestamp.system_time()
    let assert Ok(_) =
      alert_writer.write_batch(
        [
          incoming(sample_feature(
            "alert-keep",
            option.Some(sent_a_str(now)),
            now,
          )),
        ],
        True,
        ["alert-keep"],
        now,
        conn,
      )

    let assert Ok(written) = alert_writer.write_batch([], False, [], now, conn)
    list.length(written.result.ended) |> should.equal(0)
    is_ended(conn, "alert-keep") |> should.equal(False)
  })
}

fn sent_a_str(now: timestamp.Timestamp) -> String {
  timestamp.subtract(now, duration.hours(2))
  |> timestamp.to_rfc3339(calendar.utc_offset)
}

fn sent_b_str(now: timestamp.Timestamp) -> String {
  timestamp.subtract(now, duration.hours(1))
  |> timestamp.to_rfc3339(calendar.utc_offset)
}

fn incoming(
  feature: noaa.FeatureElement,
) -> record.Incoming(noaa.FeatureElement) {
  record.Incoming(
    key: record.Key("noaa", feature.id),
    revision: noaa.sent_revision_ms(feature.properties),
    payload: feature,
  )
}

fn sample_feature(
  id: String,
  sent: Option(String),
  now: timestamp.Timestamp,
) -> noaa.FeatureElement {
  let effective_str =
    timestamp.subtract(now, duration.hours(2))
    |> timestamp.to_rfc3339(calendar.utc_offset)
  let expires_str =
    timestamp.add(now, duration.hours(24))
    |> timestamp.to_rfc3339(calendar.utc_offset)

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
      effective: effective_str,
      onset: option.None,
      expires: expires_str,
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
    "SELECT (extract(epoch from last_seen_at) * 1000)::bigint FROM sea.alert WHERE source='noaa' AND source_id='"
      <> id
      <> "'",
  )
}

fn is_ended(conn, id: String) -> Bool {
  test_db.scalar_text(
    conn,
    "SELECT (ended_at IS NOT NULL)::text FROM sea.alert WHERE source='noaa' AND source_id='"
      <> id
      <> "'",
  )
  == "true"
}

pub fn noaa_sweeps_do_not_touch_non_noaa_row_integration_test() {
  test_db.with_test_db(fn(conn) {
    test_db.exec(
      conn,
      "INSERT INTO sea.source (id, name, license, attribution_text, redistributable, priority) VALUES ('cap-test', 'Test CAP', 'CC-BY', 'Test Attribution', true, 50) ON CONFLICT DO NOTHING;",
    )
    let now = timestamp.system_time()
    let active_until =
      timestamp.add(now, duration.hours(48))
      |> timestamp.to_rfc3339(calendar.utc_offset)
    let past_first_seen =
      timestamp.subtract(now, duration.hours(5))
      |> timestamp.to_rfc3339(calendar.utc_offset)
    let past_last_seen =
      timestamp.subtract(now, duration.hours(4))
      |> timestamp.to_rfc3339(calendar.utc_offset)
    let past_ended =
      timestamp.subtract(now, duration.hours(3))
      |> timestamp.to_rfc3339(calendar.utc_offset)

    test_db.exec(
      conn,
      "INSERT INTO sea.alert (source, source_id, event, severity, urgency, certainty, area_desc, active_until, first_seen_at, last_seen_at) VALUES ('cap-test', 'cap-alert-1', 'Gale', 'Moderate', 'Expected', 'Likely', 'Coastal Waters', '"
        <> active_until
        <> "'::timestamptz, '"
        <> past_first_seen
        <> "'::timestamptz, '"
        <> past_last_seen
        <> "'::timestamptz);",
    )

    test_db.exec(
      conn,
      "INSERT INTO sea.alert (source, source_id, event, severity, urgency, certainty, area_desc, active_until, first_seen_at, last_seen_at, ended_at, end_reason) VALUES ('cap-test', 'cap-alert-2', 'Wind', 'Minor', 'Expected', 'Likely', 'Coastal Waters', '"
        <> active_until
        <> "'::timestamptz, '"
        <> past_first_seen
        <> "'::timestamptz, '"
        <> past_last_seen
        <> "'::timestamptz, '"
        <> past_ended
        <> "'::timestamptz, 'withdrawn');",
    )

    let assert Ok(_) =
      alert_writer.write_batch([], True, ["cap-alert-2"], now, conn)

    // cap-alert-1 remains active and untouched
    test_db.scalar_text(
      conn,
      "SELECT (ended_at IS NULL)::text FROM sea.alert WHERE source='cap-test' AND source_id='cap-alert-1'",
    )
    |> should.equal("true")

    test_db.scalar_text(
      conn,
      "SELECT (end_reason IS NULL)::text FROM sea.alert WHERE source='cap-test' AND source_id='cap-alert-1'",
    )
    |> should.equal("true")

    test_db.scalar_text(
      conn,
      "SELECT (last_seen_at = '"
        <> past_last_seen
        <> "'::timestamptz)::text FROM sea.alert WHERE source='cap-test' AND source_id='cap-alert-1'",
    )
    |> should.equal("true")

    // cap-alert-2 remains ended and untouched
    test_db.scalar_text(
      conn,
      "SELECT (ended_at = '"
        <> past_ended
        <> "'::timestamptz)::text FROM sea.alert WHERE source='cap-test' AND source_id='cap-alert-2'",
    )
    |> should.equal("true")

    test_db.scalar_text(
      conn,
      "SELECT end_reason FROM sea.alert WHERE source='cap-test' AND source_id='cap-alert-2'",
    )
    |> should.equal("withdrawn")

    test_db.scalar_text(
      conn,
      "SELECT (last_seen_at = '"
        <> past_last_seen
        <> "'::timestamptz)::text FROM sea.alert WHERE source='cap-test' AND source_id='cap-alert-2'",
    )
    |> should.equal("true")
  })
}

pub fn noaa_row_with_past_active_until_is_not_revived_integration_test() {
  test_db.with_test_db(fn(conn) {
    let now = timestamp.system_time()
    let past_active =
      timestamp.subtract(now, duration.hours(1))
      |> timestamp.to_rfc3339(calendar.utc_offset)
    let past_first_seen =
      timestamp.subtract(now, duration.hours(3))
      |> timestamp.to_rfc3339(calendar.utc_offset)
    let past_ended =
      timestamp.subtract(now, duration.hours(2))
      |> timestamp.to_rfc3339(calendar.utc_offset)

    test_db.exec(
      conn,
      "INSERT INTO sea.alert (source, source_id, event, severity, urgency, certainty, area_desc, active_until, first_seen_at, last_seen_at, ended_at, end_reason) VALUES ('noaa', 'noaa-expired-1', 'Wind', 'Minor', 'Observed', 'Likely', 'Shore', '"
        <> past_active
        <> "'::timestamptz, '"
        <> past_first_seen
        <> "'::timestamptz, '"
        <> past_first_seen
        <> "'::timestamptz, '"
        <> past_ended
        <> "'::timestamptz, 'expired');",
    )

    let assert Ok(_) =
      alert_writer.write_batch([], False, ["noaa-expired-1"], now, conn)

    test_db.scalar_text(
      conn,
      "SELECT (ended_at IS NOT NULL)::text FROM sea.alert WHERE source='noaa' AND source_id='noaa-expired-1'",
    )
    |> should.equal("true")

    test_db.scalar_text(
      conn,
      "SELECT end_reason FROM sea.alert WHERE source='noaa' AND source_id='noaa-expired-1'",
    )
    |> should.equal("expired")
  })
}

pub fn update_past_due_noaa_row_does_not_revive_integration_test() {
  test_db.with_test_db(fn(conn) {
    let now = timestamp.system_time()
    let past_sent_1 =
      timestamp.subtract(now, duration.hours(5))
      |> timestamp.to_rfc3339(calendar.utc_offset)
    let past_sent_2 =
      timestamp.subtract(now, duration.hours(4))
      |> timestamp.to_rfc3339(calendar.utc_offset)
    let past_ends =
      timestamp.subtract(now, duration.hours(1))
      |> timestamp.to_rfc3339(calendar.utc_offset)
    let past_ended =
      timestamp.subtract(now, duration.hours(2))
      |> timestamp.to_rfc3339(calendar.utc_offset)

    test_db.exec(
      conn,
      "INSERT INTO sea.alert (source, source_id, event, severity, urgency, certainty, area_desc, sent, ends, active_until, first_seen_at, last_seen_at, ended_at, end_reason) VALUES ('noaa', 'noaa-past-update', 'Wind', 'Minor', 'Observed', 'Likely', 'Shore', '"
        <> past_sent_1
        <> "'::timestamptz, '"
        <> past_ends
        <> "'::timestamptz, '"
        <> past_ends
        <> "'::timestamptz, '"
        <> past_sent_1
        <> "'::timestamptz, '"
        <> past_sent_1
        <> "'::timestamptz, '"
        <> past_ended
        <> "'::timestamptz, 'expired');",
    )

    let feature =
      noaa.FeatureElement(
        id: "noaa-past-update",
        type_: "Feature",
        geometry: option.None,
        properties: noaa.Properties(
          id: option.Some("noaa-past-update"),
          type_: option.None,
          properties_id: option.None,
          area_desc: "Shore",
          geocode: noaa.Geocode(ugc: [], same: []),
          affected_zones: [],
          references: [],
          sent: option.Some(past_sent_2),
          effective: past_sent_2,
          onset: option.None,
          expires: past_ends,
          ends: option.Some(past_ends),
          status: noaa.Actual,
          message_type: option.Some(noaa.Update),
          category: noaa.Met,
          severity: noaa.Minor,
          certainty: noaa.Observed,
          urgency: noaa.Past,
          event: "Wind",
          sender: noaa.Sender("w-nws.webmaster@noaa.gov"),
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

    let assert Ok(written) =
      alert_writer.write_batch(
        [incoming(feature)],
        False,
        ["noaa-past-update"],
        now,
        conn,
      )

    written.new |> should.equal(0)
    written.updated |> should.equal(1)
    written.unchanged |> should.equal(0)
    written.stale |> should.equal(0)

    test_db.scalar_text(
      conn,
      "SELECT (ended_at IS NOT NULL)::text FROM sea.alert WHERE source='noaa' AND source_id='noaa-past-update'",
    )
    |> should.equal("true")

    test_db.scalar_text(
      conn,
      "SELECT end_reason FROM sea.alert WHERE source='noaa' AND source_id='noaa-past-update'",
    )
    |> should.equal("expired")
  })
}

pub fn new_past_due_noaa_row_counts_as_new_integration_test() {
  test_db.with_test_db(fn(conn) {
    let now = timestamp.system_time()
    let past_sent =
      timestamp.subtract(now, duration.hours(5))
      |> timestamp.to_rfc3339(calendar.utc_offset)
    let past_ends =
      timestamp.subtract(now, duration.hours(1))
      |> timestamp.to_rfc3339(calendar.utc_offset)

    let feature =
      noaa.FeatureElement(
        id: "noaa-new-past-due",
        type_: "Feature",
        geometry: option.None,
        properties: noaa.Properties(
          id: option.Some("noaa-new-past-due"),
          type_: option.None,
          properties_id: option.None,
          area_desc: "Shore",
          geocode: noaa.Geocode(ugc: [], same: []),
          affected_zones: [],
          references: [],
          sent: option.Some(past_sent),
          effective: past_sent,
          onset: option.None,
          expires: past_ends,
          ends: option.Some(past_ends),
          status: noaa.Actual,
          message_type: option.Some(noaa.Alert),
          category: noaa.Met,
          severity: noaa.Minor,
          certainty: noaa.Observed,
          urgency: noaa.Past,
          event: "Wind",
          sender: noaa.Sender("w-nws.webmaster@noaa.gov"),
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

    let records = [incoming(feature)]
    let assert Ok(written) =
      alert_writer.write_batch(records, False, ["noaa-new-past-due"], now, conn)

    written.new |> should.equal(1)
    written.updated |> should.equal(0)
    written.unchanged |> should.equal(0)
    written.stale |> should.equal(0)
    { written.new + written.updated + written.unchanged + written.stale }
    |> should.equal(list.length(records))

    test_db.scalar_text(
      conn,
      "SELECT (ended_at IS NOT NULL)::text FROM sea.alert WHERE source='noaa' AND source_id='noaa-new-past-due'",
    )
    |> should.equal("true")

    test_db.scalar_text(
      conn,
      "SELECT end_reason FROM sea.alert WHERE source='noaa' AND source_id='noaa-new-past-due'",
    )
    |> should.equal("expired")
  })
}

pub fn expiry_sweep_ends_past_active_until_integration_test() {
  test_db.with_test_db(fn(conn) {
    let now = timestamp.system_time()
    let past_active =
      timestamp.subtract(now, duration.hours(1))
      |> timestamp.to_rfc3339(calendar.utc_offset)
    let past_first_seen =
      timestamp.subtract(now, duration.hours(2))
      |> timestamp.to_rfc3339(calendar.utc_offset)

    test_db.exec(
      conn,
      "INSERT INTO sea.alert (source, source_id, event, severity, urgency, certainty, area_desc, active_until, first_seen_at, last_seen_at) VALUES ('noaa', 'expired-alert', 'Wind', 'Minor', 'Past', 'Observed', 'Shore', '"
        <> past_active
        <> "'::timestamptz, '"
        <> past_first_seen
        <> "'::timestamptz, '"
        <> past_first_seen
        <> "'::timestamptz);",
    )

    let assert Ok(_) = alert_writer.expire_due(now, conn)

    test_db.scalar_text(
      conn,
      "SELECT (ended_at IS NOT NULL)::text FROM sea.alert WHERE source='noaa' AND source_id='expired-alert'",
    )
    |> should.equal("true")
    test_db.scalar_text(
      conn,
      "SELECT COALESCE(end_reason, '')::text FROM sea.alert WHERE source='noaa' AND source_id='expired-alert'",
    )
    |> should.equal("expired")
  })
}

pub fn expire_due_ends_cap_row_past_active_until_with_no_noaa_write_integration_test() {
  test_db.with_test_db(fn(conn) {
    test_db.exec(
      conn,
      "INSERT INTO sea.source (id, name, license, attribution_text, redistributable, priority) VALUES ('cap-test', 'Test CAP', 'CC-BY', 'Test Attribution', true, 50) ON CONFLICT DO NOTHING;",
    )
    let now = timestamp.system_time()
    let past_active =
      timestamp.subtract(now, duration.hours(1))
      |> timestamp.to_rfc3339(calendar.utc_offset)
    let past_first_seen =
      timestamp.subtract(now, duration.hours(2))
      |> timestamp.to_rfc3339(calendar.utc_offset)

    test_db.exec(
      conn,
      "INSERT INTO sea.alert (source, source_id, event, severity, urgency, certainty, area_desc, active_until, first_seen_at, last_seen_at) VALUES ('cap-test', 'cap-expired-no-noaa', 'Wind', 'Minor', 'Past', 'Observed', 'Shore', '"
        <> past_active
        <> "'::timestamptz, '"
        <> past_first_seen
        <> "'::timestamptz, '"
        <> past_first_seen
        <> "'::timestamptz);",
    )

    let assert Ok(ended_rows) = alert_writer.expire_due(now, conn)

    list.length(ended_rows) |> should.equal(1)
    let assert Ok(ended_row) = list.first(ended_rows)
    ended_row.source |> should.equal("cap-test")
    ended_row.source_id |> should.equal("cap-expired-no-noaa")
    ended_row.end_reason |> should.equal(option.Some("expired"))
    option.is_some(ended_row.ended_at) |> should.equal(True)

    test_db.scalar_text(
      conn,
      "SELECT (ended_at IS NOT NULL)::text FROM sea.alert WHERE source='cap-test' AND source_id='cap-expired-no-noaa'",
    )
    |> should.equal("true")
    test_db.scalar_text(
      conn,
      "SELECT COALESCE(end_reason, '')::text FROM sea.alert WHERE source='cap-test' AND source_id='cap-expired-no-noaa'",
    )
    |> should.equal("expired")
  })
}

pub fn write_cap_rows_lifecycle_integration_test() {
  test_db.with_test_db(fn(conn) {
    test_db.exec(
      conn,
      "INSERT INTO sea.source (id, name, license, attribution_text, redistributable, priority) VALUES ('cap-test', 'Test CAP', 'CC-BY', 'Test Attribution', true, 50) ON CONFLICT DO NOTHING;",
    )
    let now = timestamp.system_time()
    let active_until = timestamp.add(now, duration.hours(24))

    let write_a =
      alert.AlertWrite(
        source: "cap-test",
        source_id: "cap-1",
        sender: option.Some("sender@dwd.de"),
        sender_name: option.Some("DWD"),
        identifier: option.Some("cap-1-id"),
        message_type: option.Some("Alert"),
        event: "Severe Thunderstorm",
        category: ["Met"],
        severity: "Severe",
        urgency: "Immediate",
        certainty: "Observed",
        headline: option.Some("Severe Storm Warning"),
        description: option.Some("Large hail expected"),
        instruction: option.Some("Take shelter"),
        web: option.Some("https://dwd.de"),
        contact: option.None,
        language: option.Some("en-US"),
        area_desc: "Bavaria",
        geocodes: "[]",
        countries: ["DEU"],
        geom: option.None,
        reference_keys: [],
        sent: option.Some(now),
        effective: option.Some(now),
        onset: option.None,
        expires: option.Some(active_until),
        ends: option.None,
        active_until: active_until,
        ended_at: option.None,
        end_reason: option.None,
        superseded_by: option.None,
      )

    // 1. Insert new CAP row
    let assert Ok(diff1) = alert_writer.write_cap_rows([write_a], [], now, conn)
    list.length(diff1.new) |> should.equal(1)
    list.length(diff1.updated) |> should.equal(0)
    list.length(diff1.ended) |> should.equal(0)

    // 2. Update existing CAP row (new headline)
    let write_a_updated =
      alert.AlertWrite(
        ..write_a,
        headline: option.Some("Updated Severe Storm Warning"),
      )
    let assert Ok(diff2) =
      alert_writer.write_cap_rows([write_a_updated], [], now, conn)
    list.length(diff2.new) |> should.equal(0)
    list.length(diff2.updated) |> should.equal(1)
    list.length(diff2.ended) |> should.equal(0)

    // 3. Insert already-ended CAP row lands in ended not new
    let write_already_ended =
      alert.AlertWrite(
        ..write_a,
        source_id: "cap-already-ended",
        ended_at: option.Some(now),
        end_reason: option.Some("cancelled"),
      )
    let assert Ok(diff3) =
      alert_writer.write_cap_rows([write_already_ended], [], now, conn)
    diff3.new |> should.equal([])
    list.length(diff3.ended) |> should.equal(1)
    test_db.scalar_text(
      conn,
      "SELECT (ended_at IS NOT NULL)::text FROM sea.alert WHERE source='cap-test' AND source_id='cap-already-ended'",
    )
    |> should.equal("true")

    // 4. Cancel end-instruction on an ACTIVE row ends it cancelled
    let write_active = alert.AlertWrite(..write_a, source_id: "cap-to-cancel")
    let assert Ok(_) =
      alert_writer.write_cap_rows([write_active], [], now, conn)

    let cancel_instruction =
      alert.EndInstruction(
        source: "cap-test",
        source_id: "cap-to-cancel",
        end_reason: "cancelled",
        superseded_by: option.None,
      )
    let assert Ok(diff_cancel) =
      alert_writer.write_cap_rows([], [cancel_instruction], now, conn)
    list.length(diff_cancel.ended) |> should.equal(1)
    let assert Ok(cancelled_row) = list.first(diff_cancel.ended)
    cancelled_row.end_reason |> should.equal(option.Some("cancelled"))
    option.is_some(cancelled_row.ended_at) |> should.equal(True)
    test_db.scalar_text(
      conn,
      "SELECT COALESCE(end_reason, '')::text FROM sea.alert WHERE source='cap-test' AND source_id='cap-to-cancel'",
    )
    |> should.equal("cancelled")

    // 5. End instruction on an ALREADY-ENDED row returns ended == []
    let assert Ok(diff_already_ended) =
      alert_writer.write_cap_rows([], [cancel_instruction], now, conn)
    diff_already_ended.ended |> should.equal([])

    let cancel_already_ended2 =
      alert.EndInstruction(
        source: "cap-test",
        source_id: "cap-already-ended",
        end_reason: "cancelled",
        superseded_by: option.None,
      )
    let assert Ok(diff_already_ended2) =
      alert_writer.write_cap_rows([], [cancel_already_ended2], now, conn)
    diff_already_ended2.ended |> should.equal([])

    // 6. Supersede instruction on active row cap-1
    let supersede_instruction =
      alert.EndInstruction(
        source: "cap-test",
        source_id: "cap-1",
        end_reason: "superseded",
        superseded_by: option.Some("cap-2"),
      )
    let assert Ok(diff4) =
      alert_writer.write_cap_rows([], [supersede_instruction], now, conn)
    list.length(diff4.ended) |> should.equal(1)
    test_db.scalar_text(
      conn,
      "SELECT COALESCE(end_reason, '')::text FROM sea.alert WHERE source='cap-test' AND source_id='cap-1'",
    )
    |> should.equal("superseded")
    test_db.scalar_text(
      conn,
      "SELECT COALESCE(superseded_by, '')::text FROM sea.alert WHERE source='cap-test' AND source_id='cap-1'",
    )
    |> should.equal("cap-2")
  })
}
