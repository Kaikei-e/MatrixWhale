import adapter/reciever
import adapter/streamer
import gleam/otp/task

pub fn main() {
  // Start the receiver server in a separate process
  let _ = task.async(fn() { reciever.reciever_main() })

  // Start the streamer server in the main process
  streamer.streamer()
}
