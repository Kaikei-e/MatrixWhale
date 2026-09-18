import adapter/alert_hub
import adapter/context
import adapter/earthquake_hub
import adapter/hazard_hub
import adapter/reciever
import adapter/streamer
import dot_env/env
import gleam/erlang/process
import gleam/time/timestamp
import intake/seen_set
import pog
import repeatedly
import repository/earthquake_reader
import repository/initialize_db
import repository/source_writer
import wisp

const default_seen_ttl_ms = 3_600_000

pub fn main() {
  let db = initialize_db.initialize_db()
  let assert Ok(Nil) = source_writer.sync(db)

  // Retention is independent of upstream success: a long 304/error streak
  // must not retain events beyond their seven-day occurrence window.
  cleanup_earthquakes(db)
  let _ =
    repeatedly.call(60_000, Nil, fn(_, _) {
      cleanup_earthquakes(db)
      Nil
    })

  let seen = seen_set.new("matrix_whale_seen", seen_ttl_ms())
  let _ =
    repeatedly.call(60_000, Nil, fn(_, _) {
      seen_set.purge(seen, now_ms())
      Nil
    })

  let secret = wisp.random_string(256)
  let assert Ok(hub) = alert_hub.start()
  let assert Ok(earthquake_hub) = earthquake_hub.start()
  let assert Ok(hazard_hub) = hazard_hub.start()

  let ctx =
    context.Context(
      secret: secret,
      db: db,
      hub: hub.data,
      earthquake_hub: earthquake_hub.data,
      hazard_hub: hazard_hub.data,
      seen: seen,
    )

  // Start both servers - they run in their own processes
  let _ = process.spawn(fn() { reciever.reciever_main(ctx) })
  let _ = process.spawn(fn() { streamer.streamer(ctx) })

  // Keep the main process alive
  process.sleep_forever()
}

fn seen_ttl_ms() -> Int {
  case env.get_int("INTAKE_SEEN_TTL_MS") {
    Ok(value) -> value
    Error(_) -> default_seen_ttl_ms
  }
}

fn now_ms() -> Int {
  let #(seconds, nanoseconds) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  seconds * 1000 + nanoseconds / 1_000_000
}

fn cleanup_earthquakes(db: pog.Connection) -> Nil {
  case earthquake_reader.cleanup(db) {
    Ok(_) -> Nil
    Error(error) ->
      wisp.log_error("Earthquake retention cleanup failed: " <> error)
  }
}
