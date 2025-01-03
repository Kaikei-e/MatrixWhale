import gleam/dynamic.{type Dynamic}
import gleam/json
import gleam/result
import gleam/string_tree
import wisp.{type Request, type Response}

pub type LogFormat {
  LogFormat(time: String, level: String, message: String, service: String)
}

fn decode_logs(json: Dynamic) -> Result(LogFormat, List(dynamic.DecodeError)) {
  let decoder =
    dynamic.decode4(
      LogFormat,
      dynamic.field("time", dynamic.string),
      dynamic.field("level", dynamic.string),
      dynamic.field("msg", dynamic.string),
      dynamic.field("service", dynamic.string),
    )

  decoder(json)
}

pub fn noaa_logs_handler(req: Request) -> Response {
  use json <- wisp.require_json(req)

  let result = {
    use log_format <- result.try(decode_logs(json))

    let object =
      json.object([
        #("time", json.string(log_format.time)),
        #("level", json.string(log_format.level)),
        #("msg", json.string(log_format.message)),
        #("service", json.string(log_format.service)),
      ])

    Ok(json.to_string_tree(object))
  }

  case result {
    Ok(_) -> {
      string_tree.from_string("Log recieved")
      |> wisp.json_response(200)
    }
    Error(_) -> {
      string_tree.from_string("Invalid log format")
      |> wisp.json_response(400)
    }
  }
}
