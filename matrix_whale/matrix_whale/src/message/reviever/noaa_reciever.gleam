import erlang_tools/zip
import gleam/string_builder
import wisp.{type Request, type Response}

pub fn noaa_data_handler(req: Request) -> Response {
  use bit_data <- wisp.require_bit_array_body(req)

  let result = {
    case zip.gunzip(bit_data) {
      Ok(json_data) -> {
        Ok(json_data)
      }
      Error(_) -> Error("Invalid data format")
    }
  }

  case result {
    Ok(_) -> {
      string_builder.from_string("Data recieved")
      |> wisp.json_response(200)
    }
    Error(_) -> {
      string_builder.from_string("Invalid data format")
      |> wisp.json_response(400)
    }
  }
}
