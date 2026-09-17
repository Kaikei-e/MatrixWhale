import gleam/bit_array
import gleam/dynamic.{type Dynamic}

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
