import domain/alert.{type AlertRow}
import domain/earthquake.{type MagnitudeFilter}
import domain/event.{type EventView}
import domain/hazard.{type Hazard}
import gleam/bit_array
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/string
import gleam/time/calendar
import gleam/time/timestamp.{type Timestamp}

pub type Kind {
  Earthquake
  Hazard
  Alert
}

pub fn kind_to_string(kind: Kind) -> String {
  case kind {
    Earthquake -> "earthquake"
    Hazard -> "hazard"
    Alert -> "alert"
  }
}

pub fn parse_kind(value: String) -> Result(Kind, Nil) {
  case value {
    "earthquake" -> Ok(Earthquake)
    "hazard" -> Ok(Hazard)
    "alert" -> Ok(Alert)
    _ -> Error(Nil)
  }
}

pub type Severity {
  Unknown
  Minor
  Moderate
  Severe
  Extreme
}

pub fn rank(severity: Severity) -> Int {
  case severity {
    Unknown -> 0
    Minor -> 1
    Moderate -> 2
    Severe -> 3
    Extreme -> 4
  }
}

pub fn to_string(severity: Severity) -> String {
  case severity {
    Unknown -> "unknown"
    Minor -> "minor"
    Moderate -> "moderate"
    Severe -> "severe"
    Extreme -> "extreme"
  }
}

pub fn parse(value: String) -> Result(Severity, Nil) {
  case value {
    "unknown" -> Ok(Unknown)
    "minor" -> Ok(Minor)
    "moderate" -> Ok(Moderate)
    "severe" -> Ok(Severe)
    "extreme" -> Ok(Extreme)
    _ -> Error(Nil)
  }
}

pub fn severity_for_earthquake(magnitude: Option(Float)) -> Severity {
  case magnitude {
    option.None -> Unknown
    option.Some(m) if m <. 4.5 -> Minor
    option.Some(m) if m <. 6.0 -> Moderate
    option.Some(m) if m <. 7.0 -> Severe
    option.Some(_) -> Extreme
  }
}

pub fn severity_for_hazard(cap_severity: String) -> Severity {
  case cap_severity {
    "minor" -> Minor
    "severe" -> Severe
    "extreme" -> Extreme
    _ -> Unknown
  }
}

pub fn severity_for_alert(severity: String) -> Severity {
  case string.lowercase(severity) {
    "extreme" -> Extreme
    "severe" -> Severe
    "moderate" -> Moderate
    "minor" -> Minor
    _ -> Unknown
  }
}

/// `min_severity` translated into the earthquake filter the reader applies:
/// `minor+` requires a non-null magnitude, `moderate+`/`severe+`/`extreme+`
/// additionally require a numeric floor.
pub type EarthquakeFloor {
  EarthquakeFloor(require_magnitude: Bool, minimum: Option(Float))
}

pub fn earthquake_floor_for(min_severity: Option(Severity)) -> EarthquakeFloor {
  case min_severity {
    option.None ->
      EarthquakeFloor(require_magnitude: False, minimum: option.None)
    option.Some(Minor) ->
      EarthquakeFloor(require_magnitude: True, minimum: option.None)
    option.Some(Moderate) ->
      EarthquakeFloor(require_magnitude: True, minimum: option.Some(4.5))
    option.Some(Severe) ->
      EarthquakeFloor(require_magnitude: True, minimum: option.Some(6.0))
    option.Some(Extreme) ->
      EarthquakeFloor(require_magnitude: True, minimum: option.Some(7.0))
    option.Some(Unknown) ->
      EarthquakeFloor(require_magnitude: False, minimum: option.None)
  }
}

/// `min_severity` translated into the list of `sea.hazard.cap_severity`
/// values with rank at or above it. `None` means no filter.
pub fn hazard_cap_severities_for(
  min_severity: Option(Severity),
) -> Option(List(String)) {
  case min_severity {
    option.None -> option.None
    option.Some(min) ->
      option.Some(
        [Minor, Severe, Extreme]
        |> list.filter(fn(s) { rank(s) >= rank(min) })
        |> list.map(to_string),
      )
  }
}

/// `min_severity` translated into the list of NOAA `sea.alert.severity`
/// spellings with rank at or above it. `None` means no filter.
pub fn alert_severities_for(
  min_severity: Option(Severity),
) -> Option(List(String)) {
  case min_severity {
    option.None -> option.None
    option.Some(min) ->
      option.Some(
        [Minor, Moderate, Severe, Extreme]
        |> list.filter(fn(s) { rank(s) >= rank(min) })
        |> list.map(to_noaa_string),
      )
  }
}

fn to_noaa_string(severity: Severity) -> String {
  case severity {
    Unknown -> "Unknown"
    Minor -> "Minor"
    Moderate -> "Moderate"
    Severe -> "Severe"
    Extreme -> "Extreme"
  }
}

pub type Key {
  EarthquakeKey(id: Int)
  HazardKey(source: String, source_id: String)
  AlertKey(source: String, source_id: String)
}

pub fn earthquake_key(id: Int) -> String {
  "earthquake:" <> int.to_string(id)
}

pub fn hazard_key(source: String, source_id: String) -> String {
  "hazard:" <> source <> ":" <> source_id
}

pub fn alert_key(source: String, source_id: String) -> String {
  "alert:" <> source <> ":" <> source_id
}

/// Splits on the first `:` for the kind, then applies the per-kind colon
/// rule: an alert key splits on its first `:` after `alert:` into
/// `source`/`source_id`, a hazard key splits its remainder on its own first `:` into
/// `source`/`source_id`, and an earthquake key's remainder is its integer id.
pub fn parse_key(value: String) -> Result(Key, String) {
  case string.split_once(value, ":") {
    Ok(#("earthquake", rest)) ->
      case int.parse(rest) {
        Ok(id) -> Ok(EarthquakeKey(id))
        Error(_) -> Error("invalid earthquake key: " <> value)
      }
    Ok(#("hazard", rest)) ->
      case string.split_once(rest, ":") {
        Ok(#(source, source_id)) -> Ok(HazardKey(source, source_id))
        Error(_) -> Error("invalid hazard key: " <> value)
      }
    Ok(#("alert", rest)) ->
      case string.split_once(rest, ":") {
        Ok(#(source, source_id)) -> Ok(AlertKey(source, source_id))
        Error(_) -> Error("invalid alert key: " <> value)
      }
    _ -> Error("invalid key: " <> value)
  }
}

/// A keyset cursor: `first_seen_at` kept as the exact text Postgres printed
/// (`first_seen_at::text`), so it round-trips through `::timestamptz` at
/// full microsecond precision instead of through a decoded `Timestamp`.
pub type Cursor {
  Cursor(first_seen_at_text: String, kind: Kind, key: String)
}

pub fn encode_cursor(cursor: Cursor) -> String {
  {
    cursor.first_seen_at_text
    <> "\n"
    <> kind_to_string(cursor.kind)
    <> "\n"
    <> cursor.key
  }
  |> bit_array.from_string
  |> bit_array.base64_url_encode(False)
}

pub fn decode_cursor(value: String) -> Result(Cursor, Nil) {
  use bytes <- result.try(bit_array.base64_url_decode(value))
  use text <- result.try(bit_array.to_string(bytes))
  case string.split(text, "\n") {
    [first_seen_at_text, kind_text, key] ->
      parse_kind(kind_text)
      |> result.map(fn(kind) { Cursor(first_seen_at_text:, kind:, key:) })
    _ -> Error(Nil)
  }
}

pub type Query {
  Query(
    limit: Int,
    before: Option(Cursor),
    kinds: List(Kind),
    minmag: MagnitudeFilter,
    min_severity: Option(Severity),
  )
}

pub fn parse_query(params: List(#(String, String))) -> Result(Query, String) {
  use limit <- result.try(parse_limit(param(params, "limit")))
  use before <- result.try(parse_before(param(params, "before")))
  use kinds <- result.try(parse_kinds(param(params, "kinds")))
  use minmag <- result.try(
    earthquake.parse_minmag(option.unwrap(param(params, "minmag"), "")),
  )
  use min_severity <- result.try(
    parse_min_severity(param(params, "min_severity")),
  )
  Ok(Query(limit:, before:, kinds:, minmag:, min_severity:))
}

fn param(params: List(#(String, String)), name: String) -> Option(String) {
  list.key_find(params, name) |> option.from_result
}

fn parse_limit(value: Option(String)) -> Result(Int, String) {
  case value {
    option.None -> Ok(50)
    option.Some(raw) ->
      case int.parse(raw) {
        Ok(n) if n >= 1 && n <= 200 -> Ok(n)
        _ -> Error("limit must be 1..200")
      }
  }
}

fn parse_before(value: Option(String)) -> Result(Option(Cursor), String) {
  case value {
    option.None -> Ok(option.None)
    option.Some(raw) ->
      case decode_cursor(raw) {
        Ok(cursor) -> Ok(option.Some(cursor))
        Error(Nil) -> Error("before is malformed")
      }
  }
}

fn parse_kinds(value: Option(String)) -> Result(List(Kind), String) {
  case value {
    option.None -> Ok([Earthquake, Hazard, Alert])
    option.Some(raw) ->
      case string.trim(raw) {
        "" -> Error("kinds must not be empty")
        trimmed ->
          trimmed
          |> string.split(",")
          |> list.map(string.trim)
          |> list.try_map(fn(token) {
            parse_kind(token)
            |> result.replace_error(
              "kinds must be a comma list of earthquake,hazard,alert",
            )
          })
      }
  }
}

fn parse_min_severity(
  value: Option(String),
) -> Result(Option(Severity), String) {
  case value {
    option.None -> Ok(option.None)
    option.Some(raw) ->
      case parse(raw) {
        Ok(Unknown) | Error(Nil) ->
          Error("min_severity must be minor, moderate, severe, or extreme")
        Ok(severity) -> Ok(option.Some(severity))
      }
  }
}

pub type Payload {
  EarthquakePayload(EventView)
  HazardPayload(Hazard)
  AlertPayload(AlertRow)
}

pub type TimelineItem {
  TimelineItem(
    kind: Kind,
    key: String,
    seen_at: Timestamp,
    severity: Severity,
    ended: Bool,
    payload: Payload,
  )
}

pub fn from_earthquake(view: EventView) -> TimelineItem {
  TimelineItem(
    kind: Earthquake,
    key: earthquake_key(view.event.id),
    seen_at: view.event.first_seen_at,
    severity: severity_for_earthquake(view.event.magnitude),
    ended: False,
    payload: EarthquakePayload(view),
  )
}

pub fn from_hazard(row: Hazard) -> TimelineItem {
  TimelineItem(
    kind: Hazard,
    key: hazard_key(row.source, row.source_id),
    seen_at: row.first_seen_at,
    severity: severity_for_hazard(row.cap_severity),
    ended: !row.is_current,
    payload: HazardPayload(row),
  )
}

pub fn from_alert(row: AlertRow) -> TimelineItem {
  TimelineItem(
    kind: Alert,
    key: alert_key(row.source, row.source_id),
    seen_at: row.first_seen_at,
    severity: severity_for_alert(row.severity),
    ended: option.is_some(row.ended_at),
    payload: AlertPayload(row),
  )
}

pub fn to_json(item: TimelineItem) -> json.Json {
  json.object(list.append(
    [
      #("kind", json.string(kind_to_string(item.kind))),
      #("key", json.string(item.key)),
      #("seen_at", time_json(item.seen_at)),
      #("seen_at_ms", json.int(to_unix_ms(item.seen_at))),
      #("severity", json.string(to_string(item.severity))),
      #("ended", json.bool(item.ended)),
    ],
    payload_field(item.payload),
  ))
}

fn payload_field(payload: Payload) -> List(#(String, json.Json)) {
  case payload {
    EarthquakePayload(view) -> [#("earthquake", event.to_json(view))]
    HazardPayload(row) -> [#("hazard", hazard.to_json(row))]
    AlertPayload(row) -> [#("alert", alert.to_json(row))]
  }
}

fn to_unix_ms(value: Timestamp) -> Int {
  let #(seconds, nanoseconds) = timestamp.to_unix_seconds_and_nanoseconds(value)
  seconds * 1000 + nanoseconds / 1_000_000
}

fn time_json(value: Timestamp) -> json.Json {
  json.string(timestamp.to_rfc3339(value, calendar.utc_offset))
}
