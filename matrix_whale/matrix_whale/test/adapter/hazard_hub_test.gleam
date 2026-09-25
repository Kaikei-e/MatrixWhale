import adapter/hazard_hub
import domain/geometry_transport
import domain/hazard
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/string
import gleam/time/timestamp
import gleeunit/should

fn make_hazard(id: String, polygon_text: String) -> hazard.Hazard {
  let ts = timestamp.from_unix_seconds(1_789_378_058)
  hazard.Hazard(
    source: "gdacs",
    source_id: id,
    source_episode_id: Some("2001"),
    episode_count: 1,
    hazard_type: "earthquake",
    hazard_codes: ["glide:EQ"],
    glide: None,
    alert_level: "green",
    alert_score: Some(1.0),
    cap_severity: "minor",
    severity_value: Some(5.0),
    severity_unit: Some("M"),
    severity_label: Some("Magnitude 5.0M"),
    estimate_type: "primary",
    title: "Test Earthquake " <> id,
    description: Some("Test Earthquake description"),
    countries: ["IDN"],
    report_url: None,
    external_ids: [],
    onset_at: ts,
    onset_at_ms: 1_789_378_058_000,
    expires_at: None,
    expires_at_ms: None,
    modified_at: ts,
    modified_at_ms: 1_789_378_058_000,
    is_current: True,
    longitude: 105.8726,
    latitude: -8.5419,
    bbox: None,
    primary_geometry: Some(polygon_text),
    geometries: None,
    first_seen_at: ts,
    last_seen_at: ts,
    subtype: None,
    confirmed: None,
  )
}

const sample_polygon_geojson = "{\"type\":\"Polygon\",\"coordinates\":[[[105.8726,-8.5419],[106.0,-8.0],[105.0,-8.0],[105.8726,-8.5419]]]}"

pub fn two_cohorts_delivery_and_payload_distinction_test() {
  let assert Ok(actor.Started(_, hub)) = hazard_hub.start()
  let std_sub = process.new_subject()
  let compact_sub = process.new_subject()

  let std_id = hazard_hub.subscribe(hub, std_sub, None)
  let compact_id = hazard_hub.subscribe_compact(hub, compact_sub, None)

  // IDs are distinct positive integers
  { std_id != compact_id } |> should.equal(True)

  // Both receive initial Heartbeat on connect
  let assert Ok(hazard_hub.Heartbeat(hb_std)) = process.receive(std_sub, 1000)
  let assert Ok(hazard_hub.Heartbeat(hb_compact)) =
    process.receive(compact_sub, 1000)
  hb_std |> should.equal(hb_compact)

  let h = make_hazard("EQ-1001", sample_polygon_geojson)
  hazard_hub.publish(hub, [h], [])

  // Standard client receives legacy GeoJSON payload
  let assert Ok(hazard_hub.Emit(std_event, std_event_id, std_data)) =
    process.receive(std_sub, 1000)
  std_event |> should.equal("new")

  // Compact client receives compact polyline-encoded payload
  let assert Ok(hazard_hub.Emit(compact_event, compact_event_id, compact_data)) =
    process.receive(compact_sub, 1000)
  compact_event |> should.equal("new")

  // Event IDs must be identical
  std_event_id |> should.equal(compact_event_id)

  // Standard geometry: GeoJSON Polygon without "encoding" field
  let assert Ok(std_geom_type) =
    json.parse(std_data, decode.at(["primary_geometry", "type"], decode.string))
  std_geom_type |> should.equal("Polygon")
  case
    json.parse(
      std_data,
      decode.at(["primary_geometry", "encoding"], decode.string),
    )
  {
    Error(_) -> True |> should.equal(True)
    Ok(_) -> False |> should.equal(True)
  }

  // Compact geometry: Polygon with encoding "polyline", precision 4, coordinates as list of string
  let assert Ok(compact_geom_type) =
    json.parse(
      compact_data,
      decode.at(["primary_geometry", "type"], decode.string),
    )
  compact_geom_type |> should.equal("Polygon")

  let assert Ok(compact_encoding) =
    json.parse(
      compact_data,
      decode.at(["primary_geometry", "encoding"], decode.string),
    )
  compact_encoding |> should.equal("polyline")

  let assert Ok(compact_precision) =
    json.parse(
      compact_data,
      decode.at(["primary_geometry", "precision"], decode.int),
    )
  compact_precision |> should.equal(4)

  let assert Ok(compact_rings) =
    json.parse(
      compact_data,
      decode.at(["primary_geometry", "coordinates"], decode.list(decode.string)),
    )
  list.length(compact_rings) |> should.equal(1)
}

pub fn exact_geometry_decode_roundtrip_test() {
  let assert Ok(actor.Started(_, hub)) = hazard_hub.start()
  let compact_sub = process.new_subject()
  let _ = hazard_hub.subscribe_compact(hub, compact_sub, None)
  let assert Ok(hazard_hub.Heartbeat(_)) = process.receive(compact_sub, 1000)

  let original_coords = [
    #(105.8726, -8.5419),
    #(106.0, -8.0),
    #(105.0, -8.0),
    #(105.8726, -8.5419),
  ]
  let h = make_hazard("EQ-1002", sample_polygon_geojson)
  hazard_hub.publish(hub, [h], [])

  let assert Ok(hazard_hub.Emit(_, _, compact_data)) =
    process.receive(compact_sub, 1000)

  let assert Ok(precision) =
    json.parse(
      compact_data,
      decode.at(["primary_geometry", "precision"], decode.int),
    )
  let assert Ok(rings) =
    json.parse(
      compact_data,
      decode.at(["primary_geometry", "coordinates"], decode.list(decode.string)),
    )
  let assert Ok(first_ring_enc) = list.first(rings)

  // Lossless decode roundtrip
  let assert Ok(decoded_coords) =
    geometry_transport.decode_polyline(first_ring_enc, precision)

  list.length(decoded_coords) |> should.equal(list.length(original_coords))
  list.zip(original_coords, decoded_coords)
  |> list.each(fn(pair) {
    let #(orig, dec) = pair
    orig.0 |> should.equal(dec.0)
    orig.1 |> should.equal(dec.1)
  })
}

pub fn metadata_and_id_ordering_test() {
  let assert Ok(actor.Started(_, hub)) = hazard_hub.start()
  let std_sub = process.new_subject()
  let compact_sub = process.new_subject()

  let _ = hazard_hub.subscribe(hub, std_sub, None)
  let _ = hazard_hub.subscribe_compact(hub, compact_sub, None)
  let assert Ok(hazard_hub.Heartbeat(_)) = process.receive(std_sub, 1000)
  let assert Ok(hazard_hub.Heartbeat(_)) = process.receive(compact_sub, 1000)

  let h1 = make_hazard("EQ-101", sample_polygon_geojson)
  let h2 = make_hazard("TC-102", sample_polygon_geojson)
  let h3 = make_hazard("FL-103", sample_polygon_geojson)

  // 2 new hazards, 1 updated hazard
  hazard_hub.publish(hub, [h1, h2], [h3])

  // Event 1: new h1
  let assert Ok(hazard_hub.Emit(s_ev1, s_id1, s_data1)) =
    process.receive(std_sub, 1000)
  let assert Ok(hazard_hub.Emit(c_ev1, c_id1, c_data1)) =
    process.receive(compact_sub, 1000)
  s_ev1 |> should.equal("new")
  c_ev1 |> should.equal("new")
  s_id1 |> should.equal(c_id1)

  // Event 2: new h2
  let assert Ok(hazard_hub.Emit(s_ev2, s_id2, s_data2)) =
    process.receive(std_sub, 1000)
  let assert Ok(hazard_hub.Emit(c_ev2, c_id2, c_data2)) =
    process.receive(compact_sub, 1000)
  s_ev2 |> should.equal("new")
  c_ev2 |> should.equal("new")
  s_id2 |> should.equal(c_id2)

  // Event 3: update h3
  let assert Ok(hazard_hub.Emit(s_ev3, s_id3, s_data3)) =
    process.receive(std_sub, 1000)
  let assert Ok(hazard_hub.Emit(c_ev3, c_id3, c_data3)) =
    process.receive(compact_sub, 1000)
  s_ev3 |> should.equal("update")
  c_ev3 |> should.equal("update")
  s_id3 |> should.equal(c_id3)

  // Strict ordering across sequential IDs
  { s_id1 != s_id2 } |> should.equal(True)
  { s_id2 != s_id3 } |> should.equal(True)

  // Metadata parity between cohorts
  let assert Ok(s_id_field) =
    json.parse(s_data1, decode.at(["id"], decode.string))
  let assert Ok(c_id_field) =
    json.parse(c_data1, decode.at(["id"], decode.string))
  s_id_field |> should.equal(c_id_field)

  let assert Ok(s_source_id) =
    json.parse(s_data2, decode.at(["source_id"], decode.string))
  let assert Ok(c_source_id) =
    json.parse(c_data2, decode.at(["source_id"], decode.string))
  s_source_id |> should.equal(c_source_id)

  let assert Ok(s_hazard_type) =
    json.parse(s_data3, decode.at(["hazard_type"], decode.string))
  let assert Ok(c_hazard_type) =
    json.parse(c_data3, decode.at(["hazard_type"], decode.string))
  s_hazard_type |> should.equal(c_hazard_type)
}

pub fn reconnect_resync_and_heartbeat_test() {
  let assert Ok(actor.Started(_, hub)) = hazard_hub.start()

  // Publish an event first so next_event advances
  let h = make_hazard("EQ-1004", sample_polygon_geojson)
  hazard_hub.publish(hub, [h], [])

  let std_sub = process.new_subject()
  let compact_sub = process.new_subject()

  // Reconnect with a since token (last event id)
  let _ = hazard_hub.subscribe(hub, std_sub, Some("reconnect-epoch:0"))
  let assert Ok(hazard_hub.Resync(std_resync_id)) =
    process.receive(std_sub, 1000)
  let assert Ok(hazard_hub.Heartbeat(std_hb_id)) =
    process.receive(std_sub, 1000)
  std_resync_id |> should.equal(std_hb_id)

  let _ =
    hazard_hub.subscribe_compact(hub, compact_sub, Some("reconnect-epoch:0"))
  let assert Ok(hazard_hub.Resync(compact_resync_id)) =
    process.receive(compact_sub, 1000)
  let assert Ok(hazard_hub.Heartbeat(compact_hb_id)) =
    process.receive(compact_sub, 1000)
  compact_resync_id |> should.equal(compact_hb_id)

  // Both cohorts receive the identical last event ID on resync/heartbeat
  std_resync_id |> should.equal(compact_resync_id)
}

pub fn unsubscribe_and_isolation_test() {
  let assert Ok(actor.Started(_, hub)) = hazard_hub.start()
  let std_sub = process.new_subject()
  let compact_sub = process.new_subject()

  let std_id = hazard_hub.subscribe(hub, std_sub, None)
  let compact_id = hazard_hub.subscribe_compact(hub, compact_sub, None)
  let assert Ok(hazard_hub.Heartbeat(_)) = process.receive(std_sub, 1000)
  let assert Ok(hazard_hub.Heartbeat(_)) = process.receive(compact_sub, 1000)

  // Unsubscribe standard client
  hazard_hub.unsubscribe(hub, std_id)

  let h1 = make_hazard("EQ-1005", sample_polygon_geojson)
  hazard_hub.publish(hub, [h1], [])

  // Standard client receives nothing
  process.receive(std_sub, 100) |> should.equal(Error(Nil))

  // Compact client receives event
  let assert Ok(hazard_hub.Emit(_, _, _)) = process.receive(compact_sub, 1000)

  // Unsubscribe compact client
  hazard_hub.unsubscribe(hub, compact_id)

  let h2 = make_hazard("EQ-1006", sample_polygon_geojson)
  hazard_hub.publish(hub, [h2], [])

  // Neither receives anything
  process.receive(std_sub, 100) |> should.equal(Error(Nil))
  process.receive(compact_sub, 100) |> should.equal(Error(Nil))
}

pub fn skip_unused_representation_and_zero_subscriber_test() {
  let assert Ok(actor.Started(_, hub)) = hazard_hub.start()

  // Publishing with zero subscribers succeeds cleanly
  let h1 = make_hazard("EQ-1007", sample_polygon_geojson)
  hazard_hub.publish(hub, [h1], [])

  // Only standard subscriber connected: publication delivers to standard
  let std_sub = process.new_subject()
  let _ = hazard_hub.subscribe(hub, std_sub, None)
  let assert Ok(hazard_hub.Heartbeat(_)) = process.receive(std_sub, 1000)

  let h2 = make_hazard("EQ-1008", sample_polygon_geojson)
  hazard_hub.publish(hub, [h2], [])
  let assert Ok(hazard_hub.Emit(_, _, _)) = process.receive(std_sub, 1000)

  // Only compact subscriber connected: publication delivers to compact
  let compact_sub = process.new_subject()
  let _ = hazard_hub.subscribe_compact(hub, compact_sub, None)
  let assert Ok(hazard_hub.Heartbeat(_)) = process.receive(compact_sub, 1000)

  let h3 = make_hazard("EQ-1009", sample_polygon_geojson)
  hazard_hub.publish(hub, [h3], [])
  let assert Ok(hazard_hub.Emit(_, _, _)) = process.receive(compact_sub, 1000)
}

pub fn serialized_byte_size_measurement_test() {
  let h = make_hazard("EQ-1010", sample_polygon_geojson)
  let legacy_json = json.to_string(hazard.to_json(h))
  let compact_json = json.to_string(hazard.to_polyline_json(h))

  let legacy_bytes = string.byte_size(legacy_json)
  let compact_bytes = string.byte_size(compact_json)

  // Compact polyline geometry reduces serialized payload size compared to standard GeoJSON
  { compact_bytes < legacy_bytes } |> should.equal(True)

  // Fallback case: point geometry (e.g. no polygon) has identical size
  let h_none = hazard.Hazard(..h, primary_geometry: None)
  let legacy_none = json.to_string(hazard.to_json(h_none))
  let compact_none = json.to_string(hazard.to_polyline_json(h_none))
  string.byte_size(compact_none) |> should.equal(string.byte_size(legacy_none))
}
