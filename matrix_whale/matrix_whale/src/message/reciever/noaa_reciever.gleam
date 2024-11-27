import adapter/context.{type Context}
import controller/noaa_controller.{noaa_controller}
import gleam/list
import gleam/string
import gleam/string_tree
import message/reciever/models/noaa
import wisp.{type Request, type Response}

pub fn noaa_data_handler(req: Request, ctx: Context) -> Response {
  use req <- wisp.require_json(req)

  let features_result = noaa.extract_and_decode_features(req)

  wisp.log_info(
    "Extracted " <> string.inspect(list.length(features_result)) <> " features",
  )

  // Process features in batches
  let chunks =
    features_result
    |> list.sized_chunk(100)

  let processed_count =
    chunks
    |> list.fold(0, fn(acc, chunk) {
      case noaa_controller(chunk, ctx) {
        Ok(_) -> {
          wisp.log_info(
            "Successfully processed batch of "
            <> string.inspect(list.length(chunk))
            <> " features",
          )
          acc + list.length(chunk)
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
    string_tree.from_string(
      "Processed "
      <> string.inspect(processed_count)
      <> " features successfully",
    ),
    200,
  )

  let extracted_feature =
    features_result
    |> list.first

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
    string_tree.from_string(
      "Parsing procces. First element's alert type is "
      <> string.inspect(severity),
    ),
    200,
  )
}
