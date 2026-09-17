// Opt-in PostgreSQL integration tests. Set USGS_TEST_DATABASE_URL to a
// disposable, dedicated database; this suite never connects to application DB.
import adapter/alert_hub
import adapter/context
import adapter/earthquake_hub
import adapter/streamer
import dot_env/env
import exception
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/time/timestamp
import gleeunit/should
import message/reciever/models/usgs
import message/reciever/usgs_reciever
import pog
import repository/earthquake_reader
import repository/earthquake_writer
import wisp/simulate

pub fn writer_revision_and_rollback_integration_test() {
  with_test_db(fn(conn) {
    let row = sample("revision", now_ms(), 100)
    let assert Ok(first) = earthquake_writer.upsert_and_diff([row], conn)
    list.length(first.new) |> should.equal(1)
    count(conn, "sea.earthquake") |> should.equal(1)
    count(conn, "sea.earthquake_revision") |> should.equal(1)
    scalar_text(
      conn,
      "SELECT earthquake->>'type' FROM sea.earthquake_revision WHERE source_id='revision'",
    )
    |> should.equal("Feature")

    let assert Ok(same) = earthquake_writer.upsert_and_diff([row], conn)
    list.length(same.new) |> should.equal(0)
    list.length(same.updated) |> should.equal(0)
    let assert Ok(older) =
      earthquake_writer.upsert_and_diff(
        [sample("revision", now_ms(), 99)],
        conn,
      )
    list.length(older.updated) |> should.equal(0)
    count(conn, "sea.earthquake_revision") |> should.equal(1)

    let assert Ok(newer) =
      earthquake_writer.upsert_and_diff(
        [sample("revision", now_ms(), 101)],
        conn,
      )
    list.length(newer.updated) |> should.equal(1)
    count(conn, "sea.earthquake_revision") |> should.equal(2)
    scalar_int(
      conn,
      "SELECT updated_at_ms FROM sea.earthquake WHERE source_id='revision'",
    )
    |> should.equal(101)

    // The trigger makes revision insertion fail after current rows were written;
    // writer's transaction must roll both projections back.
    let assert Error(_) =
      earthquake_writer.upsert_and_diff([sample("rollback", now_ms(), 1)], conn)
    count(conn, "sea.earthquake") |> should.equal(1)
    count(conn, "sea.earthquake_revision") |> should.equal(2)
  })
}

pub fn reader_filters_and_cleanup_integration_test() {
  with_test_db(fn(conn) {
    let current = now_ms()
    let assert Ok(_) =
      earthquake_writer.upsert_and_diff(
        [
          sample("quake", current, 1),
          usgs.IncomingEarthquake(..sample("unknown", current, 2), mag: None),
          usgs.IncomingEarthquake(
            ..sample("deleted", current, 3),
            status: Some("deleted"),
          ),
          sample("old", current - 8 * 24 * 60 * 60 * 1000, 4),
        ],
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
    count(conn, "sea.earthquake") |> should.equal(3)
    scalar_int(
      conn,
      "SELECT count(*) FROM sea.earthquake_revision WHERE source_id='old'",
    )
    |> should.equal(0)
    scalar_int(
      conn,
      "SELECT count(*) FROM sea.earthquake_revision WHERE source_id='quake'",
    )
    |> should.equal(1)
  })
}

pub fn http_ingest_snapshot_etag_and_rollback_integration_test() {
  with_test_db(fn(conn) {
    let ctx = integration_context(conn)
    let current = now_ms()

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
    count(conn, "sea.earthquake") |> should.equal(1)
  })
}

fn with_test_db(run: fn(pog.Connection) -> Nil) -> Nil {
  case env.get_string("USGS_TEST_DATABASE_URL") {
    Error(_) -> Nil
    Ok(url) -> {
      let name = process.new_name("usgs_earthquake_integration")
      let assert Ok(config) = pog.url_config(name, url)
      let assert Ok(_) = pog.start(config)
      let conn = pog.named_connection(name)
      case
        string.starts_with(wait_for_database(conn, 100), "matrixwhale_usgs_")
      {
        True -> {
          reset_schema(conn)
          run(conn)
          reset_schema(conn)
        }
        // Never run schema DDL after an accidentally supplied live DB URL.
        False -> False |> should.equal(True)
      }
    }
  }
}

fn reset_schema(conn: pog.Connection) -> Nil {
  exec(conn, "DROP SCHEMA IF EXISTS sea CASCADE")
  exec(conn, "CREATE SCHEMA sea")
  exec(
    conn,
    "CREATE TABLE sea.earthquake (source TEXT NOT NULL, source_id TEXT NOT NULL, contributing_ids TEXT[] NOT NULL DEFAULT '{}', sources TEXT[] NOT NULL DEFAULT '{}', net TEXT, code TEXT, magnitude DOUBLE PRECISION, magnitude_type TEXT, occurred_at TIMESTAMPTZ NOT NULL, occurred_at_ms BIGINT NOT NULL, updated_at TIMESTAMPTZ NOT NULL, updated_at_ms BIGINT NOT NULL, place TEXT, title TEXT, status TEXT, event_type TEXT, tsunami INTEGER, significance INTEGER, alert TEXT, mmi DOUBLE PRECISION, cdi DOUBLE PRECISION, felt INTEGER, nst INTEGER, dmin DOUBLE PRECISION, rms DOUBLE PRECISION, gap DOUBLE PRECISION, url TEXT, detail TEXT, longitude DOUBLE PRECISION NOT NULL, latitude DOUBLE PRECISION NOT NULL, depth_km DOUBLE PRECISION, first_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(), last_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(), PRIMARY KEY(source,source_id))",
  )
  exec(
    conn,
    "CREATE TABLE sea.earthquake_revision (source TEXT NOT NULL, source_id TEXT NOT NULL, updated_at_ms BIGINT NOT NULL, recorded_at TIMESTAMPTZ NOT NULL DEFAULT now(), earthquake JSONB NOT NULL, PRIMARY KEY(source,source_id,updated_at_ms), FOREIGN KEY(source,source_id) REFERENCES sea.earthquake(source,source_id) ON DELETE CASCADE)",
  )
  exec(
    conn,
    "CREATE FUNCTION sea.fail_rollback_revision() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.source_id='rollback' THEN RAISE EXCEPTION 'forced revision failure'; END IF; RETURN NEW; END $$",
  )
  exec(
    conn,
    "CREATE TRIGGER fail_rollback_revision BEFORE INSERT ON sea.earthquake_revision FOR EACH ROW EXECUTE FUNCTION sea.fail_rollback_revision()",
  )
}

fn sample(id: String, time: Int, updated: Int) -> usgs.IncomingEarthquake {
  usgs.IncomingEarthquake(
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

fn integration_context(conn: pog.Connection) -> context.Context {
  let assert Ok(alert) = alert_hub.start()
  let assert Ok(earthquake) = earthquake_hub.start()
  context.Context(
    secret: "usgs-integration-test",
    db: conn,
    hub: alert.data,
    earthquake_hub: earthquake.data,
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

fn now_ms() -> Int {
  let #(seconds, nanoseconds) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  seconds * 1000 + nanoseconds / 1_000_000
}

fn exec(conn: pog.Connection, sql: String) -> Nil {
  let assert Ok(_) =
    pog.query(sql) |> pog.returning(decode.success(Nil)) |> pog.execute(conn)
  Nil
}

fn count(conn: pog.Connection, table: String) -> Int {
  scalar_int(conn, "SELECT count(*) FROM " <> table)
}

fn scalar_int(conn: pog.Connection, sql: String) -> Int {
  let decoder = {
    use value <- decode.field(0, decode.int)
    decode.success(value)
  }
  let assert Ok(result) =
    pog.query(sql) |> pog.returning(decoder) |> pog.execute(conn)
  let assert [value] = result.rows
  value
}

fn scalar_text(conn: pog.Connection, sql: String) -> String {
  let decoder = {
    use value <- decode.field(0, decode.string)
    decode.success(value)
  }
  let assert Ok(result) =
    pog.query(sql) |> pog.returning(decoder) |> pog.execute(conn)
  let assert [value] = result.rows
  value
}

/// Pools connect asynchronously, and pgo raises rather than returns an error
/// when a checkout can't be served before the query timeout, so each probe
/// is rescued and retried with a short per-attempt timeout instead of
/// letting a cold pool eat the whole default timeout on a single try.
fn wait_for_database(conn: pog.Connection, attempts: Int) -> String {
  let decoder = {
    use value <- decode.field(0, decode.string)
    decode.success(value)
  }
  let probe = fn() {
    pog.query("SELECT current_database()")
    |> pog.timeout(200)
    |> pog.returning(decoder)
    |> pog.execute(conn)
  }
  case exception.rescue(probe), attempts {
    Ok(Ok(result)), _ -> {
      let assert [name] = result.rows
      name
    }
    _, attempts if attempts > 0 -> {
      process.sleep(50)
      wait_for_database(conn, attempts - 1)
    }
    _, _ -> {
      False |> should.equal(True)
      ""
    }
  }
}
