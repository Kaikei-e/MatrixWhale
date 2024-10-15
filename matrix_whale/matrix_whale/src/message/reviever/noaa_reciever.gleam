import adapter/context.{type Context}
import controller/noaa_controller.{noaa_controller}
import gleam/bit_array
import gleam/io
import gleam/list
import gleam/result
import gleam/string
import gleam/string_builder
import message/reviever/models/noaa
import wisp.{type Request, type Response}

pub fn noaa_data_handler(req: Request, ctx: Context) -> Response {
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
      wisp.log_error("Invalid data format: " <> string.inspect(err))
      string_builder.from_string("Invalid data format: " <> string.inspect(err))
    })
    |> result.unwrap("Invalid data format")

  // unescape the body_string
  let unescaped_body_string =
    string.trim(body_string)
    |> string.replace("\\\\", "\\")
    |> string.replace("\\\"", "\"")
    |> string.replace("", " ")
    |> string.replace("\\n", " ")
    |> string.trim

  let features_result = noaa.extract_and_decode_features(unescaped_body_string)

  wisp.log_info(
    "Extracted " <> string.inspect(list.length(features_result)) <> " features",
  )

  let handled_features =
    features_result
    |> list.filter_map(fn(feature) {
      case feature {
        Ok(feature) -> Ok(feature)
        Error(err) -> {
          wisp.log_error("Error parsing feature: " <> string.inspect(err))
          Error(err)
        }
      }
    })

  wisp.log_info(
    "Handled " <> string.inspect(list.length(handled_features)) <> " features",
  )

  let result = noaa_controller(handled_features, ctx)
  case result {
    Ok(_) -> {
      wisp.log_info("Noaa alert severities written to database")
    }
    Error(err) -> {
      wisp.log_error(
        "Error writing noaa alert severities to database: "
        <> string.inspect(err),
      )
    }
  }

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
      wisp.log_error(
        "Error parsing data from noaa_adapter: " <> string.inspect(err),
      )
      noaa.UnknownSeverity
    }
  }

  wisp.log_info("Data successfully received and parsed.")
  wisp.json_response(
    string_builder.from_string(
      "Parsing procces. First element's alert type is "
      <> string.inspect(severity),
    ),
    200,
  )
}
