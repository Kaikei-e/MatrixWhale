import adapter/context.{type Context}
import birl.{get_day, get_time_of_day, now}
import gleam/bit_array
import gleam/bytes_builder
import gleam/dynamic
import gleam/erlang/process
import gleam/function
import gleam/http.{Post}
import gleam/http/request
import gleam/http/response
import gleam/io
import gleam/json
import gleam/list
import gleam/otp/actor
import gleam/result
import gleam/string
import gleam/string_builder
import message/streamer/search_alerts.{search_alerts_by_area_description}
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

// "{\"areaDescription\":\"Calcasieu, LA\"}"

type SearchAreaDescriptionWords {
  SearchAreaDescriptionWords(area_desc: String)
}

pub fn streamer(ctx: Context) {
  wisp.log_info("Starting severity streamer")

  let init_severity = "Initial SSE"
  let assert Ok(_) =
    fn(req) {
      case request.path_segments(req) {
        ["api", "v1", "noaa_data", "stream"] -> {
          wisp.log_info("Handling SSE request")
          let resp =
            response.new(200)
            |> response.set_header("Content-Type", "text/event-stream")
            |> response.set_header("Cache-Control", "no-cache")
            |> response.set_header("Connection", "keep-alive")
            |> response.set_header("Access-Control-Allow-Origin", "*")
            |> response.set_header("X-Accel-Buffering", "no")

          mist.server_sent_events(
            req,
            resp,
            init: fn() {
              wisp.log_info("Initializing SSE connection")
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
                  let event = mist.event(string_builder.from_string(value))
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
        ["api", "v1", "noaa_data", "search_area_description"] -> {
          wisp.log_info("Received request for search_area_description")

          case req.method {
            Post -> {
              mist.read_body(req, 1024 * 1024 * 10)
              |> result.map(fn(req) {
                let search_word =
                  bit_array.to_string(req.body)
                  |> result.then(fn(body_string) {
                    json.decode(
                      body_string,
                      dynamic.decode1(
                        SearchAreaDescriptionWords,
                        dynamic.field("areaDescription", dynamic.string),
                      ),
                    )
                    |> result.map_error(fn(_) { Nil })
                  })
                  |> result.unwrap(SearchAreaDescriptionWords(""))

                wisp.log_info(
                  "Searching for area description: " <> search_word.area_desc,
                )

                let result =
                  search_alerts_by_area_description(search_word.area_desc, ctx)
                  |> result.map_error(fn(error) {
                    wisp.log_error(
                      "Error searching for area description: " <> error,
                    )
                    response.new(401)
                    |> response.set_body(
                      mist.Bytes(bytes_builder.from_string("Not Found")),
                    )
                  })

                case result {
                  Ok(severities) -> {
                    let json_body =
                      severities
                      |> list.map(fn(severity) {
                        json.object([
                          #("area_desc", json.string(severity.area_desc)),
                          #("severity", json.string(severity.severity)),
                        ])
                      })
                      |> json.preprocessed_array
                      |> json.to_string

                    io.debug(json_body)

                    response.new(200)
                    |> response.set_header("Content-Type", "application/json")
                    |> response.set_body(
                      mist.Bytes(bytes_builder.from_string(json_body)),
                    )
                  }
                  Error(error) -> {
                    wisp.log_error(
                      "Error searching for area description: "
                      <> string.inspect(error),
                    )
                    response.new(400)
                    |> response.set_body(
                      mist.Bytes(bytes_builder.from_string("Bad Request")),
                    )
                  }
                }
              })
              |> result.lazy_unwrap(fn() {
                response.new(400)
                |> response.set_body(
                  mist.Bytes(bytes_builder.from_string("Bad Request")),
                )
              })
            }
            _ -> {
              wisp.log_info("Received request for unknown path")
              response.new(405)
              |> response.set_body(
                mist.Bytes(bytes_builder.from_string("Not Allowed")),
              )
            }
          }
        }
        _ -> {
          wisp.log_alert(
            "Received request for unknown path: " <> string.inspect(req.path),
          )
          response.new(404)
          |> response.set_body(
            mist.Bytes(bytes_builder.from_string("Not Found")),
          )
        }
      }
    }
    |> mist.new
    |> mist.port(8080)
    |> mist.start_http

  wisp.log_info("Server started on port 8080")
  process.sleep_forever()
}
// type Unit {
//   Millisecond
// }

// @external(erlang, "erlang", "system_time")
// fn system_time(unit: Unit) -> Int
