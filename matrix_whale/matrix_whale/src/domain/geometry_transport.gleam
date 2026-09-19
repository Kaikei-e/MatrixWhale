import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import gleam/string

/// Minimum precision scale factor for p in 0..9.
pub fn scale_factor(p: Int) -> Float {
  case p {
    0 -> 1.0
    1 -> 10.0
    2 -> 100.0
    3 -> 1000.0
    4 -> 10_000.0
    5 -> 100_000.0
    6 -> 1_000_000.0
    7 -> 10_000_000.0
    8 -> 100_000_000.0
    9 -> 1_000_000_000.0
    _ -> 1.0
  }
}

/// Signed zigzag encoding: delta < 0 ? -2*delta - 1 : 2*delta.
pub fn zigzag_encode(delta: Int) -> Int {
  case delta < 0 {
    True -> -2 * delta - 1
    False -> 2 * delta
  }
}

/// Decodes unsigned zigzag integer back to signed delta.
pub fn zigzag_decode(u: Int) -> Int {
  case int.bitwise_and(u, 1) == 1 {
    True -> -{ { u + 1 } / 2 }
    False -> u / 2
  }
}

/// Emits 5-bit base32 chunks with continuation bit (0x20 = 32) and ASCII offset (+63).
/// Prepends to acc; caller reverses the ring codepoints once at the end.
pub fn encode_unsigned(u: Int, acc: List(Int)) -> List(Int) {
  case u >= 32 {
    True -> {
      let chunk = { u % 32 } + 32 + 63
      encode_unsigned(u / 32, [chunk, ..acc])
    }
    False -> {
      let chunk = u + 63
      [chunk, ..acc]
    }
  }
}

/// Encodes signed delta value, prepending chunks to accumulator.
pub fn encode_delta(delta: Int, acc: List(Int)) -> List(Int) {
  let u = zigzag_encode(delta)
  encode_unsigned(u, acc)
}

/// Encodes a single ring of [lon, lat] points to polyline ASCII string.
/// Resets prev_lon and prev_lat to 0 at the start of the ring.
/// Encodes longitude then latitude per point.
pub fn encode_ring(points: List(#(Float, Float)), precision: Int) -> String {
  let scale = scale_factor(precision)
  let codepoints = encode_ring_to_codepoints(points, scale)
  codepoints_to_string(codepoints)
}

fn encode_ring_to_codepoints(
  points: List(#(Float, Float)),
  scale: Float,
) -> List(Int) {
  let #(_, _, codepoints) =
    list.fold(points, #(0, 0, []), fn(state, pt) {
      let #(prev_lon, prev_lat, acc) = state
      let curr_lon = float.round(pt.0 *. scale)
      let curr_lat = float.round(pt.1 *. scale)
      let delta_lon = curr_lon - prev_lon
      let delta_lat = curr_lat - prev_lat
      let acc1 = encode_delta(delta_lon, acc)
      let acc2 = encode_delta(delta_lat, acc1)
      #(curr_lon, curr_lat, acc2)
    })
  list.reverse(codepoints)
}

fn codepoints_to_string(codepoints: List(Int)) -> String {
  let utf_cps =
    list.filter_map(codepoints, fn(code) { string.utf_codepoint(code) })
  string.from_utf_codepoints(utf_cps)
}

/// Finds minimum precision p in 0..9 such that round(v * 10^p) / 10^p == v.
pub fn min_precision_for_float(v: Float) -> Result(Int, Nil) {
  find_precision(v, 0)
}

fn find_precision(v: Float, p: Int) -> Result(Int, Nil) {
  case p > 9 {
    True -> Error(Nil)
    False -> {
      let scale = scale_factor(p)
      let rounded = float.round(v *. scale)
      case int.to_float(rounded) /. scale == v {
        True -> Ok(p)
        False -> find_precision(v, p + 1)
      }
    }
  }
}

fn min_precision_for_point(pt: #(Float, Float)) -> Result(Int, Nil) {
  use p_lon <- result.try(min_precision_for_float(pt.0))
  use p_lat <- result.try(min_precision_for_float(pt.1))
  Ok(int.max(p_lon, p_lat))
}

fn min_precision_for_ring(
  ring: List(#(Float, Float)),
  acc_p: Int,
) -> Result(Int, Nil) {
  list.fold_until(ring, Ok(acc_p), fn(acc_res, pt) {
    case acc_res {
      Error(Nil) -> list.Stop(Error(Nil))
      Ok(current_max) ->
        case min_precision_for_point(pt) {
          Ok(p) -> list.Continue(Ok(int.max(current_max, p)))
          Error(Nil) -> list.Stop(Error(Nil))
        }
    }
  })
}

fn min_precision_for_rings(
  rings: List(List(#(Float, Float))),
) -> Result(Int, Nil) {
  list.fold_until(rings, Ok(0), fn(acc_res, ring) {
    case acc_res {
      Error(Nil) -> list.Stop(Error(Nil))
      Ok(acc_p) ->
        case min_precision_for_ring(ring, acc_p) {
          Ok(p) -> list.Continue(Ok(p))
          Error(Nil) -> list.Stop(Error(Nil))
        }
    }
  })
}

fn min_precision_for_polys(
  polys: List(List(List(#(Float, Float)))),
) -> Result(Int, Nil) {
  list.fold_until(polys, Ok(0), fn(acc_res, rings) {
    case acc_res {
      Error(Nil) -> list.Stop(Error(Nil))
      Ok(acc_p) ->
        case min_precision_for_rings(rings) {
          Ok(p) -> list.Continue(Ok(int.max(acc_p, p)))
          Error(Nil) -> list.Stop(Error(Nil))
        }
    }
  })
}

fn coord_decoder() -> decode.Decoder(#(Float, Float)) {
  decode.list(decode.dynamic)
  |> decode.then(fn(items) {
    case items {
      [lon_dyn, lat_dyn] -> {
        case
          decode.run(lon_dyn, num_decoder()),
          decode.run(lat_dyn, num_decoder())
        {
          Ok(lon), Ok(lat) -> {
            case
              lon >=. -180.0 && lon <=. 180.0 && lat >=. -90.0 && lat <=. 90.0
            {
              True -> decode.success(#(lon, lat))
              False -> decode.failure(#(0.0, 0.0), "in-bounds coordinates")
            }
          }
          _, _ -> decode.failure(#(0.0, 0.0), "numeric 2D coordinate")
        }
      }
      _ -> decode.failure(#(0.0, 0.0), "exactly 2D coordinate")
    }
  })
}

fn num_decoder() -> decode.Decoder(Float) {
  decode.one_of(decode.float, or: [decode.int |> decode.map(int.to_float)])
}

fn polygon_coords_decoder() -> decode.Decoder(List(List(#(Float, Float)))) {
  decode.list(decode.list(coord_decoder()))
  |> decode.then(fn(rings) {
    case rings {
      [] -> decode.failure([], "non-empty rings")
      _ ->
        case list.all(rings, fn(ring) { !list.is_empty(ring) }) {
          True -> decode.success(rings)
          False -> decode.failure([], "non-empty ring")
        }
    }
  })
}

fn multipolygon_coords_decoder() -> decode.Decoder(
  List(List(List(#(Float, Float)))),
) {
  decode.list(polygon_coords_decoder())
  |> decode.then(fn(polys) {
    case polys {
      [] -> decode.failure([], "non-empty polygons")
      _ -> decode.success(polys)
    }
  })
}

/// Parses GeoJSON geometry text and attempts to encode it as a polyline geometry.
/// Returns Ok(json) if valid 2D Polygon or MultiPolygon with precision <= 9, in bounds,
/// and no extra fields. Returns Error(Nil) on unsupported/3D/out of bounds/extra fields.
pub fn encode_geometry_text(text: String) -> Result(json.Json, Nil) {
  use raw_dict <- result.try(
    json.parse(text, decode.dict(decode.string, decode.dynamic))
    |> result.map_error(fn(_) { Nil }),
  )
  case
    dict.size(raw_dict) == 2
    && dict.has_key(raw_dict, "type")
    && dict.has_key(raw_dict, "coordinates")
  {
    False -> Error(Nil)
    True -> {
      use type_dyn <- result.try(
        dict.get(raw_dict, "type") |> result.map_error(fn(_) { Nil }),
      )
      use type_val <- result.try(
        decode.run(type_dyn, decode.string) |> result.map_error(fn(_) { Nil }),
      )
      use coords_dyn <- result.try(
        dict.get(raw_dict, "coordinates") |> result.map_error(fn(_) { Nil }),
      )
      case type_val {
        "Polygon" -> encode_polygon(coords_dyn)
        "MultiPolygon" -> encode_multipolygon(coords_dyn)
        _ -> Error(Nil)
      }
    }
  }
}

fn encode_polygon(coords_dyn: Dynamic) -> Result(json.Json, Nil) {
  use rings <- result.try(
    decode.run(coords_dyn, polygon_coords_decoder())
    |> result.map_error(fn(_) { Nil }),
  )
  use precision <- result.try(min_precision_for_rings(rings))
  let encoded_rings = list.map(rings, fn(ring) { encode_ring(ring, precision) })
  Ok(
    json.object([
      #("type", json.string("Polygon")),
      #("encoding", json.string("polyline")),
      #("precision", json.int(precision)),
      #("coordinates", json.array(encoded_rings, json.string)),
    ]),
  )
}

fn encode_multipolygon(coords_dyn: Dynamic) -> Result(json.Json, Nil) {
  use polys <- result.try(
    decode.run(coords_dyn, multipolygon_coords_decoder())
    |> result.map_error(fn(_) { Nil }),
  )
  use precision <- result.try(min_precision_for_polys(polys))
  let encoded_polys =
    list.map(polys, fn(rings) {
      list.map(rings, fn(ring) { encode_ring(ring, precision) })
    })
  Ok(
    json.object([
      #("type", json.string("MultiPolygon")),
      #("encoding", json.string("polyline")),
      #("precision", json.int(precision)),
      #(
        "coordinates",
        json.array(encoded_polys, fn(rings) { json.array(rings, json.string) }),
      ),
    ]),
  )
}

/// Decodes polyline string back to [lon, lat] coordinate pairs.
pub fn decode_polyline(
  encoded: String,
  precision: Int,
) -> Result(List(#(Float, Float)), Nil) {
  let scale = scale_factor(precision)
  let codepoints =
    string.to_utf_codepoints(encoded)
    |> list.map(string.utf_codepoint_to_int)
  use deltas <- result.try(decode_deltas(codepoints, 0, 0, []))
  deltas_to_points(deltas, scale)
}

fn decode_deltas(
  codes: List(Int),
  shift: Int,
  current: Int,
  acc: List(Int),
) -> Result(List(Int), Nil) {
  case codes {
    [] ->
      case shift == 0 {
        True -> Ok(list.reverse(acc))
        False -> Error(Nil)
      }
    [c, ..rest] -> {
      let val = c - 63
      case val < 0 || val > 63 {
        True -> Error(Nil)
        False -> {
          let chunk = val % 32
          let next_current = current + int.bitwise_shift_left(chunk, shift)
          case val >= 32 {
            True -> decode_deltas(rest, shift + 5, next_current, acc)
            False -> {
              let delta = zigzag_decode(next_current)
              decode_deltas(rest, 0, 0, [delta, ..acc])
            }
          }
        }
      }
    }
  }
}

fn deltas_to_points(
  deltas: List(Int),
  scale: Float,
) -> Result(List(#(Float, Float)), Nil) {
  pair_deltas(deltas, 0, 0, scale, [])
}

fn pair_deltas(
  deltas: List(Int),
  prev_lon: Int,
  prev_lat: Int,
  scale: Float,
  acc: List(#(Float, Float)),
) -> Result(List(#(Float, Float)), Nil) {
  case deltas {
    [] -> Ok(list.reverse(acc))
    [d_lon, d_lat, ..rest] -> {
      let curr_lon = prev_lon + d_lon
      let curr_lat = prev_lat + d_lat
      let pt = #(
        int.to_float(curr_lon) /. scale,
        int.to_float(curr_lat) /. scale,
      )
      pair_deltas(rest, curr_lon, curr_lat, scale, [pt, ..acc])
    }
    [_] -> Error(Nil)
  }
}
