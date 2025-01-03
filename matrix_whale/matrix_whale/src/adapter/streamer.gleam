import adapter/context.{type Context}
import birl.{get_day, get_time_of_day, now}
import gleam/bytes_tree
import gleam/erlang/process
import gleam/function
import gleam/http/request
import gleam/http/response
import gleam/otp/actor
import gleam/string
import gleam/string_tree
import message/streamer/severity_streamer.{severity_streamer}
import mist
import repeatedly
import wisp

pub type EventState {
  EventState(severity: String, repeater: repeatedly.Repeater(Nil))
}

pub type Event {
  Severity(String)
  Down(process.ProcessDown)
}

pub fn streamer(ctx: Context) {
  wisp.log_info("Starting severity streamer")
  let init_severity = "Initial SSE"
  let assert Ok(_) =
    fn(req) {
      case request.path_segments(req) {
        ["api", "v1", "noaa_data", "stream"] -> {
          mist.server_sent_events(
            req,
            response.new(200),
            init: fn() {
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

                  let severity = severity_streamer(ctx)

                  let severity_state =
                    "Upcoming severity: "
                    <> severity.severity
                    <> " for "
                    <> severity.area_desc
                    <> " at "
                    <> datetime_of_now
                  wisp.log_info("Sending severity: " <> severity_state)
                  process.send(subj, Severity(severity_state))
                })
              actor.Ready(EventState(init_severity, repeater), selector)
            },
            loop: fn(message, conn, state) {
              wisp.log_info("Received message in SSE loop")
              case message {
                Severity(value) -> {
                  let event = mist.event(string_tree.from_string(value))
                  case mist.send_event(conn, event) {
                    Ok(_) -> {
                      wisp.log_info("Sent event: " <> string.inspect(value))
                      actor.continue(EventState(..state, severity: value))
                    }
                    Error(error) -> {
                      wisp.log_error(
                        "Failed to send event: " <> string.inspect(error),
                      )
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
            },
          )
        }
        _ -> {
          wisp.log_error("Invalid path segments")
          response.new(404)
          |> response.set_body(mist.Bytes(bytes_tree.from_string("Not Found")))
        }
      }
    }
    |> mist.new
    |> mist.port(8080)
    |> mist.start_http()
  wisp.log_info("Severity streamer started")
  process.sleep_forever()
}
