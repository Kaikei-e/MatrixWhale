import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import message/reciever/models/gdacs

const eq_feature = "{\"type\":\"Feature\",\"bbox\":[105.8726,-8.5419,105.8726,-8.5419],\"geometry\":{\"type\":\"Point\",\"coordinates\":[105.8726,-8.5419]},\"properties\":{\"eventtype\":\"EQ\",\"eventid\":1565193,\"episodeid\":1732972,\"eventname\":\"\",\"glide\":\"\",\"name\":\"Earthquake in South Of Java, Indonesia\",\"description\":\"Earthquake in South Of Java, Indonesia\",\"htmldescription\":\"Green M 5.5 Earthquake in South Of Java, Indonesia at: 14 Sep 2026 09:27:38.\",\"icon\":\"https://www.gdacs.org/images/gdacs_icons/maps/Green/EQ.png\",\"iconoverall\":null,\"url\":{\"geometry\":\"https://www.gdacs.org/gdacsapi/api/polygons/getgeometry?eventtype=EQ&eventid=1565193&episodeid=1732972\",\"report\":\"https://www.gdacs.org/report.aspx?eventid=1565193&episodeid=1732972&eventtype=EQ\",\"details\":\"https://www.gdacs.org/gdacsapi/api/events/geteventdata?eventtype=EQ&eventid=1565193\"},\"alertlevel\":\"Green\",\"alertscore\":1,\"episodealertlevel\":\"Green\",\"episodealertscore\":0.0,\"istemporary\":\"false\",\"iscurrent\":\"true\",\"country\":\"South Of Java, Indonesia\",\"fromdate\":\"2026-09-14T09:27:38\",\"todate\":\"2026-09-14T09:27:38\",\"datemodified\":\"2026-09-15T14:03:23\",\"iso3\":\"\",\"source\":\"NEIC\",\"sourceid\":\"us7000thc6\",\"polygonlabel\":\"Centroid\",\"Class\":\"Point_Centroid\",\"affectedcountries\":[{\"iso2\":\"ID\",\"iso3\":\"IDN\",\"countryname\":\"Indonesia\"}],\"severitydata\":{\"severity\":5.5,\"severitytext\":\"Magnitude 5.5M, Depth:10km\",\"severityunit\":\"M\"}}}"

const tc_feature = "{\"type\":\"Feature\",\"bbox\":[144.5,25.1,144.5,25.1],\"geometry\":{\"type\":\"Point\",\"coordinates\":[144.5,25.1]},\"properties\":{\"eventtype\":\"TC\",\"eventid\":1001322,\"episodeid\":11,\"eventname\":\"DUJUAN-26\",\"glide\":\"\",\"name\":\"Tropical Cyclone DUJUAN-26\",\"description\":\"Tropical Cyclone DUJUAN-26\",\"htmldescription\":\"x\",\"icon\":\"https://x/TC.png\",\"iconoverall\":\"https://x/TC.png\",\"url\":{\"geometry\":\"https://x/geometry\",\"report\":\"https://x/report\",\"details\":\"https://x/details\"},\"alertlevel\":\"Green\",\"alertscore\":1,\"episodealertlevel\":\"Green\",\"episodealertscore\":1.0,\"istemporary\":\"false\",\"iscurrent\":\"true\",\"country\":\"Japan\",\"fromdate\":\"2026-09-15T12:00:00\",\"todate\":\"2026-09-18T00:00:00\",\"datemodified\":\"2026-09-18T02:08:46\",\"iso3\":\"JPN\",\"source\":\"JTWC\",\"sourceid\":\"\",\"polygonlabel\":\"Centroid\",\"Class\":\"Point_Centroid\",\"affectedcountries\":[{\"iso2\":\"JP\",\"iso3\":\"JPN\",\"countryname\":\"Japan\"}],\"severitydata\":{\"severity\":120.3696,\"severitytext\":\"Tropical Storm (maximum wind speed of 120 km/h)\",\"severityunit\":\"km/h\"}}}"

const fl_feature = "{\"type\":\"Feature\",\"bbox\":[-0.4656,39.4367,-0.4656,39.4367],\"geometry\":{\"type\":\"Point\",\"coordinates\":[-0.4656,39.4367]},\"properties\":{\"eventtype\":\"FL\",\"eventid\":1104151,\"episodeid\":3,\"eventname\":\"\",\"glide\":\"\",\"name\":\"Flood in Spain\",\"description\":\"Flood in Spain\",\"htmldescription\":\"x\",\"icon\":\"https://x/FL.png\",\"iconoverall\":\"https://x/FL.png\",\"url\":{\"geometry\":\"https://x/geometry\",\"report\":\"https://x/report\",\"details\":\"https://x/details\"},\"alertlevel\":\"Green\",\"alertscore\":1,\"episodealertlevel\":\"Green\",\"episodealertscore\":0.5,\"istemporary\":\"false\",\"iscurrent\":\"true\",\"country\":\"Spain\",\"fromdate\":\"2026-09-09T01:00:00\",\"todate\":\"2026-09-18T01:00:00\",\"datemodified\":\"2026-09-17T10:34:46\",\"iso3\":\"ESP\",\"source\":\"GLOFAS\",\"sourceid\":\"\",\"polygonlabel\":\"Centroid\",\"Class\":\"Point_Centroid\",\"affectedcountries\":[{\"iso2\":\"ES\",\"iso3\":\"ESP\",\"countryname\":\"Spain\"}],\"severitydata\":{\"severity\":0.0,\"severitytext\":\"Magnitude 0 \",\"severityunit\":\"\"}}}"

const vo_feature = "{\"type\":\"Feature\",\"bbox\":[105.4233,-6.1009,105.4233,-6.1009],\"geometry\":{\"type\":\"Point\",\"coordinates\":[105.4233,-6.1009]},\"properties\":{\"eventtype\":\"VO\",\"eventid\":1000148,\"episodeid\":1,\"eventname\":\"Krakatau\",\"glide\":\"VO-2026-000171-IDN\",\"name\":\"Eruption  Krakatau\",\"description\":\"Eruption  Krakatau\",\"htmldescription\":\"x\",\"icon\":\"https://x/VO.png\",\"iconoverall\":\"https://x/VO.png\",\"url\":{\"geometry\":\"https://x/geometry\",\"report\":\"https://x/report\",\"details\":\"https://x/details\"},\"alertlevel\":\"Orange\",\"alertscore\":2,\"episodealertlevel\":\"Orange\",\"episodealertscore\":1.5,\"istemporary\":\"false\",\"iscurrent\":\"false\",\"country\":\"Indonesia\",\"fromdate\":\"2026-09-04T21:00:00\",\"todate\":\"2026-09-04T21:00:00\",\"datemodified\":\"2026-09-18T02:55:15\",\"iso3\":\"IDN\",\"source\":\"DARWIN\",\"sourceid\":\"\",\"polygonlabel\":\"Centroid\",\"Class\":\"Point_Centroid\",\"affectedcountries\":[{\"iso2\":\"ID\",\"iso3\":\"IDN\",\"countryname\":\"Indonesia\"}],\"severitydata\":{\"severity\":0.0,\"severitytext\":\"\",\"severityunit\":\"\"}}}"

fn envelope(features: String) -> String {
  "{\"poll_meta\":{\"fetched_at\":\"2026-09-18T00:00:00Z\",\"http_status\":200,\"feature_count\":1,\"bytes\":10,\"backfill\":true},\"features\":["
  <> features
  <> "]}"
}

pub fn decodes_eq_feature_with_gdacs_facts_test() {
  let assert Ok(body) = json.parse(envelope(eq_feature), decode.dynamic)
  let assert Ok(#(meta, features, received, dropped)) = gdacs.decode_body(body)
  received |> should.equal(1)
  dropped |> should.equal(0)
  let assert Some(meta) = meta
  meta.backfill |> should.equal(True)
  let assert [feature] = features
  feature.event_type |> should.equal("EQ")
  feature.event_id |> should.equal(1_565_193)
  feature.episode_id |> should.equal(1_732_972)
  feature.alert_level |> should.equal("Green")
  feature.alert_score |> should.equal(Some(1.0))
  feature.origin_source |> should.equal(Some("NEIC"))
  feature.origin_source_id |> should.equal(Some("us7000thc6"))
  feature.iso3 |> should.equal(None)
  feature.is_current |> should.equal(True)
  feature.is_temporary |> should.equal(False)
  feature.severity_value |> should.equal(Some(5.5))
  feature.severity_unit |> should.equal(Some("M"))
  feature.severity_text |> should.equal(Some("Magnitude 5.5M, Depth:10km"))
  feature.affected_countries |> should.equal(["IDN"])
  // "2026-09-14T09:27:38Z" and "2026-09-15T14:03:23Z" treated as UTC.
  feature.from_at_ms |> should.equal(1_789_378_058_000)
  feature.modified_at_ms |> should.equal(1_789_481_003_000)
  feature.longitude |> should.equal(105.8726)
  feature.latitude |> should.equal(-8.5419)
  feature.bbox_west |> should.equal(Some(105.8726))
  feature.report_url
  |> should.equal(Some(
    "https://www.gdacs.org/report.aspx?eventid=1565193&episodeid=1732972&eventtype=EQ",
  ))
  string.contains(feature.raw, "\"eventid\":1565193") |> should.equal(True)
}

pub fn tc_feature_has_empty_sourceid_as_none_and_nonempty_iso3_test() {
  let assert Ok(body) = json.parse(envelope(tc_feature), decode.dynamic)
  let assert Ok(#(_, features, _, _)) = gdacs.decode_body(body)
  let assert [feature] = features
  feature.origin_source |> should.equal(Some("JTWC"))
  feature.origin_source_id |> should.equal(None)
  feature.iso3 |> should.equal(Some("JPN"))
  feature.severity_unit |> should.equal(Some("km/h"))
}

pub fn fl_feature_keeps_nonempty_text_with_empty_unit_test() {
  let assert Ok(body) = json.parse(envelope(fl_feature), decode.dynamic)
  let assert Ok(#(_, features, _, _)) = gdacs.decode_body(body)
  let assert [feature] = features
  feature.severity_value |> should.equal(Some(0.0))
  feature.severity_unit |> should.equal(None)
  feature.severity_text |> should.equal(Some("Magnitude 0 "))
}

pub fn vo_feature_fully_empty_severity_and_nonempty_glide_test() {
  let assert Ok(body) = json.parse(envelope(vo_feature), decode.dynamic)
  let assert Ok(#(_, features, _, _)) = gdacs.decode_body(body)
  let assert [feature] = features
  feature.severity_value |> should.equal(Some(0.0))
  feature.severity_unit |> should.equal(None)
  feature.severity_text |> should.equal(None)
  feature.glide |> should.equal(Some("VO-2026-000171-IDN"))
  feature.is_current |> should.equal(False)
}

pub fn invalid_envelope_is_error_test() {
  let assert Ok(body) = json.parse("{\"features\":{}}", decode.dynamic)
  case gdacs.decode_body(body) {
    Error(_) -> True |> should.equal(True)
    Ok(_) -> False |> should.equal(True)
  }
}

pub fn feature_missing_required_ids_is_dropped_test() {
  let bad =
    "{\"type\":\"Feature\",\"geometry\":{\"type\":\"Point\",\"coordinates\":[1,2]},\"properties\":{\"eventtype\":\"EQ\",\"eventid\":0,\"episodeid\":1,\"fromdate\":\"2026-01-01T00:00:00\",\"datemodified\":\"2026-01-01T00:00:00\"}}"
  let assert Ok(body) = json.parse(envelope(bad), decode.dynamic)
  let assert Ok(#(_, features, received, dropped)) = gdacs.decode_body(body)
  received |> should.equal(1)
  dropped |> should.equal(1)
  list.length(features) |> should.equal(0)
}

pub fn to_incoming_earthquake_builds_ids_and_depth_for_eq_test() {
  let assert Ok(body) = json.parse(envelope(eq_feature), decode.dynamic)
  let assert Ok(#(_, features, _, _)) = gdacs.decode_body(body)
  let assert [feature] = features
  let assert Some(incoming) = gdacs.to_incoming_earthquake(feature)
  incoming.source_id |> should.equal("1565193")
  incoming.ids |> should.equal(["gdacs:1565193", "us7000thc6"])
  incoming.sources |> should.equal(["gdacs"])
  incoming.mag |> should.equal(Some(5.5))
  incoming.depth |> should.equal(Some(10.0))
  incoming.time |> should.equal(1_789_378_058_000)
  incoming.updated |> should.equal(1_789_481_003_000)
  incoming.type_ |> should.equal(Some("earthquake"))
}

pub fn to_incoming_earthquake_is_none_for_non_eq_test() {
  let assert Ok(body) = json.parse(envelope(tc_feature), decode.dynamic)
  let assert Ok(#(_, features, _, _)) = gdacs.decode_body(body)
  let assert [feature] = features
  gdacs.to_incoming_earthquake(feature) |> should.equal(None)
}

pub fn decode_geometry_body_captures_status_and_null_geometry_test() {
  let payload =
    "{\"features\":["
    <> "{\"eventtype\":\"EQ\",\"eventid\":1565193,\"episodeid\":1732972,\"http_status\":200,\"geometry\":{\"type\":\"FeatureCollection\",\"features\":[]}},"
    <> "{\"eventtype\":\"TC\",\"eventid\":1001322,\"episodeid\":11,\"http_status\":204,\"geometry\":null}"
    <> "]}"
  let assert Ok(body) = json.parse(payload, decode.dynamic)
  let assert Ok(#(_, results, received, dropped)) =
    gdacs.decode_geometry_body(body)
  received |> should.equal(2)
  dropped |> should.equal(0)
  let assert [first, second] = results
  first.http_status |> should.equal(200)
  let assert Some(geometry) = first.geometry
  string.contains(geometry, "FeatureCollection") |> should.equal(True)
  second.http_status |> should.equal(204)
  second.geometry |> should.equal(None)
}

pub fn decode_geometry_body_drops_unknown_episode_test() {
  let payload =
    "{\"features\":[{\"eventtype\":\"EQ\",\"eventid\":0,\"episodeid\":0,\"http_status\":200,\"geometry\":null}]}"
  let assert Ok(body) = json.parse(payload, decode.dynamic)
  let assert Ok(#(_, results, received, dropped)) =
    gdacs.decode_geometry_body(body)
  received |> should.equal(1)
  dropped |> should.equal(1)
  list.length(results) |> should.equal(0)
}
