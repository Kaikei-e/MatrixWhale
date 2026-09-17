// Opt-in PostgreSQL integration tests. See test/support/test_db.gleam for
// the shared harness; MATRIX_WHALE_TEST_DATABASE_URL must be set to a
// disposable, dedicated database.
import adapter/streamer
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import intake/record
import message/reciever/models/earthquake_feature
import message/reciever/usgs_reciever
import repository/earthquake_reader
import repository/earthquake_writer
import support/test_db
import wisp/simulate

pub fn writer_revision_and_rollback_integration_test() {
  test_db.with_test_db(fn(conn) {
    let now = test_db.now_ms()
    let row = incoming(sample("revision", now, 100))
    let assert Ok(first) = earthquake_writer.write_batch([row], now, conn)
    first.new |> should.equal(1)
    test_db.count(conn, "sea.earthquake") |> should.equal(1)
    test_db.count(conn, "sea.earthquake_revision") |> should.equal(1)
    test_db.scalar_text(
      conn,
      "SELECT earthquake->>'type' FROM sea.earthquake_revision WHERE source_id='revision'",
    )
    |> should.equal("Feature")

    let assert Ok(same) = earthquake_writer.write_batch([row], now, conn)
    same.new |> should.equal(0)
    same.updated |> should.equal(0)
    same.unchanged |> should.equal(1)

    let assert Ok(older) =
      earthquake_writer.write_batch(
        [incoming(sample("revision", now, 99))],
        now,
        conn,
      )
    older.updated |> should.equal(0)
    older.stale |> should.equal(1)
    test_db.count(conn, "sea.earthquake_revision") |> should.equal(1)

    let assert Ok(newer) =
      earthquake_writer.write_batch(
        [incoming(sample("revision", now, 101))],
        now,
        conn,
      )
    newer.updated |> should.equal(1)
    test_db.count(conn, "sea.earthquake_revision") |> should.equal(2)
    test_db.scalar_int(
      conn,
      "SELECT updated_at_ms FROM sea.earthquake WHERE source_id='revision'",
    )
    |> should.equal(101)

    // The trigger makes revision insertion fail after current rows were written;
    // writer's transaction must roll both projections back.
    let assert Error(_) =
      earthquake_writer.write_batch(
        [incoming(sample("rollback", now, 1))],
        now,
        conn,
      )
    test_db.count(conn, "sea.earthquake") |> should.equal(1)
    test_db.count(conn, "sea.earthquake_revision") |> should.equal(2)
  })
}

pub fn reader_filters_and_cleanup_integration_test() {
  test_db.with_test_db(fn(conn) {
    let current = test_db.now_ms()
    let assert Ok(_) =
      earthquake_writer.write_batch(
        [
          incoming(sample("quake", current, 1)),
          incoming(
            earthquake_feature.IncomingEarthquake(
              ..sample("unknown", current, 2),
              mag: None,
            ),
          ),
          incoming(
            earthquake_feature.IncomingEarthquake(
              ..sample("deleted", current, 3),
              status: Some("deleted"),
            ),
          ),
          incoming(sample("old", current - 8 * 24 * 60 * 60 * 1000, 4)),
        ],
        current,
        conn,
      )
    let assert Ok(default_rows) =
      earthquake_reader.recent(
        24,
        earthquake_reader.Minimum(2.5),
        earthquake_reader.EarthquakesOnly,
        conn,
      )
    list.length(default_rows) |> should.equal(1)
    let assert Ok(all_rows) =
      earthquake_reader.recent(
        24,
        earthquake_reader.AllMagnitudes,
        earthquake_reader.AllTypes,
        conn,
      )
    list.length(all_rows) |> should.equal(2)

    let assert Ok(_) = earthquake_reader.cleanup(conn)
    test_db.count(conn, "sea.earthquake") |> should.equal(3)
    test_db.scalar_int(
      conn,
      "SELECT count(*) FROM sea.earthquake_revision WHERE source_id='old'",
    )
    |> should.equal(0)
    test_db.scalar_int(
      conn,
      "SELECT count(*) FROM sea.earthquake_revision WHERE source_id='quake'",
    )
    |> should.equal(1)
  })
}

pub fn http_ingest_snapshot_etag_and_rollback_integration_test() {
  test_db.with_test_db(fn(conn) {
    let ctx = test_db.integration_context(conn)
    let current = test_db.now_ms()

    let ingested =
      usgs_reciever.usgs_data_handler(
        usgs_request("http-fresh", current, current + 1),
        ctx,
      )
    ingested.status |> should.equal(200)
    let ingest_body = simulate.read_body(ingested)
    string.contains(ingest_body, "\"received\":1") |> should.equal(True)
    string.contains(ingest_body, "\"written\":1") |> should.equal(True)
    string.contains(ingest_body, "1 new, 0 updated") |> should.equal(True)

    let first =
      streamer.earthquakes_response(
        request.new()
          |> request.set_query([
            #("hours", "24"),
            #("minmag", "2.5"),
            #("type", "earthquake"),
          ]),
        ctx,
      )
    first.status |> should.equal(200)
    let assert Ok(etag) = response.get_header(first, "etag")

    streamer.earthquakes_response(
      request.new()
        |> request.set_query([
          #("hours", "24"),
          #("minmag", "2.5"),
          #("type", "earthquake"),
        ])
        |> request.set_header("if-none-match", etag),
      ctx,
    ).status
    |> should.equal(304)

    // The test-schema trigger fails while writing the immutable revision;
    // the receiver must surface a storage failure rather than acknowledge it.
    usgs_reciever.usgs_data_handler(
      usgs_request("rollback", current, current + 2),
      ctx,
    ).status
    |> should.equal(503)
    test_db.count(conn, "sea.earthquake") |> should.equal(1)
  })
}

pub fn seen_set_dedupes_identical_replay_without_db_write_integration_test() {
  test_db.with_test_db(fn(conn) {
    let ctx = test_db.integration_context(conn)
    let current = test_db.now_ms()

    usgs_reciever.usgs_data_handler(
      usgs_request("seen-dedup", current, current + 1),
      ctx,
    ).status
    |> should.equal(200)
    test_db.count(conn, "sea.earthquake_revision") |> should.equal(1)

    let second =
      usgs_reciever.usgs_data_handler(
        usgs_request("seen-dedup", current, current + 1),
        ctx,
      )
    second.status |> should.equal(200)
    let body = simulate.read_body(second)
    string.contains(body, "\"received\":1") |> should.equal(True)
    string.contains(body, "\"deduped\":1") |> should.equal(True)
    string.contains(body, "\"written\":0") |> should.equal(True)
    test_db.count(conn, "sea.earthquake_revision") |> should.equal(1)
  })
}

pub fn failed_write_does_not_mark_seen_set_integration_test() {
  test_db.with_test_db(fn(conn) {
    let ctx = test_db.integration_context(conn)
    let current = test_db.now_ms()

    usgs_reciever.usgs_data_handler(
      usgs_request("rollback", current, current + 1),
      ctx,
    ).status
    |> should.equal(503)

    // If the failed attempt had marked the seen-set, this identical retry
    // would be reported as a dropped repeat (200) instead of failing again.
    usgs_reciever.usgs_data_handler(
      usgs_request("rollback", current, current + 1),
      ctx,
    ).status
    |> should.equal(503)
    test_db.count(conn, "sea.earthquake") |> should.equal(0)
  })
}

fn incoming(
  feature: earthquake_feature.IncomingEarthquake,
) -> record.Incoming(earthquake_feature.IncomingEarthquake) {
  record.Incoming(
    key: record.Key("usgs", feature.source_id),
    revision: feature.updated,
    payload: feature,
  )
}

fn sample(
  id: String,
  time: Int,
  updated: Int,
) -> earthquake_feature.IncomingEarthquake {
  earthquake_feature.IncomingEarthquake(
    source_id: id,
    ids: [id],
    sources: ["us"],
    net: Some("us"),
    code: Some(id),
    mag: Some(4.0),
    mag_type: Some("ml"),
    time:,
    updated:,
    place: Some("test"),
    title: Some("M 4 test"),
    status: Some("reviewed"),
    type_: Some("earthquake"),
    tsunami: Some(0),
    sig: Some(10),
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
    raw: "{\"type\":\"Feature\",\"id\":\""
      <> id
      <> "\",\"properties\":{\"mag\":4.0}}",
  )
}

fn usgs_request(id: String, time: Int, updated: Int) {
  simulate.request(http.Post, "/api/v1/usgs_data/send")
  |> simulate.string_body(
    "{\"poll_meta\":{\"fetched_at\":\"2026-09-17T00:00:00Z\",\"http_status\":200,\"feature_count\":1,\"bytes\":1,\"backfill\":false},\"features\":[{\"id\":\""
    <> id
    <> "\",\"type\":\"Feature\",\"geometry\":{\"type\":\"Point\",\"coordinates\":[139.0,35.0,10.0]},\"properties\":{\"ids\":\","
    <> id
    <> ",\",\"sources\":\",us,\",\"net\":\"us\",\"code\":\""
    <> id
    <> "\",\"mag\":4.0,\"magType\":\"ml\",\"time\":"
    <> string.inspect(time)
    <> ",\"updated\":"
    <> string.inspect(updated)
    <> ",\"place\":\"integration test\",\"title\":\"M 4 integration test\",\"status\":\"reviewed\",\"type\":\"earthquake\"}}]}",
  )
  |> request.set_header("content-type", "application/json")
}
