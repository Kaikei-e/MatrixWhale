// Opt-in PostgreSQL integration tests. See test/support/test_db.gleam for
// the shared harness; MATRIX_WHALE_TEST_DATABASE_URL must be set to a
// disposable, dedicated database.
import gleam/int
import gleam/option.{None, Some}
import gleeunit/should
import intake/record
import message/reciever/models/gdacs
import repository/gdacs_event_writer
import repository/gdacs_geometry_writer
import support/test_db

pub fn raw_upsert_and_revision_classification_integration_test() {
  test_db.with_test_db(fn(conn) {
    let now = test_db.now_ms()
    let feature =
      sample_feature(event_id: 1, episode_id: 1, modified_at_ms: 100)

    let assert Ok(first) =
      gdacs_event_writer.write_batch([incoming(feature)], now, conn)
    first.new |> should.equal(1)
    test_db.count(conn, "sea.gdacs_event") |> should.equal(1)
    test_db.count(conn, "sea.hazard") |> should.equal(1)

    // Same revision replayed: unchanged, no new hazard write needed.
    let assert Ok(same) =
      gdacs_event_writer.write_batch([incoming(feature)], now, conn)
    same.new |> should.equal(0)
    same.updated |> should.equal(0)
    same.unchanged |> should.equal(1)

    // Older revision: stale, dropped.
    let older =
      gdacs.GdacsFeature(..feature, modified_at_ms: 50, alert_level: "Red")
    let assert Ok(stale) =
      gdacs_event_writer.write_batch([incoming(older)], now, conn)
    stale.updated |> should.equal(0)
    stale.stale |> should.equal(1)
    test_db.scalar_text(
      conn,
      "SELECT alert_level FROM sea.gdacs_event WHERE event_type='EQ' AND event_id=1 AND episode_id=1",
    )
    |> should.equal("Green")

    // Newer revision: updated, and the hazard row reflects the new value.
    let newer =
      gdacs.GdacsFeature(..feature, modified_at_ms: 200, alert_level: "Orange")
    let assert Ok(updated) =
      gdacs_event_writer.write_batch([incoming(newer)], now, conn)
    updated.updated |> should.equal(1)
    let assert [changed] = updated.result.updated_hazards
    changed.alert_level |> should.equal("orange")
    test_db.count(conn, "sea.hazard") |> should.equal(1)
  })
}

pub fn hazard_recompute_picks_latest_episode_and_counts_episodes_integration_test() {
  test_db.with_test_db(fn(conn) {
    let now = test_db.now_ms()
    let episode_1 =
      sample_feature(event_id: 2, episode_id: 1, modified_at_ms: 100)
    let assert Ok(first) =
      gdacs_event_writer.write_batch([incoming(episode_1)], now, conn)
    let assert [created] = first.result.new_hazards
    created.episode_count |> should.equal(1)
    created.source_episode_id |> should.equal(Some("1"))

    // A later episode for the same event: the hazard now reflects episode 2
    // and the episode count grows, even though it is a different raw row.
    let episode_2 =
      sample_feature(event_id: 2, episode_id: 2, modified_at_ms: 200)
      |> fn(f) { gdacs.GdacsFeature(..f, alert_level: "Red") }
    let assert Ok(second) =
      gdacs_event_writer.write_batch([incoming(episode_2)], now, conn)
    let assert [advanced] = second.result.updated_hazards
    advanced.episode_count |> should.equal(2)
    advanced.source_episode_id |> should.equal(Some("2"))
    advanced.alert_level |> should.equal("red")
    test_db.count(conn, "sea.gdacs_event") |> should.equal(2)
    test_db.count(conn, "sea.hazard") |> should.equal(1)
  })
}

pub fn updated_episode_preserves_backfilled_origin_when_list_feed_resends_empty_sourceid_integration_test() {
  test_db.with_test_db(fn(conn) {
    let now = test_db.now_ms()
    let feature =
      sample_feature(event_id: 30, episode_id: 1, modified_at_ms: 100)
      |> fn(f) { gdacs.GdacsFeature(..f, origin_source_id: None) }
    let assert Ok(_) =
      gdacs_event_writer.write_batch([incoming(feature)], now, conn)

    let geometry_result =
      gdacs.GdacsGeometryResult(
        event_type: "EQ",
        event_id: 30,
        episode_id: 1,
        http_status: 200,
        geometry: Some(
          "{\"type\":\"FeatureCollection\",\"features\":[{\"properties\":{\"Class\":\"Point_Centroid\",\"source\":\"NEIC\",\"sourceid\":\"us7000backfill\"},\"geometry\":{\"type\":\"Point\",\"coordinates\":[105.5,-8.5]}}]}",
        ),
      )
    let assert Ok(_) = gdacs_geometry_writer.apply([geometry_result], now, conn)

    // GDACS bumps datemodified on the same episode without ever supplying a
    // sourceid; the resend must not wipe the backfilled origin.
    let bumped =
      gdacs.GdacsFeature(..feature, modified_at_ms: 200, origin_source_id: None)
    let assert Ok(resend) =
      gdacs_event_writer.write_batch([incoming(bumped)], now, conn)
    resend.updated |> should.equal(1)

    test_db.scalar_text(
      conn,
      "SELECT origin_source_id FROM sea.gdacs_event WHERE event_type='EQ' AND event_id=30 AND episode_id=1",
    )
    |> should.equal("us7000backfill")

    test_db.scalar_text(
      conn,
      "SELECT array_to_string(external_ids, ',') FROM sea.hazard WHERE source = 'gdacs' AND source_id = 'EQ-30'",
    )
    |> should.equal("usgs:us7000backfill")

    test_db.count(
      conn,
      "sea.hazard WHERE source = 'gdacs' AND source_id = 'EQ-30' AND modified_at_ms = 200",
    )
    |> should.equal(1)
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
    longitude: 105.8726,
    latitude: -8.5419,
    bbox_west: Some(105.8726),
    bbox_south: Some(-8.5419),
    bbox_east: Some(105.8726),
    bbox_north: Some(-8.5419),
    affected_countries: ["IDN"],
    report_url: Some("https://www.gdacs.org/report.aspx"),
    geometry_url: Some(
      "https://www.gdacs.org/gdacsapi/api/polygons/getgeometry",
    ),
    icon_url: None,
    raw: "{\"type\":\"Feature\"}",
  )
}
