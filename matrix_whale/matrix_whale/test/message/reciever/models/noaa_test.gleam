import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option
import gleeunit/should
import message/reciever/models/noaa

const base_properties = "
    \"@id\": \"https://api.weather.gov/alerts/urn:oid:2.49.0.1.840.0.test1\",
    \"id\": \"urn:oid:2.49.0.1.840.0.test1\",
    \"areaDesc\": \"Test County\",
    \"geocode\": {\"SAME\": [\"040143\"], \"UGC\": [\"OKC143\"]},
    \"affectedZones\": [\"https://api.weather.gov/zones/county/OKC143\"],
    \"references\": [
      {
        \"@id\": \"https://api.weather.gov/alerts/urn:oid:2.49.0.1.840.0.ref1\",
        \"identifier\": \"urn:oid:2.49.0.1.840.0.ref1\",
        \"sender\": \"w-nws.webmaster@noaa.gov\",
        \"sent\": \"2024-12-03T07:00:00-06:00\"
      }
    ],
    \"sent\": \"2024-12-03T07:37:00-06:00\",
    \"effective\": \"2024-12-03T07:37:00-06:00\",
    \"onset\": \"2024-12-03T07:37:00-06:00\",
    \"expires\": \"2024-12-03T08:37:00-06:00\",
    \"ends\": null,
    \"messageType\": \"Alert\",
    \"category\": \"Met\",
    \"certainty\": \"Observed\",
    \"urgency\": \"Immediate\",
    \"event\": \"Tornado Warning\",
    \"sender\": \"w-nws.webmaster@noaa.gov\",
    \"senderName\": \"NWS Norman OK\",
    \"headline\": \"Tornado Warning issued\",
    \"description\": \"A tornado warning is in effect.\",
    \"instruction\": \"Take cover now.\",
    \"response\": \"Shelter\",
    \"parameters\": {\"NWSheadline\": [\"TORNADO WARNING\"]}
"

fn feature_json(
  id id: String,
  geometry geometry: String,
  status status: String,
  severity severity: String,
) -> String {
  "{
    \"id\": \"" <> id <> "\",
    \"type\": \"Feature\",
    \"geometry\": " <> geometry <> ",
    \"properties\": {" <> base_properties <> ",
      \"status\": \"" <> status <> "\",
      \"severity\": \"" <> severity <> "\"
    }
  }"
}

fn parse_feature(text: String) -> Result(noaa.FeatureElement, List(String)) {
  let assert Ok(dynamic_value) = json.parse(text, decode.dynamic)
  noaa.decode_feature(dynamic_value)
}

pub fn decode_polygon_geometry_test() {
  let geometry =
    "{\"type\": \"Polygon\", \"coordinates\": [[[-97.5, 35.5], [-97.4, 35.5], [-97.4, 35.6], [-97.5, 35.5]]]}"
  let assert Ok(feature) =
    parse_feature(feature_json(
      id: "urn:oid:2.49.0.1.840.0.polygon",
      geometry: geometry,
      status: "Actual",
      severity: "Severe",
    ))

  let assert option.Some(noaa.Geometry(type_: "Polygon", polygons: polygons)) =
    feature.geometry

  polygons
  |> should.equal([
    [[#(-97.5, 35.5), #(-97.4, 35.5), #(-97.4, 35.6), #(-97.5, 35.5)]],
  ])
}

pub fn decode_multi_polygon_geometry_test() {
  let geometry =
    "{\"type\": \"MultiPolygon\", \"coordinates\": ["
    <> "[[[-97.5, 35.5], [-97.4, 35.5], [-97.4, 35.6], [-97.5, 35.5]]],"
    <> "[[[-98.5, 36.5], [-98.4, 36.5], [-98.4, 36.6], [-98.5, 36.5]]]"
    <> "]}"
  let assert Ok(feature) =
    parse_feature(feature_json(
      id: "urn:oid:2.49.0.1.840.0.multipolygon",
      geometry: geometry,
      status: "Actual",
      severity: "Severe",
    ))

  let assert option.Some(noaa.Geometry(
    type_: "MultiPolygon",
    polygons: polygons,
  )) = feature.geometry

  list.length(polygons) |> should.equal(2)
}

pub fn decode_geometry_null_test() {
  let assert Ok(feature) =
    parse_feature(feature_json(
      id: "urn:oid:2.49.0.1.840.0.nullgeom",
      geometry: "null",
      status: "Actual",
      severity: "Severe",
    ))

  feature.geometry |> should.equal(option.None)
}

pub fn decode_extreme_severity_test() {
  let assert Ok(feature) =
    parse_feature(feature_json(
      id: "urn:oid:2.49.0.1.840.0.extreme",
      geometry: "null",
      status: "Actual",
      severity: "Extreme",
    ))

  feature.properties.severity |> should.equal(noaa.Extreme)
  noaa.severity_to_string(feature.properties.severity)
  |> should.equal("Extreme")
}

pub fn decode_geocode_same_ugc_test() {
  let assert Ok(feature) =
    parse_feature(feature_json(
      id: "urn:oid:2.49.0.1.840.0.geocode",
      geometry: "null",
      status: "Actual",
      severity: "Severe",
    ))

  feature.properties.geocode.same |> should.equal(["040143"])
  feature.properties.geocode.ugc |> should.equal(["OKC143"])
}

pub fn decode_reference_at_id_test() {
  let assert Ok(feature) =
    parse_feature(feature_json(
      id: "urn:oid:2.49.0.1.840.0.reference",
      geometry: "null",
      status: "Actual",
      severity: "Severe",
    ))

  let assert [reference] = feature.properties.references
  reference.id
  |> should.equal("https://api.weather.gov/alerts/urn:oid:2.49.0.1.840.0.ref1")
}

pub fn decode_properties_at_id_and_id_test() {
  let assert Ok(feature) =
    parse_feature(feature_json(
      id: "urn:oid:2.49.0.1.840.0.propid",
      geometry: "null",
      status: "Actual",
      severity: "Severe",
    ))

  feature.properties.id
  |> should.equal(option.Some(
    "https://api.weather.gov/alerts/urn:oid:2.49.0.1.840.0.test1",
  ))
  feature.properties.properties_id
  |> should.equal(option.Some("urn:oid:2.49.0.1.840.0.test1"))
}

pub fn decode_integer_coordinates_test() {
  let geometry =
    "{\"type\": \"Polygon\", \"coordinates\": [[[-97, 35], [-96, 35], [-96, 36], [-97, 35]]]}"
  let assert Ok(feature) =
    parse_feature(feature_json(
      id: "urn:oid:2.49.0.1.840.0.intcoords",
      geometry: geometry,
      status: "Actual",
      severity: "Severe",
    ))

  let assert option.Some(noaa.Geometry(polygons: [[ring]], ..)) =
    feature.geometry
  ring
  |> should.equal([
    #(-97.0, 35.0),
    #(-96.0, 35.0),
    #(-96.0, 36.0),
    #(-97.0, 35.0),
  ])
}

pub fn geometry_to_json_round_trip_test() {
  let original =
    noaa.Geometry(type_: "MultiPolygon", polygons: [
      [[#(-97.5, 35.5), #(-97.4, 35.5), #(-97.4, 35.6), #(-97.5, 35.5)]],
      [[#(-98.5, 36.5), #(-98.4, 36.5), #(-98.4, 36.6), #(-98.5, 36.5)]],
    ])

  let text = noaa.geometry_to_json(original) |> json.to_string
  let decoded = json.parse(text, noaa.decode_geometry())

  decoded |> should.equal(Ok(original))
}

pub fn status_test_is_filtered_while_unknown_severity_is_kept_test() {
  let assert Ok(test_feature) =
    parse_feature(feature_json(
      id: "urn:oid:2.49.0.1.840.0.teststatus",
      geometry: "null",
      status: "Test",
      severity: "Severe",
    ))
  let assert Ok(unknown_severity_feature) =
    parse_feature(feature_json(
      id: "urn:oid:2.49.0.1.840.0.unknownseverity",
      geometry: "null",
      status: "Actual",
      severity: "SomethingUnexpected",
    ))

  let features = [test_feature, unknown_severity_feature]
  let kept =
    features
    |> list.filter(fn(feature) { feature.properties.status != noaa.Test })

  kept |> should.equal([unknown_severity_feature])
  unknown_severity_feature.properties.severity
  |> should.equal(noaa.UnknownSeverity)
}

pub fn decode_body_without_poll_meta_test() {
  let body =
    "{\"type\": \"FeatureCollection\", \"features\": ["
    <> feature_json(
      id: "urn:oid:2.49.0.1.840.0.legacy",
      geometry: "null",
      status: "Actual",
      severity: "Moderate",
    )
    <> "]}"

  let assert Ok(dynamic_value) = json.parse(body, decode.dynamic)
  let #(poll_meta, features, received, dropped) =
    noaa.decode_body(dynamic_value)

  poll_meta |> should.equal(option.None)
  list.length(features) |> should.equal(1)
  received |> should.equal(1)
  dropped |> should.equal(0)
}

pub fn decode_body_with_poll_meta_and_dropped_feature_test() {
  let body =
    "{\"poll_meta\": {\"fetched_at\": \"2024-12-03T07:37:00Z\", \"http_status\": 200, \"feature_count\": 2}, \"features\": ["
    <> feature_json(
      id: "urn:oid:2.49.0.1.840.0.valid",
      geometry: "null",
      status: "Actual",
      severity: "Moderate",
    )
    <> ", {\"id\": \"urn:oid:2.49.0.1.840.0.broken\", \"type\": \"Feature\"}"
    <> "]}"

  let assert Ok(dynamic_value) = json.parse(body, decode.dynamic)
  let #(poll_meta, features, received, dropped) =
    noaa.decode_body(dynamic_value)

  poll_meta
  |> should.equal(
    option.Some(noaa.PollMeta(
      fetched_at: "2024-12-03T07:37:00Z",
      http_status: 200,
      feature_count: 2,
    )),
  )
  list.length(features) |> should.equal(1)
  received |> should.equal(2)
  dropped |> should.equal(1)
}
