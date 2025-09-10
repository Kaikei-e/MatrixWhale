import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/result
import wisp.{type Request, type Response}

pub type LogFormat {
  LogFormat(time: String, level: String, message: String, service: String)
}

fn decode_logs(json: Dynamic) -> Result(LogFormat, List(decode.DecodeError)) {
  let decoder = {
    use time <- decode.field("time", decode.string)
    use level <- decode.field("level", decode.string)
    use message <- decode.field("msg", decode.string)
    use service <- decode.field("service", decode.string)
    decode.success(LogFormat(
      time: time,
      level: level,
      message: message,
      service: service,
    ))
  }

  decode.run(json, decoder)
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
      wisp.json_response("\"Log recieved\"", 200)
    }
    Error(_) -> {
      wisp.json_response("\"Invalid log format\"", 400)
    }
  }
}
