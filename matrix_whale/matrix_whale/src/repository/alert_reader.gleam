import domain/alert.{type AlertRow}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/order
import gleam/result
import gleam/string
import gleam/time/calendar
import gleam/time/duration
import gleam/time/timestamp.{type Timestamp}
import pog

pub type SeverityCounts {
  SeverityCounts(
    extreme: Int,
    severe: Int,
    moderate: Int,
    minor: Int,
    unknown: Int,
  )
}

pub type HistoryBucket {
  HistoryBucket(hour_start: Timestamp, counts: SeverityCounts)
}

pub fn list_active(conn: pog.Connection) -> Result(List(AlertRow), String) {
  pog.query("SELECT " <> alert.columns <> " FROM sea.alert
     WHERE ended_at IS NULL
       AND (COALESCE(ends, expires) IS NULL OR COALESCE(ends, expires) > now())
     ORDER BY sent DESC NULLS LAST")
  |> pog.returning(alert.row_decoder())
  |> pog.execute(conn)
  |> result.map(fn(returned) { returned.rows })
  |> result.map_error(query_error_to_string)
}

pub fn by_ids(
  ids: List(String),
  conn: pog.Connection,
) -> Result(List(AlertRow), String) {
  pog.query("SELECT " <> alert.columns <> " FROM sea.alert WHERE id = ANY($1)")
  |> pog.parameter(pog.array(pog.text, ids))
  |> pog.returning(alert.row_decoder())
  |> pog.execute(conn)
  |> result.map(fn(returned) { returned.rows })
  |> result.map_error(query_error_to_string)
}

pub fn search(
  query: String,
  conn: pog.Connection,
) -> Result(List(AlertRow), String) {
  case string.trim(query) {
    "" -> Ok([])
    trimmed ->
      pog.query("SELECT " <> alert.columns <> " FROM sea.alert
         WHERE area_desc ILIKE '%' || $1 || '%' OR event ILIKE '%' || $1 || '%'
         ORDER BY sent DESC NULLS LAST LIMIT 200")
      |> pog.parameter(pog.text(trimmed))
      |> pog.returning(alert.row_decoder())
      |> pog.execute(conn)
      |> result.map(fn(returned) { returned.rows })
      |> result.map_error(query_error_to_string)
  }
}

/// Returns exactly `hours` (clamped to 1..168) hourly buckets, oldest to
/// newest, ending at the current hour, filling in zero counts for hours
/// with no alerts.
pub fn history(
  hours: Int,
  conn: pog.Connection,
) -> Result(List(HistoryBucket), String) {
  let clamped = int.clamp(hours, 1, 168)

  use rows <- result.try(
    pog.query(
      "SELECT date_trunc('hour', first_seen_at) AS hour_start, severity, count(*)
       FROM sea.alert
       WHERE first_seen_at >= now() - ($1 || ' hours')::interval
       GROUP BY 1, 2",
    )
    |> pog.parameter(pog.text(int.to_string(clamped)))
    |> pog.returning(history_row_decoder())
    |> pog.execute(conn)
    |> result.map(fn(returned) { returned.rows })
    |> result.map_error(query_error_to_string),
  )

  Ok(fill_buckets(clamped, rows))
}

pub fn count_active_by_severity(
  conn: pog.Connection,
) -> Result(SeverityCounts, String) {
  pog.query(
    "SELECT severity, count(*) FROM sea.alert
     WHERE ended_at IS NULL
       AND (COALESCE(ends, expires) IS NULL OR COALESCE(ends, expires) > now())
     GROUP BY 1",
  )
  |> pog.returning(severity_count_decoder())
  |> pog.execute(conn)
  |> result.map(fn(returned) { fold_severity_counts(returned.rows) })
  |> result.map_error(query_error_to_string)
}

pub fn history_bucket_to_json(bucket: HistoryBucket) -> json.Json {
  json.object([
    #(
      "hour_start",
      json.string(timestamp.to_rfc3339(bucket.hour_start, calendar.utc_offset)),
    ),
    #("counts", severity_counts_to_json(bucket.counts)),
  ])
}

pub fn severity_counts_to_json(counts: SeverityCounts) -> json.Json {
  json.object([
    #("Extreme", json.int(counts.extreme)),
    #("Severe", json.int(counts.severe)),
    #("Moderate", json.int(counts.moderate)),
    #("Minor", json.int(counts.minor)),
    #("Unknown", json.int(counts.unknown)),
  ])
}

fn history_row_decoder() -> decode.Decoder(#(Timestamp, String, Int)) {
  use hour_start <- decode.field(0, alert.timestamptz_decoder())
  use severity <- decode.field(1, decode.string)
  use count <- decode.field(2, decode.int)
  decode.success(#(hour_start, severity, count))
}

fn severity_count_decoder() -> decode.Decoder(#(String, Int)) {
  use severity <- decode.field(0, decode.string)
  use count <- decode.field(1, decode.int)
  decode.success(#(severity, count))
}

fn fold_severity_counts(rows: List(#(String, Int))) -> SeverityCounts {
  list.fold(rows, empty_counts(), fn(acc, row) {
    let #(severity, count) = row
    add_count(acc, severity, count)
  })
}

fn empty_counts() -> SeverityCounts {
  SeverityCounts(extreme: 0, severe: 0, moderate: 0, minor: 0, unknown: 0)
}

fn add_count(
  acc: SeverityCounts,
  severity: String,
  count: Int,
) -> SeverityCounts {
  case severity {
    "Extreme" -> SeverityCounts(..acc, extreme: acc.extreme + count)
    "Severe" -> SeverityCounts(..acc, severe: acc.severe + count)
    "Moderate" -> SeverityCounts(..acc, moderate: acc.moderate + count)
    "Minor" -> SeverityCounts(..acc, minor: acc.minor + count)
    _ -> SeverityCounts(..acc, unknown: acc.unknown + count)
  }
}

fn fill_buckets(
  hours: Int,
  rows: List(#(Timestamp, String, Int)),
) -> List(HistoryBucket) {
  let now_hour = truncate_to_hour(timestamp.system_time())
  let start = timestamp.subtract(now_hour, duration.hours(hours - 1))

  list.repeat(Nil, hours)
  |> list.index_map(fn(_, offset) {
    let bucket_hour = timestamp.add(start, duration.hours(offset))
    HistoryBucket(
      hour_start: bucket_hour,
      counts: counts_for_hour(bucket_hour, rows),
    )
  })
}

fn counts_for_hour(
  hour: Timestamp,
  rows: List(#(Timestamp, String, Int)),
) -> SeverityCounts {
  rows
  |> list.filter(fn(row) { timestamp.compare(row.0, hour) == order.Eq })
  |> list.fold(empty_counts(), fn(acc, row) {
    let #(_, severity, count) = row
    add_count(acc, severity, count)
  })
}

fn truncate_to_hour(value: Timestamp) -> Timestamp {
  let #(date, time) = timestamp.to_calendar(value, calendar.utc_offset)
  timestamp.from_calendar(
    date: date,
    time: calendar.TimeOfDay(
      hours: time.hours,
      minutes: 0,
      seconds: 0,
      nanoseconds: 0,
    ),
    offset: calendar.utc_offset,
  )
}

fn query_error_to_string(error: pog.QueryError) -> String {
  "Database error: " <> string.inspect(error)
}
