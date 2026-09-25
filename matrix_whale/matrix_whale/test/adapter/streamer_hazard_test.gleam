import adapter/streamer
import domain/hazard
import gleam/http/request
import gleam/http/response
import gleam/option.{None, Some}
import gleam/string
import gleam/time/timestamp
import gleeunit/should

fn make_hazard(polygon_text: String) -> hazard.Hazard {
  let ts = timestamp.from_unix_seconds(1_789_378_058)
  hazard.Hazard(
    source: "gdacs",
    source_id: "EQ-1001",
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
    title: "Test Earthquake",
    description: Some("Test Earthquake"),
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

pub fn hazard_snapshot_default_vs_polyline_etag_and_revalidation_test() {
  let polygon_geojson =
    "{\"type\":\"Polygon\",\"coordinates\":[[[105.8726,-8.5419],[106.0,-8.0],[105.0,-8.0],[105.8726,-8.5419]]]}"
  let rows = [make_hazard(polygon_geojson)]
  let gen_clock = "2026-09-20T00:00:00Z"

  // 1. Default request (no geometry query param)
  let req_default = request.new()
  let resp_default =
    streamer.hazard_snapshot_response(req_default, rows, gen_clock)
  resp_default.status |> should.equal(200)
  let assert Ok(etag_default) = response.get_header(resp_default, "etag")
  string.starts_with(etag_default, "W/\"") |> should.equal(True)

  // 2. Opt-in request (?geometry=polyline)
  let req_polyline =
    request.new() |> request.set_query([#("geometry", "polyline")])
  let resp_polyline =
    streamer.hazard_snapshot_response(req_polyline, rows, gen_clock)
  resp_polyline.status |> should.equal(200)
  let assert Ok(etag_polyline) = response.get_header(resp_polyline, "etag")
  string.starts_with(etag_polyline, "W/\"") |> should.equal(True)

  // ETags must differ because representations differ
  { etag_default != etag_polyline } |> should.equal(True)

  // 3. Revalidation: default request with default ETag -> 304
  let req_reval_def =
    request.new() |> request.set_header("if-none-match", etag_default)
  let resp_reval_def =
    streamer.hazard_snapshot_response(req_reval_def, rows, gen_clock)
  resp_reval_def.status |> should.equal(304)

  // 4. Cross-revalidation: polyline request with default ETag -> 200 (different representation!)
  let req_cross =
    request.new()
    |> request.set_query([#("geometry", "polyline")])
    |> request.set_header("if-none-match", etag_default)
  let resp_cross = streamer.hazard_snapshot_response(req_cross, rows, gen_clock)
  resp_cross.status |> should.equal(200)

  // 5. Revalidation: polyline request with polyline ETag -> 304
  let req_reval_poly =
    request.new()
    |> request.set_query([#("geometry", "polyline")])
    |> request.set_header("if-none-match", etag_polyline)
  let resp_reval_poly =
    streamer.hazard_snapshot_response(req_reval_poly, rows, gen_clock)
  resp_reval_poly.status |> should.equal(304)

  // 6. Unknown geometry param falls back to default serializer
  let req_other = request.new() |> request.set_query([#("geometry", "geojson")])
  let resp_other = streamer.hazard_snapshot_response(req_other, rows, gen_clock)
  let assert Ok(etag_other) = response.get_header(resp_other, "etag")
  etag_other |> should.equal(etag_default)
}
