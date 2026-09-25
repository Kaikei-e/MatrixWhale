import domain/hazard.{type Hazard}
import domain/wis2.{type ForecastTrack}
import gleam/dict
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/string

const pi = 3.141592653589793

const earth_radius_km = 6371.0

const match_distance_km = 300.0

const match_window_hours = 12

const prefixes = [
  "severe tropical cyclone ", "tropical cyclone ", "tropical storm ",
  "super typhoon ", "cyclone ", "typhoon ", "hurricane ", "tc ", "ts ",
]

@external(erlang, "math", "sin")
fn erl_sin(x: Float) -> Float

@external(erlang, "math", "cos")
fn erl_cos(x: Float) -> Float

@external(erlang, "math", "atan2")
fn erl_atan2(y: Float, x: Float) -> Float

fn deg_to_rad(deg: Float) -> Float {
  deg *. pi /. 180.0
}

pub fn great_circle_distance_km(
  lat1: Float,
  lon1: Float,
  lat2: Float,
  lon2: Float,
) -> Float {
  let d_lat = deg_to_rad(lat2 -. lat1)
  let d_lon = deg_to_rad(lon2 -. lon1)
  let r_lat1 = deg_to_rad(lat1)
  let r_lat2 = deg_to_rad(lat2)

  let sin_half_dlat = erl_sin(d_lat /. 2.0)
  let sin_half_dlon = erl_sin(d_lon /. 2.0)

  let a =
    sin_half_dlat
    *. sin_half_dlat
    +. erl_cos(r_lat1)
    *. erl_cos(r_lat2)
    *. sin_half_dlon
    *. sin_half_dlon
  let a_clamped = float.clamp(a, 0.0, 1.0)
  let root_a = case float.square_root(a_clamped) {
    Ok(v) -> v
    Error(Nil) -> 0.0
  }
  let root_one_minus_a = case float.square_root(1.0 -. a_clamped) {
    Ok(v) -> v
    Error(Nil) -> 0.0
  }
  let c = 2.0 *. erl_atan2(root_a, root_one_minus_a)
  earth_radius_km *. c
}

fn strip_prefix(name: String, remaining_prefixes: List(String)) -> String {
  case remaining_prefixes {
    [] -> name
    [prefix, ..rest] ->
      case string.starts_with(name, prefix) {
        True -> string.drop_start(name, string.length(prefix))
        False -> strip_prefix(name, rest)
      }
  }
}

fn is_digit(char: String) -> Bool {
  case char {
    "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" -> True
    _ -> False
  }
}

fn strip_year_suffix(name: String) -> String {
  case string.split_once(name, "-") {
    Ok(#(base, suffix)) -> {
      let is_all_digits = string.to_graphemes(suffix) |> list.all(is_digit)
      case
        is_all_digits
        && { string.length(suffix) == 2 || string.length(suffix) == 4 }
      {
        True -> base
        False -> name
      }
    }
    Error(Nil) -> name
  }
}

pub fn normalize_name(name: String) -> String {
  let lower = string.lowercase(string.trim(name))
  let stripped = strip_prefix(lower, prefixes)
  string.trim(stripped) |> strip_year_suffix
}

pub fn is_named(storm_id: String, storm_name: Option(String)) -> Bool {
  case storm_name {
    None -> False
    Some(name) -> {
      let trimmed = string.trim(name)
      trimmed != ""
      && string.lowercase(trimmed) != string.lowercase(string.trim(storm_id))
    }
  }
}

pub fn is_time_within_window(
  analysis_time_ms: Int,
  hazard: Hazard,
  max_hours: Int,
) -> Bool {
  let window_ms = max_hours * 3600 * 1000
  let target_times = case hazard.expires_at_ms {
    Some(exp) -> [exp, hazard.modified_at_ms]
    None -> [hazard.onset_at_ms, hazard.modified_at_ms]
  }
  list.any(target_times, fn(t) {
    int.absolute_value(analysis_time_ms - t) <= window_ms
  })
}

pub fn match_tc_run(
  storm_id: String,
  storm_name: Option(String),
  analysis_time_ms: Int,
  analysis_lat: Float,
  analysis_lon: Float,
  candidates: List(Hazard),
) -> Option(Hazard) {
  case is_named(storm_id, storm_name) {
    True -> {
      let norm_name = normalize_name(option.unwrap(storm_name, ""))
      case
        list.find(candidates, fn(c) {
          let c_norm = normalize_name(c.title)
          c_norm != "" && c_norm == norm_name
        })
      {
        Ok(matched) -> Some(matched)
        Error(Nil) ->
          match_by_distance_and_time(
            analysis_time_ms,
            analysis_lat,
            analysis_lon,
            candidates,
          )
      }
    }
    False ->
      match_by_distance_and_time(
        analysis_time_ms,
        analysis_lat,
        analysis_lon,
        candidates,
      )
  }
}

fn match_by_distance_and_time(
  analysis_time_ms: Int,
  analysis_lat: Float,
  analysis_lon: Float,
  candidates: List(Hazard),
) -> Option(Hazard) {
  let scored =
    list.filter_map(candidates, fn(c) {
      case is_time_within_window(analysis_time_ms, c, match_window_hours) {
        False -> Error(Nil)
        True -> {
          let dist =
            great_circle_distance_km(
              analysis_lat,
              analysis_lon,
              c.latitude,
              c.longitude,
            )
          case dist <=. match_distance_km {
            True -> Ok(#(c, dist))
            False -> Error(Nil)
          }
        }
      }
    })

  case scored {
    [] -> None
    [#(first_c, first_d), ..rest] -> {
      let #(best_c, _) =
        list.fold(rest, #(first_c, first_d), fn(best, item) {
          case item.1 <. best.1 {
            True -> item
            False -> best
          }
        })
      Some(best_c)
    }
  }
}

pub fn track_analysis_position(track: ForecastTrack) -> #(Float, Float) {
  case track.points {
    [first, ..] -> #(first.lat, first.lon)
    [] -> #(0.0, 0.0)
  }
}

type TrackTier {
  MatchesHazardName
  NamedRun
  NumberedOrOther
}

fn track_tier(track: ForecastTrack, hazard_norm: String) -> TrackTier {
  let matches_hazard_name =
    hazard_norm != ""
    && case track.storm_name {
      Some(name) -> normalize_name(name) == hazard_norm
      None -> False
    }

  case matches_hazard_name {
    True -> MatchesHazardName
    False ->
      case is_named(track.storm_id, track.storm_name) {
        True -> NamedRun
        False -> NumberedOrOther
      }
  }
}

fn tier_to_int(tier: TrackTier) -> Int {
  case tier {
    MatchesHazardName -> 1
    NamedRun -> 2
    NumberedOrOther -> 3
  }
}

fn is_track_better(
  a: ForecastTrack,
  b: ForecastTrack,
  hazard_norm: String,
  hazard_lat: Float,
  hazard_lon: Float,
) -> Bool {
  let tier_a = tier_to_int(track_tier(a, hazard_norm))
  let tier_b = tier_to_int(track_tier(b, hazard_norm))

  case tier_a < tier_b {
    True -> True
    False ->
      case tier_a > tier_b {
        True -> False
        False -> {
          let #(lat_a, lon_a) = track_analysis_position(a)
          let #(lat_b, lon_b) = track_analysis_position(b)
          let dist_a =
            great_circle_distance_km(lat_a, lon_a, hazard_lat, hazard_lon)
          let dist_b =
            great_circle_distance_km(lat_b, lon_b, hazard_lat, hazard_lon)
          case dist_a <. dist_b {
            True -> True
            False ->
              case dist_b <. dist_a {
                True -> False
                False -> string.compare(a.storm_id, b.storm_id) == order.Lt
              }
          }
        }
      }
  }
}

fn keep_latest_time_runs(tracks: List(ForecastTrack)) -> List(ForecastTrack) {
  let max_time =
    list.fold(tracks, "", fn(acc, t) {
      case string.compare(t.analysis_time, acc) {
        order.Gt -> t.analysis_time
        _ -> acc
      }
    })
  list.filter(tracks, fn(t) { t.analysis_time == max_time })
}

pub fn choose_track_for_centre(
  runs: List(ForecastTrack),
  hazard_title: String,
  hazard_lat: Float,
  hazard_lon: Float,
) -> Option(ForecastTrack) {
  let latest_runs = keep_latest_time_runs(runs)
  let hazard_norm = normalize_name(hazard_title)
  case latest_runs {
    [] -> None
    [first, ..rest] -> {
      let best =
        list.fold(rest, first, fn(current_best, candidate) {
          case
            is_track_better(
              candidate,
              current_best,
              hazard_norm,
              hazard_lat,
              hazard_lon,
            )
          {
            True -> candidate
            False -> current_best
          }
        })
      Some(best)
    }
  }
}

pub fn choose_forecast_tracks(
  tracks: List(ForecastTrack),
  hazard_title: String,
  hazard_lat: Float,
  hazard_lon: Float,
) -> List(ForecastTrack) {
  let by_centre = list.group(tracks, fn(t) { t.centre_id })
  dict.to_list(by_centre)
  |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
  |> list.filter_map(fn(entry) {
    let #(_centre_id, centre_tracks) = entry
    choose_track_for_centre(centre_tracks, hazard_title, hazard_lat, hazard_lon)
    |> option.to_result(Nil)
  })
}

pub fn choose_forecast_tracks_for_hazard(
  tracks: List(ForecastTrack),
  hazard: Hazard,
) -> List(ForecastTrack) {
  choose_forecast_tracks(
    tracks,
    hazard.title,
    hazard.latitude,
    hazard.longitude,
  )
}
