import adapter/context.{type Context}
import gleam/string
import message/reviever/models/noaa.{type FeatureElement}
import repository/noaa_writer.{write_noaa_alerts}
import wisp

pub fn noaa_controller(
  features: List(FeatureElement),
  ctx: Context,
) -> Result(String, String) {
  let result = write_noaa_alerts(features, ctx.db)
  case result {
    Ok(count) -> {
      let message =
        "Inserted "
        <> string.inspect(count)
        <> " noaa alert severities into database"
      wisp.log_info(message)
      Ok(message)
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
