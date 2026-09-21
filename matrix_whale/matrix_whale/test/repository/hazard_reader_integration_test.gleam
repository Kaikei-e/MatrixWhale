// Opt-in PostgreSQL integration tests. See test/support/test_db.gleam for
// the shared harness; MATRIX_WHALE_TEST_DATABASE_URL must be set to a
// disposable, dedicated database.
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import intake/record
import message/reciever/models/gdacs
import pog
import repository/gdacs_event_writer
import repository/hazard_reader
import support/test_db

pub fn recent_filters_by_hours_type_and_level_integration_test() {
  test_db.with_test_db(fn(conn) {
    let now = test_db.now_ms()
    let old = now - 400 * 60 * 60 * 1000

    let assert Ok(_) =
      gdacs_event_writer.write_batch(
        [
          incoming(sample_feature(
            event_type: "EQ",
            event_id: 20,
            episode_id: 1,
            modified_at_ms: now,
            alert_level: "Green",
          )),
        ],
        now,
        conn,
      )
    let assert Ok(_) =
      gdacs_event_writer.write_batch(
        [
          incoming(sample_feature(
            event_type: "TC",
            event_id: 21,
            episode_id: 1,
            modified_at_ms: now,
            alert_level: "Red",
          )),
        ],
        now,
        conn,
      )
    let assert Ok(_) =
      gdacs_event_writer.write_batch(
        [
          incoming(sample_feature(
            event_type: "EQ",
            event_id: 22,
            episode_id: 1,
            modified_at_ms: old,
            alert_level: "Green",
          )),
        ],
        old,
        conn,
      )

    let assert Ok(all_recent) = hazard_reader.recent(336, [], [], conn)
    list.length(all_recent) |> should.equal(2)

    let assert Ok(only_eq) = hazard_reader.recent(336, ["EQ"], [], conn)
    list.length(only_eq) |> should.equal(1)
    let assert [eq_hazard] = only_eq
    eq_hazard.hazard_type |> should.equal("earthquake")

    let assert Ok(only_red) = hazard_reader.recent(336, [], ["red"], conn)
    list.length(only_red) |> should.equal(1)
    let assert [red_hazard] = only_red
    red_hazard.alert_level |> should.equal("red")

    // The 400h-old row falls outside a 24h window.
    let assert Ok(within_a_day) = hazard_reader.recent(24, [], [], conn)
    list.length(within_a_day) |> should.equal(2)
  })
}

pub fn detail_returns_hazard_with_episodes_integration_test() {
  test_db.with_test_db(fn(conn) {
    let now = test_db.now_ms()
    let assert Ok(_) =
      gdacs_event_writer.write_batch(
        [
          incoming(sample_feature(
            event_type: "EQ",
            event_id: 23,
            episode_id: 1,
            modified_at_ms: now,
            alert_level: "Green",
          )),
        ],
        now,
        conn,
      )
    let assert Ok(_) =
      gdacs_event_writer.write_batch(
        [
          incoming(sample_feature(
            event_type: "EQ",
            event_id: 23,
            episode_id: 2,
            modified_at_ms: now + 1000,
            alert_level: "Orange",
          )),
        ],
        now + 1000,
        conn,
      )

    let assert Ok(Some(#(hazard_row, episodes))) =
      hazard_reader.detail("gdacs", "EQ-23", conn)
    hazard_row.source_id |> should.equal("EQ-23")
    hazard_row.episode_count |> should.equal(2)
    list.length(episodes) |> should.equal(2)
    list.all(episodes, fn(e) { e.has_geometry == False }) |> should.equal(True)

    let assert Ok(None) = hazard_reader.detail("gdacs", "EQ-999999", conn)
    Nil
  })
}

pub fn recent_geometry_is_simplified_but_detail_is_full_integration_test() {
  test_db.with_test_db(fn(conn) {
    let now = test_db.now_ms()
    let assert Ok(_) =
      gdacs_event_writer.write_batch(
        [
          incoming(sample_feature(
            event_type: "EQ",
            event_id: 999,
            episode_id: 1,
            modified_at_ms: now,
            alert_level: "Green",
          )),
        ],
        now,
        conn,
      )

    let assert Ok(_) =
      pog.query(
        "UPDATE sea.hazard SET primary_geometry = ST_GeomFromGeoJSON('{\"type\":\"Point\",\"coordinates\":[1.1234567,2.1234567]}') WHERE source_id = 'EQ-999'",
      )
      |> pog.execute(conn)

    let assert Ok([recent_hazard]) = hazard_reader.recent(336, ["EQ"], [], conn)
    recent_hazard.source_id |> should.equal("EQ-999")
    let assert Some(recent_geom) = recent_hazard.primary_geometry

    string.contains(recent_geom, "1.1235") |> should.equal(True)

    let assert Ok(Some(#(detail_hazard, _))) =
      hazard_reader.detail("gdacs", "EQ-999", conn)
    detail_hazard.source_id |> should.equal("EQ-999")
    let assert Some(detail_geom) = detail_hazard.primary_geometry

    string.contains(detail_geom, "1.123457") |> should.equal(True)

    recent_geom |> should.not_equal(detail_geom)
    Nil
  })
}

fn incoming(
  feature: gdacs.GdacsFeature,
) -> record.Incoming(gdacs.GdacsFeature) {
  record.Incoming(
    key: record.Key(
      "gdacs",
      feature.event_type
        <> "-"
        <> int.to_string(feature.event_id)
        <> "-"
        <> int.to_string(feature.episode_id),
    ),
    revision: feature.modified_at_ms,
    payload: feature,
  )
}

fn sample_feature(
  event_type event_type: String,
  event_id event_id: Int,
  episode_id episode_id: Int,
  modified_at_ms modified_at_ms: Int,
  alert_level alert_level: String,
) -> gdacs.GdacsFeature {
  gdacs.GdacsFeature(
    event_type:,
    event_id:,
    episode_id:,
    alert_level:,
    alert_score: Some(1.0),
    episode_alert_level: Some(alert_level),
    episode_alert_score: Some(0.0),
    name: Some("Test hazard"),
    event_name: None,
    description: Some("Test hazard"),
    html_description: None,
    country: Some("Test Region"),
    iso3: Some("IDN"),
    glide: None,
    origin_source: Some("TEST"),
    origin_source_id: None,
    severity_value: Some(1.0),
    severity_unit: Some("M"),
    severity_text: Some("Magnitude 1.0"),
    from_at_ms: modified_at_ms,
    to_at_ms: Some(modified_at_ms),
    modified_at_ms:,
    is_current: True,
    is_temporary: False,
    longitude: 105.5,
    latitude: -8.5,
    bbox_west: None,
    bbox_south: None,
    bbox_east: None,
    bbox_north: None,
    affected_countries: [],
    report_url: None,
    geometry_url: None,
    icon_url: None,
    raw: "{\"type\":\"Feature\"}",
  )
}
