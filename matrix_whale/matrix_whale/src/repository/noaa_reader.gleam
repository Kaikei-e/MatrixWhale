// import birl.{type Time}
import gleam/dynamic
import gleam/list
import gleam/string
import pog
import wisp

pub type NOAASeverity {
  NOAASeverity(area_desc: String, severity: String)
  // datetime: Time)
}

pub type SearchAreaDescription {
  SearchAreaDescription(area_desc: String)
}

pub fn read_noaa_severity(conn: pog.Connection) -> Result(NOAASeverity, String) {
  let decoder =
    dynamic.decode2(
      NOAASeverity,
      dynamic.element(0, dynamic.string),
      dynamic.element(1, dynamic.string),
    )

  let row =
    pog.query(
      "SELECT area_desc, severity, datetime FROM sea.severity "
      <> "WHERE severity != 'UnknownSeverity' ORDER BY datetime DESC LIMIT 1",
    )
    |> pog.returning(decoder)
    |> pog.execute(conn)

  case row {
    Ok(row) -> {
      let row_result = list.first(row.rows)
      case row_result {
        Ok(severity) -> {
          wisp.log_info(
            "Severity: " <> severity.severity <> "is successfully fetched",
          )
          Ok(severity)
        }
        Error(err) -> Error("Failed to fetch severity: " <> string.inspect(err))
      }
    }
    Error(error) -> Error("Failed to fetch severity: " <> string.inspect(error))
  }
}

pub fn search_area_description(
  area_desc: String,
  conn: pog.Connection,
) -> Result(List(NOAASeverity), String) {
  let decoder =
    dynamic.decode2(
      NOAASeverity,
      dynamic.element(0, dynamic.string),
      dynamic.element(1, dynamic.string),
    )

  let rows =
    pog.query(
      "SELECT area_desc, severity FROM sea.severity WHERE area_desc = $1",
    )
    |> pog.parameter(pog.text("%" <> area_desc <> "%"))
    |> pog.returning(decoder)
    |> pog.execute(conn)

  case rows {
    Ok(rows) -> {
      wisp.log_info(
        "Found severity: " <> string.inspect(list.length(rows.rows)),
      )
      list.map(rows.rows, fn(row) { NOAASeverity(row.area_desc, row.severity) })
      |> Ok
    }
    Error(error) -> {
      wisp.log_error("Failed to fetch severity: " <> string.inspect(error))
      Error("Failed to fetch severity: " <> string.inspect(error))
    }
  }
}
