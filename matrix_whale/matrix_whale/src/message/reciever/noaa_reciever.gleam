import adapter/context.{type Context}
import controller/noaa_controller.{noaa_controller}
import gleam/bit_array
import gleam/io
import gleam/list
import gleam/result
import gleam/string
import gleam/string_builder
import message/reciever/models/noaa
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
      io.debug(err)
      string_builder.from_string("Invalid data format: " <> string.inspect(err))
    })
    |> result.unwrap("Invalid data format")

  // unescape the body_string
  let unescaped_body_string =
    string.trim(body_string)
    |> string.replace("\\\\", "\\")
    |> string.replace("\\\"", "\"")
    |> string.replace("\n", " ")
    |> string.replace("\\r", " ")
    |> string.replace("\t", " ")
    |> string.trim

  let features_result = noaa.extract_and_decode_features(unescaped_body_string)

  wisp.log_info(
    "Extracted " <> string.inspect(list.length(features_result)) <> " features",
  )

  // First attempt to decode and process features
  let valid_features = case features_result {
    [] -> {
      // If features_result is empty, JSON decoding failed completely
      wisp.log_error("No features extracted from JSON")
      // Log a sample of the input for debugging
      let sample_length = 2000
      let input_sample = case string.length(unescaped_body_string) {
        n if n > sample_length ->
          string.slice(unescaped_body_string, 0, sample_length) <> "..."
        _ -> unescaped_body_string
      }
      wisp.log_error("Input sample: " <> input_sample)
      []
    }
    features -> {
      // Process each feature, filtering out errors
      features
      |> list.filter_map(fn(feature) {
        case feature {
          Ok(feature) -> Ok([feature])
          Error(err) -> {
            wisp.log_error("Error parsing feature: " <> string.inspect(err))
            Error(Nil)
          }
        }
      })
    }
  }

  // Process the valid features
  case valid_features {
    [] -> {
      wisp.log_info("No valid features to process")
      wisp.json_response(
        string_builder.from_string("No valid features found"),
        200,
      )
    }
    features -> {
      // Process features in batches
      let chunks = list.sized_chunk(features, 100)

      let processed_count =
        chunks
        |> list.fold(0, fn(acc, chunk) {
          case noaa_controller(list.flatten(chunk), ctx) {
            Ok(_) -> {
              wisp.log_info(
                "Successfully processed batch of "
                <> string.inspect(list.length(list.flatten(chunk)))
                <> " features",
              )
              acc + list.length(list.flatten(chunk))
            }
            Error(err) -> {
              wisp.log_error(
                "Error processing batch: "
                <> string.inspect(err)
                <> ". Continuing with remaining batches.",
              )
              acc
            }
          }
        })

      wisp.log_info(
        "Processed "
        <> string.inspect(processed_count)
        <> " out of "
        <> string.inspect(list.length(features_result))
        <> " total features",
      )

      wisp.json_response(
        string_builder.from_string(
          "Processed "
          <> string.inspect(processed_count)
          <> " features successfully",
        ),
        200,
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
          wisp.log_error(
            "Error parsing data from noaa_adapter: " <> string.inspect(err),
          )
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
