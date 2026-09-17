import adapter/alert_hub
import adapter/context
import adapter/earthquake_hub
import adapter/reciever
import adapter/streamer
import gleam/erlang/process
import pog
import repeatedly
import repository/earthquake_reader
import repository/initialize_db
import wisp

pub fn main() {
  let db = initialize_db.initialize_db()
  // Retention is independent of upstream success: a long 304/error streak
  // must not retain events beyond their seven-day occurrence window.
  cleanup_earthquakes(db)
  let _ =
    repeatedly.call(60_000, Nil, fn(_, _) {
      cleanup_earthquakes(db)
      Nil
    })
  let secret = wisp.random_string(256)
  let assert Ok(hub) = alert_hub.start()
  let assert Ok(earthquake_hub) = earthquake_hub.start()

  let ctx =
    context.Context(
      secret: secret,
      db: db,
      hub: hub.data,
      earthquake_hub: earthquake_hub.data,
    )

  // Start both servers - they run in their own processes
  let _ = process.spawn(fn() { reciever.reciever_main(ctx) })
  let _ = process.spawn(fn() { streamer.streamer(ctx) })

  // Keep the main process alive
  process.sleep_forever()
}

fn cleanup_earthquakes(db: pog.Connection) -> Nil {
  case earthquake_reader.cleanup(db) {
    Ok(_) -> Nil
    Error(error) ->
      wisp.log_error("Earthquake retention cleanup failed: " <> error)
  }
}
