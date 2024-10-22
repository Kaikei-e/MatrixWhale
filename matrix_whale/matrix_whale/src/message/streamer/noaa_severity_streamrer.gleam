import adapter/context.{type Context}
import birl.{get_day, get_time_of_day, now}
import gleam/erlang/process
import gleam/function
import gleam/otp/actor.{type InitResult}
import gleam/string
import gleam/string_builder
import message/streamer/severity_streamer.{severity_streamer}
import mist.{type SSEConnection}
import repeatedly
import wisp.{type Request, type Response}

pub type EventState {
  EventState(severity: String, repeater: repeatedly.Repeater(Nil))
}

pub type Event {
  Severity(String)
  Down(process.ProcessDown)
}

// pub type InitConnectionResult {
//   InitConnectionResult(actor.InitResult(EventState, Event), process.Selector)
// }

pub fn sse_noaa_severity(req: Request, ctx: Context) -> Response {
  wisp.log_info("Starting severity streamer")

  let resp =
    wisp.response(200)
    |> wisp.set_header("Content-Type", "text/event-stream")
    |> wisp.set_header("Cache-Control", "no-cache")
    |> wisp.set_header("Connection", "keep-alive")
    |> wisp.set_header("Access-Control-Allow-Origin", "*")
    |> wisp.set_header("X-Accel-Buffering", "no")

  let init_conn = initialize_streamer(ctx)

  // keep_connection_alive(init_conn.event, init_conn.init_result)
  wisp.log_info("Severity streamer started")

  todo
}

fn initialize_streamer(ctx: Context) -> InitResult(EventState, Event) {
  let init_severity = "Initializing severity streamer"

  wisp.log_info("Initializing severity streamer")
  let subj = process.new_subject()
  let monitor = process.monitor_process(process.self())
  let selector =
    process.new_selector()
    |> process.selecting(subj, function.identity)
    |> process.selecting_process_down(monitor, Down)

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
  actor.Ready(EventState(init_severity, repeater), selector)
}

fn keep_connection_alive(message: Event, conn: SSEConnection, state: EventState) {
  wisp.log_info("Received message in SSE loop")
  case message {
    Severity(value) -> {
      let event = mist.event(string_builder.from_string(value))
      case mist.send_event(conn, event) {
        Ok(_) -> {
          wisp.log_info("Sent event: " <> string.inspect(value))
          actor.continue(EventState(..state, severity: value))
        }
        Error(error) -> {
          wisp.log_error("Failed to send event: " <> string.inspect(error))
          repeatedly.stop(state.repeater)
          actor.Stop(process.Normal)
        }
      }
    }
    Down(_process_down) -> {
      wisp.log_info("Client disconnected")
      repeatedly.stop(state.repeater)
      actor.Stop(process.Normal)
    }
  }
}
