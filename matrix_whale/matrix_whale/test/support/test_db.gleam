// Shared harness for the opt-in PostgreSQL integration suites. Set
// MATRIX_WHALE_TEST_DATABASE_URL to a disposable, dedicated database; this
// module never connects to an application DB. The schema itself
// (sea.alert/earthquake/earthquake_revision/source/event/event_member) is
// expected to already
// be applied by Atlas migrations before tests run.
import adapter/alert_hub
import adapter/context
import adapter/earthquake_hub
import adapter/hazard_hub
import dot_env/env
import exception
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/string
import gleam/time/timestamp
import gleeunit/should
import intake/seen_set
import pog
import repository/source_writer
import wisp

pub fn with_test_db(run: fn(pog.Connection) -> Nil) -> Nil {
  case env.get_string("MATRIX_WHALE_TEST_DATABASE_URL") {
    Error(_) -> Nil
    Ok(url) -> {
      let name = process.new_name("matrix_whale_test_db")
      let assert Ok(config) = pog.url_config(name, url)
      // Every test spins up its own pool that is never stopped (pog exposes
      // no shutdown call); a small pool keeps the whole suite's connection
      // count well under the test database's max_connections=400
      // (db/scripts/test_core.sh raises it above Postgres's default).
      let assert Ok(_) = pog.start(pog.pool_size(config, 2))
      let conn = pog.named_connection(name)
      case
        string.starts_with(wait_for_database(conn, 100), "matrixwhale_test")
      {
        True -> {
          setup_test_schema(conn)
          run(conn)
          teardown_test_schema(conn)
        }
        // Never run schema DDL after an accidentally supplied live DB URL.
        False -> False |> should.equal(True)
      }
    }
  }
}

// The application schema itself is applied by Atlas migrations before tests
// run; this only clears rows, reseeds the source registry (earthquake rows
// carry a NOT NULL FK to it) and (re)installs the test-only trigger that
// simulates a write failure.
fn setup_test_schema(conn: pog.Connection) -> Nil {
  exec(
    conn,
    "TRUNCATE sea.cap_item, sea.cap_message, sea.cap_feed, sea.cap_authority, sea.hazard, sea.gdacs_event, sea.event_member, sea.event, sea.earthquake_revision, sea.earthquake, sea.alert, sea.source CASCADE",
  )
  let assert Ok(Nil) = source_writer.sync(conn)
  exec(
    conn,
    "CREATE OR REPLACE FUNCTION sea.fail_rollback_revision() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.source_id='rollback' THEN RAISE EXCEPTION 'forced revision failure'; END IF; RETURN NEW; END $$",
  )
  exec(
    conn,
    "DROP TRIGGER IF EXISTS fail_rollback_revision ON sea.earthquake_revision",
  )
  exec(
    conn,
    "CREATE TRIGGER fail_rollback_revision BEFORE INSERT ON sea.earthquake_revision FOR EACH ROW EXECUTE FUNCTION sea.fail_rollback_revision()",
  )
}

fn teardown_test_schema(conn: pog.Connection) -> Nil {
  exec(
    conn,
    "TRUNCATE sea.cap_item, sea.cap_message, sea.cap_feed, sea.cap_authority, sea.hazard, sea.gdacs_event, sea.event_member, sea.event, sea.earthquake_revision, sea.earthquake, sea.alert, sea.source CASCADE",
  )
  exec(
    conn,
    "DROP TRIGGER IF EXISTS fail_rollback_revision ON sea.earthquake_revision",
  )
  exec(conn, "DROP FUNCTION IF EXISTS sea.fail_rollback_revision()")
}

/// A distinct, per-call seen-set name keeps one test's dedupe state from
/// bleeding into another's within the same suite run.
pub fn integration_context(conn: pog.Connection) -> context.Context {
  let assert Ok(alert) = alert_hub.start()
  let assert Ok(earthquake) = earthquake_hub.start()
  let assert Ok(hazard) = hazard_hub.start()
  context.Context(
    secret: "integration-test",
    db: conn,
    hub: alert.data,
    earthquake_hub: earthquake.data,
    hazard_hub: hazard.data,
    seen: seen_set.new("test_seen_" <> wisp.random_string(16), 3_600_000),
  )
}

pub fn now_ms() -> Int {
  let #(seconds, nanoseconds) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  seconds * 1000 + nanoseconds / 1_000_000
}

pub fn exec(conn: pog.Connection, sql: String) -> Nil {
  let assert Ok(_) =
    pog.query(sql) |> pog.returning(decode.success(Nil)) |> pog.execute(conn)
  Nil
}

pub fn count(conn: pog.Connection, table: String) -> Int {
  scalar_int(conn, "SELECT count(*) FROM " <> table)
}

pub fn scalar_int(conn: pog.Connection, sql: String) -> Int {
  let decoder = {
    use value <- decode.field(0, decode.int)
    decode.success(value)
  }
  let assert Ok(result) =
    pog.query(sql) |> pog.returning(decoder) |> pog.execute(conn)
  let assert [value] = result.rows
  value
}

pub fn scalar_text(conn: pog.Connection, sql: String) -> String {
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
