import adapter/context
import adapter/reciever
import adapter/streamer
import gleam/erlang/process
import gleam/otp/task
import repository/initialize_db
import wisp

pub fn main() {
  let db = initialize_db.initialize_db()
  let secret = wisp.random_string(256)

  let ctx = context.Context(secret: secret, db: db)

  // Start both servers asynchronously
  let receiver_task = task.async(fn() { reciever.reciever_main(ctx) })
  let streamer_task = task.async(fn() { streamer.streamer(ctx) })

  // Wait for both tasks to complete (which they never will, as they run forever)
  task.await_forever(receiver_task)
  task.await_forever(streamer_task)

  // This line will never be reached, but it's good practice to include it
  process.sleep_forever()
}
