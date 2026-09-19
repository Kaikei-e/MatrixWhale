import domain/cap_geometry
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import message/reciever/models/cap as models_cap

pub fn coordinate_formatting_test() {
  // At least 5 decimals (6 decimals emitted), plain decimal, no scientific notation
  cap_geometry.format_coordinate(0.0) |> should.equal("0.000000")
  cap_geometry.format_coordinate(180.0) |> should.equal("180.000000")
  cap_geometry.format_coordinate(-19.0487) |> should.equal("-19.048700")
  cap_geometry.format_coordinate(-169.8619) |> should.equal("-169.861900")
  // Small float that would trigger scientific notation in float.to_string
  cap_geometry.format_coordinate(0.00001) |> should.equal("0.000010")
  cap_geometry.format_coordinate(-0.000005) |> should.equal("-0.000005")
}

pub fn polygon_ring_closing_test() {
  // 3 points (triangle) not closed -> gets closed to 4 points
  let unclosed = "10.0,20.0 10.0,25.0 15.0,25.0"
  let assert Some(ring) = cap_geometry.parse_polygon(unclosed)
  list.length(ring) |> should.equal(4)
  let assert Ok(first) = list.first(ring)
  let assert Ok(last) = list.last(ring)
  first |> should.equal(last)
  first |> should.equal(#(20.0, 10.0))

  // Already closed ring retains points
  let closed = "10.0,20.0 10.0,25.0 15.0,25.0 10.0,20.0"
  let assert Some(ring2) = cap_geometry.parse_polygon(closed)
  list.length(ring2) |> should.equal(4)
}

pub fn polygon_too_short_ring_dropped_test() {
  // Only 2 points -> after closing has 3 points (< 4) -> dropped
  let two_points = "10.0,20.0 10.0,25.0"
  cap_geometry.parse_polygon(two_points) |> should.equal(None)

  // Empty string -> dropped
  cap_geometry.parse_polygon("") |> should.equal(None)
}

pub fn polygon_out_of_range_points_skipped_test() {
  // Ring with an out-of-range point (|lat| > 90 or |lon| > 180) and unparseable chunk
  let poly =
    "10.0,20.0 95.0,20.0 10.0,195.0 bad_chunk 10.0,25.0 15.0,25.0 10.0,20.0"
  let assert Some(ring) = cap_geometry.parse_polygon(poly)
  // The 2 out-of-range points and 1 bad chunk are skipped, leaving the 4 valid points
  list.length(ring) |> should.equal(4)
  let assert Ok(first) = list.first(ring)
  let assert Ok(last) = list.last(ring)
  first |> should.equal(last)
}

pub fn polygon_antimeridian_shift_test() {
  // Polygon crossing 180° meridian (e.g. lon 179 to lon -179)
  // In CAP lat,lon: "10.0,179.0 10.0,-179.0 15.0,-179.0 15.0,179.0 10.0,179.0"
  let cross_poly = "10.0,179.0 10.0,-179.0 15.0,-179.0 15.0,179.0 10.0,179.0"
  let assert Some(ring) = cap_geometry.parse_polygon(cross_poly)

  // Longitudes in GeoJSON are p.0
  // Negative longitudes (-179.0) should have +360 added -> 181.0
  let lons = list.map(ring, fn(p) { p.0 })
  lons |> should.equal([179.0, 181.0, 181.0, 179.0, 179.0])

  // Regular polygon not crossing 180°: no shift
  let regular_poly = "10.0,-50.0 10.0,-45.0 15.0,-45.0 10.0,-50.0"
  let assert Some(reg_ring) = cap_geometry.parse_polygon(regular_poly)
  let reg_lons = list.map(reg_ring, fn(p) { p.0 })
  reg_lons |> should.equal([-50.0, -45.0, -45.0, -50.0])
}

pub fn circle_samoa_fixture_test() {
  // Samoa circle fixture: "-19.0487,-169.8619 14"
  let samoa_str = "-19.0487,-169.8619 14"
  let assert Some(ring) = cap_geometry.parse_circle(samoa_str)

  // Closed 32-vertex ring: 32 vertices + 1 closure point = 33 points
  list.length(ring) |> should.equal(33)

  let assert Ok(first) = list.first(ring)
  let assert Ok(last) = list.last(ring)
  first |> should.equal(last)

  // Points should be within expected bounds around Samoa (-19.0487 lat, -169.8619 lon)
  let assert Ok(min_lat) =
    list.map(ring, fn(p) { p.1 }) |> list.reduce(should_min)
  let assert Ok(max_lat) =
    list.map(ring, fn(p) { p.1 }) |> list.reduce(should_max)
  should.be_true(min_lat <. -19.0487)
  should.be_true(max_lat >. -19.0487)
}

pub fn circle_radius_zero_and_negative_test() {
  // Radius 0 -> skipped
  cap_geometry.parse_circle("10.0,20.0 0") |> should.equal(None)
  cap_geometry.parse_circle("10.0,20.0 0.0") |> should.equal(None)

  // Negative radius -> skipped
  cap_geometry.parse_circle("10.0,20.0 -5") |> should.equal(None)
  cap_geometry.parse_circle("10.0,20.0 -14.2") |> should.equal(None)

  // Unparseable circle
  cap_geometry.parse_circle("10.0,20.0 abc") |> should.equal(None)
  cap_geometry.parse_circle("invalid") |> should.equal(None)
}

pub fn geojson_multipolygon_output_test() {
  // Single ring — exact full-string assertion
  // Polygon: 10.0,20.0 10.0,25.0 15.0,25.0 10.0,20.0 (lat,lon → GeoJSON [lon,lat])
  // Points after parse: [lon=20,lat=10], [25,10], [25,15], [20,10] — already closed
  let poly = "10.0,20.0 10.0,25.0 15.0,25.0 10.0,20.0"
  let assert Some(one_ring_json) =
    cap_geometry.geometries_to_geojson([poly], [])
  one_ring_json
  |> should.equal(
    "{\"type\":\"MultiPolygon\",\"coordinates\":[[[[20.000000,10.000000],[25.000000,10.000000],[25.000000,15.000000],[20.000000,10.000000]]]]}",
  )

  // Two polygons — exactly 4 opening brackets per polygon block
  let poly2 = "0.0,0.0 0.0,5.0 5.0,5.0 0.0,0.0"
  let assert Some(two_ring_json) =
    cap_geometry.geometries_to_geojson([poly, poly2], [])
  two_ring_json
  |> should.equal(
    "{\"type\":\"MultiPolygon\",\"coordinates\":[[[[20.000000,10.000000],[25.000000,10.000000],[25.000000,15.000000],[20.000000,10.000000]]],[[[0.000000,0.000000],[5.000000,0.000000],[5.000000,5.000000],[0.000000,0.000000]]]]}",
  )

  // Circle first vertex: exactly 4 `[` after "coordinates":`, followed by the exact first vertex
  let samoa = "-19.0487,-169.8619 14"
  let assert Some(circle_json) = cap_geometry.geometries_to_geojson([], [samoa])
  let assert Ok(#(_, after_coords)) =
    string.split_once(circle_json, "\"coordinates\":")
  should.be_true(string.starts_with(after_coords, "[[[["))
  should.be_false(string.starts_with(after_coords, "[[[[["))
  should.be_true(string.starts_with(
    circle_json,
    "{\"type\":\"MultiPolygon\",\"coordinates\":[[[[-169.728851,-19.048700],",
  ))
  should.be_true(string.ends_with(circle_json, "]]]]}"))

  // Empty geometry → None
  cap_geometry.geometries_to_geojson([], []) |> should.equal(None)

  // Areas helper with geocode-only area → None
  let empty_area =
    models_cap.CapArea(
      area_desc: "Geocode only",
      polygon: [],
      circle: [],
      geocode: [],
      altitude: None,
      ceiling: None,
    )
  cap_geometry.areas_to_geojson([empty_area]) |> should.equal(None)
}

fn should_min(a: Float, b: Float) -> Float {
  case a <. b {
    True -> a
    False -> b
  }
}

fn should_max(a: Float, b: Float) -> Float {
  case a >. b {
    True -> a
    False -> b
  }
}

pub fn parse_number_scientific_test() {
  // Scientific notation without a decimal point in the mantissa
  cap_geometry.parse_number("5e-06") |> should.equal(Ok(0.000005))
  cap_geometry.parse_number("-1E+2") |> should.equal(Ok(-100.0))

  // Leading "+" sign
  cap_geometry.parse_number("+12.5") |> should.equal(Ok(12.5))

  // Plain integer (no decimal, no exponent)
  cap_geometry.parse_number("12") |> should.equal(Ok(12.0))

  // Normal floats still work
  cap_geometry.parse_number("3.14") |> should.equal(Ok(3.14))
  cap_geometry.parse_number("-0.5") |> should.equal(Ok(-0.5))

  // Invalid
  cap_geometry.parse_number("abc") |> should.equal(Error(Nil))
  cap_geometry.parse_number("") |> should.equal(Error(Nil))
}
