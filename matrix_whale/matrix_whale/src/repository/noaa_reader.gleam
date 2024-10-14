// import birl.{type Time}
import gleam/dynamic
import gleam/list
import gleam/pgo
import gleam/string
import wisp

pub type NOAASeverity {
  NOAASeverity(area_desc: String, severity: String)
  // datetime: Time)
}

pub fn read_noaa_severity(conn: pgo.Connection) -> Result(NOAASeverity, String) {
  let decoder =
    dynamic.decode2(
      NOAASeverity,
      dynamic.element(0, dynamic.string),
      dynamic.element(1, dynamic.string),
    )

  let row =
    pgo.execute(
      "SELECT area_desc, severity, datetime FROM sea.severity WHERE datetime BETWEEN NOW() - INTERVAL '12 hours' AND NOW() AND severity != 'UnknownSeverity' ORDER BY datetime DESC LIMIT 1",
      conn,
      [],
      decoder,
    )

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
// fn decode_timestamp(
//   dyn: dynamic.Dynamic,
// ) -> Result(Time, List(dynamic.DecodeError)) {
//   // let decode_tuple3 = dynamic.tuple3(dynamic.int, dynamic.int, dynamic.int)

//   // use date <- dynamic.tuple2(decode_tuple3, decode_tuple3)

//   // let #(#(year, month, day), #(hour, minute, second)) = date
//   // case time.new(year, month, day, hour, minute, second, 0) {
//   //   Ok(datetime) -> Ok(datetime)
//   //   Error(_) -> Error([dynamic.DecodeError("Invalid datetime", "DateTime", [])])
//   // }

//   todo
// }

// fn decode_tuple3(dyn: dynamic.Dynamic) -> #(Int, Int, Int) {
//   let decoder = dynamic.tuple3(dynamic.int, dynamic.int, dynamic.int)

//   todo
// }
