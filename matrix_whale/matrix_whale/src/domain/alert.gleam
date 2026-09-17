import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/json
import gleam/option.{type Option}
import gleam/time/calendar
import gleam/time/timestamp.{type Timestamp}
import message/reciever/models/noaa.{type Geometry}

/// Column list, in the exact order `row_decoder` expects, shared by every
/// query that selects or returns alert rows.
pub const columns = "id, event, severity, urgency, certainty, message_type, headline, area_desc, ugc, same, geometry, sent, effective, expires, ends, first_seen_at, last_seen_at, ended_at"

/// A row of `sea.alert`. This is the single shared representation used by
/// the writer (upserts), the reader (queries) and the SSE streamer, so the
/// JSON shape sent to clients and the columns read from Postgres never
/// drift apart.
pub type AlertRow {
  AlertRow(
    id: String,
    event: String,
    severity: String,
    urgency: String,
    certainty: String,
    message_type: Option(String),
    headline: Option(String),
    area_desc: String,
    ugc: List(String),
    same: List(String),
    geometry: Option(Geometry),
    sent: Option(Timestamp),
    effective: Option(Timestamp),
    expires: Option(Timestamp),
    ends: Option(Timestamp),
    first_seen_at: Timestamp,
    last_seen_at: Timestamp,
    ended_at: Option(Timestamp),
  )
}

/// Decodes one row returned by a query that selects the alert columns in
/// exactly this order:
/// `id, event, severity, urgency, certainty, message_type, headline,
/// area_desc, ugc, same, geometry, sent, effective, expires, ends,
/// first_seen_at, last_seen_at, ended_at`.
pub fn row_decoder() -> decode.Decoder(AlertRow) {
  use id <- decode.field(0, decode.string)
  use event <- decode.field(1, decode.string)
  use severity <- decode.field(2, decode.string)
  use urgency <- decode.field(3, decode.string)
  use certainty <- decode.field(4, decode.string)
  use message_type <- decode.field(5, decode.optional(decode.string))
  use headline <- decode.field(6, decode.optional(decode.string))
  use area_desc <- decode.field(7, decode.string)
  use ugc <- decode.field(8, decode.list(decode.string))
  use same <- decode.field(9, decode.list(decode.string))
  use geometry <- decode.field(10, decode_geometry_column())
  use sent <- decode.field(11, decode.optional(timestamptz_decoder()))
  use effective <- decode.field(12, decode.optional(timestamptz_decoder()))
  use expires <- decode.field(13, decode.optional(timestamptz_decoder()))
  use ends <- decode.field(14, decode.optional(timestamptz_decoder()))
  use first_seen_at <- decode.field(15, timestamptz_decoder())
  use last_seen_at <- decode.field(16, timestamptz_decoder())
  use ended_at <- decode.field(17, decode.optional(timestamptz_decoder()))
  decode.success(AlertRow(
    id:,
    event:,
    severity:,
    urgency:,
    certainty:,
    message_type:,
    headline:,
    area_desc:,
    ugc:,
    same:,
    geometry:,
    sent:,
    effective:,
    expires:,
    ends:,
    first_seen_at:,
    last_seen_at:,
    ended_at:,
  ))
}

/// `timestamptz` columns arrive as `{{Y,M,D},{H,Mi,S}}` in UTC: pg_types only
/// applies pog's microsecond `timestamp_config` to `timestamp`, not `timestamptz`.
pub fn timestamptz_decoder() -> decode.Decoder(Timestamp) {
  use #(year, month, day) <- decode.field(0, {
    use year <- decode.field(0, decode.int)
    use month <- decode.field(1, decode.int)
    use day <- decode.field(2, decode.int)
    decode.success(#(year, month, day))
  })
  use #(hours, minutes, seconds) <- decode.field(1, {
    use hours <- decode.field(0, decode.int)
    use minutes <- decode.field(1, decode.int)
    use seconds <- decode.field(
      2,
      decode.one_of(decode.float, or: [decode.int |> decode.map(int.to_float)]),
    )
    decode.success(#(hours, minutes, seconds))
  })
  case calendar.month_from_int(month) {
    Ok(month) -> {
      let whole_seconds = float.truncate(seconds)
      let nanoseconds =
        float.round(
          { seconds -. int.to_float(whole_seconds) } *. 1_000_000_000.0,
        )
      decode.success(timestamp.from_calendar(
        date: calendar.Date(year:, month:, day:),
        time: calendar.TimeOfDay(
          hours:,
          minutes:,
          seconds: whole_seconds,
          nanoseconds:,
        ),
        offset: calendar.utc_offset,
      ))
    }
    Error(_) -> decode.failure(timestamp.from_unix_seconds(0), "Timestamp")
  }
}

/// `jsonb` columns come back from the driver as the raw JSON text.
fn decode_geometry_column() -> decode.Decoder(Option(Geometry)) {
  decode.optional(decode.string)
  |> decode.map(fn(maybe_text) {
    case maybe_text {
      option.None -> option.None
      option.Some(text) ->
        case json.parse(text, noaa.decode_geometry()) {
          Ok(geometry) -> option.Some(geometry)
          Error(_) -> option.None
        }
    }
  })
}

pub fn to_json(row: AlertRow) -> json.Json {
  json.object([
    #("id", json.string(row.id)),
    #("event", json.string(row.event)),
    #("severity", json.string(row.severity)),
    #("urgency", json.string(row.urgency)),
    #("certainty", json.string(row.certainty)),
    #("message_type", json.nullable(row.message_type, json.string)),
    #("headline", json.nullable(row.headline, json.string)),
    #("area_desc", json.string(row.area_desc)),
    #("ugc", json.array(row.ugc, json.string)),
    #("same", json.array(row.same, json.string)),
    #("geometry", json.nullable(row.geometry, noaa.geometry_to_json)),
    #("sent", json.nullable(row.sent, timestamp_to_json)),
    #("effective", json.nullable(row.effective, timestamp_to_json)),
    #("expires", json.nullable(row.expires, timestamp_to_json)),
    #("ends", json.nullable(row.ends, timestamp_to_json)),
    #("first_seen_at", timestamp_to_json(row.first_seen_at)),
    #("last_seen_at", timestamp_to_json(row.last_seen_at)),
    #("ended_at", json.nullable(row.ended_at, timestamp_to_json)),
  ])
}

fn timestamp_to_json(value: Timestamp) -> json.Json {
  json.string(timestamp.to_rfc3339(value, calendar.utc_offset))
}
