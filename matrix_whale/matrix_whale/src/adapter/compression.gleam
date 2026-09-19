import gleam/bit_array
import gleam/bytes_tree
import gleam/float
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import mist

@external(erlang, "zlib", "gzip")
pub fn gzip(data: BitArray) -> BitArray

@external(erlang, "zlib", "gunzip")
pub fn gunzip(data: BitArray) -> BitArray

pub type EncodingPreference {
  EncodingPreference(coding: String, q: Float)
}

fn parse_q_value(q_str: String) -> Float {
  let q_str = string.trim(q_str)
  let raw_q = case float.parse(q_str) {
    Ok(q) -> q
    Error(_) ->
      case int.parse(q_str) {
        Ok(q_int) -> int.to_float(q_int)
        Error(_) -> 0.0
      }
  }
  case raw_q <. 0.0, raw_q >. 1.0 {
    True, _ -> 0.0
    _, True -> 0.0
    _, _ -> raw_q
  }
}

pub fn parse_accept_encoding(header: String) -> List(EncodingPreference) {
  header
  |> string.split(",")
  |> list.filter_map(fn(part) {
    let part = string.trim(part)
    case part {
      "" -> Error(Nil)
      _ -> {
        let items = string.split(part, ";")
        case items {
          [coding] ->
            Ok(EncodingPreference(string.lowercase(string.trim(coding)), 1.0))
          [coding, ..params] -> {
            let coding = string.lowercase(string.trim(coding))
            let q =
              list.find_map(params, fn(p) {
                let p = string.trim(p) |> string.replace(" ", "")
                case string.starts_with(string.lowercase(p), "q=") {
                  True -> {
                    let q_str = string.drop_start(p, 2)
                    Ok(parse_q_value(q_str))
                  }
                  False -> Error(Nil)
                }
              })
              |> result.unwrap(1.0)
            Ok(EncodingPreference(coding, q))
          }
          [] -> Error(Nil)
        }
      }
    }
  })
}

pub fn accepts_gzip_header(header: String) -> Bool {
  let prefs = parse_accept_encoding(header)

  let gzip_q = case list.find(prefs, fn(p) { p.coding == "gzip" }) {
    Ok(p) -> p.q
    Error(Nil) ->
      case list.find(prefs, fn(p) { p.coding == "*" }) {
        Ok(p) -> p.q
        Error(Nil) -> 0.0
      }
  }

  let identity_q = case list.find(prefs, fn(p) { p.coding == "identity" }) {
    Ok(p) -> p.q
    Error(Nil) ->
      case list.find(prefs, fn(p) { p.coding == "*" }) {
        Ok(p) -> p.q
        Error(Nil) -> 1.0
      }
  }

  gzip_q >. 0.0 && gzip_q >=. identity_q
}

pub fn request_accepts_gzip(req: Request(a)) -> Bool {
  case request.get_header(req, "accept-encoding") {
    Ok(val) -> accepts_gzip_header(val)
    Error(Nil) -> False
  }
}

pub fn extract_opaque_tag(tag: String) -> Result(String, Nil) {
  let trimmed = string.trim(tag)
  let stripped_weak = case string.starts_with(trimmed, "W/") {
    True -> string.drop_start(trimmed, 2) |> string.trim
    False -> trimmed
  }
  case
    string.starts_with(stripped_weak, "\"")
    && string.ends_with(stripped_weak, "\"")
    && string.length(stripped_weak) >= 2
  {
    True ->
      Ok(
        stripped_weak
        |> string.drop_start(1)
        |> string.drop_end(1),
      )
    False -> Error(Nil)
  }
}

pub fn if_none_match_matches(
  header_value: String,
  response_etag: String,
) -> Bool {
  case extract_opaque_tag(response_etag) {
    Error(Nil) -> False
    Ok(expected_opaque) ->
      header_value
      |> string.split(",")
      |> list.any(fn(candidate) {
        let candidate = string.trim(candidate)
        case candidate == "*" {
          True -> True
          False ->
            case extract_opaque_tag(candidate) {
              Ok(cand_opaque) -> cand_opaque == expected_opaque
              Error(Nil) -> False
            }
        }
      })
  }
}

pub fn add_vary_accept_encoding(res: Response(a)) -> Response(a) {
  case response.get_header(res, "vary") {
    Ok(existing) -> {
      let tokens =
        existing
        |> string.split(",")
        |> list.map(fn(t) { string.lowercase(string.trim(t)) })
      case
        list.contains(tokens, "accept-encoding") || list.contains(tokens, "*")
      {
        True -> res
        False ->
          response.set_header(res, "vary", existing <> ", accept-encoding")
      }
    }
    Error(Nil) -> response.set_header(res, "vary", "accept-encoding")
  }
}

pub fn update_etag_for_gzip(res: Response(a)) -> Response(a) {
  case response.get_header(res, "etag") {
    Ok(tag) -> {
      let trimmed = string.trim(tag)
      let is_weak = string.starts_with(trimmed, "W/")
      case extract_opaque_tag(trimmed) {
        Ok(opaque_value) -> {
          case string.ends_with(opaque_value, "-gzip") {
            True -> res
            False -> {
              let new_tag = case is_weak {
                True -> "W/\"" <> opaque_value <> "-gzip\""
                False -> "\"" <> opaque_value <> "-gzip\""
              }
              response.set_header(res, "etag", new_tag)
            }
          }
        }
        Error(Nil) -> res
      }
    }
    Error(Nil) -> res
  }
}

pub fn compress_response_if_needed(
  req: Request(a),
  res: Response(mist.ResponseData),
) -> Response(mist.ResponseData) {
  case res.body {
    mist.Bytes(body_tree) -> {
      case
        res.status >= 200
        && res.status < 300
        && res.status != 204
        && res.status != 304
      {
        False -> res
        True -> {
          case response.get_header(res, "content-encoding") {
            Ok(_) -> res
            Error(Nil) -> {
              let is_json = case response.get_header(res, "content-type") {
                Ok(ct) ->
                  string.contains(string.lowercase(ct), "application/json")
                Error(Nil) -> False
              }
              case is_json && request_accepts_gzip(req) {
                False -> {
                  case is_json {
                    True -> add_vary_accept_encoding(res)
                    False -> res
                  }
                }
                True -> {
                  let body_bytes = bytes_tree.to_bit_array(body_tree)
                  case bit_array.byte_size(body_bytes) >= 128 {
                    False -> res
                    True -> {
                      let compressed = gzip(body_bytes)
                      let compressed_size = bit_array.byte_size(compressed)
                      res
                      |> response.set_header("content-encoding", "gzip")
                      |> add_vary_accept_encoding
                      |> update_etag_for_gzip
                      |> response.set_header(
                        "content-length",
                        int.to_string(compressed_size),
                      )
                      |> response.set_body(
                        mist.Bytes(bytes_tree.from_bit_array(compressed)),
                      )
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
    _ -> res
  }
}
