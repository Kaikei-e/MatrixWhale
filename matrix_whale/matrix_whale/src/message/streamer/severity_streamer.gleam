import adapter/context.{type Context}
import gleam/string
import repository/noaa_reader.{NOAASeverity, read_noaa_severity}
import wisp

pub fn severity_streamer(ctx: Context) -> List(String) {
  wisp.log_info("Severity streamer started streaming")

  let conn = ctx.db

  let severity_result = read_noaa_severity(conn)

  let severity = case severity_result {
    Ok(severity) -> severity
    Error(err) -> {
      wisp.log_error("Failed to fetch severity: " <> string.inspect(err))
      NOAASeverity(area_desc: "", severity: "")
    }
  }

  let area_desc = severity.area_desc
  let severity = severity.severity
  // let datetime = severity.datetime

  [area_desc, severity]
}
