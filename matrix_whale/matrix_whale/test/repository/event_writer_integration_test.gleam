// Opt-in PostgreSQL integration tests. See test/support/test_db.gleam for
// the shared harness; MATRIX_WHALE_TEST_DATABASE_URL must be set to a
// disposable, dedicated database.
import adapter/streamer
import domain/earthquake
import gleam/bit_array
import gleam/bytes_tree
import gleam/dynamic/decode
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import intake/record
import message/reciever/emsc_reciever
import message/reciever/models/earthquake_feature
import mist
import repository/earthquake_reader
import repository/earthquake_writer
import support/test_db
import wisp/simulate

pub fn cross_source_matching_and_projection_integration_test() {
  test_db.with_test_db(fn(conn) {
    let now = test_db.now_ms()

    let assert Ok(created) =
      earthquake_writer.write_batch(
        [usgs_incoming("us1", now, now, 10.0, 20.0, 5.0)],
        now,
        conn,
      )
    let assert [origin_view] = created.result.events.new
    origin_view.event.preferred_source |> should.equal("usgs")
    let assert [origin_member] = origin_view.members
    origin_member.matched_by |> should.equal("origin")

    // 20s later, ~10km away, 0.2 magnitude apart: within the misfit window
    // and m2 >= 2 (location + magnitude), so it attaches to the same event.
    let close_time = now + 20_000
    let assert Ok(attached) =
      earthquake_writer.write_batch(
        [emsc_incoming("e1", close_time, close_time, 10.09, 20.0, 4.8)],
        close_time,
        conn,
      )
    attached.result.events.matched |> should.equal(1)
    let assert [merged_view] = attached.result.events.updated
    merged_view.event.preferred_source |> should.equal("usgs")
    merged_view.event.updated_at_ms |> should.equal(close_time)
    list.length(merged_view.members) |> should.equal(2)
    let assert Ok(emsc_member) =
      list.find(merged_view.members, fn(m) { m.source == "emsc" })
    emsc_member.matched_by |> should.equal("misfit")

    // 10 minutes away is outside the misfit time window: a new event.
    let far_time = now + 600_000
    let assert Ok(separate) =
      earthquake_writer.write_batch(
        [emsc_incoming("e2", far_time, far_time, 10.0, 20.0, 5.0)],
        far_time,
        conn,
      )
    separate.result.events.new |> list.length |> should.equal(1)
    test_db.count(conn, "sea.event") |> should.equal(2)

    // A delete action on the EMSC member marks that member deleted without
    // deleting the event itself, since the USGS member is still live.
    let delete_time = now + 30_000
    let assert Ok(deleted) =
      earthquake_writer.write_batch(
        [
          earthquake_incoming(
            "emsc",
            "e1",
            delete_time,
            earthquake_feature.IncomingEarthquake(
              ..emsc_feature("e1", close_time, delete_time, 10.09, 20.0, 4.8),
              status: Some("deleted"),
            ),
          ),
        ],
        delete_time,
        conn,
      )
    let assert [after_delete] = deleted.result.events.updated
    after_delete.event.status |> should.not_equal(Some("deleted"))
    let assert Ok(deleted_member) =
      list.find(after_delete.members, fn(m) { m.source == "emsc" })
    deleted_member.status |> should.equal(Some("deleted"))

    let assert Ok(rows) =
      earthquake_reader.recent(
        24,
        earthquake.AllMagnitudes,
        earthquake_reader.AllTypes,
        conn,
      )
    let assert Ok(merged) =
      list.find(rows, fn(view) { list.length(view.members) == 2 })
    merged.event.preferred_source |> should.equal("usgs")

    let response =
      streamer.earthquakes_response(
        request.new()
          |> request.set_query([
            #("hours", "24"),
            #("minmag", "all"),
            #("type", "all"),
          ]),
        test_db.integration_context(conn),
      )
    response.status |> should.equal(200)
    let body = read_mist_body(response)
    let assert Ok(parsed) = json.parse(body, decode.dynamic)
    let assert Ok(earthquakes) =
      decode.run(
        parsed,
        decode.field("earthquakes", decode.list(decode.dynamic), decode.success),
      )
    let item_decoder = {
      use preferred_source <- decode.field("preferred_source", decode.string)
      use members <- decode.field("members", decode.list(decode.dynamic))
      decode.success(#(preferred_source, list.length(members)))
    }
    let assert Ok(items) =
      list.try_map(earthquakes, fn(x) { decode.run(x, item_decoder) })
    let assert Ok(contract_event) = list.find(items, fn(pair) { pair.1 == 2 })
    contract_event.0 |> should.equal("usgs")
  })
}

pub fn emsc_http_ingest_dedupes_identical_replay_integration_test() {
  test_db.with_test_db(fn(conn) {
    let ctx = test_db.integration_context(conn)

    let first = emsc_reciever.emsc_data_handler(emsc_request("dedup1"), ctx)
    first.status |> should.equal(200)
    let first_body = simulate.read_body(first)
    string.contains(first_body, "\"received\":1") |> should.equal(True)
    string.contains(first_body, "\"deduped\":0") |> should.equal(True)

    let second = emsc_reciever.emsc_data_handler(emsc_request("dedup1"), ctx)
    second.status |> should.equal(200)
    let second_body = simulate.read_body(second)
    string.contains(second_body, "\"received\":1") |> should.equal(True)
    string.contains(second_body, "\"deduped\":1") |> should.equal(True)
    string.contains(second_body, "\"written\":0") |> should.equal(True)
  })
}

pub fn retention_removes_old_events_integration_test() {
  test_db.with_test_db(fn(conn) {
    let now = test_db.now_ms()
    let old_time = now - 8 * 24 * 60 * 60 * 1000

    let assert Ok(_) =
      earthquake_writer.write_batch(
        [usgs_incoming("recent", now, now, 1.0, 1.0, 4.0)],
        now,
        conn,
      )
    let assert Ok(_) =
      earthquake_writer.write_batch(
        [usgs_incoming("stale", old_time, old_time, 1.0, 1.0, 4.0)],
        old_time,
        conn,
      )
    test_db.count(conn, "sea.event") |> should.equal(2)

    let assert Ok(_) = earthquake_reader.cleanup(conn)
    test_db.count(conn, "sea.event") |> should.equal(1)
    test_db.scalar_int(
      conn,
      "SELECT count(*) FROM sea.event WHERE preferred_source_id='recent'",
    )
    |> should.equal(1)
  })
}

fn usgs_incoming(
  id: String,
  time_ms: Int,
  updated_ms: Int,
  lat: Float,
  lon: Float,
  mag: Float,
) -> record.Incoming(earthquake_feature.IncomingEarthquake) {
  earthquake_incoming(
    "usgs",
    id,
    updated_ms,
    usgs_feature(id, time_ms, updated_ms, lat, lon, mag),
  )
}

fn emsc_incoming(
  id: String,
  time_ms: Int,
  updated_ms: Int,
  lat: Float,
  lon: Float,
  mag: Float,
) -> record.Incoming(earthquake_feature.IncomingEarthquake) {
  earthquake_incoming(
    "emsc",
    id,
    updated_ms,
    emsc_feature(id, time_ms, updated_ms, lat, lon, mag),
  )
}

fn earthquake_incoming(
  source: String,
  id: String,
  revision: Int,
  payload: earthquake_feature.IncomingEarthquake,
) -> record.Incoming(earthquake_feature.IncomingEarthquake) {
  record.Incoming(key: record.Key(source, id), revision:, payload:)
}

fn usgs_feature(
  id: String,
  time_ms: Int,
  updated_ms: Int,
  lat: Float,
  lon: Float,
  mag: Float,
) -> earthquake_feature.IncomingEarthquake {
  earthquake_feature.IncomingEarthquake(
    source_id: id,
    ids: [id],
    sources: ["us"],
    net: Some("us"),
    code: Some(id),
    mag: Some(mag),
    mag_type: Some("mww"),
    time: time_ms,
    updated: updated_ms,
    place: Some("test place"),
    title: Some("M test"),
    status: Some("reviewed"),
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
    lon:,
    lat:,
    depth: Some(10.0),
    raw: "{\"type\":\"Feature\",\"id\":\"" <> id <> "\"}",
  )
}

fn emsc_feature(
  id: String,
  time_ms: Int,
  updated_ms: Int,
  lat: Float,
  lon: Float,
  mag: Float,
) -> earthquake_feature.IncomingEarthquake {
  earthquake_feature.IncomingEarthquake(
    source_id: id,
    ids: [id],
    sources: ["EMSC"],
    net: Some("EMSC"),
    code: Some(id),
    mag: Some(mag),
    mag_type: Some("ml"),
    time: time_ms,
    updated: updated_ms,
    place: Some("test region"),
    title: Some("M test"),
    status: Some("automatic"),
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
    url: Some("https://www.seismicportal.eu/eventdetails.html?unid=" <> id),
    detail: None,
    lon:,
    lat:,
    depth: Some(10.0),
    raw: "{\"type\":\"Feature\",\"properties\":{\"unid\":\"" <> id <> "\"}}",
  )
}

fn read_mist_body(res: response.Response(mist.ResponseData)) -> String {
  let assert mist.Bytes(tree) = res.body
  let assert Ok(text) = bit_array.to_string(bytes_tree.to_bit_array(tree))
  text
}

fn emsc_request(id: String) {
  simulate.request(http.Post, "/api/v1/emsc_data/send")
  |> simulate.string_body(
    "{\"poll_meta\":{\"fetched_at\":\"2026-09-18T00:00:00Z\",\"http_status\":200,\"feature_count\":1,\"bytes\":1,\"backfill\":false},\"features\":[{\"action\":\"create\",\"data\":{\"type\":\"Feature\",\"properties\":{\"unid\":\""
    <> id
    <> "\",\"source_id\":\""
    <> id
    <> "\",\"lastupdate\":\"2026-09-18T00:00:00.000000Z\",\"time\":\"2026-09-18T00:00:00Z\",\"flynn_region\":\"TEST REGION\",\"lat\":1.0,\"lon\":1.0,\"depth\":10.0,\"evtype\":\"ke\",\"auth\":\"EMSC\",\"mag\":4.5,\"magtype\":\"ml\"}}}]}",
  )
  |> request.set_header("content-type", "application/json")
}
