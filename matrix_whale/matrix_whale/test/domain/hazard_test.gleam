import domain/hazard
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/time/timestamp
import gleeunit/should

pub fn hazard_type_for_covers_all_gdacs_types_test() {
  hazard.hazard_type_for("EQ") |> should.equal("earthquake")
  hazard.hazard_type_for("TC") |> should.equal("tropical_cyclone")
  hazard.hazard_type_for("FL") |> should.equal("flood")
  hazard.hazard_type_for("VO") |> should.equal("volcano")
  hazard.hazard_type_for("WF") |> should.equal("wildfire")
  hazard.hazard_type_for("DR") |> should.equal("drought")
  hazard.hazard_type_for("TS") |> should.equal("tsunami")
}

pub fn hazard_codes_for_eq_has_all_three_test() {
  hazard.hazard_codes_for("EQ")
  |> should.equal(["glide:EQ", "emdat:nat-geo-ear-gro", "undrr-isc-2025:GH0101"])
}

pub fn hazard_codes_for_wf_omits_undrr_test() {
  hazard.hazard_codes_for("WF")
  |> should.equal(["glide:WF", "emdat:nat-cli-wil-for"])
}

pub fn cap_severity_for_maps_alert_levels_test() {
  hazard.cap_severity_for("Green") |> should.equal("minor")
  hazard.cap_severity_for("Orange") |> should.equal("severe")
  hazard.cap_severity_for("Red") |> should.equal("extreme")
}

pub fn external_ids_for_neic_with_id_test() {
  hazard.external_ids_for(Some("NEIC"), "us7000thc6")
  |> should.equal(["usgs:us7000thc6"])
}

pub fn external_ids_for_neic_without_id_is_empty_test() {
  hazard.external_ids_for(Some("NEIC"), "") |> should.equal([])
}

pub fn external_ids_for_other_source_is_empty_test() {
  hazard.external_ids_for(Some("JTWC"), "anything") |> should.equal([])
}

pub fn merge_origin_keeps_current_when_incoming_is_empty_test() {
  hazard.merge_origin(None, None, Some("NEIC"), Some("us7000backfill"))
  |> should.equal(#(Some("NEIC"), Some("us7000backfill")))
}

pub fn merge_origin_prefers_incoming_when_present_test() {
  hazard.merge_origin(
    Some("NEIC"),
    Some("us7000new"),
    Some("NEIC"),
    Some("us7000backfill"),
  )
  |> should.equal(#(Some("NEIC"), Some("us7000new")))
}

pub fn merge_origin_is_none_when_neither_has_a_value_test() {
  hazard.merge_origin(None, None, None, None) |> should.equal(#(None, None))
}

pub fn origin_from_geometry_picks_first_feature_with_sourceid_test() {
  let text =
    "{\"type\":\"FeatureCollection\",\"features\":["
    <> "{\"properties\":{\"Class\":\"Point_Centroid\",\"source\":\"NEIC\",\"sourceid\":\"us7000ti1p\"}},"
    <> "{\"properties\":{\"Class\":\"Poly_Circle\",\"source\":\"NEIC\",\"sourceid\":\"us7000ti1p\"}}"
    <> "]}"
  hazard.origin_from_geometry(text)
  |> should.equal(Some(#("NEIC", "us7000ti1p")))
}

pub fn origin_from_geometry_skips_features_with_empty_sourceid_test() {
  let text =
    "{\"type\":\"FeatureCollection\",\"features\":["
    <> "{\"properties\":{\"Class\":\"Point_Centroid\",\"source\":\"\",\"sourceid\":\"\"}},"
    <> "{\"properties\":{\"Class\":\"Poly_Circle\",\"source\":\"NEIC\",\"sourceid\":\"us7000ti1p\"}}"
    <> "]}"
  hazard.origin_from_geometry(text)
  |> should.equal(Some(#("NEIC", "us7000ti1p")))
}

pub fn origin_from_geometry_returns_none_without_sourceid_test() {
  let text =
    "{\"type\":\"FeatureCollection\",\"features\":["
    <> "{\"properties\":{\"Class\":\"Point_Centroid\"}}"
    <> "]}"
  hazard.origin_from_geometry(text) |> should.equal(None)
}

pub fn origin_from_geometry_invalid_json_is_none_test() {
  hazard.origin_from_geometry("not json") |> should.equal(None)
}

pub fn severity_for_all_empty_is_none_test() {
  hazard.severity_for(0.0, "", "") |> should.equal(None)
}

pub fn severity_for_with_value_is_some_test() {
  let assert Some(severity) =
    hazard.severity_for(5.5, "M", "Magnitude 5.5M, Depth:10km")
  severity.value |> should.equal(5.5)
  severity.unit |> should.equal(Some("M"))
  severity.label |> should.equal(Some("Magnitude 5.5M, Depth:10km"))
}

pub fn severity_for_empty_unit_only_is_still_some_test() {
  let assert Some(severity) = hazard.severity_for(71_434.0, "ha", "")
  severity.unit |> should.equal(Some("ha"))
  severity.label |> should.equal(None)
}

pub fn latest_episode_picks_highest_modified_at_test() {
  let a = sample_episode_row(episode_id: 1, modified_at_ms: 100)
  let b = sample_episode_row(episode_id: 2, modified_at_ms: 200)
  let assert Some(latest) = hazard.latest_episode([a, b])
  latest.episode_id |> should.equal(2)
}

pub fn latest_episode_tie_breaks_on_episode_id_test() {
  let a = sample_episode_row(episode_id: 5, modified_at_ms: 100)
  let b = sample_episode_row(episode_id: 3, modified_at_ms: 100)
  let assert Some(latest) = hazard.latest_episode([a, b])
  latest.episode_id |> should.equal(5)
}

pub fn latest_episode_of_empty_list_is_none_test() {
  hazard.latest_episode([]) |> should.equal(None)
}

pub fn primary_geometry_from_prefers_poly_affected_test() {
  let text =
    "{\"type\":\"FeatureCollection\",\"features\":["
    <> "{\"properties\":{\"Class\":\"Poly_Circle\"},\"geometry\":{\"type\":\"Polygon\",\"coordinates\":[[[0,0],[10,0],[10,10],[0,10],[0,0]]]}},"
    <> "{\"properties\":{\"Class\":\"Poly_Affected\"},\"geometry\":{\"type\":\"Polygon\",\"coordinates\":[[[0,0],[1,0],[1,1],[0,1],[0,0]]]}}"
    <> "]}"
  let assert Some(geometry) = hazard.primary_geometry_from(text)
  let assert Ok(type_) =
    json.parse(geometry, decode.field("type", decode.string, decode.success))
  type_ |> should.equal("Polygon")
  string.contains(geometry, "[1,1]") |> should.equal(True)
  string.contains(geometry, "[10,10]") |> should.equal(False)
}

pub fn primary_geometry_from_picks_largest_poly_when_no_affected_test() {
  let text =
    "{\"type\":\"FeatureCollection\",\"features\":["
    <> "{\"properties\":{\"Class\":\"Poly_SMPInt_4\"},\"geometry\":{\"type\":\"Polygon\",\"coordinates\":[[[0,0],[1,0],[1,1],[0,1],[0,0]]]}},"
    <> "{\"properties\":{\"Class\":\"Poly_Circle\"},\"geometry\":{\"type\":\"Polygon\",\"coordinates\":[[[0,0],[10,0],[10,10],[0,10],[0,0]]]}}"
    <> "]}"
  let assert Some(geometry) = hazard.primary_geometry_from(text)
  string.contains(geometry, "[10,10]") |> should.equal(True)
}

pub fn primary_geometry_from_never_picks_point_or_linestring_test() {
  let text =
    "{\"type\":\"FeatureCollection\",\"features\":["
    <> "{\"properties\":{\"Class\":\"Point_Centroid\"},\"geometry\":{\"type\":\"Point\",\"coordinates\":[1,2]}},"
    <> "{\"properties\":{\"Class\":\"Poly_Track\"},\"geometry\":{\"type\":\"LineString\",\"coordinates\":[[1,2],[3,4]]}}"
    <> "]}"
  hazard.primary_geometry_from(text) |> should.equal(None)
}

pub fn primary_geometry_from_invalid_json_is_none_test() {
  hazard.primary_geometry_from("not json") |> should.equal(None)
}

pub fn normalize_maps_event_to_hazard_type_and_codes_test() {
  let row = sample_episode_row(episode_id: 1, modified_at_ms: 100)
  let normalized = hazard.normalize(row, 1)
  normalized.source_id |> should.equal("EQ-1565193")
  normalized.hazard_type |> should.equal("earthquake")
  normalized.alert_level |> should.equal("green")
  normalized.cap_severity |> should.equal("minor")
  normalized.external_ids |> should.equal(["usgs:us7000thc6"])
}

pub fn normalize_falls_back_country_to_iso3_test() {
  let row = sample_episode_row(episode_id: 1, modified_at_ms: 100)
  let row =
    hazard.GdacsEpisodeRow(..row, affected_countries: [], iso3: Some("IDN"))
  hazard.normalize(row, 1).countries |> should.equal(["IDN"])
}

pub fn normalize_degenerate_bbox_is_none_test() {
  let row = sample_episode_row(episode_id: 1, modified_at_ms: 100)
  let row =
    hazard.GdacsEpisodeRow(
      ..row,
      bbox_west: Some(105.8726),
      bbox_east: Some(105.8726),
      bbox_south: Some(-8.5419),
      bbox_north: Some(-8.5419),
    )
  hazard.normalize(row, 1).bbox |> should.equal(None)
}

pub fn to_json_omits_geometries_but_detail_includes_them_test() {
  let h = sample_hazard()
  let list_text = json.to_string(hazard.to_json(h))
  let detail_text = json.to_string(hazard.to_detail_json(h))
  string.contains(list_text, "\"geometries\"") |> should.equal(False)
  string.contains(detail_text, "\"geometries\"") |> should.equal(True)
  string.contains(list_text, "\"id\":\"gdacs:EQ-1565193\"")
  |> should.equal(True)
  string.contains(list_text, "\"source_type_code\":\"EQ\"")
  |> should.equal(True)
  string.contains(list_text, "\"bbox\":[105.8726") |> should.equal(True)
  let assert Ok(geometry_type) =
    json.parse(
      list_text,
      decode.at(["primary_geometry", "type"], decode.string),
    )
  geometry_type |> should.equal("Point")
}

fn sample_episode_row(
  episode_id episode_id: Int,
  modified_at_ms modified_at_ms: Int,
) -> hazard.GdacsEpisodeRow {
  hazard.GdacsEpisodeRow(
    event_type: "EQ",
    event_id: 1_565_193,
    episode_id:,
    alert_level: "Green",
    alert_score: Some(1.0),
    name: Some("Earthquake in South Of Java, Indonesia"),
    description: Some("Earthquake in South Of Java, Indonesia"),
    country: Some("South Of Java, Indonesia"),
    iso3: None,
    glide: None,
    origin_source: Some("NEIC"),
    origin_source_id: Some("us7000thc6"),
    severity_value: Some(5.5),
    severity_unit: Some("M"),
    severity_text: Some("Magnitude 5.5M, Depth:10km"),
    from_at_ms: 1_789_378_058_000,
    to_at_ms: Some(1_789_378_058_000),
    modified_at_ms:,
    is_current: True,
    longitude: 105.8726,
    latitude: -8.5419,
    bbox_west: Some(105.8726),
    bbox_south: Some(-8.5419),
    bbox_east: Some(105.8726),
    bbox_north: Some(-8.5419),
    affected_countries: ["IDN"],
    report_url: Some(
      "https://www.gdacs.org/report.aspx?eventid=1565193&episodeid=1732972&eventtype=EQ",
    ),
    geometry: None,
  )
}

fn sample_hazard() -> hazard.Hazard {
  let ts = timestamp.from_unix_seconds(1_789_378_058)
  hazard.Hazard(
    source: "gdacs",
    source_id: "EQ-1565193",
    source_episode_id: Some("1732972"),
    episode_count: 1,
    hazard_type: "earthquake",
    hazard_codes: ["glide:EQ", "emdat:nat-geo-ear-gro", "undrr-isc-2025:GH0101"],
    glide: None,
    alert_level: "green",
    alert_score: Some(1.0),
    cap_severity: "minor",
    severity_value: Some(5.5),
    severity_unit: Some("M"),
    severity_label: Some("Magnitude 5.5M, Depth:10km"),
    estimate_type: "primary",
    title: "Earthquake in South Of Java, Indonesia",
    description: Some("Earthquake in South Of Java, Indonesia"),
    countries: ["IDN"],
    report_url: Some(
      "https://www.gdacs.org/report.aspx?eventid=1565193&episodeid=1732972&eventtype=EQ",
    ),
    external_ids: ["usgs:us7000thc6"],
    onset_at: ts,
    onset_at_ms: 1_789_378_058_000,
    expires_at: Some(ts),
    expires_at_ms: Some(1_789_378_058_000),
    modified_at: ts,
    modified_at_ms: 1_789_481_003_000,
    is_current: True,
    longitude: 105.8726,
    latitude: -8.5419,
    bbox: Some(#(105.8726, -8.5419, 105.8726, -8.5419)),
    primary_geometry: Some(
      "{\"type\":\"Point\",\"coordinates\":[105.8726,-8.5419]}",
    ),
    geometries: Some("{\"type\":\"FeatureCollection\",\"features\":[]}"),
    first_seen_at: ts,
    last_seen_at: ts,
  )
}

pub fn to_polyline_json_encodes_polygon_and_preserves_other_fields_test() {
  let polygon_geojson =
    "{\"type\":\"Polygon\",\"coordinates\":[[[105.8726,-8.5419],[106.0,-8.0],[105.0,-8.0],[105.8726,-8.5419]]]}"
  let h =
    hazard.Hazard(..sample_hazard(), primary_geometry: Some(polygon_geojson))

  let default_json = hazard.to_json(h) |> json.to_string
  let polyline_json = hazard.to_polyline_json(h) |> json.to_string

  // Both have identical id
  let assert Ok(id1) =
    json.parse(default_json, decode.at(["id"], decode.string))
  let assert Ok(id2) =
    json.parse(polyline_json, decode.at(["id"], decode.string))
  id1 |> should.equal(id2)

  // Default geometry is GeoJSON Polygon without "encoding" field
  let assert Ok(def_geom_type) =
    json.parse(
      default_json,
      decode.at(["primary_geometry", "type"], decode.string),
    )
  def_geom_type |> should.equal("Polygon")
  case
    json.parse(
      default_json,
      decode.at(["primary_geometry", "encoding"], decode.string),
    )
  {
    Error(_) -> True |> should.equal(True)
    Ok(_) -> False |> should.equal(True)
  }

  // Polyline geometry has type: Polygon, encoding: polyline, precision: 4, coordinates: list(string)
  let assert Ok(poly_geom_type) =
    json.parse(
      polyline_json,
      decode.at(["primary_geometry", "type"], decode.string),
    )
  poly_geom_type |> should.equal("Polygon")

  let assert Ok(poly_encoding) =
    json.parse(
      polyline_json,
      decode.at(["primary_geometry", "encoding"], decode.string),
    )
  poly_encoding |> should.equal("polyline")

  let assert Ok(poly_precision) =
    json.parse(
      polyline_json,
      decode.at(["primary_geometry", "precision"], decode.int),
    )
  poly_precision |> should.equal(4)

  let assert Ok(poly_coords) =
    json.parse(
      polyline_json,
      decode.at(["primary_geometry", "coordinates"], decode.list(decode.string)),
    )
  list.length(poly_coords) |> should.equal(1)
}

pub fn to_polyline_json_falls_back_for_point_test() {
  let h = sample_hazard()
  let default_json = hazard.to_json(h) |> json.to_string
  let polyline_json = hazard.to_polyline_json(h) |> json.to_string
  polyline_json |> should.equal(default_json)
}

pub fn to_polyline_json_handles_none_geometry_test() {
  let h = hazard.Hazard(..sample_hazard(), primary_geometry: None)
  let default_json = hazard.to_json(h) |> json.to_string
  let polyline_json = hazard.to_polyline_json(h) |> json.to_string
  polyline_json |> should.equal(default_json)
}
