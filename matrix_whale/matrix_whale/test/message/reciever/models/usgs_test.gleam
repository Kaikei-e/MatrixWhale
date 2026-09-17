import controller/earthquake_controller
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option
import gleeunit/should
import message/reciever/models/earthquake_feature
import message/reciever/models/usgs

pub fn nullable_feature_is_accepted_test() {
  let assert Ok(body) =
    json.parse(
      "{\"poll_meta\":{\"fetched_at\":\"2026-09-17T00:00:00Z\",\"http_status\":200,\"feature_count\":1,\"bytes\":12},\"features\":[{\"id\":\"us1\",\"type\":\"Feature\",\"geometry\":{\"type\":\"Point\",\"coordinates\":[139.0,35.0,10]},\"properties\":{\"time\":1700000000000,\"updated\":1700000000001,\"mag\":null,\"place\":null,\"ids\":\",us1,ci2,\"}}]}",
      decode.dynamic,
    )
  let assert Ok(#(meta, features, received, dropped)) = usgs.decode_body(body)
  received |> should.equal(1)
  dropped |> should.equal(0)
  list.length(features) |> should.equal(1)
  meta
  |> should.equal(
    option.Some(earthquake_feature.PollMeta(
      "2026-09-17T00:00:00Z",
      200,
      1,
      12,
      False,
    )),
  )
}

pub fn invalid_envelope_is_error_test() {
  let assert Ok(body) = json.parse("{\"features\":{}}", decode.dynamic)
  case usgs.decode_body(body) {
    Error(_) -> True |> should.equal(True)
    Ok(_) -> False |> should.equal(True)
  }
}

pub fn invalid_features_are_dropped_but_valid_null_depth_is_kept_test() {
  let payload =
    "{\"features\":[{\"id\":\"ok\",\"type\":\"Feature\",\"geometry\":{\"type\":\"Point\",\"coordinates\":[1,2,null]},\"properties\":{\"time\":1,\"updated\":2}},{\"id\":\"\",\"type\":\"Feature\",\"geometry\":{\"type\":\"Point\",\"coordinates\":[1,2]},\"properties\":{\"time\":1,\"updated\":2}},{\"id\":\"bad-lat\",\"type\":\"Feature\",\"geometry\":{\"type\":\"Point\",\"coordinates\":[1,91]},\"properties\":{\"time\":1,\"updated\":2}}]}"
  let assert Ok(body) = json.parse(payload, decode.dynamic)
  let assert Ok(#(_, features, received, dropped)) = usgs.decode_body(body)
  received |> should.equal(3)
  dropped |> should.equal(2)
  let assert [feature] = features
  feature.depth |> should.equal(option.None)
}

pub fn decoded_feature_carries_raw_geojson_test() {
  let payload =
    "{\"features\":[{\"id\":\"raw1\",\"type\":\"Feature\",\"geometry\":{\"type\":\"Point\",\"coordinates\":[139.0,35.0,10]},\"properties\":{\"time\":1700000000000,\"updated\":1700000000001,\"mag\":5.4}}]}"
  let assert Ok(body) = json.parse(payload, decode.dynamic)
  let assert Ok(#(_, features, _, _)) = usgs.decode_body(body)
  let assert [feature] = features
  let assert Ok(raw) = json.parse(feature.raw, decode.dynamic)
  let decoder = {
    use type_ <- decode.field("type", decode.string)
    use mag <- decode.subfield(["properties", "mag"], decode.float)
    decode.success(#(type_, mag))
  }
  let assert Ok(#(type_, mag)) = decode.run(raw, decoder)
  type_ |> should.equal("Feature")
  mag |> should.equal(5.4)
}

pub fn expired_features_are_dropped_not_deduped_test() {
  let payload =
    "{\"features\":[{\"id\":\"old\",\"type\":\"Feature\",\"geometry\":{\"type\":\"Point\",\"coordinates\":[1,2]},\"properties\":{\"time\":1,\"updated\":2}},{\"id\":\"new\",\"type\":\"Feature\",\"geometry\":{\"type\":\"Point\",\"coordinates\":[1,2]},\"properties\":{\"time\":11,\"updated\":12}}]}"
  let assert Ok(body) = json.parse(payload, decode.dynamic)
  let assert Ok(#(_, features, _, _)) = usgs.decode_body(body)
  let #(live, expired) = earthquake_controller.split_expired(features, 10)
  list.length(live) |> should.equal(1)
  expired |> should.equal(1)
}
