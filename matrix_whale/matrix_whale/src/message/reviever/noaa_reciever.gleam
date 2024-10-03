import erlang_tools/zip
import gleam/bit_array
import gleam/dynamic
import gleam/io
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import gleam/string_builder
import message/reviever/models/noaa
import wisp.{type Request, type Response}

pub fn noaa_data_handler(req: Request) -> Response {
  use bit_data <- wisp.require_bit_array_body(req)

  io.debug(
    "Received data length: " <> string.inspect(bit_array.byte_size(bit_data)),
  )

  let decoded_result =
    zip.gunzip(bit_data)
    |> result.map(fn(data) {
      io.debug(
        "Unzipped data length: "
        <> string.inspect(bit_array.byte_size(bit_array.from_string(data))),
      )
      io.debug(
        "Unzipped data (first 100 chars): " <> string.slice(data, 0, 100),
      )
      json.decode(data, dynamic.string)
    })
    |> result.map_error(fn(err) {
      io.debug("Gunzip error: " <> string.inspect(err))
      err
    })

  let parsed_result = case decoded_result {
    Ok(decoded_result) -> {
      let unwrapped_result =
        result.unwrap(decoded_result, or: "Invalid data format")

      io.debug(unwrapped_result)

      noaa.decode_alert_element_list(unwrapped_result)
      |> result.map_error(fn(err) {
        io.debug(err)
        string_builder.from_string(
          "Invalid data format: " <> string.inspect(err),
        )
      })
    }
    Error(err) -> {
      io.debug(err)
      Error(string_builder.from_string(
        "Invalid data format: " <> string.inspect(err),
      ))
    }
  }

  case parsed_result {
    Ok(features) -> {
      wisp.log_info("Data successfully received and parsed.")
      wisp.json_response(
        string_builder.from_string(
          "Parsing procce. First element's alert type is "
          <> string.inspect(
            list.first(features.elements)
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
