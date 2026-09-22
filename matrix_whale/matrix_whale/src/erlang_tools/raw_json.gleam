import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/json

@external(erlang, "json", "encode")
fn raw_encode(data: Dynamic) -> Dynamic

@external(erlang, "erlang", "iolist_to_binary")
fn iolist_to_binary(data: Dynamic) -> BitArray

/// Re-encodes a Dynamic produced by gleam_json's decoder (OTP 27 `json:decode/1`)
/// back into JSON text, so a wire payload can be stored verbatim after decoding.
pub fn encode(data: Dynamic) -> Result(String, Nil) {
  data
  |> raw_encode
  |> iolist_to_binary
  |> bit_array.to_string
}

/// Injects a pre-serialized JSON string directly into a json.Json value.
/// gleam_json represents Json as iodata on the BEAM, so a binary is valid as-is.
@external(erlang, "raw_json_ffi", "raw")
pub fn json(text: String) -> json.Json
