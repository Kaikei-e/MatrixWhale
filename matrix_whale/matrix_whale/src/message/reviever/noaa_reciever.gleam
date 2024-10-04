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

  let features_list = noaa.extract_and_decode_features(unescaped_body_string)

  io.debug(list.first(features_list) |> string.inspect)

  wisp.log_info("Data successfully received and parsed.")
  wisp.json_response(
    string_builder.from_string(
      "Parsing procce. First element's alert type is "
      <> string.inspect(
        list.first(features_list)
        |> result.map(fn(element) { element.properties.severity })
        |> result.unwrap(or: noaa.UnknownSeverity),
      ),
    ),
    200,
  )
  // case processed_result {
  //   Ok(features) -> {
  //     wisp.log_info("Data successfully received and parsed.")
  //     wisp.json_response(
  //       string_builder.from_string(
  //         "Parsing procce. First element's alert type is "
  //         <> string.inspect(
  //           list.first(features)
  //           |> result.map(fn(element) { element.properties.severity })
  //           |> result.unwrap(or: noaa.UnknownSeverity),
  //         ),
  //       ),
  //       200,
  //     )
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
