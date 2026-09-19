import domain/earthquake
import domain/timeline
import gleam/option.{None, Some}
import gleeunit/should

pub fn severity_for_earthquake_boundaries_test() {
  timeline.severity_for_earthquake(None) |> should.equal(timeline.Unknown)
  timeline.severity_for_earthquake(Some(-0.3)) |> should.equal(timeline.Minor)
  timeline.severity_for_earthquake(Some(4.49)) |> should.equal(timeline.Minor)
  timeline.severity_for_earthquake(Some(4.5)) |> should.equal(timeline.Moderate)
  timeline.severity_for_earthquake(Some(5.99))
  |> should.equal(timeline.Moderate)
  timeline.severity_for_earthquake(Some(6.0)) |> should.equal(timeline.Severe)
  timeline.severity_for_earthquake(Some(6.99)) |> should.equal(timeline.Severe)
  timeline.severity_for_earthquake(Some(7.0)) |> should.equal(timeline.Extreme)
  timeline.severity_for_earthquake(Some(9.1)) |> should.equal(timeline.Extreme)
}

pub fn severity_for_hazard_maps_known_cap_values_test() {
  timeline.severity_for_hazard("minor") |> should.equal(timeline.Minor)
  timeline.severity_for_hazard("severe") |> should.equal(timeline.Severe)
  timeline.severity_for_hazard("extreme") |> should.equal(timeline.Extreme)
  timeline.severity_for_hazard("moderate") |> should.equal(timeline.Unknown)
  timeline.severity_for_hazard("green") |> should.equal(timeline.Unknown)
}

pub fn severity_for_alert_maps_noaa_spellings_test() {
  timeline.severity_for_alert("Extreme") |> should.equal(timeline.Extreme)
  timeline.severity_for_alert("Severe") |> should.equal(timeline.Severe)
  timeline.severity_for_alert("Moderate") |> should.equal(timeline.Moderate)
  timeline.severity_for_alert("Minor") |> should.equal(timeline.Minor)
  timeline.severity_for_alert("extreme") |> should.equal(timeline.Extreme)
  timeline.severity_for_alert("Unknown") |> should.equal(timeline.Unknown)
  timeline.severity_for_alert("Nonsense") |> should.equal(timeline.Unknown)
}

pub fn rank_orders_severity_levels_test() {
  let ranks = [
    timeline.rank(timeline.Unknown),
    timeline.rank(timeline.Minor),
    timeline.rank(timeline.Moderate),
    timeline.rank(timeline.Severe),
    timeline.rank(timeline.Extreme),
  ]
  ranks |> should.equal([0, 1, 2, 3, 4])
}

pub fn severity_to_string_and_parse_round_trip_test() {
  [
    timeline.Unknown,
    timeline.Minor,
    timeline.Moderate,
    timeline.Severe,
    timeline.Extreme,
  ]
  |> should.equal([
    assert_round_trips(timeline.Unknown),
    assert_round_trips(timeline.Minor),
    assert_round_trips(timeline.Moderate),
    assert_round_trips(timeline.Severe),
    assert_round_trips(timeline.Extreme),
  ])
  timeline.parse("bogus") |> should.equal(Error(Nil))
}

fn assert_round_trips(severity: timeline.Severity) -> timeline.Severity {
  let assert Ok(parsed) = timeline.parse(timeline.to_string(severity))
  parsed
}

pub fn earthquake_floor_for_translates_min_severity_test() {
  timeline.earthquake_floor_for(None)
  |> should.equal(timeline.EarthquakeFloor(
    require_magnitude: False,
    minimum: None,
  ))
  timeline.earthquake_floor_for(Some(timeline.Minor))
  |> should.equal(timeline.EarthquakeFloor(
    require_magnitude: True,
    minimum: None,
  ))
  timeline.earthquake_floor_for(Some(timeline.Moderate))
  |> should.equal(timeline.EarthquakeFloor(
    require_magnitude: True,
    minimum: Some(4.5),
  ))
  timeline.earthquake_floor_for(Some(timeline.Severe))
  |> should.equal(timeline.EarthquakeFloor(
    require_magnitude: True,
    minimum: Some(6.0),
  ))
  timeline.earthquake_floor_for(Some(timeline.Extreme))
  |> should.equal(timeline.EarthquakeFloor(
    require_magnitude: True,
    minimum: Some(7.0),
  ))
}

pub fn hazard_cap_severities_for_filters_by_rank_test() {
  timeline.hazard_cap_severities_for(None) |> should.equal(None)
  timeline.hazard_cap_severities_for(Some(timeline.Minor))
  |> should.equal(Some(["minor", "severe", "extreme"]))
  timeline.hazard_cap_severities_for(Some(timeline.Moderate))
  |> should.equal(Some(["severe", "extreme"]))
  timeline.hazard_cap_severities_for(Some(timeline.Severe))
  |> should.equal(Some(["severe", "extreme"]))
  timeline.hazard_cap_severities_for(Some(timeline.Extreme))
  |> should.equal(Some(["extreme"]))
}

pub fn alert_severities_for_filters_by_rank_test() {
  timeline.alert_severities_for(None) |> should.equal(None)
  timeline.alert_severities_for(Some(timeline.Moderate))
  |> should.equal(Some(["Moderate", "Severe", "Extreme"]))
  timeline.alert_severities_for(Some(timeline.Extreme))
  |> should.equal(Some(["Extreme"]))
}

pub fn key_round_trip_for_each_kind_test() {
  timeline.earthquake_key(42) |> should.equal("earthquake:42")
  timeline.parse_key("earthquake:42")
  |> should.equal(Ok(timeline.EarthquakeKey(42)))

  timeline.hazard_key("gdacs", "EQ-1565193")
  |> should.equal("hazard:gdacs:EQ-1565193")
  timeline.parse_key("hazard:gdacs:EQ-1565193")
  |> should.equal(Ok(timeline.HazardKey("gdacs", "EQ-1565193")))

  let noaa_id = "urn:oid:2.49.0.1.840.0.abc"
  timeline.alert_key("noaa", noaa_id) |> should.equal("alert:noaa:" <> noaa_id)
  timeline.parse_key("alert:noaa:" <> noaa_id)
  |> should.equal(Ok(timeline.AlertKey("noaa", noaa_id)))

  let cap_source = "cap-2.49.0.0.276.0"
  let cap_id = "opendata@dwd.de,2.49.0.0.276.0.DWD.PVW"
  timeline.alert_key(cap_source, cap_id)
  |> should.equal("alert:" <> cap_source <> ":" <> cap_id)
  timeline.parse_key("alert:" <> cap_source <> ":" <> cap_id)
  |> should.equal(Ok(timeline.AlertKey(cap_source, cap_id)))
}

pub fn parse_key_rejects_malformed_values_test() {
  timeline.parse_key("earthquake:not-an-int")
  |> should.be_error
  timeline.parse_key("hazard:only-one-part") |> should.be_error
  timeline.parse_key("alert:only-one-part") |> should.be_error
  timeline.parse_key("nokind") |> should.be_error
}

pub fn cursor_round_trip_test() {
  let cursor =
    timeline.Cursor(
      first_seen_at_text: "2026-09-18 12:34:56.789012+00",
      kind: timeline.Hazard,
      key: "hazard:gdacs:EQ-1565193",
    )
  timeline.encode_cursor(cursor)
  |> timeline.decode_cursor
  |> should.equal(Ok(cursor))
}

pub fn decode_cursor_rejects_garbage_test() {
  timeline.decode_cursor("@@@") |> should.be_error
  timeline.decode_cursor("bm90LWVub3VnaC1wYXJ0cw") |> should.be_error
}

pub fn parse_query_defaults_test() {
  let assert Ok(query) = timeline.parse_query([])
  query.limit |> should.equal(50)
  query.before |> should.equal(None)
  query.kinds
  |> should.equal([timeline.Earthquake, timeline.Hazard, timeline.Alert])
  query.minmag |> should.equal(earthquake.Minimum(2.5))
  query.min_severity |> should.equal(None)
}

pub fn parse_query_accepts_valid_overrides_test() {
  let assert Ok(query) =
    timeline.parse_query([
      #("limit", "200"),
      #("kinds", "earthquake, hazard"),
      #("minmag", "all"),
      #("min_severity", "severe"),
    ])
  query.limit |> should.equal(200)
  query.kinds |> should.equal([timeline.Earthquake, timeline.Hazard])
  query.minmag |> should.equal(earthquake.AllMagnitudes)
  query.min_severity |> should.equal(Some(timeline.Severe))
}

pub fn parse_query_rejects_limit_out_of_range_test() {
  timeline.parse_query([#("limit", "0")]) |> should.be_error
  timeline.parse_query([#("limit", "201")]) |> should.be_error
  timeline.parse_query([#("limit", "not-a-number")]) |> should.be_error
}

pub fn parse_query_rejects_bad_kinds_test() {
  timeline.parse_query([#("kinds", "")]) |> should.be_error
  timeline.parse_query([#("kinds", "foo")]) |> should.be_error
}

pub fn parse_query_rejects_bad_minmag_test() {
  timeline.parse_query([#("minmag", "many")]) |> should.be_error
}

pub fn parse_query_rejects_bad_min_severity_test() {
  timeline.parse_query([#("min_severity", "huge")]) |> should.be_error
  timeline.parse_query([#("min_severity", "unknown")]) |> should.be_error
}

pub fn parse_query_rejects_malformed_before_test() {
  timeline.parse_query([#("before", "@@@")]) |> should.be_error
}
