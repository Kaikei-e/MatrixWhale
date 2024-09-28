import erlang_tools/zip
import gleam/dynamic
import gleam/io
import gleam/json
import gleam/result
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
      let result = {
        case gleam_decode.decode(decoded) {
          Ok(json) -> {
            let object =
              json.object([
                #("info", json.string(json.string(json.field("info", json)))),
                #("features", json.array(json.field("features", json))),
              ])
          }
          Error(_) -> Error("Invalid JSON format")
        }

        Ok(json.to_string_builder(object))
      }

      case result {
        Ok(_) -> {
          string_builder.from_string("Data received")
          |> wisp.json_response(200)
        }
        Error(_) -> {
          string_builder.from_string("Invalid data format")
          |> wisp.json_response(400)
        }
      }
    }
    Error(_) -> {
      string_builder.from_string("Invalid data format")
      |> wisp.json_response(400)
    }
  }

  case result {
    Ok(decompressed) -> {
      let parsed_result =
        noaa.decode_alerts(decompressed, dynamic.string)
        |> result.map_err(fn(err) { "Invalid JSON format: " <> err })

      case parsed_result {
        Ok(parsed) -> {
          string_builder.from_string("Data received")
          |> wisp.json_response(200)
        }
        Error(err) -> {
          string_builder.from_string(err)
          |> wisp.json_response(400)
        }
      }
    }
    Error(err) -> {
      string_builder.from_string(err)
      |> wisp.json_response(400)
    }
  }
}
