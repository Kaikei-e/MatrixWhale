import domain/hazard.{type Hazard}
import domain/wis2.{type Wis2PollMeta}
import domain/wis2_matcher
import dot_env/env
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

pub const hazard_type_observed_extreme = "observed_extreme"

pub type ObservationSubtype {
  SubtypeWind
  SubtypeGust
  SubtypeRain1h
  SubtypeRain24h
  SubtypeLowPressure
}

pub fn subtype_to_string(s: ObservationSubtype) -> String {
  case s {
    SubtypeWind -> "wind"
    SubtypeGust -> "gust"
    SubtypeRain1h -> "rain_1h"
    SubtypeRain24h -> "rain_24h"
    SubtypeLowPressure -> "low_pressure"
  }
}

pub fn subtype_from_string(s: String) -> Result(ObservationSubtype, Nil) {
  case string.trim(s) {
    "wind" -> Ok(SubtypeWind)
    "gust" -> Ok(SubtypeGust)
    "rain_1h" -> Ok(SubtypeRain1h)
    "rain_24h" -> Ok(SubtypeRain24h)
    "low_pressure" -> Ok(SubtypeLowPressure)
    _ -> Error(Nil)
  }
}

pub type Wis2Precip {
  Wis2Precip(period_h: Float, mm: Float)
}

pub type Wis2ObservationFeature {
  Wis2ObservationFeature(
    data_id: String,
    centre_id: String,
    pubtime: String,
    station_id: String,
    station_name: Option(String),
    lat: Float,
    lon: Float,
    elevation_m: Option(Float),
    observed_at: String,
    wind_speed_ms: Option(Float),
    gust_ms: Option(Float),
    gust_period_min: Option(Int),
    precip: List(Wis2Precip),
    mslp_pa: Option(Float),
  )
}

pub type ObservationThresholds {
  ObservationThresholds(
    wind_ms: Float,
    gust_ms: Float,
    rain_1h_mm: Float,
    rain_24h_mm: Float,
    mslp_hpa: Float,
  )
}

pub fn default_thresholds() -> ObservationThresholds {
  ObservationThresholds(
    wind_ms: 20.0,
    gust_ms: 30.0,
    rain_1h_mm: 50.0,
    rain_24h_mm: 150.0,
    mslp_hpa: 970.0,
  )
}

pub fn thresholds_with_lookup(
  lookup: fn(String) -> Result(String, Nil),
) -> ObservationThresholds {
  let defaults = default_thresholds()
  ObservationThresholds(
    wind_ms: get_float_with(lookup, "WIS2_OBS_WIND_MS", defaults.wind_ms),
    gust_ms: get_float_with(lookup, "WIS2_OBS_GUST_MS", defaults.gust_ms),
    rain_1h_mm: get_float_with(
      lookup,
      "WIS2_OBS_RAIN_1H_MM",
      defaults.rain_1h_mm,
    ),
    rain_24h_mm: get_float_with(
      lookup,
      "WIS2_OBS_RAIN_24H_MM",
      defaults.rain_24h_mm,
    ),
    mslp_hpa: get_float_with(lookup, "WIS2_OBS_MSLP_HPA", defaults.mslp_hpa),
  )
}

pub fn thresholds_from_env() -> ObservationThresholds {
  thresholds_with_lookup(fn(key) {
    env.get_string(key) |> result.replace_error(Nil)
  })
}

fn get_float_with(
  lookup: fn(String) -> Result(String, Nil),
  key: String,
  default: Float,
) -> Float {
  case lookup(key) {
    Ok(val) ->
      case float.parse(string.trim(val)) {
        Ok(f) -> f
        Error(_) -> default
      }
    Error(_) -> default
  }
}

pub fn is_plausible_wind(w: Float) -> Bool {
  w >=. 0.0 && w <=. 110.0
}

pub fn is_plausible_gust(g: Float) -> Bool {
  g >=. 0.0 && g <=. 110.0
}

pub fn is_plausible_precip_1h(r: Float) -> Bool {
  r >=. 0.0 && r <=. 400.0
}

pub fn is_plausible_precip_24h(r: Float) -> Bool {
  r >=. 0.0 && r <=. 1850.0
}

pub fn is_plausible_mslp_hpa(p: Float) -> Bool {
  p >=. 870.0 && p <=. 1090.0
}

pub fn is_plausible_gust_period(m: Int) -> Bool {
  m >= 1 && m <= 1440
}

pub fn is_corrupt_station_name(name: String) -> Bool {
  let codepoints =
    string.to_utf_codepoints(name)
    |> list.map(string.utf_codepoint_to_int)

  list.any(codepoints, fn(cp) {
    cp == 65_533 || cp < 32 || cp == 127 || { cp >= 128 && cp <= 159 }
  })
}

pub fn is_plausible_station_name(name: Option(String)) -> Bool {
  case name {
    Some(n) -> !is_corrupt_station_name(n)
    None -> True
  }
}

pub fn is_plausible_precip_period(period_h: Float) -> Bool {
  period_h == 1.0
  || period_h == 2.0
  || period_h == 3.0
  || period_h == 6.0
  || period_h == 9.0
  || period_h == 12.0
  || period_h == 15.0
  || period_h == 18.0
  || period_h == 24.0
}

pub fn is_plausible_precip_amount(period_h: Float, mm: Float) -> Bool {
  case mm >=. 0.0 {
    False -> False
    True ->
      case period_h == 1.0 {
        True -> mm <=. 400.0
        False -> mm <=. 1850.0
      }
  }
}

pub fn is_plausible_observation(feature: Wis2ObservationFeature) -> Bool {
  let station_name_ok = is_plausible_station_name(feature.station_name)
  let wind_ok = case feature.wind_speed_ms {
    Some(w) -> is_plausible_wind(w)
    None -> True
  }
  let gust_ok = case feature.gust_ms {
    Some(g) -> is_plausible_gust(g)
    None -> True
  }
  let gust_period_ok = case feature.gust_period_min {
    Some(m) -> is_plausible_gust_period(m)
    None -> True
  }
  let precip_ok =
    list.all(feature.precip, fn(p) {
      is_plausible_precip_period(p.period_h)
      && is_plausible_precip_amount(p.period_h, p.mm)
    })
  let mslp_ok = case feature.mslp_pa {
    Some(pa) -> is_plausible_mslp_hpa(pa /. 100.0)
    None -> True
  }

  station_name_ok
  && wind_ok
  && gust_ok
  && gust_period_ok
  && precip_ok
  && mslp_ok
}

pub type PlausibleObservation {
  PlausibleObservation(
    data_id: String,
    centre_id: String,
    pubtime: String,
    station_id: String,
    station_name: Option(String),
    lat: Float,
    lon: Float,
    elevation_m: Option(Float),
    observed_at: String,
    observed_at_ms: Int,
    wind_speed_ms: Option(Float),
    gust_ms: Option(Float),
    precip_1h_mm: Option(Float),
    precip_24h_mm: Option(Float),
    mslp_hpa: Option(Float),
  )
}

pub fn filter_plausible(
  feature: Wis2ObservationFeature,
  observed_at_ms: Int,
) -> Result(PlausibleObservation, Nil) {
  case is_plausible_observation(feature) {
    False -> Error(Nil)
    True -> {
      let precip_1h_mm =
        list.find(feature.precip, fn(p) { p.period_h == 1.0 })
        |> result.map(fn(p) { p.mm })
        |> option.from_result

      let precip_24h_mm =
        list.find(feature.precip, fn(p) { p.period_h == 24.0 })
        |> result.map(fn(p) { p.mm })
        |> option.from_result

      let mslp_hpa = option.map(feature.mslp_pa, fn(pa) { pa /. 100.0 })

      Ok(PlausibleObservation(
        data_id: feature.data_id,
        centre_id: feature.centre_id,
        pubtime: feature.pubtime,
        station_id: feature.station_id,
        station_name: feature.station_name,
        lat: feature.lat,
        lon: feature.lon,
        elevation_m: feature.elevation_m,
        observed_at: feature.observed_at,
        observed_at_ms:,
        wind_speed_ms: feature.wind_speed_ms,
        gust_ms: feature.gust_ms,
        precip_1h_mm:,
        precip_24h_mm:,
        mslp_hpa:,
      ))
    }
  }
}

pub type Exceedance {
  Exceedance(
    subtype: ObservationSubtype,
    value: Float,
    unit: String,
    label: String,
  )
}

pub fn detect_exceedances(
  obs: PlausibleObservation,
  thresholds: ObservationThresholds,
) -> List(Exceedance) {
  let wind_exceedance = case obs.wind_speed_ms {
    Some(w) if w >=. thresholds.wind_ms -> [
      Exceedance(
        subtype: SubtypeWind,
        value: round_to_one_decimal(w),
        unit: "m/s",
        label: "Wind Speed",
      ),
    ]
    _ -> []
  }

  let gust_exceedance = case obs.gust_ms {
    Some(g) if g >=. thresholds.gust_ms -> [
      Exceedance(
        subtype: SubtypeGust,
        value: round_to_one_decimal(g),
        unit: "m/s",
        label: "Gust",
      ),
    ]
    _ -> []
  }

  let rain_1h_exceedance = case obs.precip_1h_mm {
    Some(r) if r >=. thresholds.rain_1h_mm -> [
      Exceedance(
        subtype: SubtypeRain1h,
        value: round_to_one_decimal(r),
        unit: "mm",
        label: "1h Precipitation",
      ),
    ]
    _ -> []
  }

  let rain_24h_exceedance = case obs.precip_24h_mm {
    Some(r) if r >=. thresholds.rain_24h_mm -> [
      Exceedance(
        subtype: SubtypeRain24h,
        value: round_to_one_decimal(r),
        unit: "mm",
        label: "24h Precipitation",
      ),
    ]
    _ -> []
  }

  let mslp_exceedance = case obs.mslp_hpa {
    Some(p) if p <=. thresholds.mslp_hpa -> [
      Exceedance(
        subtype: SubtypeLowPressure,
        value: round_to_one_decimal(p),
        unit: "hPa",
        label: "Mean Sea Level Pressure",
      ),
    ]
    _ -> []
  }

  list.flatten([
    wind_exceedance,
    gust_exceedance,
    rain_1h_exceedance,
    rain_24h_exceedance,
    mslp_exceedance,
  ])
}

pub type StationNeighbour {
  StationNeighbour(
    station_id: String,
    lat: Float,
    lon: Float,
    wind_speed_ms: Option(Float),
    wind_observed_at_ms: Option(Int),
    gust_ms: Option(Float),
    gust_observed_at_ms: Option(Int),
    precip_1h_mm: Option(Float),
    precip_1h_observed_at_ms: Option(Int),
    precip_24h_mm: Option(Float),
    precip_24h_observed_at_ms: Option(Int),
    mslp_hpa: Option(Float),
    mslp_observed_at_ms: Option(Int),
  )
}

pub fn is_corroborated(
  station_id: String,
  obs_lat: Float,
  obs_lon: Float,
  obs_time_ms: Int,
  subtype: ObservationSubtype,
  thresholds: ObservationThresholds,
  candidates: List(StationNeighbour),
) -> Bool {
  let three_hours_ms = 3 * 3600 * 1000
  list.any(candidates, fn(candidate) {
    case candidate.station_id == station_id {
      True -> False
      False -> {
        let dist =
          wis2_matcher.great_circle_distance_km(
            obs_lat,
            obs_lon,
            candidate.lat,
            candidate.lon,
          )
        case dist <=. 150.0 {
          False -> False
          True ->
            check_candidate_element(
              candidate,
              subtype,
              obs_time_ms,
              three_hours_ms,
              thresholds,
            )
        }
      }
    }
  })
}

fn check_candidate_element(
  candidate: StationNeighbour,
  subtype: ObservationSubtype,
  obs_time_ms: Int,
  window_ms: Int,
  thresholds: ObservationThresholds,
) -> Bool {
  case subtype {
    SubtypeWind ->
      case candidate.wind_speed_ms, candidate.wind_observed_at_ms {
        Some(w), Some(t) ->
          int.absolute_value(obs_time_ms - t) <= window_ms
          && w >=. 0.7 *. thresholds.wind_ms
        _, _ -> False
      }
    SubtypeGust ->
      case candidate.gust_ms, candidate.gust_observed_at_ms {
        Some(g), Some(t) ->
          int.absolute_value(obs_time_ms - t) <= window_ms
          && g >=. 0.7 *. thresholds.gust_ms
        _, _ -> False
      }
    SubtypeRain1h ->
      case candidate.precip_1h_mm, candidate.precip_1h_observed_at_ms {
        Some(r), Some(t) ->
          int.absolute_value(obs_time_ms - t) <= window_ms
          && r >=. 0.7 *. thresholds.rain_1h_mm
        _, _ -> False
      }
    SubtypeRain24h ->
      case candidate.precip_24h_mm, candidate.precip_24h_observed_at_ms {
        Some(r), Some(t) ->
          int.absolute_value(obs_time_ms - t) <= window_ms
          && r >=. 0.7 *. thresholds.rain_24h_mm
        _, _ -> False
      }
    SubtypeLowPressure ->
      case candidate.mslp_hpa, candidate.mslp_observed_at_ms {
        Some(p), Some(t) ->
          int.absolute_value(obs_time_ms - t) <= window_ms
          && p <=. thresholds.mslp_hpa +. 10.0
        _, _ -> False
      }
  }
}

pub fn can_merge(hazard: Hazard, obs_time_ms: Int) -> Bool {
  let three_hours_ms = 3 * 3600 * 1000
  hazard.is_current
  && obs_time_ms <= hazard.modified_at_ms + three_hours_ms
  && obs_time_ms >= hazard.onset_at_ms - three_hours_ms
}

pub fn round_to_one_decimal(val: Float) -> Float {
  let rounded_int = float.round(val *. 10.0)
  int.to_float(rounded_int) /. 10.0
}

pub fn format_one_decimal(val: Float) -> String {
  let scaled = float.round(val *. 10.0)
  let whole = int.absolute_value(scaled) / 10
  let frac = int.absolute_value(scaled) % 10
  let sign = case scaled < 0 {
    True -> "-"
    False -> ""
  }
  sign <> int.to_string(whole) <> "." <> int.to_string(frac)
}

pub fn format_float(val: Float) -> String {
  format_one_decimal(val)
}

pub fn merge_severity_value(
  subtype: ObservationSubtype,
  current: Float,
  new: Float,
) -> Float {
  let v = case subtype {
    SubtypeLowPressure -> float.min(current, new)
    _ -> float.max(current, new)
  }
  round_to_one_decimal(v)
}

pub fn format_station_label(
  station_id: String,
  station_name: Option(String),
) -> String {
  case station_name {
    Some(name) -> {
      let trimmed = string.trim(name)
      case trimmed {
        "" -> station_id
        _ -> trimmed
      }
    }
    None -> station_id
  }
}

pub fn format_title(
  subtype: ObservationSubtype,
  value: Float,
  station_id: String,
  station_name: Option(String),
) -> String {
  let target = format_station_label(station_id, station_name)
  case subtype {
    SubtypeWind -> "Wind " <> format_one_decimal(value) <> " m/s at " <> target
    SubtypeGust -> "Gust " <> format_one_decimal(value) <> " m/s at " <> target
    SubtypeRain1h ->
      "Rain 1h " <> format_one_decimal(value) <> " mm at " <> target
    SubtypeRain24h ->
      "Rain 24h " <> format_one_decimal(value) <> " mm at " <> target
    SubtypeLowPressure ->
      "MSLP " <> int.to_string(float.round(value)) <> " hPa at " <> target
  }
}

pub type EpisodeAction {
  ActionIgnore
  ActionEndExisting
  ActionExtend(merged_value: Float, title: String, confirmed: Bool)
  ActionEndAndCreate(title: String, confirmed: Bool)
  ActionCreate(title: String, confirmed: Bool)
}

pub fn decide_episode_action(
  subtype: ObservationSubtype,
  obs_value: Float,
  obs_time_ms: Int,
  station_id: String,
  station_name: Option(String),
  is_confirmed: Bool,
  active_opt: Option(Hazard),
) -> EpisodeAction {
  case subtype, is_confirmed {
    SubtypeLowPressure, False ->
      case active_opt {
        Some(active) ->
          case option.unwrap(active.confirmed, False) {
            False -> ActionEndExisting
            True ->
              case can_merge(active, obs_time_ms) {
                True -> {
                  let current_val =
                    option.unwrap(active.severity_value, obs_value)
                  let merged_val =
                    merge_severity_value(subtype, current_val, obs_value)
                  let title =
                    format_title(subtype, merged_val, station_id, station_name)
                  ActionExtend(
                    merged_value: merged_val,
                    title: title,
                    confirmed: True,
                  )
                }
                False -> ActionEndExisting
              }
          }
        None -> ActionIgnore
      }

    SubtypeLowPressure, True ->
      case active_opt {
        Some(active) ->
          case can_merge(active, obs_time_ms) {
            True -> {
              let current_val = option.unwrap(active.severity_value, obs_value)
              let merged_val =
                merge_severity_value(subtype, current_val, obs_value)
              let title =
                format_title(subtype, merged_val, station_id, station_name)
              ActionExtend(
                merged_value: merged_val,
                title: title,
                confirmed: True,
              )
            }
            False -> {
              let rounded_val = round_to_one_decimal(obs_value)
              let title =
                format_title(subtype, rounded_val, station_id, station_name)
              ActionEndAndCreate(title: title, confirmed: True)
            }
          }
        None -> {
          let rounded_val = round_to_one_decimal(obs_value)
          let title =
            format_title(subtype, rounded_val, station_id, station_name)
          ActionCreate(title: title, confirmed: True)
        }
      }

    _, _ ->
      case active_opt {
        Some(active) ->
          case can_merge(active, obs_time_ms) {
            True -> {
              let current_val = option.unwrap(active.severity_value, obs_value)
              let merged_val =
                merge_severity_value(subtype, current_val, obs_value)
              let title =
                format_title(subtype, merged_val, station_id, station_name)
              let confirmed =
                option.unwrap(active.confirmed, False) || is_confirmed
              ActionExtend(
                merged_value: merged_val,
                title: title,
                confirmed: confirmed,
              )
            }
            False -> {
              let rounded_val = round_to_one_decimal(obs_value)
              let title =
                format_title(subtype, rounded_val, station_id, station_name)
              ActionEndAndCreate(title: title, confirmed: is_confirmed)
            }
          }
        None -> {
          let rounded_val = round_to_one_decimal(obs_value)
          let title =
            format_title(subtype, rounded_val, station_id, station_name)
          ActionCreate(title: title, confirmed: is_confirmed)
        }
      }
  }
}

pub fn episode_source_id(
  station_id: String,
  subtype: ObservationSubtype,
  onset_at_sec: Int,
) -> String {
  station_id
  <> "/"
  <> subtype_to_string(subtype)
  <> "/"
  <> int.to_string(onset_at_sec)
}

pub fn point_geojson(lon: Float, lat: Float) -> String {
  json.to_string(
    json.object([
      #("type", json.string("Point")),
      #("coordinates", json.array([lon, lat], json.float)),
    ]),
  )
}

pub fn episode_feature_collection_geojson(
  station_id: String,
  station_name: Option(String),
  subtype: ObservationSubtype,
  value: Float,
  unit: String,
  lon: Float,
  lat: Float,
) -> String {
  let geom_json = point_geojson(lon, lat)
  let props = [
    #("station_id", json.string(station_id)),
    #("station_name", json.nullable(station_name, json.string)),
    #("subtype", json.string(subtype_to_string(subtype))),
    #("severity_value", json.float(value)),
    #("severity_unit", json.string(unit)),
  ]
  let feature =
    json.object([
      #("type", json.string("Feature")),
      #("geometry", raw_json.json(geom_json)),
      #("properties", json.object(props)),
    ])
  json.to_string(
    json.object([
      #("type", json.string("FeatureCollection")),
      #("features", json.array([feature], fn(x) { x })),
    ]),
  )
}

fn num_decoder() -> decode.Decoder(Float) {
  decode.one_of(decode.float, or: [decode.int |> decode.map(int.to_float)])
}

pub fn precip_decoder() -> decode.Decoder(Wis2Precip) {
  use period_h <- decode.field("period_h", num_decoder())
  use mm <- decode.field("mm", num_decoder())
  decode.success(Wis2Precip(period_h:, mm:))
}

pub fn observation_feature_decoder() -> decode.Decoder(Wis2ObservationFeature) {
  use data_id <- decode.field("data_id", decode.string)
  use centre_id <- decode.field("centre_id", decode.string)
  use pubtime <- decode.field("pubtime", decode.string)
  use station_id <- decode.field("station_id", decode.string)
  use station_name <- decode.optional_field(
    "station_name",
    None,
    decode.optional(decode.string),
  )
  use lat <- decode.field("lat", num_decoder())
  use lon <- decode.field("lon", num_decoder())
  use elevation_m <- decode.optional_field(
    "elevation_m",
    None,
    decode.optional(num_decoder()),
  )
  use observed_at <- decode.field("observed_at", decode.string)
  use wind_speed_ms <- decode.optional_field(
    "wind_speed_ms",
    None,
    decode.optional(num_decoder()),
  )
  use gust_ms <- decode.optional_field(
    "gust_ms",
    None,
    decode.optional(num_decoder()),
  )
  use gust_period_min <- decode.optional_field(
    "gust_period_min",
    None,
    decode.optional(decode.int),
  )
  use precip <- decode.optional_field(
    "precip",
    [],
    decode.list(precip_decoder()),
  )
  use mslp_pa <- decode.optional_field(
    "mslp_pa",
    None,
    decode.optional(num_decoder()),
  )

  let trimmed_station_id = string.trim(station_id)
  let trimmed_station_name = case station_name {
    Some(name) ->
      case string.trim(name) {
        "" -> None
        t -> Some(t)
      }
    None -> None
  }

  decode.success(Wis2ObservationFeature(
    data_id: string.trim(data_id),
    centre_id: string.trim(centre_id),
    pubtime: string.trim(pubtime),
    station_id: trimmed_station_id,
    station_name: trimmed_station_name,
    lat:,
    lon:,
    elevation_m:,
    observed_at: string.trim(observed_at),
    wind_speed_ms:,
    gust_ms:,
    gust_period_min:,
    precip:,
    mslp_pa:,
  ))
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
  decode.success(wis2.Wis2PollMeta(
    feed_url: option.map(feed_url, string.trim),
    error: option.map(error, string.trim),
  ))
}

pub fn decode_observations_body(
  data: Dynamic,
) -> Result(
  #(Option(Wis2PollMeta), List(Wis2ObservationFeature), Int, Int),
  String,
) {
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
          case decode.run(x, observation_feature_decoder()) {
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

pub fn observation_feature_to_json(
  feature: Wis2ObservationFeature,
) -> json.Json {
  json.object([
    #("data_id", json.string(feature.data_id)),
    #("centre_id", json.string(feature.centre_id)),
    #("pubtime", json.string(feature.pubtime)),
    #("station_id", json.string(feature.station_id)),
    #("station_name", json.nullable(feature.station_name, json.string)),
    #("lat", json.float(feature.lat)),
    #("lon", json.float(feature.lon)),
    #("elevation_m", json.nullable(feature.elevation_m, json.float)),
    #("observed_at", json.string(feature.observed_at)),
    #("wind_speed_ms", json.nullable(feature.wind_speed_ms, json.float)),
    #("gust_ms", json.nullable(feature.gust_ms, json.float)),
    #("gust_period_min", json.nullable(feature.gust_period_min, json.int)),
    #(
      "precip",
      json.array(feature.precip, fn(p) {
        json.object([
          #("period_h", json.float(p.period_h)),
          #("mm", json.float(p.mm)),
        ])
      }),
    ),
    #("mslp_pa", json.nullable(feature.mslp_pa, json.float)),
  ])
}

pub fn observations_envelope_to_json(
  features: List(Wis2ObservationFeature),
) -> json.Json {
  json.object([
    #(
      "poll_meta",
      json.object([
        #("feed_url", json.string("mqtts://wis2.example.org:8883")),
        #("error", json.null()),
      ]),
    ),
    #("features", json.array(features, observation_feature_to_json)),
  ])
}
