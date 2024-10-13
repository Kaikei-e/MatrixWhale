import adapter/context
import adapter/reciever
import adapter/streamer
import gleam/otp/task
import repository/initialize_db
import wisp

pub fn main() {
  let db = initialize_db.initialize_db()
  let secret = wisp.random_string(256)

  let ctx = context.Context(secret: secret, db: db)

  // Start the receiver server in a separate process
  let _ = task.async(fn() { reciever.reciever_main(ctx) })

  // Start the streamer server in the main process
  streamer.streamer(ctx)
}
