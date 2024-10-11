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
    Ok(_) -> {
      wisp.log_info("Noaa alert severities written to database")
      Ok("Noaa alert severities written to database")
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
