import adapter/context
import adapter/reciever
import adapter/streamer
import gleam/erlang/process
import repository/initialize_db
import wisp

pub fn main() {
  let db = initialize_db.initialize_db()
  let secret = wisp.random_string(256)

  let ctx = context.Context(secret: secret, db: db)

  // Start both servers - they run in their own processes
  let _ = process.spawn(fn() { reciever.reciever_main(ctx) })
  let _ = process.spawn(fn() { streamer.streamer(ctx) })

  // Keep the main process alive
  process.sleep_forever()
}
