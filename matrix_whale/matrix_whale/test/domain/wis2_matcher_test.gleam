import domain/hazard.{type Hazard, Hazard}
import domain/wis2_matcher
import gleam/option.{None, Some}
import gleam/time/timestamp
import gleeunit/should

fn make_test_hazard(
  id: String,
  title: String,
  lat: Float,
  lon: Float,
  time_ms: Int,
) -> Hazard {
  let ts = timestamp.from_unix_seconds_and_nanoseconds(time_ms / 1000, 0)
  Hazard(
    source: "gdacs",
    source_id: id,
    source_episode_id: Some("1"),
    episode_count: 1,
    hazard_type: "tropical_cyclone",
    hazard_codes: ["glide:TC"],
    glide: None,
    alert_level: "orange",
    alert_score: Some(1.5),
    cap_severity: "severe",
    severity_value: Some(120.0),
    severity_unit: Some("km/h"),
    severity_label: Some("Wind speed 120 km/h"),
    estimate_type: "primary",
    title: title,
    description: Some("Test cyclone"),
    countries: ["USA"],
    report_url: None,
    external_ids: [],
    onset_at: ts,
    onset_at_ms: time_ms,
    expires_at: Some(ts),
    expires_at_ms: Some(time_ms),
    modified_at: ts,
    modified_at_ms: time_ms,
    is_current: True,
    longitude: lon,
    latitude: lat,
    bbox: None,
    primary_geometry: None,
    geometries: None,
    first_seen_at: ts,
    last_seen_at: ts,
  )
}

pub fn normalize_name_test() {
  wis2_matcher.normalize_name("Tropical Cyclone FAY")
  |> should.equal("fay")

  wis2_matcher.normalize_name("Tropical Cyclone Fay-26")
  |> should.equal("fay")

  wis2_matcher.normalize_name("TC FAY")
  |> should.equal("fay")

  wis2_matcher.normalize_name("  fay  ")
  |> should.equal("fay")

  wis2_matcher.normalize_name("Super Typhoon Surigae-2021")
  |> should.equal("surigae")

  wis2_matcher.normalize_name("Hurricane Gonzalo")
  |> should.equal("gonzalo")

  wis2_matcher.normalize_name("70W")
  |> should.equal("70w")
}

pub fn is_named_test() {
  wis2_matcher.is_named("06L", Some("FAY"))
  |> should.equal(True)

  wis2_matcher.is_named("06L", Some("   "))
  |> should.equal(False)

  wis2_matcher.is_named("06L", None)
  |> should.equal(False)

  // Unnamed numbered disturbance where storm_name equals storm_id
  wis2_matcher.is_named("70W", Some("70W"))
  |> should.equal(False)

  wis2_matcher.is_named("70W", Some("70w"))
  |> should.equal(False)
}

pub fn great_circle_distance_test() {
  // Same point
  wis2_matcher.great_circle_distance_km(0.0, 0.0, 0.0, 0.0)
  |> should.equal(0.0)

  // Approx 1 degree longitude at equator ~ 111 km
  let d1 = wis2_matcher.great_circle_distance_km(0.0, 0.0, 0.0, 1.0)
  { d1 >. 110.0 && d1 <. 112.0 }
  |> should.equal(True)

  // 2 degrees latitude ~ 222 km
  let d2 = wis2_matcher.great_circle_distance_km(10.0, 20.0, 12.0, 20.0)
  { d2 >. 220.0 && d2 <. 224.0 }
  |> should.equal(True)
}

pub fn match_by_name_test() {
  let time_ms = 1_790_000_000_000
  let h1 =
    make_test_hazard("TC-101", "Tropical Cyclone FAY-26", 29.8, -42.6, time_ms)
  let h2 =
    make_test_hazard("TC-102", "Tropical Cyclone POLO", 15.0, 120.0, time_ms)

  let matched =
    wis2_matcher.match_tc_run("06L", Some("FAY"), time_ms, 29.8, -42.6, [h1, h2])
  matched |> should.equal(Some(h1))
}

pub fn match_by_distance_and_time_test() {
  let time_ms = 1_790_000_000_000
  // GDACS hazard with different name or unnamed
  let h1 =
    make_test_hazard("TC-201", "Tropical Cyclone Unknown", 30.0, -42.0, time_ms)

  // Run at (29.8, -42.6), approx 60km away from (30.0, -42.0), within 12h
  let matched =
    wis2_matcher.match_tc_run(
      "06L",
      None,
      time_ms + 2 * 3600 * 1000,
      29.8,
      -42.6,
      [h1],
    )
  matched |> should.equal(Some(h1))

  // Run too far (>300 km)
  let too_far =
    wis2_matcher.match_tc_run("06L", None, time_ms, 35.0, -42.6, [h1])
  too_far |> should.equal(None)

  // Run too late (>12 h)
  let too_late =
    wis2_matcher.match_tc_run(
      "06L",
      None,
      time_ms + 14 * 3600 * 1000,
      29.8,
      -42.6,
      [h1],
    )
  too_late |> should.equal(None)
}
