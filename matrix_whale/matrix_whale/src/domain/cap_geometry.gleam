import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import message/reciever/models/cap as models_cap

const pi = 3.141592653589793

@external(erlang, "math", "cos")
fn erl_cos(x: Float) -> Float

@external(erlang, "math", "sin")
fn erl_sin(x: Float) -> Float

fn to_radians(deg: Float) -> Float {
  deg *. pi /. 180.0
}

fn int_range(current: Int, target: Int, acc: List(Int)) -> List(Int) {
  case current > target {
    True -> list.reverse(acc)
    False -> int_range(current + 1, target, [current, ..acc])
  }
}

pub fn format_coordinate(val: Float) -> String {
  let #(sign, abs_val) = case val <. 0.0 {
    True -> #("-", 0.0 -. val)
    False -> #("", val)
  }
  let int_part = float.truncate(abs_val)
  let rem = abs_val -. int.to_float(int_part)
  let frac_int = float.round(rem *. 1_000_000.0)
  let #(final_int, final_frac) = case frac_int >= 1_000_000 {
    True -> #(int_part + 1, 0)
    False -> #(int_part, frac_int)
  }
  let frac_str =
    int.to_string(final_frac)
    |> string.pad_start(6, "0")
  sign <> int.to_string(final_int) <> "." <> frac_str
}

pub fn parse_number(s: String) -> Result(Float, Nil) {
  let trimmed = string.trim(s)
  let clean = case string.starts_with(trimmed, "+") {
    True -> string.drop_start(trimmed, 1)
    False -> trimmed
  }
  let normalized = case string.split_once(clean, "e") {
    Ok(#(mantissa, exp)) ->
      case string.contains(mantissa, ".") {
        True -> clean
        False -> mantissa <> ".0e" <> exp
      }
    Error(Nil) ->
      case string.split_once(clean, "E") {
        Ok(#(mantissa, exp)) ->
          case string.contains(mantissa, ".") {
            True -> clean
            False -> mantissa <> ".0E" <> exp
          }
        Error(Nil) -> clean
      }
  }
  case float.parse(normalized) {
    Ok(f) -> Ok(f)
    Error(Nil) ->
      case int.parse(clean) {
        Ok(i) -> Ok(int.to_float(i))
        Error(Nil) -> Error(Nil)
      }
  }
}

pub fn parse_polygon_points(polygon_str: String) -> List(#(Float, Float)) {
  polygon_str
  |> string.split("\n")
  |> list.flat_map(string.split(_, " "))
  |> list.flat_map(string.split(_, "\t"))
  |> list.filter_map(fn(chunk) {
    let trimmed = string.trim(chunk)
    case trimmed == "" {
      True -> Error(Nil)
      False ->
        case string.split_once(trimmed, ",") {
          Error(Nil) -> Error(Nil)
          Ok(#(lat_str, lon_str)) ->
            case parse_number(lat_str), parse_number(lon_str) {
              Ok(lat), Ok(lon) ->
                case
                  lat >=. -90.0
                  && lat <=. 90.0
                  && lon >=. -180.0
                  && lon <=. 180.0
                {
                  True -> Ok(#(lon, lat))
                  False -> Error(Nil)
                }
              _, _ -> Error(Nil)
            }
        }
    }
  })
}

pub fn close_ring(points: List(#(Float, Float))) -> List(#(Float, Float)) {
  case points {
    [] -> []
    [first, ..] -> {
      case list.last(points) {
        Ok(last) ->
          case last == first {
            True -> points
            False -> list.append(points, [first])
          }
        Error(Nil) -> points
      }
    }
  }
}

pub fn validate_ring(
  points: List(#(Float, Float)),
) -> Option(List(#(Float, Float))) {
  let closed = close_ring(points)
  case list.length(closed) >= 4 {
    True -> Some(closed)
    False -> None
  }
}

pub fn shift_antimeridian(
  points: List(#(Float, Float)),
) -> List(#(Float, Float)) {
  case points {
    [] -> []
    _ -> {
      let lons = list.map(points, fn(p) { p.0 })
      let min_lon = list.fold(lons, 180.0, float.min)
      let max_lon = list.fold(lons, -180.0, float.max)
      case max_lon -. min_lon >. 180.0 {
        True ->
          list.map(points, fn(p) {
            let lon = case p.0 <. 0.0 {
              True -> p.0 +. 360.0
              False -> p.0
            }
            #(lon, p.1)
          })
        False -> points
      }
    }
  }
}

pub fn parse_polygon(polygon_str: String) -> Option(List(#(Float, Float))) {
  let points = parse_polygon_points(polygon_str)
  case validate_ring(points) {
    None -> None
    Some(ring) -> Some(shift_antimeridian(ring))
  }
}

pub fn parse_circle(circle_str: String) -> Option(List(#(Float, Float))) {
  let chunks =
    circle_str
    |> string.split("\n")
    |> list.flat_map(string.split(_, " "))
    |> list.flat_map(string.split(_, "\t"))
    |> list.map(string.trim)
    |> list.filter(fn(c) { c != "" })

  case chunks {
    [coord_part, radius_part] -> {
      case string.split_once(coord_part, ",") {
        Error(Nil) -> None
        Ok(#(lat_str, lon_str)) ->
          case
            parse_number(lat_str),
            parse_number(lon_str),
            parse_number(radius_part)
          {
            Ok(lat), Ok(lon), Ok(r) ->
              case
                r >. 0.0
                && lat >=. -90.0
                && lat <=. 90.0
                && lon >=. -180.0
                && lon <=. 180.0
              {
                True -> Some(circle_to_ring(lat, lon, r))
                False -> None
              }
            _, _, _ -> None
          }
      }
    }
    _ -> None
  }
}

pub fn circle_to_ring(
  lat: Float,
  lon: Float,
  r: Float,
) -> List(#(Float, Float)) {
  let cos_lat = float.max(0.01, erl_cos(to_radians(lat)))
  let dlat = r /. 111.32
  let dlon = r /. { 111.32 *. cos_lat }

  let vertices =
    int_range(0, 31, [])
    |> list.map(fn(i) {
      let angle = 2.0 *. pi *. int.to_float(i) /. 32.0
      let raw_lat = lat +. dlat *. erl_sin(angle)
      let clamped_lat = float.clamp(raw_lat, -90.0, 90.0)
      let p_lon = lon +. dlon *. erl_cos(angle)
      #(p_lon, clamped_lat)
    })

  let closed = close_ring(vertices)
  shift_antimeridian(closed)
}

pub fn rings_to_geojson(rings: List(List(#(Float, Float)))) -> Option(String) {
  case rings {
    [] -> None
    _ -> {
      let polygons_json =
        rings
        |> list.map(fn(ring) {
          let coords =
            ring
            |> list.map(fn(p) {
              "["
              <> format_coordinate(p.0)
              <> ","
              <> format_coordinate(p.1)
              <> "]"
            })
            |> string.join(",")
          "[[" <> coords <> "]]"
        })
        |> string.join(",")
      Some(
        "{\"type\":\"MultiPolygon\",\"coordinates\":[" <> polygons_json <> "]}",
      )
    }
  }
}

pub fn geometries_to_geojson(
  polygons: List(String),
  circles: List(String),
) -> Option(String) {
  let poly_rings =
    list.filter_map(polygons, fn(p) { option.to_result(parse_polygon(p), Nil) })
  let circle_rings =
    list.filter_map(circles, fn(c) { option.to_result(parse_circle(c), Nil) })
  let all_rings = list.append(poly_rings, circle_rings)
  rings_to_geojson(all_rings)
}

pub fn areas_to_geojson(areas: List(models_cap.CapArea)) -> Option(String) {
  let polygons = list.flat_map(areas, fn(a) { a.polygon })
  let circles = list.flat_map(areas, fn(a) { a.circle })
  geometries_to_geojson(polygons, circles)
}
