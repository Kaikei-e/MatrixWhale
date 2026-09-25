import domain/hazard.{type Hazard}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
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
