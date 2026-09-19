import domain/geometry_transport
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleeunit/should

pub fn scale_factor_test() {
  geometry_transport.scale_factor(0) |> should.equal(1.0)
  geometry_transport.scale_factor(1) |> should.equal(10.0)
  geometry_transport.scale_factor(4) |> should.equal(10_000.0)
  geometry_transport.scale_factor(9) |> should.equal(1_000_000_000.0)
  geometry_transport.scale_factor(10) |> should.equal(1.0)
}

pub fn zigzag_roundtrip_test() {
  let values = [0, 1, -1, 2, -2, 10, -10, 100_000, -100_000, 10_000_000_000]
  list.each(values, fn(v) {
    geometry_transport.zigzag_decode(geometry_transport.zigzag_encode(v))
    |> should.equal(v)
  })
}

pub fn zigzag_encode_matches_standard_test() {
  geometry_transport.zigzag_encode(0) |> should.equal(0)
  geometry_transport.zigzag_encode(-1) |> should.equal(1)
  geometry_transport.zigzag_encode(1) |> should.equal(2)
  geometry_transport.zigzag_encode(-2) |> should.equal(3)
  geometry_transport.zigzag_encode(2) |> should.equal(4)
}

pub fn min_precision_for_float_test() {
  geometry_transport.min_precision_for_float(10.0) |> should.equal(Ok(0))
  geometry_transport.min_precision_for_float(-5.0) |> should.equal(Ok(0))
  geometry_transport.min_precision_for_float(10.5) |> should.equal(Ok(1))
  geometry_transport.min_precision_for_float(-5.2) |> should.equal(Ok(1))
  geometry_transport.min_precision_for_float(10.25) |> should.equal(Ok(2))
  geometry_transport.min_precision_for_float(105.8726) |> should.equal(Ok(4))
  geometry_transport.min_precision_for_float(-8.5419) |> should.equal(Ok(4))
  geometry_transport.min_precision_for_float(12.123456789)
  |> should.equal(Ok(9))
  geometry_transport.min_precision_for_float(1.123456789012)
  |> should.equal(Error(Nil))
}

pub fn encode_ring_roundtrip_test() {
  let points = [
    #(105.8726, -8.5419),
    #(106.1234, -8.1234),
    #(106.5, -8.0),
    #(105.8726, -8.5419),
  ]
  let precision = 4
  let encoded = geometry_transport.encode_ring(points, precision)
  let assert Ok(decoded) =
    geometry_transport.decode_polyline(encoded, precision)

  list.length(decoded) |> should.equal(list.length(points))
  list.zip(points, decoded)
  |> list.each(fn(pair) {
    let #(orig, dec) = pair
    orig.0 |> should.equal(dec.0)
    orig.1 |> should.equal(dec.1)
  })
}

pub fn encode_ring_antimeridian_and_negative_test() {
  let points = [
    #(-180.0, -90.0),
    #(180.0, 90.0),
    #(-179.12345, 89.98765),
    #(-180.0, -90.0),
  ]
  let precision = 5
  let encoded = geometry_transport.encode_ring(points, precision)
  let assert Ok(decoded) =
    geometry_transport.decode_polyline(encoded, precision)

  list.length(decoded) |> should.equal(list.length(points))
  list.zip(points, decoded)
  |> list.each(fn(pair) {
    let #(orig, dec) = pair
    orig.0 |> should.equal(dec.0)
    orig.1 |> should.equal(dec.1)
  })
}

pub fn encode_ring_precision_9_test() {
  let points = [
    #(12.123456789, -45.987654321),
    #(12.987654321, -45.123456789),
    #(12.123456789, -45.987654321),
  ]
  let precision = 9
  let encoded = geometry_transport.encode_ring(points, precision)
  let assert Ok(decoded) =
    geometry_transport.decode_polyline(encoded, precision)

  list.length(decoded) |> should.equal(list.length(points))
  list.zip(points, decoded)
  |> list.each(fn(pair) {
    let #(orig, dec) = pair
    orig.0 |> should.equal(dec.0)
    orig.1 |> should.equal(dec.1)
  })
}

pub fn encode_geometry_text_polygon_with_hole_test() {
  // Outer ring and inner ring (hole); verify prev 0,0 reset per ring
  let geojson =
    "{\"type\":\"Polygon\",\"coordinates\":["
    <> "[[10.0,20.0],[10.0,30.0],[20.0,30.0],[20.0,20.0],[10.0,20.0]],"
    <> "[[12.0,22.0],[12.0,28.0],[18.0,28.0],[18.0,22.0],[12.0,22.0]]"
    <> "]}"

  let assert Ok(encoded_json) = geometry_transport.encode_geometry_text(geojson)
  let encoded_str = json.to_string(encoded_json)

  let assert Ok(type_val) =
    json.parse(encoded_str, decode.at(["type"], decode.string))
  type_val |> should.equal("Polygon")

  let assert Ok(encoding_val) =
    json.parse(encoded_str, decode.at(["encoding"], decode.string))
  encoding_val |> should.equal("polyline")

  let assert Ok(precision_val) =
    json.parse(encoded_str, decode.at(["precision"], decode.int))
  precision_val |> should.equal(0)

  let assert Ok(rings) =
    json.parse(
      encoded_str,
      decode.at(["coordinates"], decode.list(decode.string)),
    )
  list.length(rings) |> should.equal(2)

  let assert Ok(outer_ring_enc) = list.first(rings)
  let assert Ok(inner_ring_enc) = list.last(rings)

  let assert Ok(outer_pts) =
    geometry_transport.decode_polyline(outer_ring_enc, precision_val)
  let assert Ok(inner_pts) =
    geometry_transport.decode_polyline(inner_ring_enc, precision_val)

  list.first(outer_pts) |> should.equal(Ok(#(10.0, 20.0)))
  list.first(inner_pts) |> should.equal(Ok(#(12.0, 22.0)))
}

pub fn encode_geometry_text_multipolygon_test() {
  let geojson =
    "{\"type\":\"MultiPolygon\",\"coordinates\":["
    <> "[[[10.5,20.25],[10.5,30.0],[20.0,30.0],[10.5,20.25]]],"
    <> "[[[40.0,50.0],[40.0,60.0],[50.0,60.0],[40.0,50.0]]]"
    <> "]}"

  let assert Ok(encoded_json) = geometry_transport.encode_geometry_text(geojson)
  let encoded_str = json.to_string(encoded_json)

  let assert Ok(type_val) =
    json.parse(encoded_str, decode.at(["type"], decode.string))
  type_val |> should.equal("MultiPolygon")

  let assert Ok(precision_val) =
    json.parse(encoded_str, decode.at(["precision"], decode.int))
  precision_val |> should.equal(2)

  let assert Ok(polys) =
    json.parse(
      encoded_str,
      decode.at(["coordinates"], decode.list(decode.list(decode.string))),
    )
  list.length(polys) |> should.equal(2)
}

pub fn encode_geometry_text_rejects_3d_coordinates_test() {
  let geojson =
    "{\"type\":\"Polygon\",\"coordinates\":["
    <> "[[10.0,20.0,5.0],[10.0,30.0,5.0],[20.0,30.0,5.0],[10.0,20.0,5.0]]"
    <> "]}"
  geometry_transport.encode_geometry_text(geojson) |> should.equal(Error(Nil))
}

pub fn encode_geometry_text_rejects_out_of_bounds_test() {
  let lon_oob =
    "{\"type\":\"Polygon\",\"coordinates\":["
    <> "[[181.0,20.0],[181.0,30.0],[190.0,30.0],[181.0,20.0]]"
    <> "]}"
  geometry_transport.encode_geometry_text(lon_oob) |> should.equal(Error(Nil))

  let lat_oob =
    "{\"type\":\"Polygon\",\"coordinates\":["
    <> "[[10.0,-91.0],[10.0,-80.0],[20.0,-80.0],[10.0,-91.0]]"
    <> "]}"
  geometry_transport.encode_geometry_text(lat_oob) |> should.equal(Error(Nil))
}

pub fn encode_geometry_text_rejects_extra_fields_test() {
  let with_bbox =
    "{\"type\":\"Polygon\",\"coordinates\":["
    <> "[[10.0,20.0],[10.0,30.0],[20.0,30.0],[10.0,20.0]]"
    <> "],\"bbox\":[10.0,20.0,20.0,30.0]}"
  geometry_transport.encode_geometry_text(with_bbox) |> should.equal(Error(Nil))
}

pub fn encode_geometry_text_rejects_non_polygon_test() {
  let point = "{\"type\":\"Point\",\"coordinates\":[10.0,20.0]}"
  geometry_transport.encode_geometry_text(point) |> should.equal(Error(Nil))
}

pub fn encode_geometry_text_rejects_excessive_precision_test() {
  let high_prec =
    "{\"type\":\"Polygon\",\"coordinates\":["
    <> "[[10.123456789012,20.0],[10.0,30.0],[20.0,30.0],[10.123456789012,20.0]]"
    <> "]}"
  geometry_transport.encode_geometry_text(high_prec) |> should.equal(Error(Nil))
}
