import domain/earthquake
import domain/geometry_transport
import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam/time/calendar
import gleam/time/timestamp.{type Timestamp}

/// One raw `sea.gdacs_event` row, trimmed to the columns the hazard
/// normalization needs (raw JSONB, geometry bookkeeping columns and the
/// seen/first-seen timestamps are the writer's concern, not the projection's).
pub type GdacsEpisodeRow {
  GdacsEpisodeRow(
    event_type: String,
    event_id: Int,
    episode_id: Int,
    alert_level: String,
    alert_score: Option(Float),
    name: Option(String),
    description: Option(String),
    country: Option(String),
    iso3: Option(String),
    glide: Option(String),
    origin_source: Option(String),
    origin_source_id: Option(String),
    severity_value: Option(Float),
    severity_unit: Option(String),
    severity_text: Option(String),
    from_at_ms: Int,
    to_at_ms: Option(Int),
    modified_at_ms: Int,
    is_current: Bool,
    longitude: Float,
    latitude: Float,
    bbox_west: Option(Float),
    bbox_south: Option(Float),
    bbox_east: Option(Float),
    bbox_north: Option(Float),
    affected_countries: List(String),
    report_url: Option(String),
    geometry: Option(String),
  )
}

pub const episode_columns = "event_type, event_id, episode_id, alert_level, alert_score, name, description, country, iso3, glide, origin_source, origin_source_id, severity_value, severity_unit, severity_text, from_at_ms, to_at_ms, modified_at_ms, is_current, longitude, latitude, bbox_west, bbox_south, bbox_east, bbox_north, affected_countries, report_url, geometry::text"

pub fn episode_row_decoder() -> decode.Decoder(GdacsEpisodeRow) {
  use event_type <- decode.field(0, decode.string)
  use event_id <- decode.field(1, decode.int)
  use episode_id <- decode.field(2, decode.int)
  use alert_level <- decode.field(3, decode.string)
  use alert_score <- decode.field(4, decode.optional(decode.float))
  use name <- decode.field(5, decode.optional(decode.string))
  use description <- decode.field(6, decode.optional(decode.string))
  use country <- decode.field(7, decode.optional(decode.string))
  use iso3 <- decode.field(8, decode.optional(decode.string))
  use glide <- decode.field(9, decode.optional(decode.string))
  use origin_source <- decode.field(10, decode.optional(decode.string))
  use origin_source_id <- decode.field(11, decode.optional(decode.string))
  use severity_value <- decode.field(12, decode.optional(decode.float))
  use severity_unit <- decode.field(13, decode.optional(decode.string))
  use severity_text <- decode.field(14, decode.optional(decode.string))
  use from_at_ms <- decode.field(15, decode.int)
  use to_at_ms <- decode.field(16, decode.optional(decode.int))
  use modified_at_ms <- decode.field(17, decode.int)
  use is_current <- decode.field(18, decode.bool)
  use longitude <- decode.field(19, decode.float)
  use latitude <- decode.field(20, decode.float)
  use bbox_west <- decode.field(21, decode.optional(decode.float))
  use bbox_south <- decode.field(22, decode.optional(decode.float))
  use bbox_east <- decode.field(23, decode.optional(decode.float))
  use bbox_north <- decode.field(24, decode.optional(decode.float))
  use affected_countries <- decode.field(25, decode.list(decode.string))
  use report_url <- decode.field(26, decode.optional(decode.string))
  use geometry <- decode.field(27, decode.optional(decode.string))
  decode.success(GdacsEpisodeRow(
    event_type:,
    event_id:,
    episode_id:,
    alert_level:,
    alert_score:,
    name:,
    description:,
    country:,
    iso3:,
    glide:,
    origin_source:,
    origin_source_id:,
    severity_value:,
    severity_unit:,
    severity_text:,
    from_at_ms:,
    to_at_ms:,
    modified_at_ms:,
    is_current:,
    longitude:,
    latitude:,
    bbox_west:,
    bbox_south:,
    bbox_east:,
    bbox_north:,
    affected_countries:,
    report_url:,
    geometry:,
  ))
}

/// Picks the episode a hazard row should reflect: highest `modified_at_ms`,
/// ties broken by the highest `episode_id`.
pub fn latest_episode(rows: List(GdacsEpisodeRow)) -> Option(GdacsEpisodeRow) {
  list.fold(rows, None, fn(acc, row) { keep_latest(acc, row) })
}

fn keep_latest(
  acc: Option(GdacsEpisodeRow),
  row: GdacsEpisodeRow,
) -> Option(GdacsEpisodeRow) {
  case acc {
    None -> Some(row)
    Some(current) ->
      case is_later(row, current) {
        True -> Some(row)
        False -> Some(current)
      }
  }
}

fn is_later(candidate: GdacsEpisodeRow, current: GdacsEpisodeRow) -> Bool {
  case
    candidate.modified_at_ms > current.modified_at_ms,
    candidate.modified_at_ms == current.modified_at_ms
  {
    True, _ -> True
    _, True -> candidate.episode_id > current.episode_id
    _, _ -> False
  }
}

pub fn hazard_type_for(event_type: String) -> String {
  case event_type {
    "EQ" -> "earthquake"
    "TC" -> "tropical_cyclone"
    "FL" -> "flood"
    "VO" -> "volcano"
    "WF" -> "wildfire"
    "DR" -> "drought"
    "TS" -> "tsunami"
    _ -> string.lowercase(event_type)
  }
}

/// Monty-convention codes: `glide:<code>` always, `emdat:<slug>` and
/// `undrr-isc-2025:<code>` when the GDACS type has one (WF has no UNDRR
/// code).
pub fn hazard_codes_for(event_type: String) -> List(String) {
  let codes = ["glide:" <> event_type]
  let codes = case emdat_slug_for(event_type) {
    Some(slug) -> list.append(codes, ["emdat:" <> slug])
    None -> codes
  }
  case undrr_code_for(event_type) {
    Some(code) -> list.append(codes, ["undrr-isc-2025:" <> code])
    None -> codes
  }
}

fn emdat_slug_for(event_type: String) -> Option(String) {
  case event_type {
    "EQ" -> Some("nat-geo-ear-gro")
    "TC" -> Some("nat-met-sto-tro")
    "FL" -> Some("nat-hyd-flo-flo")
    "VO" -> Some("nat-geo-vol-vol")
    "DR" -> Some("nat-cli-dro-dro")
    "TS" -> Some("nat-geo-ear-tsu")
    "WF" -> Some("nat-cli-wil-for")
    _ -> None
  }
}

fn undrr_code_for(event_type: String) -> Option(String) {
  case event_type {
    "FL" -> Some("MH0600")
    "EQ" -> Some("GH0101")
    "TC" -> Some("MH0306")
    "TS" -> Some("MH0705")
    "VO" -> Some("GH0201")
    "DR" -> Some("MH0401")
    _ -> None
  }
}

pub fn cap_severity_for(alert_level: String) -> String {
  case string.lowercase(alert_level) {
    "green" -> "minor"
    "orange" -> "severe"
    "red" -> "extreme"
    other -> other
  }
}

/// GDACS EQ rows sourced from NEIC carry the USGS event id verbatim in
/// `sourceid`, so that is the only case an external id can be derived.
pub fn external_ids_for(
  origin_source: Option(String),
  origin_source_id: String,
) -> List(String) {
  case origin_source, origin_source_id {
    Some("NEIC"), id if id != "" -> ["usgs:" <> id]
    _, _ -> []
  }
}

/// GDACS list polls always resend an empty `origin_source`/`origin_source_id`
/// (see `origin_from_geometry`); keeping the episode row's current value
/// when the incoming one is empty stops a later `datemodified` bump from
/// wiping the id `getgeometry` backfilled earlier.
pub fn merge_origin(
  incoming_source: Option(String),
  incoming_source_id: Option(String),
  current_source: Option(String),
  current_source_id: Option(String),
) -> #(Option(String), Option(String)) {
  #(
    option.or(incoming_source, current_source),
    option.or(incoming_source_id, current_source_id),
  )
}

/// Extracts the `source`/`sourceid` pair GDACS attaches to features of a
/// `polygons/getgeometry` FeatureCollection: the first feature whose
/// `sourceid` is non-empty. GDACS list endpoints (`geteventlist`, `search`,
/// `events4app`) always send an empty `sourceid`; only `getgeometry` (and
/// `geteventdata`) carry the real cross-source id.
pub fn origin_from_geometry(
  feature_collection_json: String,
) -> Option(#(String, String)) {
  case json.parse(feature_collection_json, origin_collection_decoder()) {
    Ok(origins) -> list.find(origins, fn(o) { o.1 != "" }) |> option.from_result
    Error(_) -> None
  }
}

fn origin_collection_decoder() -> decode.Decoder(List(#(String, String))) {
  use type_ <- decode.field("type", decode.string)
  use raw_features <- decode.field("features", decode.list(decode.dynamic))
  case type_ {
    "FeatureCollection" ->
      decode.success(
        raw_features
        |> list.filter_map(fn(f) {
          case decode.run(f, origin_feature_decoder()) {
            Ok(pair) -> Ok(pair)
            Error(_) -> Error(Nil)
          }
        }),
      )
    _ -> decode.failure([], "FeatureCollection")
  }
}

fn origin_feature_decoder() -> decode.Decoder(#(String, String)) {
  use source <- decode.subfield(["properties", "source"], decode.string)
  use source_id <- decode.subfield(["properties", "sourceid"], decode.string)
  decode.success(#(source, source_id))
}

pub type Severity {
  Severity(value: Float, unit: Option(String), label: Option(String))
}

/// `None` when GDACS sent no real severity signal at all (unit and text
/// both empty and the value defaulted to zero), otherwise the value plus
/// whichever of unit/text were actually populated.
pub fn severity_for(
  value: Float,
  unit: String,
  text: String,
) -> Option(Severity) {
  case unit, text, value {
    "", "", 0.0 -> None
    _, _, _ ->
      Some(Severity(value:, unit: non_empty(unit), label: non_empty(text)))
  }
}

fn non_empty(value: String) -> Option(String) {
  case value {
    "" -> None
    _ -> Some(value)
  }
}

/// Extracts the geometry a hazard should show as its `primary_geometry`
/// from a `polygons/getgeometry` FeatureCollection: the `Poly_Affected`
/// feature when present, else the `Poly_*` Polygon/MultiPolygon feature
/// with the largest planar (shoelace) area. LineStrings (TC tracks) and
/// points are never chosen. Returns the geometry object re-serialized as
/// its own JSON text, or `None` when nothing qualifies.
pub fn primary_geometry_from(
  feature_collection_json: String,
) -> Option(String) {
  case json.parse(feature_collection_json, feature_collection_decoder()) {
    Ok(features) ->
      pick_primary_geometry(features) |> option.map(geometry_to_text)
    Error(_) -> None
  }
}

type GeometryFeature {
  GeometryFeature(class: String, geometry_type: String, geometry: Dynamic)
}

fn feature_collection_decoder() -> decode.Decoder(List(GeometryFeature)) {
  use type_ <- decode.field("type", decode.string)
  use raw_features <- decode.field("features", decode.list(decode.dynamic))
  case type_ {
    "FeatureCollection" ->
      decode.success(
        raw_features
        |> list.filter_map(fn(f) {
          decode.run(f, geometry_feature_decoder()) |> result_first_error
        }),
      )
    _ -> decode.failure([], "FeatureCollection")
  }
}

fn result_first_error(
  result: Result(GeometryFeature, List(decode.DecodeError)),
) -> Result(GeometryFeature, Nil) {
  case result {
    Ok(feature) -> Ok(feature)
    Error(_) -> Error(Nil)
  }
}

fn geometry_feature_decoder() -> decode.Decoder(GeometryFeature) {
  use class <- decode.subfield(["properties", "Class"], decode.string)
  use geometry_type <- decode.subfield(["geometry", "type"], decode.string)
  use geometry <- decode.field("geometry", decode.dynamic)
  decode.success(GeometryFeature(class:, geometry_type:, geometry:))
}

fn pick_primary_geometry(features: List(GeometryFeature)) -> Option(Dynamic) {
  case list.find(features, fn(f) { f.class == "Poly_Affected" }) {
    Ok(feature) -> Some(feature.geometry)
    Error(Nil) ->
      features
      |> list.filter(fn(f) {
        string.starts_with(f.class, "Poly_")
        && { f.geometry_type == "Polygon" || f.geometry_type == "MultiPolygon" }
      })
      |> pick_largest_area
  }
}

fn pick_largest_area(features: List(GeometryFeature)) -> Option(Dynamic) {
  list.fold(features, None, fn(acc, feature) {
    let area = area_of(feature.geometry_type, feature.geometry)
    case acc {
      None -> Some(#(feature.geometry, area))
      Some(#(_, best)) if area >. best -> Some(#(feature.geometry, area))
      _ -> acc
    }
  })
  |> option.map(fn(pair) { pair.0 })
}

fn area_of(geometry_type: String, geometry: Dynamic) -> Float {
  case geometry_type {
    "Polygon" ->
      case
        decode.run(
          geometry,
          decode.at(["coordinates"], polygon_coords_decoder()),
        )
      {
        Ok(rings) -> polygon_area(rings)
        Error(_) -> 0.0
      }
    "MultiPolygon" ->
      case
        decode.run(
          geometry,
          decode.at(["coordinates"], decode.list(polygon_coords_decoder())),
        )
      {
        Ok(polygons) ->
          list.fold(polygons, 0.0, fn(acc, r) { acc +. polygon_area(r) })
        Error(_) -> 0.0
      }
    _ -> 0.0
  }
}

fn polygon_coords_decoder() -> decode.Decoder(List(List(#(Float, Float)))) {
  decode.list(decode.list(ring_point_decoder()))
}

fn ring_point_decoder() -> decode.Decoder(#(Float, Float)) {
  decode.list(coord_num())
  |> decode.then(fn(xs) {
    case xs {
      [lon, lat, ..] -> decode.success(#(lon, lat))
      _ -> decode.failure(#(0.0, 0.0), "GeoJSON coordinate")
    }
  })
}

fn coord_num() -> decode.Decoder(Float) {
  decode.one_of(decode.float, or: [decode.int |> decode.map(int.to_float)])
}

/// Signed shoelace area of a polygon (exterior ring minus holes), in the
/// squared units of the input coordinates (degrees here - planar, not
/// geodesic, which is enough to rank candidate GDACS impact polygons).
fn polygon_area(rings: List(List(#(Float, Float)))) -> Float {
  case rings {
    [] -> 0.0
    [exterior, ..holes] -> {
      let holes_area =
        list.fold(holes, 0.0, fn(acc, ring) { acc +. ring_area(ring) })
      float.absolute_value(ring_area(exterior)) -. holes_area
    }
  }
}

fn ring_area(points: List(#(Float, Float))) -> Float {
  case points {
    [] | [_] -> 0.0
    [first, ..] -> {
      let shifted = list.append(list.drop(points, 1), [first])
      let sum =
        list.zip(points, shifted)
        |> list.fold(0.0, fn(acc, pair) {
          let #(#(x1, y1), #(x2, y2)) = pair
          acc +. { x1 *. y2 -. x2 *. y1 }
        })
      float.absolute_value(sum) /. 2.0
    }
  }
}

fn geometry_to_text(geometry: Dynamic) -> String {
  json.to_string(json_value_of(geometry))
}

/// A JSON value decoded via `gleam/json` retains its Erlang shape (map,
/// list, binary, number, bool, the `null` atom); this walks that shape back
/// into a `gleam/json` builder value so previously-stored JSON text (a
/// GeoJSON geometry or FeatureCollection) can be embedded as a real nested
/// value in an outgoing response instead of a re-escaped string.
fn json_value_of(data: Dynamic) -> json.Json {
  case decode.run(data, decode.optional(decode.dynamic)) {
    Ok(None) -> json.null()
    _ -> json_value_of_present(data)
  }
}

fn json_value_of_present(data: Dynamic) -> json.Json {
  case decode.run(data, decode.string) {
    Ok(value) -> json.string(value)
    Error(_) -> json_value_of_bool(data)
  }
}

fn json_value_of_bool(data: Dynamic) -> json.Json {
  case decode.run(data, decode.bool) {
    Ok(value) -> json.bool(value)
    Error(_) -> json_value_of_int(data)
  }
}

fn json_value_of_int(data: Dynamic) -> json.Json {
  case decode.run(data, decode.int) {
    Ok(value) -> json.int(value)
    Error(_) -> json_value_of_float(data)
  }
}

fn json_value_of_float(data: Dynamic) -> json.Json {
  case decode.run(data, decode.float) {
    Ok(value) -> json.float(value)
    Error(_) -> json_value_of_list(data)
  }
}

fn json_value_of_list(data: Dynamic) -> json.Json {
  case decode.run(data, decode.list(decode.dynamic)) {
    Ok(items) -> json.array(items, json_value_of)
    Error(_) -> json_value_of_object(data)
  }
}

fn json_value_of_object(data: Dynamic) -> json.Json {
  case decode.run(data, decode.dict(decode.string, decode.dynamic)) {
    Ok(fields) ->
      json.object(
        dict.to_list(fields)
        |> list.map(fn(kv) { #(kv.0, json_value_of(kv.1)) }),
      )
    Error(_) -> json.null()
  }
}

fn json_of_text(text: String) -> json.Json {
  case json.parse(text, decode.dynamic) {
    Ok(data) -> json_value_of(data)
    Error(_) -> json.null()
  }
}

fn nullable_raw_json(text: Option(String)) -> json.Json {
  case text {
    Some(t) -> json_of_text(t)
    None -> json.null()
  }
}

/// Every `sea.hazard` column the normalization decides, ready to bind into
/// an INSERT or UPDATE. Kept separate from `Hazard` (the row read back from
/// the database) because it has no first/last-seen timestamps yet - those
/// are the writer's job, decided by whether the row already existed.
pub type NormalizedHazard {
  NormalizedHazard(
    source_id: String,
    source_episode_id: String,
    episode_count: Int,
    hazard_type: String,
    hazard_codes: List(String),
    glide: Option(String),
    alert_level: String,
    alert_score: Option(Float),
    cap_severity: String,
    severity_value: Option(Float),
    severity_unit: Option(String),
    severity_label: Option(String),
    title: String,
    description: Option(String),
    countries: List(String),
    report_url: Option(String),
    external_ids: List(String),
    onset_at_ms: Int,
    expires_at_ms: Option(Int),
    modified_at_ms: Int,
    is_current: Bool,
    longitude: Float,
    latitude: Float,
    bbox: Option(#(Float, Float, Float, Float)),
    primary_geometry: Option(String),
    geometries: Option(String),
  )
}

pub const estimate_type = "primary"

/// Normalizes the latest episode of a GDACS event into the source-agnostic
/// shape `sea.hazard` stores. Pure: no I/O, so every rule here is unit
/// testable without a database.
pub fn normalize(row: GdacsEpisodeRow, episode_count: Int) -> NormalizedHazard {
  let severity =
    severity_for(
      option.unwrap(row.severity_value, 0.0),
      option.unwrap(row.severity_unit, ""),
      option.unwrap(row.severity_text, ""),
    )
  NormalizedHazard(
    source_id: row.event_type <> "-" <> int.to_string(row.event_id),
    source_episode_id: int.to_string(row.episode_id),
    episode_count:,
    hazard_type: hazard_type_for(row.event_type),
    hazard_codes: hazard_codes_for(row.event_type),
    glide: row.glide,
    alert_level: string.lowercase(row.alert_level),
    alert_score: row.alert_score,
    cap_severity: cap_severity_for(row.alert_level),
    severity_value: option.map(severity, fn(s) { s.value }),
    severity_unit: option.then(severity, fn(s) { s.unit }),
    severity_label: option.then(severity, fn(s) { s.label }),
    title: option.unwrap(row.name, ""),
    description: row.description,
    countries: countries_for(row.affected_countries, row.iso3),
    report_url: row.report_url,
    external_ids: external_ids_for(
      row.origin_source,
      option.unwrap(row.origin_source_id, ""),
    ),
    onset_at_ms: row.from_at_ms,
    expires_at_ms: row.to_at_ms,
    modified_at_ms: row.modified_at_ms,
    is_current: row.is_current,
    longitude: row.longitude,
    latitude: row.latitude,
    bbox: bbox_for(row.bbox_west, row.bbox_south, row.bbox_east, row.bbox_north),
    primary_geometry: option.then(row.geometry, primary_geometry_from),
    geometries: row.geometry,
  )
}

fn countries_for(
  affected_countries: List(String),
  iso3: Option(String),
) -> List(String) {
  case affected_countries {
    [] ->
      case option.unwrap(iso3, "") {
        "" -> []
        code -> [code]
      }
    codes -> codes
  }
}

fn bbox_for(
  west: Option(Float),
  south: Option(Float),
  east: Option(Float),
  north: Option(Float),
) -> Option(#(Float, Float, Float, Float)) {
  case west, south, east, north {
    Some(w), Some(s), Some(e), Some(n) if w != e || s != n -> Some(#(w, s, e, n))
    _, _, _, _ -> None
  }
}

/// A `sea.hazard` row as read back from the database: normalized fields
/// plus the bookkeeping the writer owns (first/last seen).
pub type Hazard {
  Hazard(
    source: String,
    source_id: String,
    source_episode_id: Option(String),
    episode_count: Int,
    hazard_type: String,
    hazard_codes: List(String),
    glide: Option(String),
    alert_level: String,
    alert_score: Option(Float),
    cap_severity: String,
    severity_value: Option(Float),
    severity_unit: Option(String),
    severity_label: Option(String),
    estimate_type: String,
    title: String,
    description: Option(String),
    countries: List(String),
    report_url: Option(String),
    external_ids: List(String),
    onset_at: Timestamp,
    onset_at_ms: Int,
    expires_at: Option(Timestamp),
    expires_at_ms: Option(Int),
    modified_at: Timestamp,
    modified_at_ms: Int,
    is_current: Bool,
    longitude: Float,
    latitude: Float,
    bbox: Option(#(Float, Float, Float, Float)),
    primary_geometry: Option(String),
    geometries: Option(String),
    first_seen_at: Timestamp,
    last_seen_at: Timestamp,
  )
}

pub const columns = "source, source_id, source_episode_id, episode_count, hazard_type, hazard_codes, glide, alert_level, alert_score, cap_severity, severity_value, severity_unit, severity_label, estimate_type, title, description, countries, report_url, external_ids, onset_at, onset_at_ms, expires_at, expires_at_ms, modified_at, modified_at_ms, is_current, ST_X(centroid), ST_Y(centroid), ST_XMin(bbox), ST_YMin(bbox), ST_XMax(bbox), ST_YMax(bbox), ST_AsGeoJSON(primary_geometry), geometries::text, first_seen_at, last_seen_at"

pub fn row_decoder() -> decode.Decoder(Hazard) {
  use source <- decode.field(0, decode.string)
  use source_id <- decode.field(1, decode.string)
  use source_episode_id <- decode.field(2, decode.optional(decode.string))
  use episode_count <- decode.field(3, decode.int)
  use hazard_type <- decode.field(4, decode.string)
  use hazard_codes <- decode.field(5, decode.list(decode.string))
  use glide <- decode.field(6, decode.optional(decode.string))
  use alert_level <- decode.field(7, decode.string)
  use alert_score <- decode.field(8, decode.optional(decode.float))
  use cap_severity <- decode.field(9, decode.string)
  use severity_value <- decode.field(10, decode.optional(decode.float))
  use severity_unit <- decode.field(11, decode.optional(decode.string))
  use severity_label <- decode.field(12, decode.optional(decode.string))
  use estimate_type <- decode.field(13, decode.string)
  use title <- decode.field(14, decode.string)
  use description <- decode.field(15, decode.optional(decode.string))
  use countries <- decode.field(16, decode.list(decode.string))
  use report_url <- decode.field(17, decode.optional(decode.string))
  use external_ids <- decode.field(18, decode.list(decode.string))
  use onset_at <- decode.field(19, earthquake.timestamptz_decoder())
  use onset_at_ms <- decode.field(20, decode.int)
  use expires_at <- decode.field(
    21,
    decode.optional(earthquake.timestamptz_decoder()),
  )
  use expires_at_ms <- decode.field(22, decode.optional(decode.int))
  use modified_at <- decode.field(23, earthquake.timestamptz_decoder())
  use modified_at_ms <- decode.field(24, decode.int)
  use is_current <- decode.field(25, decode.bool)
  use longitude <- decode.field(26, decode.float)
  use latitude <- decode.field(27, decode.float)
  use bbox_west <- decode.field(28, decode.optional(decode.float))
  use bbox_south <- decode.field(29, decode.optional(decode.float))
  use bbox_east <- decode.field(30, decode.optional(decode.float))
  use bbox_north <- decode.field(31, decode.optional(decode.float))
  use primary_geometry <- decode.field(32, decode.optional(decode.string))
  use geometries <- decode.field(33, decode.optional(decode.string))
  use first_seen_at <- decode.field(34, earthquake.timestamptz_decoder())
  use last_seen_at <- decode.field(35, earthquake.timestamptz_decoder())
  decode.success(Hazard(
    source:,
    source_id:,
    source_episode_id:,
    episode_count:,
    hazard_type:,
    hazard_codes:,
    glide:,
    alert_level:,
    alert_score:,
    cap_severity:,
    severity_value:,
    severity_unit:,
    severity_label:,
    estimate_type:,
    title:,
    description:,
    countries:,
    report_url:,
    external_ids:,
    onset_at:,
    onset_at_ms:,
    expires_at:,
    expires_at_ms:,
    modified_at:,
    modified_at_ms:,
    is_current:,
    longitude:,
    latitude:,
    bbox: case bbox_west, bbox_south, bbox_east, bbox_north {
      Some(w), Some(s), Some(e), Some(n) -> Some(#(w, s, e, n))
      _, _, _, _ -> None
    },
    primary_geometry:,
    geometries:,
    first_seen_at:,
    last_seen_at:,
  ))
}

/// `sea.hazard` has no dedicated type-code column: for GDACS, `source_id`
/// is always `"<event_type>-<event_id>"`, so the code is the part before
/// the first hyphen.
pub fn source_type_code_of(source_id: String) -> String {
  case string.split_once(source_id, "-") {
    Ok(#(code, _)) -> code
    Error(Nil) -> source_id
  }
}

pub fn to_json(hazard: Hazard) -> json.Json {
  json.object(common_fields(hazard))
}

pub fn to_polyline_json(hazard: Hazard) -> json.Json {
  let primary_geom = case hazard.primary_geometry {
    None -> json.null()
    Some(text) ->
      case geometry_transport.encode_geometry_text(text) {
        Ok(encoded) -> encoded
        Error(Nil) -> nullable_raw_json(hazard.primary_geometry)
      }
  }
  json.object(common_fields_with_geometry(hazard, primary_geom))
}

pub fn to_detail_json(hazard: Hazard) -> json.Json {
  json.object(
    list.append(common_fields(hazard), [
      #("geometries", nullable_raw_json(hazard.geometries)),
    ]),
  )
}

fn common_fields(h: Hazard) -> List(#(String, json.Json)) {
  common_fields_with_geometry(h, nullable_raw_json(h.primary_geometry))
}

fn common_fields_with_geometry(
  h: Hazard,
  primary_geometry: json.Json,
) -> List(#(String, json.Json)) {
  [
    #("id", json.string(h.source <> ":" <> h.source_id)),
    #("source", json.string(h.source)),
    #("source_id", json.string(h.source_id)),
    #("source_type_code", json.string(source_type_code_of(h.source_id))),
    #("hazard_type", json.string(h.hazard_type)),
    #("hazard_codes", json.array(h.hazard_codes, json.string)),
    #("glide", json.nullable(h.glide, json.string)),
    #("alert_level", json.string(h.alert_level)),
    #("alert_score", json.nullable(h.alert_score, json.float)),
    #("cap_severity", json.string(h.cap_severity)),
    #("severity_value", json.nullable(h.severity_value, json.float)),
    #("severity_unit", json.nullable(h.severity_unit, json.string)),
    #("severity_label", json.nullable(h.severity_label, json.string)),
    #("estimate_type", json.string(h.estimate_type)),
    #("title", json.string(h.title)),
    #("description", json.nullable(h.description, json.string)),
    #("countries", json.array(h.countries, json.string)),
    #("report_url", json.nullable(h.report_url, json.string)),
    #("onset_at", time_json(h.onset_at)),
    #("onset_at_ms", json.int(h.onset_at_ms)),
    #("expires_at", json.nullable(h.expires_at, time_json)),
    #("expires_at_ms", json.nullable(h.expires_at_ms, json.int)),
    #("modified_at", time_json(h.modified_at)),
    #("modified_at_ms", json.int(h.modified_at_ms)),
    #("is_current", json.bool(h.is_current)),
    #("episode_id", json.nullable(h.source_episode_id, json.string)),
    #("episode_count", json.int(h.episode_count)),
    #("longitude", json.float(h.longitude)),
    #("latitude", json.float(h.latitude)),
    #("bbox", bbox_json(h.bbox)),
    #("primary_geometry", primary_geometry),
    #("external_ids", json.array(h.external_ids, json.string)),
    #("first_seen_at", time_json(h.first_seen_at)),
    #("last_seen_at", time_json(h.last_seen_at)),
  ]
}

fn bbox_json(bbox: Option(#(Float, Float, Float, Float))) -> json.Json {
  case bbox {
    Some(#(w, s, e, n)) -> json.array([w, s, e, n], json.float)
    None -> json.null()
  }
}

fn time_json(x: Timestamp) -> json.Json {
  json.string(timestamp.to_rfc3339(x, calendar.utc_offset))
}

/// One entry in a hazard's episode history, as returned by the detail
/// endpoint.
pub type HazardEpisode {
  HazardEpisode(
    episode_id: Int,
    alert_level: String,
    alert_score: Option(Float),
    severity_value: Option(Float),
    severity_label: Option(String),
    from_at: Timestamp,
    to_at: Option(Timestamp),
    modified_at: Timestamp,
    has_geometry: Bool,
  )
}

pub fn episode_to_json(episode: HazardEpisode) -> json.Json {
  json.object([
    #("episode_id", json.string(int.to_string(episode.episode_id))),
    #("alert_level", json.string(episode.alert_level)),
    #("alert_score", json.nullable(episode.alert_score, json.float)),
    #("severity_value", json.nullable(episode.severity_value, json.float)),
    #("severity_label", json.nullable(episode.severity_label, json.string)),
    #("from_at", time_json(episode.from_at)),
    #("to_at", json.nullable(episode.to_at, time_json)),
    #("modified_at", time_json(episode.modified_at)),
    #("has_geometry", json.bool(episode.has_geometry)),
  ])
}
