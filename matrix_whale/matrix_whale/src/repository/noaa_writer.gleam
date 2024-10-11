import birl
import gleam/int
import gleam/io
import gleam/iterator
import gleam/list
import gleam/option.{None, Some}
import gleam/pgo
import gleam/result
import gleam/string
import message/reviever/models/noaa.{type FeatureElement}
import string_tools/list_element_to_int.{list_element_to_int}
import wisp

pub fn write_noaa_alerts(
  features: List(FeatureElement),
  conn: pgo.Connection,
) -> Result(Nil, String) {
  let insert_alert = fn(feature: FeatureElement) -> Result(Nil, String) {
    let severity = feature.properties.severity

    let datetime = case feature.properties.sent {
      Some(sent) -> birl.parse(sent)
      None -> birl.parse(feature.properties.effective)
    }

    let datetime_parsed = case datetime {
      Ok(datetime) -> datetime
      Error(_) -> birl.now()
    }

    let timestamp_parsed_list =
      birl.to_iso8601(datetime_parsed)
      |> string.split("-")
      |> list.map(fn(s) { string.split(s, "T") })
      |> list.flatten
      |> list.map(fn(s) { string.split(s, ":") })
      |> list.flatten
      |> list.map(fn(s) { string.split(s, ".") })
      |> list.flatten


    // #(#(year, month, day), #(hour, minute, second))
    let year =
      list_element_to_int(timestamp_parsed_list, 0)
      |> result.unwrap(-1)
    let month =
      list_element_to_int(timestamp_parsed_list, 1) |> result.unwrap(-1)
    let day = list_element_to_int(timestamp_parsed_list, 2) |> result.unwrap(-1)
    let hour =
      list_element_to_int(timestamp_parsed_list, 3) |> result.unwrap(-1)
    let minute =
      list_element_to_int(timestamp_parsed_list, 4) |> result.unwrap(-1)
    let second =
      list_element_to_int(timestamp_parsed_list, 5) |> result.unwrap(-1)

    let ts = #(#(year, month, day), #(hour, minute, second))

    case
      pgo.execute(
        "INSERT INTO sea.severity (severity, datetime) VALUES ($1, $2) ON CONFLICT (severity, datetime) DO NOTHING;",
        conn,
        [pgo.text(string.inspect(severity)), pgo.timestamp(ts)],
        fn(_) { Ok(Nil) },
      )
    {
      Ok(_) -> Ok(Nil)
      Error(err) -> {
        let error_message = err
        wisp.log_error(
          "Failed to insert severity: " <> string.inspect(error_message),
        )
        Error(string.inspect(error_message))
      }
    }
  }

  pgo.transaction(conn, fn(_) {
    features
    |> list.try_map(fn(feature) { insert_alert(feature) })
  })
  |> result.map_error(fn(err) {
    case err {
      pgo.TransactionRolledBack(reason) -> reason
      // pgo.TransactionQueryError(pgo.PostgresqlError(
      //   "40000",
      //   "transaction_rollback",
      //   string.inspect(reason),
      // ))
      pgo.TransactionQueryError(query_error) -> string.inspect(query_error)
      // pgo.TransactionQueryError(pgo.PostgresqlError(
      //   "25P02",
      //   "in_failed_sql_transaction",
      //   string.inspect(query_error),
      // ))
    }
  })
  |> result.map(fn(_) { Nil })
}
