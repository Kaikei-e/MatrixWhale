// Opt-in PostgreSQL integration tests. See test/support/test_db.gleam for
// the shared harness; MATRIX_WHALE_TEST_DATABASE_URL must be set to a
// disposable, dedicated database.
import gleam/http
import gleam/http/request
import gleam/option.{None, Some}
import gleam/string
import gleam/time/calendar
import gleam/time/timestamp
import gleeunit/should
import intake/record
import message/reciever/gdacs_reciever
import message/reciever/models/earthquake_feature
import repository/earthquake_writer
import support/test_db
import wisp/simulate

pub fn http_ingest_ack_and_dual_write_into_earthquake_pipeline_integration_test() {
  test_db.with_test_db(fn(conn) {
    let ctx = test_db.integration_context(conn)
    let current = test_db.now_ms()

    // An existing USGS earthquake at the same place/time/magnitude the
    // GDACS feature below reports, and carrying the exact id GDACS embeds
    // in `sourceid` for NEIC-origin events.
    let assert Ok(_) =
      earthquake_writer.write_batch(
        [
          record.Incoming(
            key: record.Key("usgs", "us7000test1"),
            revision: current,
            payload: earthquake_feature.IncomingEarthquake(
              source_id: "us7000test1",
              ids: ["us7000test1"],
              sources: ["us"],
              net: Some("us"),
              code: Some("7000test1"),
              mag: Some(5.5),
              mag_type: Some("mww"),
              time: current,
              updated: current,
              place: Some("South Of Java, Indonesia"),
              title: Some("M 5.5 - South Of Java, Indonesia"),
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
              lon: 105.8726,
              lat: -8.5419,
              depth: Some(10.0),
              raw: "{\"type\":\"Feature\",\"id\":\"us7000test1\"}",
            ),
          ),
        ],
        current,
        conn,
      )
    test_db.count(conn, "sea.event") |> should.equal(1)

    // The GDACS feature's fromdate/datemodified must land in the same
    // matcher window (+/-60s) as the USGS row above for the exact-id path
    // to even consider it a candidate. The list feature itself carries an
    // empty `sourceid` - matching reality, where GDACS list endpoints never
    // populate it.
    let ts = ms_to_gdacs_timestamp(current)
    let ingest =
      gdacs_reciever.gdacs_data_handler(gdacs_eq_request("", ts), ctx)
    ingest.status |> should.equal(200)
    let ingest_body = simulate.read_body(ingest)
    string.contains(ingest_body, "\"received\":1") |> should.equal(True)
    string.contains(ingest_body, "\"written\":1") |> should.equal(True)
    string.contains(ingest_body, "\"dropped\":0") |> should.equal(True)

    // No cross-source id is known yet, so the earthquake dual-write has not
    // run: the list POST alone never writes to sea.earthquake.
    test_db.count(conn, "sea.earthquake WHERE source = 'gdacs'")
    |> should.equal(0)
    test_db.count(conn, "sea.gdacs_event") |> should.equal(1)

    // getgeometry is the only GDACS endpoint that actually carries the USGS
    // id for a NEIC-origin earthquake.
    let geometry_response =
      gdacs_reciever.gdacs_geometry_handler(
        simulate.request(http.Post, "/api/v1/gdacs_data/geometry")
          |> simulate.string_body(geometry_request_body("us7000test1"))
          |> request.set_header("content-type", "application/json"),
        ctx,
      )
    geometry_response.status |> should.equal(200)

    // The GDACS EQ feature landed in sea.earthquake as its own source row
    // only once the geometry POST supplied the USGS id...
    test_db.count(conn, "sea.earthquake WHERE source = 'gdacs'")
    |> should.equal(1)
    // ...and its hazard row picked up the backfilled external id.
    test_db.scalar_text(
      conn,
      "SELECT array_to_string(external_ids, ',') FROM sea.hazard WHERE source = 'gdacs' AND source_id = 'EQ-1565193'",
    )
    |> should.equal("usgs:us7000test1")

    // Exact-id matching (GDACS sourceid == the USGS id) merged it into the
    // same canonical event rather than creating a second one.
    test_db.count(conn, "sea.event") |> should.equal(1)
    test_db.scalar_text(
      conn,
      "SELECT matched_by FROM sea.event_member WHERE source = 'gdacs'",
    )
    |> should.equal("id")
  })
}

fn geometry_request_body(sourceid: String) -> String {
  "{\"features\":[{\"eventtype\":\"EQ\",\"eventid\":1565193,\"episodeid\":1732972,\"http_status\":200,\"geometry\":{\"type\":\"FeatureCollection\",\"features\":[{\"properties\":{\"Class\":\"Point_Centroid\",\"source\":\"NEIC\",\"sourceid\":\""
  <> sourceid
  <> "\"},\"geometry\":{\"type\":\"Point\",\"coordinates\":[105.8726,-8.5419]}}]}}]}"
}

pub fn http_ingest_dedupes_identical_replay_integration_test() {
  test_db.with_test_db(fn(conn) {
    let ctx = test_db.integration_context(conn)

    let ts = ms_to_gdacs_timestamp(test_db.now_ms())
    let first = gdacs_reciever.gdacs_data_handler(gdacs_eq_request("", ts), ctx)
    first.status |> should.equal(200)

    let second =
      gdacs_reciever.gdacs_data_handler(gdacs_eq_request("", ts), ctx)
    second.status |> should.equal(200)
    let body = simulate.read_body(second)
    string.contains(body, "\"received\":1") |> should.equal(True)
    string.contains(body, "\"deduped\":1") |> should.equal(True)
    string.contains(body, "\"written\":0") |> should.equal(True)
  })
}

pub fn geometry_pending_and_apply_http_round_trip_integration_test() {
  test_db.with_test_db(fn(conn) {
    let ctx = test_db.integration_context(conn)
    let ts = ms_to_gdacs_timestamp(test_db.now_ms())
    let ingest =
      gdacs_reciever.gdacs_data_handler(gdacs_eq_request("", ts), ctx)
    ingest.status |> should.equal(200)

    let pending_response =
      gdacs_reciever.gdacs_geometry_pending_handler(
        simulate.request(
          http.Get,
          "/api/v1/gdacs_data/geometry/pending?limit=10",
        ),
        ctx,
      )
    pending_response.status |> should.equal(200)
    let pending_body = simulate.read_body(pending_response)
    string.contains(pending_body, "\"eventid\":1565193") |> should.equal(True)

    test_db.count(conn, "sea.earthquake WHERE source = 'gdacs'")
    |> should.equal(0)

    let apply_response =
      gdacs_reciever.gdacs_geometry_handler(
        simulate.request(http.Post, "/api/v1/gdacs_data/geometry")
          |> simulate.string_body(
            "{\"features\":[{\"eventtype\":\"EQ\",\"eventid\":1565193,\"episodeid\":1732972,\"http_status\":204,\"geometry\":null}]}",
          )
          |> request.set_header("content-type", "application/json"),
        ctx,
      )
    apply_response.status |> should.equal(200)
    let apply_body = simulate.read_body(apply_response)
    string.contains(apply_body, "\"written\":1") |> should.equal(True)

    // A 204/null geometry still counts as "applied" (the episode's
    // geometry_fetched_at was set), so the EQ dual-write still runs - just
    // without a USGS id to carry, since backfill needs an actual geometry.
    test_db.count(conn, "sea.earthquake WHERE source = 'gdacs'")
    |> should.equal(1)
    test_db.scalar_text(
      conn,
      "SELECT array_to_string(contributing_ids, ',') FROM sea.earthquake WHERE source = 'gdacs'",
    )
    |> should.equal("gdacs:1565193")

    let pending_after =
      gdacs_reciever.gdacs_geometry_pending_handler(
        simulate.request(
          http.Get,
          "/api/v1/gdacs_data/geometry/pending?limit=10",
        ),
        ctx,
      )
    let pending_after_body = simulate.read_body(pending_after)
    string.contains(pending_after_body, "\"eventid\":1565193")
    |> should.equal(False)
  })
}

fn gdacs_eq_request(sourceid: String, gdacs_timestamp: String) {
  simulate.request(http.Post, "/api/v1/gdacs_data/send")
  |> simulate.string_body(
    "{\"poll_meta\":{\"fetched_at\":\"2026-09-18T00:00:00Z\",\"http_status\":200,\"feature_count\":1,\"bytes\":1,\"backfill\":false},\"features\":[{\"type\":\"Feature\",\"bbox\":[105.8726,-8.5419,105.8726,-8.5419],\"geometry\":{\"type\":\"Point\",\"coordinates\":[105.8726,-8.5419]},\"properties\":{\"eventtype\":\"EQ\",\"eventid\":1565193,\"episodeid\":1732972,\"eventname\":\"\",\"glide\":\"\",\"name\":\"Earthquake in South Of Java, Indonesia\",\"description\":\"Earthquake in South Of Java, Indonesia\",\"htmldescription\":\"x\",\"icon\":\"https://x/EQ.png\",\"url\":{\"geometry\":\"https://x/geometry\",\"report\":\"https://x/report\",\"details\":\"https://x/details\"},\"alertlevel\":\"Green\",\"alertscore\":1,\"episodealertlevel\":\"Green\",\"episodealertscore\":0.0,\"istemporary\":\"false\",\"iscurrent\":\"true\",\"country\":\"South Of Java, Indonesia\",\"fromdate\":\""
    <> gdacs_timestamp
    <> "\",\"todate\":\""
    <> gdacs_timestamp
    <> "\",\"datemodified\":\""
    <> gdacs_timestamp
    <> "\",\"iso3\":\"\",\"source\":\"NEIC\",\"sourceid\":\""
    <> sourceid
    <> "\",\"polygonlabel\":\"Centroid\",\"Class\":\"Point_Centroid\",\"affectedcountries\":[{\"iso2\":\"ID\",\"iso3\":\"IDN\",\"countryname\":\"Indonesia\"}],\"severitydata\":{\"severity\":5.5,\"severitytext\":\"Magnitude 5.5M, Depth:10km\",\"severityunit\":\"M\"}}}]}",
  )
  |> request.set_header("content-type", "application/json")
}

/// Renders a ms timestamp as the zone-less `YYYY-MM-DDTHH:MM:SS` shape
/// GDACS uses, the inverse of `gdacs.gleam`'s own parser.
fn ms_to_gdacs_timestamp(ms: Int) -> String {
  let ts = timestamp.from_unix_seconds(ms / 1000)
  let rfc3339 = timestamp.to_rfc3339(ts, calendar.utc_offset)
  string.drop_end(rfc3339, 1)
}
