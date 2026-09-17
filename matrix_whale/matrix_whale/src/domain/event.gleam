import domain/earthquake.{type Earthquake}
import gleam/dynamic/decode
import gleam/json
import gleam/option.{type Option}
import gleam/time/calendar
import gleam/time/timestamp.{type Timestamp}

pub const columns = "id, kind, preferred_source, preferred_source_id, magnitude, magnitude_type, occurred_at, occurred_at_ms, updated_at, updated_at_ms, place, title, status, event_type, longitude, latitude, depth_km, first_seen_at, last_seen_at"

pub type Event {
  Event(
    id: Int,
    kind: String,
    preferred_source: String,
    preferred_source_id: String,
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
    longitude: Float,
    latitude: Float,
    depth_km: Option(Float),
    first_seen_at: Timestamp,
    last_seen_at: Timestamp,
  )
}

/// One member row rendered inside `Event.members`: a slice of its
/// `sea.earthquake` projection plus how it was linked to the event.
pub type MemberView {
  MemberView(
    source: String,
    source_id: String,
    magnitude: Option(Float),
    magnitude_type: Option(String),
    occurred_at_ms: Int,
    updated_at_ms: Int,
    latitude: Float,
    longitude: Float,
    depth_km: Option(Float),
    place: Option(String),
    status: Option(String),
    url: Option(String),
    matched_by: String,
    misfit: Option(Float),
  )
}

/// An event plus its preferred member's full earthquake row (source of the
/// per-source detail fields the event table does not cache) and its member
/// views, ready for `to_json`.
pub type EventView {
  EventView(
    event: Event,
    preferred: Earthquake,
    members: List(MemberView),
    sources: List(String),
  )
}

pub fn row_decoder() -> decode.Decoder(Event) {
  use id <- decode.field(0, decode.int)
  use kind <- decode.field(1, decode.string)
  use preferred_source <- decode.field(2, decode.string)
  use preferred_source_id <- decode.field(3, decode.string)
  use magnitude <- decode.field(4, decode.optional(decode.float))
  use magnitude_type <- decode.field(5, decode.optional(decode.string))
  use occurred_at <- decode.field(6, earthquake.timestamptz_decoder())
  use occurred_at_ms <- decode.field(7, decode.int)
  use updated_at <- decode.field(8, earthquake.timestamptz_decoder())
  use updated_at_ms <- decode.field(9, decode.int)
  use place <- decode.field(10, decode.optional(decode.string))
  use title <- decode.field(11, decode.optional(decode.string))
  use status <- decode.field(12, decode.optional(decode.string))
  use event_type <- decode.field(13, decode.optional(decode.string))
  use longitude <- decode.field(14, decode.float)
  use latitude <- decode.field(15, decode.float)
  use depth_km <- decode.field(16, decode.optional(decode.float))
  use first_seen_at <- decode.field(17, earthquake.timestamptz_decoder())
  use last_seen_at <- decode.field(18, earthquake.timestamptz_decoder())
  decode.success(Event(
    id:,
    kind:,
    preferred_source:,
    preferred_source_id:,
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
    longitude:,
    latitude:,
    depth_km:,
    first_seen_at:,
    last_seen_at:,
  ))
}

pub fn to_json(view: EventView) -> json.Json {
  let e = view.event
  let p = view.preferred
  json.object([
    #("id", json.int(e.id)),
    #("kind", json.string(e.kind)),
    #("magnitude", json.nullable(e.magnitude, json.float)),
    #("magnitude_type", json.nullable(e.magnitude_type, json.string)),
    #("occurred_at", time_json(e.occurred_at)),
    #("occurred_at_ms", json.int(e.occurred_at_ms)),
    #("updated_at", time_json(e.updated_at)),
    #("updated_at_ms", json.int(e.updated_at_ms)),
    #("place", json.nullable(e.place, json.string)),
    #("title", json.nullable(e.title, json.string)),
    #("status", json.nullable(e.status, json.string)),
    #("event_type", json.nullable(e.event_type, json.string)),
    #("tsunami", json.nullable(p.tsunami, json.int)),
    #("significance", json.nullable(p.significance, json.int)),
    #("alert", json.nullable(p.alert, json.string)),
    #("mmi", json.nullable(p.mmi, json.float)),
    #("cdi", json.nullable(p.cdi, json.float)),
    #("felt", json.nullable(p.felt, json.int)),
    #("nst", json.nullable(p.nst, json.int)),
    #("dmin", json.nullable(p.dmin, json.float)),
    #("rms", json.nullable(p.rms, json.float)),
    #("gap", json.nullable(p.gap, json.float)),
    #("net", json.nullable(p.net, json.string)),
    #("code", json.nullable(p.code, json.string)),
    #("url", json.nullable(p.url, json.string)),
    #("detail", json.nullable(p.detail, json.string)),
    #("longitude", json.float(e.longitude)),
    #("latitude", json.float(e.latitude)),
    #("depth_km", json.nullable(e.depth_km, json.float)),
    #("preferred_source", json.string(e.preferred_source)),
    #("sources", json.array(view.sources, json.string)),
    #("members", json.array(view.members, member_to_json)),
    #("first_seen_at", time_json(e.first_seen_at)),
    #("last_seen_at", time_json(e.last_seen_at)),
  ])
}

fn member_to_json(x: MemberView) -> json.Json {
  json.object([
    #("source", json.string(x.source)),
    #("source_id", json.string(x.source_id)),
    #("magnitude", json.nullable(x.magnitude, json.float)),
    #("magnitude_type", json.nullable(x.magnitude_type, json.string)),
    #("occurred_at_ms", json.int(x.occurred_at_ms)),
    #("updated_at_ms", json.int(x.updated_at_ms)),
    #("latitude", json.float(x.latitude)),
    #("longitude", json.float(x.longitude)),
    #("depth_km", json.nullable(x.depth_km, json.float)),
    #("place", json.nullable(x.place, json.string)),
    #("status", json.nullable(x.status, json.string)),
    #("url", json.nullable(x.url, json.string)),
    #("matched_by", json.string(x.matched_by)),
    #("misfit", json.nullable(x.misfit, json.float)),
  ])
}

fn time_json(x: Timestamp) -> json.Json {
  json.string(timestamp.to_rfc3339(x, calendar.utc_offset))
}
