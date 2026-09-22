import erlang_tools/raw_json
import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/time/calendar
import gleam/time/timestamp.{type Timestamp}

pub const columns = "a.source, a.source_id, s.name AS source_name, s.attribution_text AS attribution, a.sender, a.sender_name, a.identifier, a.message_type, a.event, a.category, a.severity, a.urgency, a.certainty, a.headline, a.description, a.instruction, a.web, a.contact, a.language, a.area_desc, a.geocodes::text, a.countries, "
  <> geom_expr
  <> ", a.reference_keys, a.sent, a.effective, a.onset, a.expires, a.ends, a.active_until, a.first_seen_at, a.last_seen_at, a.ended_at, a.end_reason, a.superseded_by"

/// Filters out tiny polygon parts (< 1e-5 deg²) before simplification to
/// avoid transferring thousands of invisible island slivers from JMA alerts.
const geom_expr = "(SELECT ST_AsGeoJSON(ST_Multi(ST_SimplifyPreserveTopology(ST_CollectionExtract(ST_Collect(d.geom), 3), 0.01)), 4) FROM (SELECT g.geom, row_number() OVER (ORDER BY ST_Area(g.geom) DESC) AS rn FROM ST_Dump(a.geom) g) d WHERE ST_Area(d.geom) >= 1e-5 OR d.rn = 1)"

pub const detail_columns = "a.source, a.source_id, s.name AS source_name, s.attribution_text AS attribution, a.sender, a.sender_name, a.identifier, a.message_type, a.event, a.category, a.severity, a.urgency, a.certainty, a.headline, a.description, a.instruction, a.web, a.contact, a.language, a.area_desc, a.geocodes::text, a.countries, ST_AsGeoJSON(a.geom, 6), a.reference_keys, a.sent, a.effective, a.onset, a.expires, a.ends, a.active_until, a.first_seen_at, a.last_seen_at, a.ended_at, a.end_reason, a.superseded_by"

pub type AlertRow {
  AlertRow(
    source: String,
    source_id: String,
    source_name: String,
    attribution: String,
    sender: Option(String),
    sender_name: Option(String),
    identifier: Option(String),
    message_type: Option(String),
    event: String,
    category: List(String),
    severity: String,
    urgency: String,
    certainty: String,
    headline: Option(String),
    description: Option(String),
    instruction: Option(String),
    web: Option(String),
    contact: Option(String),
    language: Option(String),
    area_desc: String,
    geocodes: String,
    countries: List(String),
    geom: Option(String),
    reference_keys: List(String),
    sent: Option(Timestamp),
    effective: Option(Timestamp),
    onset: Option(Timestamp),
    expires: Option(Timestamp),
    ends: Option(Timestamp),
    active_until: Timestamp,
    first_seen_at: Timestamp,
    last_seen_at: Timestamp,
    ended_at: Option(Timestamp),
    end_reason: Option(String),
    superseded_by: Option(String),
  )
}

pub type AlertWrite {
  AlertWrite(
    source: String,
    source_id: String,
    sender: Option(String),
    sender_name: Option(String),
    identifier: Option(String),
    message_type: Option(String),
    event: String,
    category: List(String),
    severity: String,
    urgency: String,
    certainty: String,
    headline: Option(String),
    description: Option(String),
    instruction: Option(String),
    web: Option(String),
    contact: Option(String),
    language: Option(String),
    area_desc: String,
    geocodes: String,
    countries: List(String),
    geom: Option(String),
    reference_keys: List(String),
    sent: Option(Timestamp),
    effective: Option(Timestamp),
    onset: Option(Timestamp),
    expires: Option(Timestamp),
    ends: Option(Timestamp),
    active_until: Timestamp,
    ended_at: Option(Timestamp),
    end_reason: Option(String),
    superseded_by: Option(String),
  )
}

pub type EndInstruction {
  EndInstruction(
    source: String,
    source_id: String,
    end_reason: String,
    superseded_by: Option(String),
  )
}

pub fn row_decoder() -> decode.Decoder(AlertRow) {
  use source <- decode.field(0, decode.string)
  use source_id <- decode.field(1, decode.string)
  use source_name <- decode.field(2, decode.string)
  use attribution <- decode.field(3, decode.string)
  use sender <- decode.field(4, decode.optional(decode.string))
  use sender_name <- decode.field(5, decode.optional(decode.string))
  use identifier <- decode.field(6, decode.optional(decode.string))
  use message_type <- decode.field(7, decode.optional(decode.string))
  use event <- decode.field(8, decode.string)
  use category <- decode.field(9, decode.list(decode.string))
  use severity <- decode.field(10, decode.string)
  use urgency <- decode.field(11, decode.string)
  use certainty <- decode.field(12, decode.string)
  use headline <- decode.field(13, decode.optional(decode.string))
  use description <- decode.field(14, decode.optional(decode.string))
  use instruction <- decode.field(15, decode.optional(decode.string))
  use web <- decode.field(16, decode.optional(decode.string))
  use contact <- decode.field(17, decode.optional(decode.string))
  use language <- decode.field(18, decode.optional(decode.string))
  use area_desc <- decode.field(19, decode.string)
  use geocodes <- decode.field(20, decode.string)
  use countries <- decode.field(21, decode.list(decode.string))
  use geom <- decode.field(22, decode.optional(decode.string))
  use reference_keys <- decode.field(23, decode.list(decode.string))
  use sent <- decode.field(24, decode.optional(timestamptz_decoder()))
  use effective <- decode.field(25, decode.optional(timestamptz_decoder()))
  use onset <- decode.field(26, decode.optional(timestamptz_decoder()))
  use expires <- decode.field(27, decode.optional(timestamptz_decoder()))
  use ends <- decode.field(28, decode.optional(timestamptz_decoder()))
  use active_until <- decode.field(29, timestamptz_decoder())
  use first_seen_at <- decode.field(30, timestamptz_decoder())
  use last_seen_at <- decode.field(31, timestamptz_decoder())
  use ended_at <- decode.field(32, decode.optional(timestamptz_decoder()))
  use end_reason <- decode.field(33, decode.optional(decode.string))
  use superseded_by <- decode.field(34, decode.optional(decode.string))
  decode.success(AlertRow(
    source:,
    source_id:,
    source_name:,
    attribution:,
    sender:,
    sender_name:,
    identifier:,
    message_type:,
    event:,
    category:,
    severity:,
    urgency:,
    certainty:,
    headline:,
    description:,
    instruction:,
    web:,
    contact:,
    language:,
    area_desc:,
    geocodes:,
    countries:,
    geom:,
    reference_keys:,
    sent:,
    effective:,
    onset:,
    expires:,
    ends:,
    active_until:,
    first_seen_at:,
    last_seen_at:,
    ended_at:,
    end_reason:,
    superseded_by:,
  ))
}

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

pub fn to_json(row: AlertRow) -> json.Json {
  json.object([
    #("id", json.string(row.source <> ":" <> row.source_id)),
    #("source", json.string(row.source)),
    #("source_id", json.string(row.source_id)),
    #("source_name", json.string(row.source_name)),
    #("attribution", json.string(row.attribution)),
    #("countries", json.array(row.countries, json.string)),
    #("sender", json.nullable(row.sender, json.string)),
    #("sender_name", json.nullable(row.sender_name, json.string)),
    #("message_type", json.nullable(row.message_type, json.string)),
    #("event", json.string(row.event)),
    #("category", json.array(row.category, json.string)),
    #("severity", json.string(row.severity)),
    #("urgency", json.string(row.urgency)),
    #("certainty", json.string(row.certainty)),
    #("headline", json.nullable(row.headline, json.string)),
    #("language", json.nullable(row.language, json.string)),
    #("web", json.nullable(row.web, json.string)),
    #("area_desc", json.string(row.area_desc)),
    #("geocodes", raw_json_or_empty_array(row.geocodes)),
    #("geometry", nullable_raw_json(row.geom)),
    #("sent", json.nullable(row.sent, timestamp_to_json)),
    #("effective", json.nullable(row.effective, timestamp_to_json)),
    #("onset", json.nullable(row.onset, timestamp_to_json)),
    #("expires", json.nullable(row.expires, timestamp_to_json)),
    #("ends", json.nullable(row.ends, timestamp_to_json)),
    #("active_until", timestamp_to_json(row.active_until)),
    #("first_seen_at", timestamp_to_json(row.first_seen_at)),
    #("last_seen_at", timestamp_to_json(row.last_seen_at)),
    #("ended_at", json.nullable(row.ended_at, timestamp_to_json)),
    #("end_reason", json.nullable(row.end_reason, json.string)),
    #("superseded_by", json.nullable(row.superseded_by, json.string)),
  ])
}

pub fn to_detail_alert_json(row: AlertRow) -> json.Json {
  json.object([
    #("id", json.string(row.source <> ":" <> row.source_id)),
    #("source", json.string(row.source)),
    #("source_id", json.string(row.source_id)),
    #("source_name", json.string(row.source_name)),
    #("attribution", json.string(row.attribution)),
    #("countries", json.array(row.countries, json.string)),
    #("sender", json.nullable(row.sender, json.string)),
    #("sender_name", json.nullable(row.sender_name, json.string)),
    #("message_type", json.nullable(row.message_type, json.string)),
    #("event", json.string(row.event)),
    #("category", json.array(row.category, json.string)),
    #("severity", json.string(row.severity)),
    #("urgency", json.string(row.urgency)),
    #("certainty", json.string(row.certainty)),
    #("headline", json.nullable(row.headline, json.string)),
    #("description", json.nullable(row.description, json.string)),
    #("instruction", json.nullable(row.instruction, json.string)),
    #("web", json.nullable(row.web, json.string)),
    #("contact", json.nullable(row.contact, json.string)),
    #("language", json.nullable(row.language, json.string)),
    #("area_desc", json.string(row.area_desc)),
    #("geocodes", raw_json_or_empty_array(row.geocodes)),
    #("geometry", nullable_raw_json(row.geom)),
    #("sent", json.nullable(row.sent, timestamp_to_json)),
    #("effective", json.nullable(row.effective, timestamp_to_json)),
    #("onset", json.nullable(row.onset, timestamp_to_json)),
    #("expires", json.nullable(row.expires, timestamp_to_json)),
    #("ends", json.nullable(row.ends, timestamp_to_json)),
    #("active_until", timestamp_to_json(row.active_until)),
    #("first_seen_at", timestamp_to_json(row.first_seen_at)),
    #("last_seen_at", timestamp_to_json(row.last_seen_at)),
    #("ended_at", json.nullable(row.ended_at, timestamp_to_json)),
    #("end_reason", json.nullable(row.end_reason, json.string)),
    #("superseded_by", json.nullable(row.superseded_by, json.string)),
  ])
}

pub fn to_detail_json(
  row: AlertRow,
  infos: json.Json,
  cap_url: Option(String),
  feed_url: Option(String),
) -> json.Json {
  json.object([
    #("alert", to_detail_alert_json(row)),
    #("infos", infos),
    #("cap_url", json.nullable(cap_url, json.string)),
    #("feed_url", json.nullable(feed_url, json.string)),
  ])
}

fn timestamp_to_json(value: Timestamp) -> json.Json {
  json.string(timestamp.to_rfc3339(value, calendar.utc_offset))
}

pub fn nullable_raw_json(text: Option(String)) -> json.Json {
  case text {
    Some(t) -> raw_json.json(t)
    None -> json.null()
  }
}

pub fn raw_json_or_empty_array(text: String) -> json.Json {
  case text {
    "" | "null" -> raw_json.json("[]")
    t -> raw_json.json(t)
  }
}

pub fn json_of_text(text: String) -> json.Json {
  raw_json.json(text)
}
