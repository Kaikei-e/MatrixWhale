import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/option.{type Option, None}
import gleam/result
import logs/reciever/service_classifier
import wisp.{type Request, type Response}

pub type LogFormat {
  LogFormat(
    time: String,
    level: String,
    message: String,
    service: String,
    source: Option(String),
  )
}

fn decode_logs(json: Dynamic) -> Result(LogFormat, List(decode.DecodeError)) {
  let decoder = {
    use time <- decode.field("time", decode.string)
    use level <- decode.field("level", decode.string)
    use message <- decode.field("msg", decode.string)
    use service <- decode.field("service", decode.string)
    use source <- decode.optional_field(
      "source",
      None,
      decode.optional(decode.string),
    )
    decode.success(LogFormat(
      time: time,
      level: level,
      message: message,
      service: service,
      source: source,
    ))
  }

  decode.run(json, decoder)
}

pub fn noaa_logs_handler(req: Request) -> Response {
  use json <- wisp.require_json(req)

  let result = {
    use log_format <- result.try(decode_logs(json))

    emit_log(log_format)

    Ok(Nil)
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

fn emit_log(log_format: LogFormat) -> Nil {
  let source =
    service_classifier.classify(log_format.service, log_format.source)
    |> service_classifier.source_name
  let message =
    "[source="
    <> source
    <> "][service="
    <> log_format.service
    <> "] "
    <> log_format.message
  case log_format.level {
    "EMERGENCY" -> wisp.log_emergency(message)
    "ALERT" -> wisp.log_alert(message)
    "CRITICAL" -> wisp.log_critical(message)
    "ERROR" -> wisp.log_error(message)
    "WARN" -> wisp.log_warning(message)
    "WARNING" -> wisp.log_warning(message)
    "NOTICE" -> wisp.log_notice(message)
    "DEBUG" -> wisp.log_debug(message)
    _ -> wisp.log_info(message)
  }
}
