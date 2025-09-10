import adapter/context.{type Context}
import birl.{get_day, get_time_of_day, now}
import gleam/erlang/process
import gleam/otp/actor
import gleam/string
import repeatedly
import wisp.{type Request, type Response}

pub type EventState {
  EventState(severity: String, repeater: repeatedly.Repeater(Nil))
}

pub type Event {
  Severity(String)
  Down(process.Down)
}

// pub type InitConnectionResult {
//   InitConnectionResult(actor.InitResult(EventState, Event), process.Selector)
// }

pub fn sse_noaa_severity(_req: Request, ctx: Context) -> Response {
  wisp.log_info("Starting severity streamer")

  let _resp =
    wisp.response(200)
    |> wisp.set_header("Content-Type", "text/event-stream")
    |> wisp.set_header("Cache-Control", "no-cache")
    |> wisp.set_header("Connection", "keep-alive")
    |> wisp.set_header("Access-Control-Allow-Origin", "*")
    |> wisp.set_header("X-Accel-Buffering", "no")

  let _init_conn = initialize_streamer(ctx)

  // keep_connection_alive(init_conn.event, init_conn.init_result)
  wisp.log_info("Severity streamer started")

  wisp.response(404)
  |> wisp.string_body("SSE endpoint not implemented")
}

fn initialize_streamer(
  _ctx: Context,
) -> Result(actor.Initialised(EventState, Event, Nil), String) {
  let init_severity = "Initializing severity streamer"

  wisp.log_info("Initializing severity streamer")
  let subj = process.new_subject()
  let _monitor = process.monitor(process.self())
  let _selector =
    process.new_selector()
    |> process.select(subj)

  let repeater =
    repeatedly.call(5000, Nil, fn(_state, _count) {
      let t_now = now()
      let date = get_day(t_now)
      let time = get_time_of_day(t_now)
      let datetime_of_now =
        string.concat([
          string.inspect(date.year),
          "-",
          string.inspect(date.month),
          "-",
          string.inspect(date.date),
          " ",
          string.inspect(time.hour),
          ":",
          string.inspect(time.minute),
          ":",
          string.inspect(time.second),
        ])

      let severity_state = "Upcoming severity will be here: " <> datetime_of_now

      wisp.log_info("Sending severity: " <> severity_state)
      process.send(subj, Severity(severity_state))
    })
  Ok(actor.initialised(EventState(init_severity, repeater)))
}
