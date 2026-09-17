import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option
import gleeunit/should
import message/reciever/models/emsc

pub fn nullable_magnitude_is_accepted_test() {
  let payload =
    "{\"features\":[{\"action\":\"create\",\"data\":{\"type\":\"Feature\",\"properties\":{\"unid\":\"20260918_0000001\",\"source_id\":\"usp000abcd\",\"lastupdate\":\"2026-09-18T00:00:00.123456Z\",\"time\":\"2026-09-18T00:00:00Z\",\"flynn_region\":\"CENTRAL ITALY\",\"lat\":42.5,\"lon\":13.2,\"depth\":10.0,\"evtype\":\"ke\",\"auth\":\"EMSC\",\"mag\":null,\"magtype\":\"ML\"}}}]}"
  let assert Ok(body) = json.parse(payload, decode.dynamic)
  let assert Ok(#(_, features, received, dropped)) = emsc.decode_body(body)
  received |> should.equal(1)
  dropped |> should.equal(0)
  let assert [feature] = features
  feature.mag |> should.equal(option.None)
  feature.source_id |> should.equal("20260918_0000001")
  feature.code |> should.equal(option.Some("usp000abcd"))
  feature.net |> should.equal(option.Some("EMSC"))
  feature.status |> should.equal(option.Some("automatic"))
}

pub fn invalid_features_are_dropped_test() {
  let payload =
    "{\"features\":[{\"action\":\"create\",\"data\":{\"type\":\"Feature\",\"properties\":{\"unid\":\"\",\"time\":\"2026-09-18T00:00:00Z\",\"lastupdate\":\"2026-09-18T00:00:00Z\",\"lat\":1.0,\"lon\":1.0}}},{\"action\":\"create\",\"data\":{\"type\":\"Feature\",\"properties\":{\"unid\":\"bad-time\",\"time\":\"not-a-date\",\"lastupdate\":\"2026-09-18T00:00:00Z\",\"lat\":1.0,\"lon\":1.0}}},{\"action\":\"create\",\"data\":{\"type\":\"Feature\",\"properties\":{\"unid\":\"ok\",\"time\":\"2026-09-18T00:00:00Z\",\"lastupdate\":\"2026-09-18T00:00:00Z\",\"lat\":1.0,\"lon\":1.0}}}]}"
  let assert Ok(body) = json.parse(payload, decode.dynamic)
  let assert Ok(#(_, features, received, dropped)) = emsc.decode_body(body)
  received |> should.equal(3)
  dropped |> should.equal(2)
  let assert [feature] = features
  feature.source_id |> should.equal("ok")
}

pub fn delete_action_sets_status_deleted_test() {
  let payload =
    "{\"features\":[{\"action\":\"delete\",\"data\":{\"type\":\"Feature\",\"properties\":{\"unid\":\"gone\",\"time\":\"2026-09-18T00:00:00Z\",\"lastupdate\":\"2026-09-18T00:00:00Z\",\"lat\":1.0,\"lon\":1.0}}}]}"
  let assert Ok(body) = json.parse(payload, decode.dynamic)
  let assert Ok(#(_, features, _, _)) = emsc.decode_body(body)
  let assert [feature] = features
  feature.status |> should.equal(option.Some("deleted"))
}

pub fn evtype_maps_to_the_isc_event_type_test() {
  let payload = fn(evtype: String, unid: String) {
    "{\"action\":\"create\",\"data\":{\"type\":\"Feature\",\"properties\":{\"unid\":\""
    <> unid
    <> "\",\"time\":\"2026-09-18T00:00:00Z\",\"lastupdate\":\"2026-09-18T00:00:00Z\",\"lat\":1.0,\"lon\":1.0,\"evtype\":\""
    <> evtype
    <> "\"}}}"
  }
  let cases = [
    #("ke", "earthquake"),
    #("se", "earthquake"),
    #("fe", "earthquake"),
    #("de", "earthquake"),
    #("kr", "rock burst"),
    #("sr", "rock burst"),
    #("ki", "induced or triggered event"),
    #("km", "mining explosion"),
    #("kh", "explosion"),
    #("sx", "explosion"),
    #("kn", "nuclear explosion"),
    #("ls", "landslide"),
    #("zz", "other event"),
  ]
  let body_text =
    "{\"features\":["
    <> {
      cases
      |> list.index_map(fn(pair, i) {
        payload(pair.0, "id" <> int.to_string(i))
      })
      |> list.fold("", fn(acc, x) {
        case acc {
          "" -> x
          _ -> acc <> "," <> x
        }
      })
    }
    <> "]}"
  let assert Ok(body) = json.parse(body_text, decode.dynamic)
  let assert Ok(#(_, features, _, _)) = emsc.decode_body(body)
  list.length(features) |> should.equal(list.length(cases))
  list.zip(features, cases)
  |> list.each(fn(pair) {
    let #(feature, expected) = pair
    feature.type_ |> should.equal(option.Some(expected.1))
  })
}

pub fn raw_json_preserves_only_the_feature_data_test() {
  let payload =
    "{\"features\":[{\"action\":\"update\",\"data\":{\"type\":\"Feature\",\"properties\":{\"unid\":\"raw1\",\"time\":\"2026-09-18T00:00:00Z\",\"lastupdate\":\"2026-09-18T00:00:00Z\",\"lat\":1.0,\"lon\":1.0,\"mag\":6.1}}}]}"
  let assert Ok(body) = json.parse(payload, decode.dynamic)
  let assert Ok(#(_, features, _, _)) = emsc.decode_body(body)
  let assert [feature] = features
  let assert Ok(raw) = json.parse(feature.raw, decode.dynamic)
  let decoder = {
    use type_ <- decode.field("type", decode.string)
    use mag <- decode.subfield(["properties", "mag"], decode.float)
    decode.success(#(type_, mag))
  }
  let assert Ok(#(type_, mag)) = decode.run(raw, decoder)
  type_ |> should.equal("Feature")
  mag |> should.equal(6.1)
  case decode.run(raw, decode.field("action", decode.string, decode.success)) {
    Error(_) -> True |> should.equal(True)
    Ok(_) -> False |> should.equal(True)
  }
}

pub fn url_is_derived_from_unid_test() {
  let payload =
    "{\"features\":[{\"action\":\"create\",\"data\":{\"type\":\"Feature\",\"properties\":{\"unid\":\"20260918_0000099\",\"time\":\"2026-09-18T00:00:00Z\",\"lastupdate\":\"2026-09-18T00:00:00Z\",\"lat\":1.0,\"lon\":1.0}}}]}"
  let assert Ok(body) = json.parse(payload, decode.dynamic)
  let assert Ok(#(_, features, _, _)) = emsc.decode_body(body)
  let assert [feature] = features
  feature.url
  |> should.equal(option.Some(
    "https://www.seismicportal.eu/eventdetails.html?unid=20260918_0000099",
  ))
}
