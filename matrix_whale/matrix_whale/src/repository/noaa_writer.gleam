import birl
import gleam/dynamic
import gleam/int
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
) -> Result(Int, String) {
  wisp.log_info(
    "Writing " <> string.inspect(list.length(features)) <> " features",
  )

  let insert_alert = fn(feature: FeatureElement) -> Result(Int, String) {
    let area_desc = feature.properties.area_desc
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
        "INSERT INTO sea.severity (area_desc, severity, datetime) VALUES ($1, $2, $3)
        ON CONFLICT (area_desc, severity, datetime)
        DO UPDATE SET severity = EXCLUDED.severity, datetime = EXCLUDED.datetime;",
        conn,
        [
          pgo.text(string.inspect(area_desc)),
          pgo.text(string.inspect(severity)),
          pgo.timestamp(ts),
        ],
        dynamic.dynamic,
      )
    {
      Ok(result) -> {
        result.rows
        |> list.length
        |> Ok
      }
      Error(err) -> {
        wisp.log_error("Failed to insert severity: " <> string.inspect(err))
        Ok(0)
      }
    }
  }

  let insert_result =
    pgo.transaction(conn, fn(_) {
      features
      |> list.try_map(fn(feature) { insert_alert(feature) })
    })
    |> result.map_error(fn(err) {
      case err {
        pgo.TransactionRolledBack(reason) -> {
          wisp.log_error("Transaction rolled back: " <> string.inspect(reason))
          reason
        }
        pgo.TransactionQueryError(query_error) -> {
          wisp.log_error(
            "Transaction query error: " <> string.inspect(query_error),
          )
          string.inspect(query_error)
        }
      }
    })
    |> result.map_error(fn(err) {
      wisp.log_error("Error writing noaa alerts: " <> string.inspect(err))
      err
    })

  case insert_result {
    Ok(count_list) -> {
      let total_count = list.fold(count_list, 0, int.add)
      wisp.log_info(
        "Inserted or updated " <> string.inspect(total_count) <> " alerts",
      )
      Ok(total_count)
    }
    Error(err) -> {
      wisp.log_error("Error writing noaa alerts: " <> string.inspect(err))
      Error(err)
    }
  }
}
