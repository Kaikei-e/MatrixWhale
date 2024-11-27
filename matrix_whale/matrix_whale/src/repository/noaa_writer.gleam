import birl.{type Time}
import gleam/dynamic
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import message/reciever/models/noaa.{type FeatureElement}
import pog
import wisp

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
    // 2024-11-07T11:05:21+00:00 actual format

    let datetime = case sent_datetime {
      Some(sent) -> parse_formatted_datetime(sent)
      None -> parse_formatted_datetime(feature.properties.effective)
    }

    let datetime_parsed = case datetime {
      Ok(datetime) -> {
        datetime
      }
      Error(_) -> {
        birl.now()
      }
    }

    let day = datetime_parsed |> birl.get_day
    let month = datetime_parsed |> birl.month
    let time_of_day = datetime_parsed |> birl.get_time_of_day

    let year = day.year
    let month_num = case month {
      birl.Jan -> 1
      birl.Feb -> 2
      birl.Mar -> 3
      birl.Apr -> 4
      birl.May -> 5
      birl.Jun -> 6
      birl.Jul -> 7
      birl.Aug -> 8
      birl.Sep -> 9
      birl.Oct -> 10
      birl.Nov -> 11
      birl.Dec -> 12
    }
    let day_num = day.date
    let hour = time_of_day.hour
    let minute = time_of_day.minute
    let second = time_of_day.second

    let ts_date = pog.Date(year, month_num, day_num)
    let ts_time = pog.Time(hour, minute, second, 0)
    let ts = pog.Timestamp(ts_date, ts_time)

    let query =
      "INSERT INTO sea.severity (area_desc, severity, datetime) VALUES ($1, $2, $3)
        ON CONFLICT (area_desc, severity, datetime)
        DO UPDATE SET
          area_desc = EXCLUDED.area_desc,
          severity = EXCLUDED.severity,
          datetime = EXCLUDED.datetime;"

    let row_decoder =
      dynamic.tuple3(dynamic.string, dynamic.string, dynamic.string)

    let assert Ok(response) =
      pog.query(query)
      |> pog.parameter(pog.text(area_desc))
      |> pog.parameter(pog.text(string.inspect(severity)))
      |> pog.parameter(pog.timestamp(ts))
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

fn parse_formatted_datetime(sent_datetime: String) -> Result(Time, Nil) {
  sent_datetime
  |> string.split("+")
  |> string.join(".000+00:00")
  |> birl.parse
}
