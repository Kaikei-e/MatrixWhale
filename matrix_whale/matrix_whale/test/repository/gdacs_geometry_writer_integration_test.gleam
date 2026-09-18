// Opt-in PostgreSQL integration tests. See test/support/test_db.gleam for
// the shared harness; MATRIX_WHALE_TEST_DATABASE_URL must be set to a
// disposable, dedicated database.
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import intake/record
import message/reciever/models/gdacs
import repository/gdacs_event_writer
import repository/gdacs_geometry_writer
import support/test_db

const feature_collection = "{\"type\":\"FeatureCollection\",\"features\":[{\"properties\":{\"Class\":\"Poly_Circle\"},\"geometry\":{\"type\":\"Polygon\",\"coordinates\":[[[105,-9],[106,-9],[106,-8],[105,-8],[105,-9]]]}}]}"

pub fn pending_excludes_fetched_episodes_integration_test() {
  test_db.with_test_db(fn(conn) {
    let now = test_db.now_ms()
    let feature =
      sample_feature(event_id: 10, episode_id: 1, modified_at_ms: 100)
    let assert Ok(_) =
      gdacs_event_writer.write_batch([incoming(feature)], now, conn)

    let assert Ok(pending_before) = gdacs_geometry_writer.pending(20, conn)
    list.any(pending_before, fn(p) { p.1 == 10 }) |> should.equal(True)

    let result =
      gdacs.GdacsGeometryResult(
        event_type: "EQ",
        event_id: 10,
        episode_id: 1,
        http_status: 200,
        geometry: Some(feature_collection),
      )
    let assert Ok(outcome) = gdacs_geometry_writer.apply([result], now, conn)
    outcome.written |> should.equal(1)
    outcome.deduped |> should.equal(0)
    outcome.dropped |> should.equal(0)

    let assert Ok(pending_after) = gdacs_geometry_writer.pending(20, conn)
    list.any(pending_after, fn(p) { p.1 == 10 }) |> should.equal(False)

    // Re-applying the same episode is a no-op (already fetched), not an error.
    let assert Ok(replay) = gdacs_geometry_writer.apply([result], now, conn)
    replay.written |> should.equal(0)
    replay.deduped |> should.equal(1)
  })
}

pub fn apply_fills_primary_geometry_and_geometries_integration_test() {
  test_db.with_test_db(fn(conn) {
    let now = test_db.now_ms()
    let feature =
      sample_feature(event_id: 11, episode_id: 1, modified_at_ms: 100)
    let assert Ok(_) =
      gdacs_event_writer.write_batch([incoming(feature)], now, conn)

    let result =
      gdacs.GdacsGeometryResult(
        event_type: "EQ",
        event_id: 11,
        episode_id: 1,
        http_status: 200,
        geometry: Some(feature_collection),
      )
    let assert Ok(outcome) = gdacs_geometry_writer.apply([result], now, conn)
    let assert [changed] = outcome.changed_hazards
    changed.primary_geometry |> should.not_equal(None)
    changed.geometries |> should.not_equal(None)
  })
}

pub fn apply_backfills_origin_source_id_when_missing_integration_test() {
  test_db.with_test_db(fn(conn) {
    let now = test_db.now_ms()
    let feature =
      sample_feature(event_id: 12, episode_id: 1, modified_at_ms: 100)
    let feature = gdacs.GdacsFeature(..feature, origin_source_id: None)
    let assert Ok(_) =
      gdacs_event_writer.write_batch([incoming(feature)], now, conn)

    let geometry_with_origin =
      "{\"type\":\"FeatureCollection\",\"features\":[{\"properties\":{\"Class\":\"Point_Centroid\",\"source\":\"NEIC\",\"sourceid\":\"us7000backfill\"},\"geometry\":{\"type\":\"Point\",\"coordinates\":[105.5,-8.5]}}]}"
    let result =
      gdacs.GdacsGeometryResult(
        event_type: "EQ",
        event_id: 12,
        episode_id: 1,
        http_status: 200,
        geometry: Some(geometry_with_origin),
      )
    let assert Ok(outcome) = gdacs_geometry_writer.apply([result], now, conn)
    outcome.written |> should.equal(1)

    test_db.scalar_text(
      conn,
      "SELECT origin_source_id FROM sea.gdacs_event WHERE event_type = 'EQ' AND event_id = 12 AND episode_id = 1",
    )
    |> should.equal("us7000backfill")

    test_db.scalar_text(
      conn,
      "SELECT array_to_string(external_ids, ',') FROM sea.hazard WHERE source = 'gdacs' AND source_id = 'EQ-12'",
    )
    |> should.equal("usgs:us7000backfill")
  })
}

pub fn apply_unknown_episode_is_dropped_integration_test() {
  test_db.with_test_db(fn(conn) {
    let now = test_db.now_ms()
    let result =
      gdacs.GdacsGeometryResult(
        event_type: "EQ",
        event_id: 99_999,
        episode_id: 1,
        http_status: 204,
        geometry: None,
      )
    let assert Ok(outcome) = gdacs_geometry_writer.apply([result], now, conn)
    outcome.written |> should.equal(0)
    outcome.dropped |> should.equal(1)
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
  event_id event_id: Int,
  episode_id episode_id: Int,
  modified_at_ms modified_at_ms: Int,
) -> gdacs.GdacsFeature {
  gdacs.GdacsFeature(
    event_type: "EQ",
    event_id:,
    episode_id:,
    alert_level: "Green",
    alert_score: Some(1.0),
    episode_alert_level: Some("Green"),
    episode_alert_score: Some(0.0),
    name: Some("Earthquake in Test Region"),
    event_name: None,
    description: Some("Earthquake in Test Region"),
    html_description: None,
    country: Some("Test Region"),
    iso3: None,
    glide: None,
    origin_source: Some("NEIC"),
    origin_source_id: Some("us7000test"),
    severity_value: Some(5.5),
    severity_unit: Some("M"),
    severity_text: Some("Magnitude 5.5M, Depth:10km"),
    from_at_ms: 1_789_378_058_000,
    to_at_ms: Some(1_789_378_058_000),
    modified_at_ms:,
    is_current: True,
    is_temporary: False,
    longitude: 105.5,
    latitude: -8.5,
    bbox_west: Some(105.5),
    bbox_south: Some(-8.5),
    bbox_east: Some(105.5),
    bbox_north: Some(-8.5),
    affected_countries: ["IDN"],
    report_url: Some("https://www.gdacs.org/report.aspx"),
    geometry_url: Some(
      "https://www.gdacs.org/gdacsapi/api/polygons/getgeometry",
    ),
    icon_url: None,
    raw: "{\"type\":\"Feature\"}",
  )
}
