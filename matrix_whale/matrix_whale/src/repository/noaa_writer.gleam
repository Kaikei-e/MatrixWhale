import birl.{type Time}
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import message/reciever/models/noaa.{type FeatureElement}
import pog
import wisp

type ParsedDatetime {
  ParsedDatetime(datetime: Time, timezone_offset: String)
}

pub fn write_noaa_alerts(
  features: List(FeatureElement),
  conn: pog.Connection,
) -> Result(Int, String) {
  wisp.log_info(
    "Writing " <> string.inspect(list.length(features)) <> " features",
  )

  let insert_alert = fn(feature: FeatureElement) -> Result(Int, String) {
    let area_desc = feature.properties.area_desc
    let severity = feature.properties.severity
    let sent_datetime = feature.properties.sent

    // 1905-12-22T16:38:23.000+03:30 -> 1905-12-22T16:38:23.000+03:30 parse func example
    // "2024-12-03T07:37:00-09:00" actual format

    let datetime = case sent_datetime {
      Some(sent) -> parse_formatted_datetime(sent)
      None -> parse_formatted_datetime(feature.properties.effective)
    }

    let datetime_parsed = case datetime {
      Ok(datetime) -> {
        // 09:00 -> 9 is hours
        let offset_seconds =
          datetime.timezone_offset
          |> int.parse
          |> result.map(fn(offset) { offset * 60 * 60 })
          |> result.unwrap(0)

        let unixtime_with_offset =
          birl.to_unix(datetime.datetime) + offset_seconds

        let datetime_utc = birl.from_unix(unixtime_with_offset)

        let _time_of_day = datetime_utc |> birl.get_time_of_day
        let _day = datetime_utc |> birl.get_day

        let ts = datetime_utc |> birl.to_iso8601
        ts
      }
      Error(_) -> {
        let now = birl.utc_now()
        let _time_of_day = now |> birl.get_time_of_day
        let _day = now |> birl.get_day

        now |> birl.to_iso8601
      }
    }

    let query =
      "INSERT INTO sea.severity (area_desc, severity, datetime) VALUES ($1, $2, $3)
        ON CONFLICT (area_desc, severity, datetime)
        DO UPDATE SET
          area_desc = EXCLUDED.area_desc,
          severity = EXCLUDED.severity,
          datetime = EXCLUDED.datetime;"

    let row_decoder = decode.success(Nil)

    let assert Ok(response) =
      pog.query(query)
      |> pog.parameter(pog.text(area_desc))
      |> pog.parameter(pog.text(string.inspect(severity)))
      |> pog.parameter(pog.text(datetime_parsed))
      |> pog.returning(row_decoder)
      |> pog.execute(conn)

    Ok(list.length(response.rows))
  }

  let insert_result =
    features
    |> list.try_map(fn(feature) { insert_alert(feature) })

  case insert_result {
    Ok(count_list) -> {
      let total_count =
        count_list
        |> list.filter(fn(count) { count > 0 })
        |> list.length

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

fn parse_formatted_datetime(
  sent_datetime: String,
) -> Result(ParsedDatetime, Nil) {
  // Example input: "2024-12-03T07:37:00-09:00"
  let timezone_offset = extract_timezone_offset(sent_datetime)

  let datetime_result =
    sent_datetime
    |> string.replace("-", "+")
    |> string.split("+")
    |> fn(parts) {
      case parts {
        [datetime, timezone] -> {
          datetime <> "+" <> timezone
        }
        _ -> sent_datetime
      }
    }
    |> birl.parse
    |> result.map(fn(datetime) { ParsedDatetime(datetime, timezone_offset) })

  datetime_result
}

fn extract_timezone_offset(sent_datetime: String) -> String {
  // Example input: "2024-12-03T07:37:00-09:00"
  case string.split(sent_datetime, "-") {
    [_, _, timezone] -> {
      case string.split(timezone, ":") {
        [hours, _] -> "-" <> hours
        _ -> "00"
      }
    }
    _ -> {
      case string.split(sent_datetime, "+") {
        [_, timezone] -> {
          case string.split(timezone, ":") {
            [hours, _] -> "+" <> hours
            _ -> "00"
          }
        }
        _ -> "00"
      }
    }
  }
}
