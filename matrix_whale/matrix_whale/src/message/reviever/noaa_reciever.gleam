import gleam/bit_array
import gleam/io
import gleam/list
import gleam/result
import gleam/string
import gleam/string_builder
import message/reviever/models/noaa
import string_tools/replace_back_slashes
import wisp.{type Request, type Response}

pub fn noaa_data_handler(req: Request) -> Response {
  let req_body = case wisp.read_body_to_bitstring(req) {
    Ok(body) -> body
    Error(err) -> {
      wisp.log_error("Error reading body: " <> string.inspect(err))
      <<>>
    }
  }

  let body_string =
    bit_array.to_string(req_body)
    |> result.map_error(fn(err) {
      io.debug(err)
      string_builder.from_string("Invalid data format: " <> string.inspect(err))
    })
    |> result.unwrap("Invalid data format")

  // unescape the body_string
  let unescaped_body_string =
    replace_back_slashes.replace_double_backslash(body_string, "")
    |> replace_back_slashes.replace_back_slash
    |> string.trim

  io.debug(
    "body_string"
    <> string.inspect(string.slice(unescaped_body_string, 0, 1000)),
  )

  let features_string =
    noaa.extract_features(unescaped_body_string)
    |> result.map_error(fn(err) {
      io.debug(err)
      string_builder.from_string("Invalid data format: " <> string.inspect(err))
    })

  let unwrapped_result = case features_string {
    Ok(features) -> features
    Error(err) -> {
      io.debug(err)
      wisp.log_error("Error extracting features: " <> string.inspect(err))
      []
    }
  }

  let processed_result =
    list.map(unwrapped_result, fn(feature_target) {
      noaa.decode_feature(result.unwrap(feature_target, ""))
    })
    |> result.all
    |> result.map_error(fn(err) {
      io.debug(err)
      string_builder.from_string("Invalid data format: " <> string.inspect(err))
    })
    |> result.map(fn(features) { features })

  case processed_result {
    Ok(features) -> {
      wisp.log_info("Data successfully received and parsed.")
      wisp.json_response(
        string_builder.from_string(
          "Parsing procce. First element's alert type is "
          <> string.inspect(
            list.first(features)
            |> result.map(fn(element) { element.properties.severity })
            |> result.unwrap(or: noaa.UnknownSeverity),
          ),
        ),
        200,
      )
    }
    Error(err) -> {
      wisp.log_error("Error parsing data: " <> string.inspect(err))
      wisp.json_response(
        string_builder.from_string(
          "Invalid data format: " <> string.inspect(err),
        ),
        400,
      )
    }
  }
}
