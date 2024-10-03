import erlang_tools/zip
import gleam/dynamic
import gleam/json
import gleam/result
import gleam/string
import gleam/string_builder
import message/reviever/models/noaa
import wisp.{type Request, type Response}

pub fn noaa_data_handler(req: Request) -> Response {
  use bit_data <- wisp.require_bit_array_body(req)

  let decoded_result =
    zip.gunzip(bit_data)
    |> result.map(fn(data) { json.decode(data, dynamic.string) })

  case decoded_result {
    Ok(decoded) -> {
      case decoded {
        Ok(decoded) -> {
          noaa.decode_alert_element_list(decoded)
          |> result.map_error(fn(err) {
            string_builder.from_string(
              "Invalid data format: " <> string.inspect(err),
            )
          })
          |> result.map(fn(_) {
            wisp.json_response(
              string_builder.from_string("Parsing proccess was succeded"),
              200,
            )
          })
          |> result.unwrap(wisp.json_response(
            string_builder.from_string("Invalid data format"),
            400,
          ))
        }
        Error(err) -> {
          wisp.json_response(
            string_builder.from_string(
              "Invalid data format: " <> string.inspect(err),
            ),
            400,
          )
        }
      }
    }
    Error(_) -> {
      wisp.json_response(string_builder.from_string("Invalid data format"), 400)
    }
  }
}
