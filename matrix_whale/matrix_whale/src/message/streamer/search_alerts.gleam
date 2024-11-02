import adapter/context.{type Context}
import domain/noaa_severity.{type NOAASeverity, NOAASeverity}
import gleam/list
import gleam/string
import repository/noaa_reader
import wisp

pub fn search_alerts_by_area_description(
  area_desc: String,
  ctx: Context,
) -> Result(List(NOAASeverity), String) {
  let conn = ctx.db
  let severities = noaa_reader.search_area_description(area_desc, conn)

  let result = case severities {
    Ok(severities) -> {
      wisp.log_info("Found severity: " <> string.inspect(severities))
      Ok(
        list.map(severities, fn(severity) {
          NOAASeverity(severity.area_desc, severity.severity)
        }),
      )
    }
    Error(error) -> {
      wisp.log_error("Failed to fetch severity: " <> string.inspect(error))
      Error(error)
    }
  }

  result
}
