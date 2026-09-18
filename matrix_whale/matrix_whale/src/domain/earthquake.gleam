import domain/source
import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/json
import gleam/option.{type Option}
import gleam/time/calendar
import gleam/time/timestamp.{type Timestamp}

pub const columns = "source, source_id, contributing_ids, sources, net, code, magnitude, magnitude_type, occurred_at, occurred_at_ms, updated_at, updated_at_ms, place, title, status, event_type, tsunami, significance, alert, mmi, cdi, felt, nst, dmin, rms, gap, url, detail, longitude, latitude, depth_km, first_seen_at, last_seen_at"

pub type MagnitudeFilter {
  Minimum(Float)
  AllMagnitudes
}

/// Shared by `/api/v1/earthquakes/recent` and `/api/v1/timeline`.
pub fn parse_minmag(value: String) -> Result(MagnitudeFilter, String) {
  case value {
    "" -> Ok(Minimum(2.5))
    "all" -> Ok(AllMagnitudes)
    value ->
      case float.parse(value) {
        Ok(value) -> Ok(Minimum(value))
        Error(_) -> Error("minmag must be a number or all")
      }
  }
}

pub type Earthquake {
  Earthquake(
    source: String,
    source_id: String,
    contributing_ids: List(String),
    sources: List(String),
    net: Option(String),
    code: Option(String),
    magnitude: Option(Float),
    magnitude_type: Option(String),
    occurred_at: Timestamp,
    occurred_at_ms: Int,
    updated_at: Timestamp,
    updated_at_ms: Int,
    place: Option(String),
    title: Option(String),
    status: Option(String),
    event_type: Option(String),
    tsunami: Option(Int),
    significance: Option(Int),
    alert: Option(String),
    mmi: Option(Float),
    cdi: Option(Float),
    felt: Option(Int),
    nst: Option(Int),
    dmin: Option(Float),
    rms: Option(Float),
    gap: Option(Float),
    url: Option(String),
    detail: Option(String),
    longitude: Float,
    latitude: Float,
    depth_km: Option(Float),
    first_seen_at: Timestamp,
    last_seen_at: Timestamp,
  )
}

pub fn row_decoder() -> decode.Decoder(Earthquake) {
  use source <- decode.field(0, decode.string)
  use source_id <- decode.field(1, decode.string)
  use contributing_ids <- decode.field(2, decode.list(decode.string))
  use sources <- decode.field(3, decode.list(decode.string))
  use net <- decode.field(4, decode.optional(decode.string))
  use code <- decode.field(5, decode.optional(decode.string))
  use magnitude <- decode.field(6, decode.optional(decode.float))
  use magnitude_type <- decode.field(7, decode.optional(decode.string))
  use occurred_at <- decode.field(8, timestamptz_decoder())
  use occurred_at_ms <- decode.field(9, decode.int)
  use updated_at <- decode.field(10, timestamptz_decoder())
  use updated_at_ms <- decode.field(11, decode.int)
  use place <- decode.field(12, decode.optional(decode.string))
  use title <- decode.field(13, decode.optional(decode.string))
  use status <- decode.field(14, decode.optional(decode.string))
  use event_type <- decode.field(15, decode.optional(decode.string))
  use tsunami <- decode.field(16, decode.optional(decode.int))
  use significance <- decode.field(17, decode.optional(decode.int))
  use alert <- decode.field(18, decode.optional(decode.string))
  use mmi <- decode.field(19, decode.optional(decode.float))
  use cdi <- decode.field(20, decode.optional(decode.float))
  use felt <- decode.field(21, decode.optional(decode.int))
  use nst <- decode.field(22, decode.optional(decode.int))
  use dmin <- decode.field(23, decode.optional(decode.float))
  use rms <- decode.field(24, decode.optional(decode.float))
  use gap <- decode.field(25, decode.optional(decode.float))
  use url <- decode.field(26, decode.optional(decode.string))
  use detail <- decode.field(27, decode.optional(decode.string))
  use longitude <- decode.field(28, decode.float)
  use latitude <- decode.field(29, decode.float)
  use depth_km <- decode.field(30, decode.optional(decode.float))
  use first_seen_at <- decode.field(31, timestamptz_decoder())
  use last_seen_at <- decode.field(32, timestamptz_decoder())
  decode.success(Earthquake(
    source:,
    source_id:,
    contributing_ids:,
    sources:,
    net:,
    code:,
    magnitude:,
    magnitude_type:,
    occurred_at:,
    occurred_at_ms:,
    updated_at:,
    updated_at_ms:,
    place:,
    title:,
    status:,
    event_type:,
    tsunami:,
    significance:,
    alert:,
    mmi:,
    cdi:,
    felt:,
    nst:,
    dmin:,
    rms:,
    gap:,
    url:,
    detail:,
    longitude:,
    latitude:,
    depth_km:,
    first_seen_at:,
    last_seen_at:,
  ))
}

pub fn to_json(x: Earthquake) -> json.Json {
  let assert Ok(registered) = source.lookup(x.source)
  json.object([
    #("source", json.string(x.source)),
    #("source_id", json.string(x.source_id)),
    #("contributing_ids", json.array(x.contributing_ids, json.string)),
    #("sources", json.array(x.sources, json.string)),
    #("magnitude", json.nullable(x.magnitude, json.float)),
    #("magnitude_type", json.nullable(x.magnitude_type, json.string)),
    #("occurred_at", time_json(x.occurred_at)),
    #("occurred_at_ms", json.int(x.occurred_at_ms)),
    #("updated_at", time_json(x.updated_at)),
    #("updated_at_ms", json.int(x.updated_at_ms)),
    #("place", json.nullable(x.place, json.string)),
    #("title", json.nullable(x.title, json.string)),
    #("status", json.nullable(x.status, json.string)),
    #("event_type", json.nullable(x.event_type, json.string)),
    #("tsunami", json.nullable(x.tsunami, json.int)),
    #("significance", json.nullable(x.significance, json.int)),
    #("alert", json.nullable(x.alert, json.string)),
    #("mmi", json.nullable(x.mmi, json.float)),
    #("cdi", json.nullable(x.cdi, json.float)),
    #("felt", json.nullable(x.felt, json.int)),
    #("nst", json.nullable(x.nst, json.int)),
    #("dmin", json.nullable(x.dmin, json.float)),
    #("rms", json.nullable(x.rms, json.float)),
    #("gap", json.nullable(x.gap, json.float)),
    #("url", json.nullable(x.url, json.string)),
    #("detail", json.nullable(x.detail, json.string)),
    #("longitude", json.float(x.longitude)),
    #("latitude", json.float(x.latitude)),
    #("depth_km", json.nullable(x.depth_km, json.float)),
    #("license", json.string(registered.license)),
    #("attribution", json.string(registered.attribution_text)),
    #("redistributable", json.bool(registered.redistributable)),
    #("first_seen_at", time_json(x.first_seen_at)),
    #("last_seen_at", time_json(x.last_seen_at)),
  ])
}

fn time_json(x: Timestamp) -> json.Json {
  json.string(timestamp.to_rfc3339(x, calendar.utc_offset))
}

pub fn timestamptz_decoder() -> decode.Decoder(Timestamp) {
  use #(y, m, d) <- decode.field(0, {
    use y <- decode.field(0, decode.int)
    use m <- decode.field(1, decode.int)
    use d <- decode.field(2, decode.int)
    decode.success(#(y, m, d))
  })
  use #(h, mi, s) <- decode.field(1, {
    use h <- decode.field(0, decode.int)
    use mi <- decode.field(1, decode.int)
    use s <- decode.field(
      2,
      decode.one_of(decode.float, or: [decode.int |> decode.map(int.to_float)]),
    )
    decode.success(#(h, mi, s))
  })
  case calendar.month_from_int(m) {
    Ok(month) -> {
      let whole = float.truncate(s)
      decode.success(timestamp.from_calendar(
        date: calendar.Date(y, month, d),
        time: calendar.TimeOfDay(
          h,
          mi,
          whole,
          float.round({ s -. int.to_float(whole) } *. 1_000_000_000.0),
        ),
        offset: calendar.utc_offset,
      ))
    }
    Error(_) -> decode.failure(timestamp.from_unix_seconds(0), "timestamp")
  }
}
