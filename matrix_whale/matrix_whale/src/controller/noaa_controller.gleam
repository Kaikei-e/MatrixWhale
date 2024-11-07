import adapter/context.{type Context}
import gleam/list
import gleam/string
import message/reciever/models/noaa.{type FeatureElement, Test}
import repository/noaa_writer.{write_noaa_alerts}
import wisp

pub fn noaa_controller(
  features: List(FeatureElement),
  ctx: Context,
) -> Result(String, String) {
  wisp.log_info(
    "Processing " <> string.inspect(list.length(features)) <> " features",
  )

  let test_data_removed_list =
    features
    |> list.filter(fn(feature) { feature.properties.status != Test })

  let result = write_noaa_alerts(test_data_removed_list, ctx.db)
  case result {
    Ok(count) -> {
      let message =
        "Inserted "
        <> string.inspect(count)
        <> " noaa alert severities into database"
      wisp.log_info(message)
      Ok("OK at " <> string.inspect(count))
    }
    Error(err) -> {
      wisp.log_error(
        "Error writing noaa alert severities to database: "
        <> string.inspect(err),
      )
      Error(err)
    }
  }
}
