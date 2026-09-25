import domain/source
import erlang_tools/raw_json
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/calendar
import gleam/time/timestamp.{type Timestamp}
import message/reciever/models/cap as models_cap

pub type AreaPrecision {
  Exact
  Bbox
}

pub type Wis2CapFeature {
  Wis2CapFeature(
    notification_id: String,
    data_id: String,
    topic: String,
    centre_id: String,
    channel: String,
    pubtime: String,
    datetime: Option(String),
    license_url: Option(String),
    fetched_via: String,
    download_url: Option(String),
    raw_xml: String,
    cap: Option(models_cap.CapMessage),
    area_key: Option(String),
    area_geometry: Option(String),
    area_precision: Option(AreaPrecision),
  )
}

pub type Wis2PollMeta {
  Wis2PollMeta(feed_url: Option(String), error: Option(String))
}

pub type Wis2HealthFeature {
  Wis2HealthFeature(
    centre_id: String,
    kind: String,
    window_start: String,
    window_end: String,
    received: Int,
    duplicates: Int,
    download_failed: Int,
    decode_failed: Int,
    integrity_failed: Int,
    last_received_at: Option(String),
  )
}

pub type ChannelStatus {
  StatusOk
  StatusStale
  StatusFailing
}

pub type BrokerState {
  BrokerState(
    url: String,
    connected: Bool,
    last_report_at: Option(Timestamp),
    error: Option(String),
  )
}

pub type ChannelHealth {
  ChannelHealth(
    centre_id: String,
    kind: String,
    received_24h: Int,
    duplicates_24h: Int,
    download_failed_24h: Int,
    decode_failed_24h: Int,
    integrity_failed_24h: Int,
    last_received_at: Option(Timestamp),
    status: ChannelStatus,
  )
}

pub type WindRadii {
  WindRadii(threshold_ms: Float, radii_m: List(Option(Float)))
}

pub type ForecastPoint {
  ForecastPoint(
    lead_hours: Int,
    time: String,
    lat: Float,
    lon: Float,
    mslp_pa: Option(Float),
    max_wind_ms: Option(Float),
    max_wind_lat: Option(Float),
    max_wind_lon: Option(Float),
    wind_radii: List(WindRadii),
  )
}

pub type Wis2TcFeature {
  Wis2TcFeature(
    notification_id: String,
    data_id: String,
    topic: String,
    centre_id: String,
    channel: String,
    pubtime: String,
    fetched_via: String,
    download_url: Option(String),
    message_index: Int,
    originating_centre: Int,
    storm_id: String,
    storm_name: Option(String),
    ensemble_member: Option(Int),
    analysis_time: String,
    points: List(ForecastPoint),
  )
}

pub type ForecastTrack {
  ForecastTrack(
    source: String,
    centre_id: String,
    storm_id: String,
    storm_name: Option(String),
    analysis_time: String,
    points: List(ForecastPoint),
  )
}

pub fn area_precision_to_string(precision: AreaPrecision) -> String {
  case precision {
    Exact -> "exact"
    Bbox -> "bbox"
  }
}

pub fn area_precision_from_string(s: String) -> Result(AreaPrecision, Nil) {
  case string.trim(s) {
    "exact" -> Ok(Exact)
    "bbox" -> Ok(Bbox)
    _ -> Error(Nil)
  }
}

pub fn should_replace_area(
  incoming: AreaPrecision,
  stored: Option(AreaPrecision),
) -> Bool {
  case incoming, stored {
    _, None -> True
    Exact, _ -> True
    Bbox, Some(Bbox) -> True
    Bbox, Some(Exact) -> False
  }
}

pub fn is_new_area(
  incoming: AreaPrecision,
  stored: Option(AreaPrecision),
) -> Bool {
  case incoming, stored {
    _, None -> True
    Exact, Some(Bbox) -> True
    _, _ -> False
  }
}

pub fn source_id(centre_id: String) -> String {
  "wis2-" <> string.trim(centre_id)
}

pub fn make_source(
  centre_id: String,
  license_url: Option(String),
) -> source.Source {
  let trimmed = string.trim(centre_id)
  let license = case license_url {
    Some(l) -> {
      let t = string.trim(l)
      case t {
        "" -> "Unknown"
        _ -> t
      }
    }
    None -> "Unknown"
  }
  source.Source(
    id: source_id(trimmed),
    name: "WMO WIS2 / " <> trimmed,
    homepage: None,
    license: license,
    attribution_text: "WMO WIS2 / " <> trimmed,
    redistributable: False,
    priority: 70,
  )
}

pub fn make_tc_source(centre_id: String) -> source.Source {
  let trimmed = string.trim(centre_id)
  source.Source(
    id: source_id(trimmed),
    name: "WMO WIS2 / " <> trimmed,
    homepage: None,
    license: "Unknown",
    attribution_text: "WMO WIS2 / " <> trimmed,
    redistributable: False,
    priority: 75,
  )
}

pub fn truncate_to_hour(ts: Timestamp) -> Timestamp {
  let #(sec, _) = timestamp.to_unix_seconds_and_nanoseconds(ts)
  let hour_sec = { sec / 3600 } * 3600
  timestamp.from_unix_seconds_and_nanoseconds(hour_sec, 0)
}

pub fn channel_status_to_string(status: ChannelStatus) -> String {
  case status {
    StatusOk -> "ok"
    StatusStale -> "stale"
    StatusFailing -> "failing"
  }
}

pub fn compute_status(
  kind: String,
  received_24h: Int,
  download_failed_24h: Int,
  decode_failed_24h: Int,
  integrity_failed_24h: Int,
  last_received_at: Option(Timestamp),
  now: Timestamp,
) -> ChannelStatus {
  let total_failed =
    download_failed_24h + decode_failed_24h + integrity_failed_24h
  let is_failing = received_24h > 0 && total_failed * 2 > received_24h
  case is_failing {
    True -> StatusFailing
    False -> {
      let threshold_hours = case string.lowercase(string.trim(kind)) {
        "trajectory" -> 24
        _ -> 6
      }
      let is_stale = case last_received_at {
        None -> True
        Some(last_ts) -> {
          let #(now_sec, _) = timestamp.to_unix_seconds_and_nanoseconds(now)
          let #(last_sec, _) =
            timestamp.to_unix_seconds_and_nanoseconds(last_ts)
          now_sec - last_sec > threshold_hours * 3600
        }
      }
      case is_stale {
        True -> StatusStale
        False -> StatusOk
      }
    }
  }
}

pub fn decode_cap_body(
  data: Dynamic,
) -> Result(#(Option(Wis2PollMeta), List(Wis2CapFeature), Int, Int), String) {
  let decoder = {
    use poll_meta <- decode.optional_field(
      "poll_meta",
      None,
      decode.optional(poll_meta_decoder()),
    )
    use raw <- decode.field("features", decode.list(decode.dynamic))
    decode.success(#(poll_meta, raw))
  }
  case decode.run(data, decoder) {
    Ok(#(poll_meta, raw)) -> {
      let items =
        raw
        |> list.filter_map(fn(x) {
          case decode.run(x, cap_feature_decoder()) {
            Ok(item) -> Ok(item)
            Error(_) -> Error(Nil)
          }
        })
      let received = list.length(raw)
      let dropped = received - list.length(items)
      Ok(#(poll_meta, items, received, dropped))
    }
    Error(errors) -> Error(string.inspect(errors))
  }
}

pub fn decode_health_body(
  data: Dynamic,
) -> Result(#(Option(Wis2PollMeta), List(Wis2HealthFeature), Int, Int), String) {
  let decoder = {
    use poll_meta <- decode.optional_field(
      "poll_meta",
      None,
      decode.optional(poll_meta_decoder()),
    )
    use raw <- decode.field("features", decode.list(decode.dynamic))
    decode.success(#(poll_meta, raw))
  }
  case decode.run(data, decoder) {
    Ok(#(poll_meta, raw)) -> {
      let items =
        raw
        |> list.filter_map(fn(x) {
          case decode.run(x, health_feature_decoder()) {
            Ok(item) -> Ok(item)
            Error(_) -> Error(Nil)
          }
        })
      let received = list.length(raw)
      let dropped = received - list.length(items)
      Ok(#(poll_meta, items, received, dropped))
    }
    Error(errors) -> Error(string.inspect(errors))
  }
}

fn poll_meta_decoder() -> decode.Decoder(Wis2PollMeta) {
  use feed_url <- decode.optional_field(
    "feed_url",
    None,
    decode.optional(decode.string),
  )
  use error <- decode.optional_field(
    "error",
    None,
    decode.optional(decode.string),
  )
  decode.success(Wis2PollMeta(
    feed_url: option.map(feed_url, string.trim),
    error: option.map(error, string.trim),
  ))
}

fn area_geometry_decoder() -> decode.Decoder(Option(String)) {
  let string_or_json_object =
    decode.one_of(decode.string, [
      decode.dynamic
      |> decode.map(fn(dyn) { raw_json.encode(dyn) |> result.unwrap("") }),
    ])
  decode.optional(string_or_json_object)
  |> decode.map(fn(opt) {
    case opt {
      Some(s) ->
        case string.trim(s) {
          "" -> None
          trimmed -> Some(trimmed)
        }
      None -> None
    }
  })
}

pub fn area_precision_decoder() -> decode.Decoder(Option(AreaPrecision)) {
  use opt_str <- decode.then(decode.optional(decode.string))
  case opt_str {
    None -> decode.success(None)
    Some(s) ->
      case string.trim(s) {
        "exact" -> decode.success(Some(Exact))
        "bbox" -> decode.success(Some(Bbox))
        _ -> decode.failure(None, "AreaPrecision (exact | bbox)")
      }
  }
}

fn cap_feature_decoder() -> decode.Decoder(Wis2CapFeature) {
  use notification_id <- decode.field("notification_id", decode.string)
  use data_id <- decode.field("data_id", decode.string)
  use topic <- decode.field("topic", decode.string)
  use centre_id <- decode.field("centre_id", decode.string)
  use channel <- decode.field("channel", decode.string)
  use pubtime <- decode.field("pubtime", decode.string)
  use datetime <- decode.optional_field(
    "datetime",
    None,
    decode.optional(decode.string),
  )
  use license_url <- decode.optional_field(
    "license_url",
    None,
    decode.optional(decode.string),
  )
  use fetched_via <- decode.field("fetched_via", decode.string)
  use download_url <- decode.optional_field(
    "download_url",
    None,
    decode.optional(decode.string),
  )
  use raw_xml <- decode.optional_field("raw_xml", "", decode.string)
  use cap_dyn <- decode.optional_field(
    "cap",
    None,
    decode.optional(decode.dynamic),
  )
  use area_key <- decode.optional_field(
    "area_key",
    None,
    decode.optional(decode.string),
  )
  use area_geometry <- decode.optional_field(
    "area_geometry",
    None,
    area_geometry_decoder(),
  )
  use area_precision_opt <- decode.optional_field(
    "area_precision",
    None,
    area_precision_decoder(),
  )

  let cap = case cap_dyn {
    Some(dyn) ->
      case models_cap.decode_cap(dyn) {
        Ok(msg) -> Some(msg)
        Error(_) -> None
      }
    None -> None
  }

  let area_precision = case area_precision_opt {
    Some(p) -> Some(p)
    None ->
      case area_geometry {
        Some(_) -> Some(Exact)
        None -> None
      }
  }

  decode.success(Wis2CapFeature(
    notification_id: string.trim(notification_id),
    data_id: string.trim(data_id),
    topic: string.trim(topic),
    centre_id: string.trim(centre_id),
    channel: string.trim(channel),
    pubtime: string.trim(pubtime),
    datetime: option.map(datetime, string.trim),
    license_url: option.map(license_url, string.trim),
    fetched_via: string.trim(fetched_via),
    download_url: option.map(download_url, string.trim),
    raw_xml:,
    cap:,
    area_key: option.map(area_key, string.trim),
    area_geometry:,
    area_precision:,
  ))
}

fn health_feature_decoder() -> decode.Decoder(Wis2HealthFeature) {
  use centre_id <- decode.field("centre_id", decode.string)
  use kind <- decode.field("kind", decode.string)
  use window_start <- decode.field("window_start", decode.string)
  use window_end <- decode.field("window_end", decode.string)
  use received <- decode.field("received", decode.int)
  use duplicates <- decode.field("duplicates", decode.int)
  use download_failed <- decode.field("download_failed", decode.int)
  use decode_failed <- decode.field("decode_failed", decode.int)
  use integrity_failed <- decode.field("integrity_failed", decode.int)
  use last_received_at <- decode.optional_field(
    "last_received_at",
    None,
    decode.optional(decode.string),
  )
  decode.success(Wis2HealthFeature(
    centre_id: string.trim(centre_id),
    kind: string.trim(kind),
    window_start: string.trim(window_start),
    window_end: string.trim(window_end),
    received:,
    duplicates:,
    download_failed:,
    decode_failed:,
    integrity_failed:,
    last_received_at: option.map(last_received_at, string.trim),
  ))
}

pub fn broker_to_json(b: BrokerState) -> json.Json {
  json.object([
    #("url", json.string(b.url)),
    #("connected", json.bool(b.connected)),
    #(
      "last_report_at",
      json.nullable(b.last_report_at, fn(t) {
        json.string(timestamp.to_rfc3339(t, calendar.utc_offset))
      }),
    ),
    #("error", json.nullable(b.error, json.string)),
  ])
}

pub fn channel_health_to_json(ch: ChannelHealth) -> json.Json {
  json.object([
    #("centre_id", json.string(ch.centre_id)),
    #("kind", json.string(ch.kind)),
    #("received_24h", json.int(ch.received_24h)),
    #("duplicates_24h", json.int(ch.duplicates_24h)),
    #("download_failed_24h", json.int(ch.download_failed_24h)),
    #("decode_failed_24h", json.int(ch.decode_failed_24h)),
    #("integrity_failed_24h", json.int(ch.integrity_failed_24h)),
    #(
      "last_received_at",
      json.nullable(ch.last_received_at, fn(t) {
        json.string(timestamp.to_rfc3339(t, calendar.utc_offset))
      }),
    ),
    #("status", json.string(channel_status_to_string(ch.status))),
  ])
}

pub fn health_report_to_json(
  broker: BrokerState,
  channels: List(ChannelHealth),
) -> json.Json {
  json.object([
    #("broker", broker_to_json(broker)),
    #("channels", json.array(channels, channel_health_to_json)),
  ])
}

fn num_decoder() -> decode.Decoder(Float) {
  decode.one_of(decode.float, or: [decode.int |> decode.map(int.to_float)])
}

pub fn wind_radii_decoder() -> decode.Decoder(WindRadii) {
  use threshold_ms <- decode.field("threshold_ms", num_decoder())
  use radii_m <- decode.optional_field(
    "radii_m",
    [],
    decode.list(decode.optional(num_decoder())),
  )
  decode.success(WindRadii(threshold_ms:, radii_m:))
}

pub fn forecast_point_decoder() -> decode.Decoder(ForecastPoint) {
  use lead_hours <- decode.field("lead_hours", decode.int)
  use time <- decode.field("time", decode.string)
  use lat <- decode.field("lat", num_decoder())
  use lon <- decode.field("lon", num_decoder())
  use mslp_pa <- decode.optional_field(
    "mslp_pa",
    None,
    decode.optional(num_decoder()),
  )
  use max_wind_ms <- decode.optional_field(
    "max_wind_ms",
    None,
    decode.optional(num_decoder()),
  )
  use max_wind_lat <- decode.optional_field(
    "max_wind_lat",
    None,
    decode.optional(num_decoder()),
  )
  use max_wind_lon <- decode.optional_field(
    "max_wind_lon",
    None,
    decode.optional(num_decoder()),
  )
  use wind_radii <- decode.optional_field(
    "wind_radii",
    [],
    decode.list(wind_radii_decoder()),
  )
  decode.success(ForecastPoint(
    lead_hours:,
    time: string.trim(time),
    lat:,
    lon:,
    mslp_pa:,
    max_wind_ms:,
    max_wind_lat:,
    max_wind_lon:,
    wind_radii:,
  ))
}

pub fn points_decoder() -> decode.Decoder(List(ForecastPoint)) {
  decode.list(forecast_point_decoder())
}

pub fn tc_feature_decoder() -> decode.Decoder(Wis2TcFeature) {
  use notification_id <- decode.field("notification_id", decode.string)
  use data_id <- decode.field("data_id", decode.string)
  use topic <- decode.field("topic", decode.string)
  use centre_id <- decode.field("centre_id", decode.string)
  use channel <- decode.field("channel", decode.string)
  use pubtime <- decode.field("pubtime", decode.string)
  use fetched_via <- decode.field("fetched_via", decode.string)
  use download_url <- decode.optional_field(
    "download_url",
    None,
    decode.optional(decode.string),
  )
  use message_index <- decode.field("message_index", decode.int)
  use originating_centre <- decode.field("originating_centre", decode.int)
  use storm_id <- decode.field("storm_id", decode.string)
  use storm_name_opt <- decode.optional_field(
    "storm_name",
    None,
    decode.optional(decode.string),
  )
  use ensemble_member <- decode.optional_field(
    "ensemble_member",
    None,
    decode.optional(decode.int),
  )
  use analysis_time <- decode.field("analysis_time", decode.string)
  use points <- decode.field("points", decode.list(forecast_point_decoder()))

  let trimmed_storm_id = string.trim(storm_id)
  let trimmed_storm_name = case storm_name_opt {
    Some(n) ->
      case string.trim(n) {
        "" -> None
        name -> Some(name)
      }
    None -> None
  }

  case trimmed_storm_id != "" && !list.is_empty(points) {
    True ->
      decode.success(Wis2TcFeature(
        notification_id: string.trim(notification_id),
        data_id: string.trim(data_id),
        topic: string.trim(topic),
        centre_id: string.trim(centre_id),
        channel: string.trim(channel),
        pubtime: string.trim(pubtime),
        fetched_via: string.trim(fetched_via),
        download_url: option.map(download_url, string.trim),
        message_index:,
        originating_centre:,
        storm_id: trimmed_storm_id,
        storm_name: trimmed_storm_name,
        ensemble_member:,
        analysis_time: string.trim(analysis_time),
        points:,
      ))
    False ->
      decode.failure(
        Wis2TcFeature(
          "",
          "",
          "",
          "",
          "",
          "",
          "",
          None,
          0,
          0,
          "",
          None,
          None,
          "",
          [],
        ),
        "Wis2TcFeature with non-empty points",
      )
  }
}

pub fn decode_tc_tracks_body(
  data: Dynamic,
) -> Result(#(Option(Wis2PollMeta), List(Wis2TcFeature), Int, Int), String) {
  let decoder = {
    use poll_meta <- decode.optional_field(
      "poll_meta",
      None,
      decode.optional(poll_meta_decoder()),
    )
    use raw <- decode.field("features", decode.list(decode.dynamic))
    decode.success(#(poll_meta, raw))
  }
  case decode.run(data, decoder) {
    Ok(#(poll_meta, raw)) -> {
      let items =
        raw
        |> list.filter_map(fn(x) {
          case decode.run(x, tc_feature_decoder()) {
            Ok(item) -> Ok(item)
            Error(_) -> Error(Nil)
          }
        })
      let received = list.length(raw)
      let dropped = received - list.length(items)
      Ok(#(poll_meta, items, received, dropped))
    }
    Error(errors) -> Error(string.inspect(errors))
  }
}

pub fn analysis_year(analysis_time: String) -> String {
  case string.split_once(analysis_time, "-") {
    Ok(#(year, _)) -> year
    Error(Nil) -> "2026"
  }
}

pub fn tc_hazard_source_id(storm_id: String, analysis_time: String) -> String {
  storm_id <> "/" <> analysis_year(analysis_time)
}

pub fn max_wind_from_points(points: List(ForecastPoint)) -> Option(Float) {
  list.fold(points, None, fn(acc, pt) {
    case pt.max_wind_ms {
      Some(w) ->
        case acc {
          Some(curr) if curr >=. w -> acc
          _ -> Some(w)
        }
      None -> acc
    }
  })
}

pub fn calculate_alert_level(points: List(ForecastPoint)) -> String {
  case max_wind_from_points(points) {
    Some(w) if w >=. 50.0 -> "red"
    Some(w) if w >=. 33.0 -> "orange"
    _ -> "green"
  }
}

pub fn points_to_bbox(
  points: List(ForecastPoint),
) -> Option(#(Float, Float, Float, Float)) {
  case points {
    [] -> None
    [first, ..rest] -> {
      let #(min_lon, min_lat, max_lon, max_lat) =
        list.fold(
          rest,
          #(first.lon, first.lat, first.lon, first.lat),
          fn(acc, pt) {
            #(
              float.min(acc.0, pt.lon),
              float.min(acc.1, pt.lat),
              float.max(acc.2, pt.lon),
              float.max(acc.3, pt.lat),
            )
          },
        )
      case min_lon != max_lon || min_lat != max_lat {
        True -> Some(#(min_lon, min_lat, max_lon, max_lat))
        False -> None
      }
    }
  }
}

pub fn points_to_centroid(points: List(ForecastPoint)) -> #(Float, Float) {
  case points {
    [first, ..] -> #(first.lon, first.lat)
    [] -> #(0.0, 0.0)
  }
}

pub fn points_to_linestring_geojson(
  points: List(ForecastPoint),
) -> Option(String) {
  case points {
    [_, _, ..] -> {
      let coords =
        list.map(points, fn(p) { json.array([p.lon, p.lat], json.float) })
      Some(
        json.to_string(
          json.object([
            #("type", json.string("LineString")),
            #("coordinates", json.array(coords, fn(x) { x })),
          ]),
        ),
      )
    }
    _ -> None
  }
}

pub fn track_to_feature_collection_geojson(
  storm_id: String,
  storm_name: Option(String),
  analysis_time: String,
  points: List(ForecastPoint),
) -> Option(String) {
  case points_to_linestring_geojson(points) {
    Some(geom_text) -> {
      let props = [
        #("storm_id", json.string(storm_id)),
        #("storm_name", json.nullable(storm_name, json.string)),
        #("analysis_time", json.string(analysis_time)),
      ]
      let feature =
        json.object([
          #("type", json.string("Feature")),
          #("geometry", raw_json.json(geom_text)),
          #("properties", json.object(props)),
        ])
      Some(
        json.to_string(
          json.object([
            #("type", json.string("FeatureCollection")),
            #("features", json.array([feature], fn(x) { x })),
          ]),
        ),
      )
    }
    None -> None
  }
}

pub fn wind_radii_to_json(wr: WindRadii) -> json.Json {
  json.object([
    #("threshold_ms", json.float(wr.threshold_ms)),
    #("radii_m", json.array(wr.radii_m, fn(r) { json.nullable(r, json.float) })),
  ])
}

pub fn forecast_point_to_json(pt: ForecastPoint) -> json.Json {
  json.object([
    #("lead_hours", json.int(pt.lead_hours)),
    #("time", json.string(pt.time)),
    #("lat", json.float(pt.lat)),
    #("lon", json.float(pt.lon)),
    #("mslp_pa", json.nullable(pt.mslp_pa, json.float)),
    #("max_wind_ms", json.nullable(pt.max_wind_ms, json.float)),
    #("max_wind_lat", json.nullable(pt.max_wind_lat, json.float)),
    #("max_wind_lon", json.nullable(pt.max_wind_lon, json.float)),
    #("wind_radii", json.array(pt.wind_radii, wind_radii_to_json)),
  ])
}

pub fn forecast_track_to_json(track: ForecastTrack) -> json.Json {
  json.object([
    #("source", json.string(track.source)),
    #("centre_id", json.string(track.centre_id)),
    #("storm_id", json.string(track.storm_id)),
    #("storm_name", json.nullable(track.storm_name, json.string)),
    #("analysis_time", json.string(track.analysis_time)),
    #("points", json.array(track.points, forecast_point_to_json)),
  ])
}
