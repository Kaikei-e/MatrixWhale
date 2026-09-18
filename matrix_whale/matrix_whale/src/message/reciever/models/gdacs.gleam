import erlang_tools/raw_json
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/timestamp
import message/reciever/models/earthquake_feature.{
  type IncomingEarthquake, type PollMeta, IncomingEarthquake, PollMeta,
}

/// One `geteventlist` / `getgeometry` list feature, kept close to the wire
/// shape (see the shared GDACS contract) so it maps onto `sea.gdacs_event`
/// almost column-for-column; normalization into the source-agnostic hazard
/// shape happens in `domain/hazard`.
pub type GdacsFeature {
  GdacsFeature(
    event_type: String,
    event_id: Int,
    episode_id: Int,
    alert_level: String,
    alert_score: Option(Float),
    episode_alert_level: Option(String),
    episode_alert_score: Option(Float),
    name: Option(String),
    event_name: Option(String),
    description: Option(String),
    html_description: Option(String),
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
    is_temporary: Bool,
    longitude: Float,
    latitude: Float,
    bbox_west: Option(Float),
    bbox_south: Option(Float),
    bbox_east: Option(Float),
    bbox_north: Option(Float),
    affected_countries: List(String),
    report_url: Option(String),
    geometry_url: Option(String),
    icon_url: Option(String),
    raw: String,
  )
}

/// One `polygons/getgeometry` result the adapter posts back for an episode
/// it was asked to fetch.
pub type GdacsGeometryResult {
  GdacsGeometryResult(
    event_type: String,
    event_id: Int,
    episode_id: Int,
    http_status: Int,
    geometry: Option(String),
  )
}

pub fn decode_body(
  data: Dynamic,
) -> Result(#(Option(PollMeta), List(GdacsFeature), Int, Int), String) {
  let decoder = {
    use poll_meta <- decode.optional_field(
      "poll_meta",
      None,
      decode.optional(meta()),
    )
    use raw <- decode.field("features", decode.list(decode.dynamic))
    decode.success(#(poll_meta, raw))
  }
  case decode.run(data, decoder) {
    Ok(#(poll_meta, raw)) -> {
      let rows =
        raw
        |> list.filter_map(fn(x) {
          case decode_feature(x) {
            Ok(x) -> Ok(x)
            Error(_) -> Error(Nil)
          }
        })
      Ok(#(
        poll_meta,
        rows,
        list.length(raw),
        list.length(raw) - list.length(rows),
      ))
    }
    Error(errors) -> Error(string.inspect(errors))
  }
}

pub fn decode_geometry_body(
  data: Dynamic,
) -> Result(#(Option(PollMeta), List(GdacsGeometryResult), Int, Int), String) {
  let decoder = {
    use poll_meta <- decode.optional_field(
      "poll_meta",
      None,
      decode.optional(meta()),
    )
    use raw <- decode.field("features", decode.list(decode.dynamic))
    decode.success(#(poll_meta, raw))
  }
  case decode.run(data, decoder) {
    Ok(#(poll_meta, raw)) -> {
      let rows =
        raw
        |> list.filter_map(fn(x) {
          case decode.run(x, geometry_result_decoder()) {
            Ok(x) -> Ok(x)
            Error(_) -> Error(Nil)
          }
        })
      Ok(#(
        poll_meta,
        rows,
        list.length(raw),
        list.length(raw) - list.length(rows),
      ))
    }
    Error(errors) -> Error(string.inspect(errors))
  }
}

fn meta() -> decode.Decoder(PollMeta) {
  use fetched_at <- decode.field("fetched_at", decode.string)
  use http_status <- decode.field("http_status", decode.int)
  use feature_count <- decode.field("feature_count", decode.int)
  use bytes <- decode.optional_field("bytes", 0, decode.int)
  use backfill <- decode.optional_field("backfill", False, decode.bool)
  decode.success(PollMeta(
    fetched_at:,
    http_status:,
    feature_count:,
    bytes:,
    backfill:,
  ))
}

fn geometry_result_decoder() -> decode.Decoder(GdacsGeometryResult) {
  use event_type <- decode.field("eventtype", decode.string)
  use event_id <- decode.field("eventid", decode.int)
  use episode_id <- decode.field("episodeid", decode.int)
  use http_status <- decode.field("http_status", decode.int)
  use geometry <- decode.field("geometry", decode.optional(decode.dynamic))
  let result =
    GdacsGeometryResult(
      event_type:,
      event_id:,
      episode_id:,
      http_status:,
      geometry: option.then(geometry, fn(g) {
        raw_json.encode(g) |> option.from_result
      }),
    )
  case event_type != "" && event_id > 0 && episode_id > 0 {
    True -> decode.success(result)
    False -> decode.failure(result, "valid GDACS geometry result")
  }
}

pub fn decode_feature(data: Dynamic) -> Result(GdacsFeature, List(String)) {
  let decoder = {
    use feature_type <- decode.field("type", decode.string)
    use bbox <- decode.optional_field(
      "bbox",
      None,
      decode.optional(bbox_decoder()),
    )
    use #(lon, lat) <- decode.field("geometry", point_decoder())
    use p <- decode.field("properties", props())
    let raw = raw_json.encode(data)
    let #(bbox_west, bbox_south, bbox_east, bbox_north) = case bbox {
      Some(#(w, s, e, n)) -> #(Some(w), Some(s), Some(e), Some(n))
      None -> #(None, None, None, None)
    }
    let feature =
      GdacsFeature(
        event_type: p.event_type,
        event_id: p.event_id,
        episode_id: p.episode_id,
        alert_level: p.alert_level,
        alert_score: p.alert_score,
        episode_alert_level: p.episode_alert_level,
        episode_alert_score: p.episode_alert_score,
        name: p.name,
        event_name: p.event_name,
        description: p.description,
        html_description: p.html_description,
        country: p.country,
        iso3: p.iso3,
        glide: p.glide,
        origin_source: p.origin_source,
        origin_source_id: p.origin_source_id,
        severity_value: p.severity_value,
        severity_unit: p.severity_unit,
        severity_text: p.severity_text,
        from_at_ms: option.unwrap(p.from_at_ms, 0),
        to_at_ms: p.to_at_ms,
        modified_at_ms: option.unwrap(p.modified_at_ms, 0),
        is_current: p.is_current,
        is_temporary: p.is_temporary,
        longitude: lon,
        latitude: lat,
        bbox_west:,
        bbox_south:,
        bbox_east:,
        bbox_north:,
        affected_countries: p.affected_countries,
        report_url: p.report_url,
        geometry_url: p.geometry_url,
        icon_url: p.icon_url,
        raw: result.unwrap(raw, ""),
      )
    case
      feature_type == "Feature"
      && feature.event_type != ""
      && feature.event_id > 0
      && feature.episode_id > 0
      && option.is_some(p.from_at_ms)
      && option.is_some(p.modified_at_ms)
      && lon >=. -180.0
      && lon <=. 180.0
      && lat >=. -90.0
      && lat <=. 90.0
      && result.is_ok(raw)
    {
      True -> decode.success(feature)
      False -> decode.failure(feature, "valid GDACS feature")
    }
  }
  decode.run(data, decoder) |> result.map_error(list.map(_, string.inspect))
}

type Props {
  Props(
    event_type: String,
    event_id: Int,
    episode_id: Int,
    alert_level: String,
    alert_score: Option(Float),
    episode_alert_level: Option(String),
    episode_alert_score: Option(Float),
    name: Option(String),
    event_name: Option(String),
    description: Option(String),
    html_description: Option(String),
    country: Option(String),
    iso3: Option(String),
    glide: Option(String),
    origin_source: Option(String),
    origin_source_id: Option(String),
    severity_value: Option(Float),
    severity_unit: Option(String),
    severity_text: Option(String),
    from_at_ms: Option(Int),
    to_at_ms: Option(Int),
    modified_at_ms: Option(Int),
    is_current: Bool,
    is_temporary: Bool,
    affected_countries: List(String),
    report_url: Option(String),
    geometry_url: Option(String),
    icon_url: Option(String),
  )
}

fn props() -> decode.Decoder(Props) {
  use event_type <- decode.optional_field("eventtype", "", decode.string)
  use event_id <- decode.optional_field("eventid", 0, decode.int)
  use episode_id <- decode.optional_field("episodeid", 0, decode.int)
  use alert_level <- decode.optional_field("alertlevel", "", decode.string)
  use alert_score <- decode.optional_field(
    "alertscore",
    None,
    decode.optional(num()),
  )
  use episode_alert_level <- decode.optional_field(
    "episodealertlevel",
    None,
    decode.optional(decode.string),
  )
  use episode_alert_score <- decode.optional_field(
    "episodealertscore",
    None,
    decode.optional(num()),
  )
  use name <- decode.optional_field("name", None, non_empty_string())
  use event_name <- decode.optional_field("eventname", None, non_empty_string())
  use description <- decode.optional_field(
    "description",
    None,
    non_empty_string(),
  )
  use html_description <- decode.optional_field(
    "htmldescription",
    None,
    non_empty_string(),
  )
  use country <- decode.optional_field("country", None, non_empty_string())
  use iso3 <- decode.optional_field("iso3", None, non_empty_string())
  use glide <- decode.optional_field("glide", None, non_empty_string())
  use origin_source <- decode.optional_field("source", None, non_empty_string())
  use origin_source_id <- decode.optional_field(
    "sourceid",
    None,
    non_empty_string(),
  )
  use fromdate <- decode.optional_field("fromdate", "", decode.string)
  use todate <- decode.optional_field("todate", "", decode.string)
  use datemodified <- decode.optional_field("datemodified", "", decode.string)
  use istemporary <- decode.optional_field(
    "istemporary",
    "false",
    decode.string,
  )
  use iscurrent <- decode.optional_field("iscurrent", "false", decode.string)
  use url <- decode.optional_field("url", #(None, None), url_decoder())
  use affectedcountries <- decode.optional_field(
    "affectedcountries",
    [],
    decode.list(country_decoder()),
  )
  use icon <- decode.optional_field("icon", None, non_empty_string())
  use severitydata <- decode.optional_field(
    "severitydata",
    #(0.0, "", ""),
    severity_decoder(),
  )
  let #(severity_value, severity_text, severity_unit) = severitydata
  let #(report_url, geometry_url) = url
  decode.success(Props(
    event_type:,
    event_id:,
    episode_id:,
    alert_level:,
    alert_score:,
    episode_alert_level:,
    episode_alert_score:,
    name:,
    event_name:,
    description:,
    html_description:,
    country:,
    iso3:,
    glide:,
    origin_source:,
    origin_source_id:,
    severity_value: Some(severity_value),
    severity_unit: non_empty(severity_unit),
    severity_text: non_empty(severity_text),
    from_at_ms: gdacs_timestamp_to_ms(fromdate),
    to_at_ms: gdacs_timestamp_to_ms(todate),
    modified_at_ms: gdacs_timestamp_to_ms(datemodified),
    is_current: iscurrent == "true",
    is_temporary: istemporary == "true",
    affected_countries: list.filter(affectedcountries, fn(c) { c != "" }),
    report_url: report_url,
    geometry_url: geometry_url,
    icon_url: icon,
  ))
}

fn url_decoder() -> decode.Decoder(#(Option(String), Option(String))) {
  use report <- decode.optional_field("report", None, non_empty_string())
  use geometry <- decode.optional_field("geometry", None, non_empty_string())
  decode.success(#(report, geometry))
}

fn country_decoder() -> decode.Decoder(String) {
  use iso3 <- decode.optional_field("iso3", "", decode.string)
  decode.success(iso3)
}

fn severity_decoder() -> decode.Decoder(#(Float, String, String)) {
  use value <- decode.optional_field("severity", 0.0, num())
  use text <- decode.optional_field("severitytext", "", decode.string)
  use unit <- decode.optional_field("severityunit", "", decode.string)
  decode.success(#(value, text, unit))
}

fn point_decoder() -> decode.Decoder(#(Float, Float)) {
  use type_ <- decode.field("type", decode.string)
  use xs <- decode.field("coordinates", decode.list(num()))
  case type_, xs {
    "Point", [lon, lat, ..] -> decode.success(#(lon, lat))
    _, _ -> decode.failure(#(0.0, 0.0), "GDACS Point coordinates")
  }
}

fn bbox_decoder() -> decode.Decoder(#(Float, Float, Float, Float)) {
  decode.list(num())
  |> decode.then(fn(xs) {
    case xs {
      [w, s, e, n] -> decode.success(#(w, s, e, n))
      _ -> decode.failure(#(0.0, 0.0, 0.0, 0.0), "GDACS bbox")
    }
  })
}

fn num() -> decode.Decoder(Float) {
  decode.one_of(decode.float, or: [decode.int |> decode.map(int.to_float)])
}

fn non_empty_string() -> decode.Decoder(Option(String)) {
  decode.string |> decode.map(non_empty)
}

fn non_empty(value: String) -> Option(String) {
  case value {
    "" -> None
    _ -> Some(value)
  }
}

/// GDACS timestamps carry no zone suffix; GDACS operates in UTC, so this
/// treats them as UTC by appending the `Z` designator RFC 3339 requires.
fn gdacs_timestamp_to_ms(input: String) -> Option(Int) {
  case timestamp.parse_rfc3339(input <> "Z") {
    Ok(ts) -> {
      let #(seconds, nanoseconds) =
        timestamp.to_unix_seconds_and_nanoseconds(ts)
      Some(seconds * 1000 + nanoseconds / 1_000_000)
    }
    Error(_) -> None
  }
}

/// Builds the earthquake-pipeline record for a GDACS `EQ` feature, or
/// `None` for every other hazard type. Depth is not a first-class GDACS
/// field for earthquakes; it is embedded in `severitydata.severitytext` as
/// `Depth:<n>km`.
pub fn to_incoming_earthquake(
  feature: GdacsFeature,
) -> Option(IncomingEarthquake) {
  case feature.event_type {
    "EQ" ->
      Some(IncomingEarthquake(
        source_id: int.to_string(feature.event_id),
        ids: gdacs_ids(
          feature.event_id,
          feature.origin_source,
          feature.origin_source_id,
        ),
        sources: ["gdacs"],
        net: None,
        code: None,
        mag: feature.severity_value,
        mag_type: None,
        time: feature.from_at_ms,
        updated: feature.modified_at_ms,
        place: feature.country,
        title: feature.name,
        status: None,
        type_: Some("earthquake"),
        tsunami: None,
        sig: None,
        alert: None,
        mmi: None,
        cdi: None,
        felt: None,
        nst: None,
        dmin: None,
        rms: None,
        gap: None,
        url: feature.report_url,
        detail: None,
        lon: feature.longitude,
        lat: feature.latitude,
        depth: depth_from_severity_text(feature.severity_text),
        raw: feature.raw,
      ))
    _ -> None
  }
}

fn gdacs_ids(
  event_id: Int,
  origin_source: Option(String),
  origin_source_id: Option(String),
) -> List(String) {
  let base = ["gdacs:" <> int.to_string(event_id)]
  case origin_source, origin_source_id {
    Some("NEIC"), Some(id) if id != "" -> list.append(base, [id])
    _, _ -> base
  }
}

fn depth_from_severity_text(text: Option(String)) -> Option(Float) {
  case text {
    None -> None
    Some(t) ->
      case string.split_once(t, "Depth:") {
        Ok(#(_, rest)) ->
          case string.split_once(rest, "km") {
            Ok(#(number, _)) -> parse_number(string.trim(number))
            Error(Nil) -> None
          }
        Error(Nil) -> None
      }
  }
}

fn parse_number(text: String) -> Option(Float) {
  case float.parse(text) {
    Ok(value) -> Some(value)
    Error(Nil) ->
      case int.parse(text) {
        Ok(value) -> Some(int.to_float(value))
        Error(Nil) -> None
      }
  }
}
