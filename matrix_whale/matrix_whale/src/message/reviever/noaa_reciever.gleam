import gleam/bit_array
import gleam/io
import gleam/list
import gleam/result
import gleam/string
import gleam/string_builder
import message/reviever/models/noaa
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
    string.trim(body_string)
    |> string.replace("\\\\", "\\")
    |> string.replace("\\\"", "\"")
    |> string.replace("\n", "")
    |> string.replace("\\r", "")
    |> string.trim

  let features_result = noaa.extract_and_decode_features(unescaped_body_string)

  let extracted_feature =
    features_result
    |> list.first
    |> result.try(fn(feature_element) {
      case feature_element {
        Ok(fe) -> Ok(fe)
        Error(err) -> {
          io.debug("Error parsing data: " <> string.inspect(err))
          Error(Nil)
        }
      }
    })

  let severity = case extracted_feature {
    Ok(feature_element) -> {
      feature_element.properties.severity
    }
    Error(err) -> {
      wisp.log_error("Error parsing data: " <> string.inspect(err))
      noaa.UnknownSeverity
    }
  }

  wisp.log_info("Data successfully received and parsed.")
  wisp.json_response(
    string_builder.from_string(
      "Parsing procce. First element's alert type is "
      <> string.inspect(severity),
    ),
    200,
  )
  // case extracted_feature {
  //   Ok(severity) -> {

  //   }
  //   Error(err) -> {
  //     wisp.log_error("Error parsing data: " <> string.inspect(err))
  //     wisp.json_response(
  //       string_builder.from_string(
  //         "Invalid data format: " <> string.inspect(err),
  //       ),
  //       400,
  //     )
  //   }
  // }
}
