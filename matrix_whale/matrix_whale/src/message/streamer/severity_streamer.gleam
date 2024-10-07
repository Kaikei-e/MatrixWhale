// import gleam/erlang/process
// import gleam/int
// import gleam/string
// import gleam/string_builder
// import gleam/option.{type Option}
// import wisp.{type Request, type Response}
// import gleam/http/response

// pub type Message {
//   Severity(String)
//   Down(process.ProcessDown)
// }

// pub fn streamer(req: Request) -> Response {
//   wisp.log_info("Starting severity streamer")

//   let headers = [
//     #("Content-Type", "text/event-stream"),
//     #("Cache-Control", "no-cache"),
//     #("Connection", "keep-alive"),
//   ]

//   wisp.stream_response(
//     response.new(200)
//     |> response.set_headers(headers),
//     fn(send) {
//       let subj = process.new_subject()
//       let monitor = process.monitor_process(process.self())
//       let selector =
//         process.new_selector()
//         |> process.selecting(subj, fn(msg) { msg })
//         |> process.selecting_process_down(monitor, fn(_) { Down })

//       stream_loop(selector, send)
//     }
//   )
// }

// fn stream_loop(
//   selector: process.Selector(Message),
//   send: fn(String) -> Result(Nil, Nil),
// ) -> Result(Nil, Nil) {
//   case process.select(selector) {
//     Severity(value) -> {
//       let event_data =
//         string_builder.new()
//         |> string_builder.append("event: stream_severity\n")
//         |> string_builder.append("data: ")
//         |> string_builder.append(value)
//         |> string_builder.append("\n\n")
//         |> string_builder.to_string()

//       case send(event_data) {
//         Ok(_) -> {
//           wisp.log_info("Sent event: " <> value)
//           stream_loop(selector, send)
//         }
//         Error(_) -> {
//           wisp.log_error("Failed to send event")
//           Ok(Nil)
//         }
//       }
//     }
//     Down -> {
//       wisp.log_info("Stream closed")
//       Ok(Nil)
//     }
//   }
// }

// @external(erlang, "erlang", "system_time")
// fn system_time(unit: atom) -> Int
