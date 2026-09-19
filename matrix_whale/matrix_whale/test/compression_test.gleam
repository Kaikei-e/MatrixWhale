import adapter/compression
import adapter/streamer
import gleam/bit_array
import gleam/bytes_tree
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/json
import gleam/string
import gleeunit/should
import mist

pub fn gzip_and_gunzip_roundtrip_test() {
  let sample_json =
    "{\"hazards\":[{\"id\":\"gdacs:TC-12345\",\"title\":\"Tropical Cyclone Example\",\"coordinates\":[139.7,35.6],\"details\":\"A large text payload repeated to test compression efficiency across multiple lines of GeoJSON features and coordinates.\"}]}"
  let input = bit_array.from_string(sample_json)
  let compressed = compression.gzip(input)

  let decompressed = compression.gunzip(compressed)
  decompressed
  |> should.equal(input)
}

pub fn parse_accept_encoding_q_precedence_test() {
  // Simple gzip
  compression.accepts_gzip_header("gzip")
  |> should.be_true

  // Multiple encodings
  compression.accepts_gzip_header("gzip, deflate, br")
  |> should.be_true

  // identity;q=1, gzip;q=0.5 -> identity preferred over gzip
  compression.accepts_gzip_header("identity;q=1, gzip;q=0.5")
  |> should.be_false

  // gzip;q=0.8, identity;q=0.5 -> gzip preferred
  compression.accepts_gzip_header("identity;q=0.5, gzip;q=0.8")
  |> should.be_true

  // Explicit gzip;q=0 takes precedence over wildcard
  compression.accepts_gzip_header("*;q=1, gzip;q=0")
  |> should.be_false

  compression.accepts_gzip_header("gzip; q=0.0")
  |> should.be_false

  compression.accepts_gzip_header("gzip;\tq=0")
  |> should.be_false

  // Wildcard with explicit gzip > 0
  compression.accepts_gzip_header("*;q=0, gzip;q=0.8")
  |> should.be_true

  // No gzip specified
  compression.accepts_gzip_header("deflate, br")
  |> should.be_false

  compression.accepts_gzip_header("")
  |> should.be_false

  compression.accepts_gzip_header("gzip;q=1.5")
  |> should.be_false

  compression.accepts_gzip_header("gzip;q=invalid")
  |> should.be_false
}

pub fn extract_opaque_tag_test() {
  compression.extract_opaque_tag("\"abc123\"")
  |> should.equal(Ok("abc123"))

  compression.extract_opaque_tag("\"abc123-gzip\"")
  |> should.equal(Ok("abc123-gzip"))

  compression.extract_opaque_tag("W/\"abc123\"")
  |> should.equal(Ok("abc123"))

  compression.extract_opaque_tag("W/\"abc123-gzip\"")
  |> should.equal(Ok("abc123-gzip"))

  // Unquoted invalid tags must fail to match
  compression.extract_opaque_tag("abc123")
  |> should.equal(Error(Nil))

  compression.extract_opaque_tag("")
  |> should.equal(Error(Nil))
}

pub fn if_none_match_matches_test() {
  let gzip_etag = "\"myhash-gzip\""
  let identity_etag = "\"myhash\""

  // Exact match with response_etag
  compression.if_none_match_matches("\"myhash-gzip\"", gzip_etag)
  |> should.be_true

  // Weak tag matches response_etag
  compression.if_none_match_matches("W/\"myhash-gzip\"", gzip_etag)
  |> should.be_true

  // Identity tag sent against gzip response must NOT match (returns 200)
  compression.if_none_match_matches("\"myhash\"", gzip_etag)
  |> should.be_false

  // Gzip tag sent against identity response must NOT match
  compression.if_none_match_matches("\"myhash-gzip\"", identity_etag)
  |> should.be_false

  // Unquoted invalid tag must NOT match
  compression.if_none_match_matches("myhash-gzip", gzip_etag)
  |> should.be_false

  // Wildcard matches
  compression.if_none_match_matches("*", gzip_etag)
  |> should.be_true
}

pub fn etag_json_response_variant_and_status_test() {
  let payload = json.object([#("k", json.string("v"))])

  // 1. Client requests with gzip -> returns 200 with -gzip ETag
  let req_gzip =
    request.new()
    |> request.set_header("accept-encoding", "gzip")

  let res1 = streamer.etag_json_response(req_gzip, payload)
  res1.status
  |> should.equal(200)

  let assert Ok(etag_gzip) = response.get_header(res1, "etag")
  response.get_header(res1, "content-encoding")
  |> should.equal(Ok("gzip"))

  // 2. Client sends identity tag to gzip endpoint -> returns 200
  let req_identity =
    request.new()
    |> request.set_header("accept-encoding", "")

  let res_identity = streamer.etag_json_response(req_identity, payload)
  let assert Ok(etag_id) = response.get_header(res_identity, "etag")

  let req_mismatch =
    request.new()
    |> request.set_header("accept-encoding", "gzip")
    |> request.set_header("if-none-match", etag_id)

  let res_mismatch = streamer.etag_json_response(req_mismatch, payload)
  res_mismatch.status
  |> should.equal(200)

  // 3. Client sends matching gzip tag to gzip endpoint -> returns 304
  let req_match =
    request.new()
    |> request.set_header("accept-encoding", "gzip")
    |> request.set_header("if-none-match", etag_gzip)

  let res_match = streamer.etag_json_response(req_match, payload)
  res_match.status
  |> should.equal(304)
  response.get_header(res_match, "content-encoding")
  |> should.equal(Error(Nil))
}

pub fn header_preservation_test() {
  // Existing Vary header preservation
  let res =
    response.new(200)
    |> response.set_header("vary", "Origin")
  let res = compression.add_vary_accept_encoding(res)
  response.get_header(res, "vary")
  |> should.equal(Ok("Origin, accept-encoding"))

  // Weak ETag preserved as weak when updating for gzip
  let weak_res =
    response.new(200)
    |> response.set_header("etag", "W/\"hash123\"")
  let updated_weak = compression.update_etag_for_gzip(weak_res)
  response.get_header(updated_weak, "etag")
  |> should.equal(Ok("W/\"hash123-gzip\""))
}

pub fn middleware_compresses_json_without_stale_content_length_test() {
  let req = request.new() |> request.set_header("accept-encoding", "gzip")
  let text = string.repeat("{\"value\":\"repeatable\"}", 100)
  let original =
    response.new(200)
    |> response.set_header("content-type", "application/json")
    |> response.set_header(
      "content-length",
      int.to_string(string.byte_size(text)),
    )
    |> response.set_header("vary", "Origin")
    |> response.set_body(mist.Bytes(bytes_tree.from_string(text)))
  let compressed = compression.compress_response_if_needed(req, original)
  let assert mist.Bytes(body) = compressed.body
  let bytes = bytes_tree.to_bit_array(body)
  compression.gunzip(bytes) |> should.equal(bit_array.from_string(text))
  response.get_header(compressed, "content-length")
  |> should.equal(Ok(int.to_string(bit_array.byte_size(bytes))))
  response.get_header(compressed, "vary")
  |> should.equal(Ok("Origin, accept-encoding"))
  let identity =
    compression.compress_response_if_needed(request.new(), original)
  identity.body |> should.equal(original.body)
}

pub fn middleware_leaves_sse_and_bodyless_responses_untouched_test() {
  let req = request.new() |> request.set_header("accept-encoding", "gzip")
  let stream =
    response.new(200)
    |> response.set_header("content-type", "text/event-stream")
    |> response.set_body(mist.ServerSentEvents)
  compression.compress_response_if_needed(req, stream) |> should.equal(stream)
  let not_modified =
    response.new(304)
    |> response.set_header("etag", "\"current-gzip\"")
    |> response.set_body(mist.Bytes(bytes_tree.new()))
  compression.compress_response_if_needed(req, not_modified)
  |> should.equal(not_modified)
}

pub fn hazard_revalidation_ignores_only_response_generation_time_test() {
  let req = request.new() |> request.set_header("accept-encoding", "gzip")
  let first = streamer.hazard_snapshot_response(req, [], "2026-09-19T17:00:00Z")
  let assert Ok(tag) = response.get_header(first, "etag")
  string.starts_with(tag, "W/\"") |> should.be_true
  let conditional = req |> request.set_header("if-none-match", tag)
  let second =
    streamer.hazard_snapshot_response(conditional, [], "2026-09-19T17:01:00Z")
  second.status |> should.equal(304)
  response.get_header(second, "etag") |> should.equal(Ok(tag))
  let changed_encoding =
    conditional |> request.set_header("accept-encoding", "identity")
  streamer.hazard_snapshot_response(
    changed_encoding,
    [],
    "2026-09-19T17:02:00Z",
  ).status
  |> should.equal(200)
}
