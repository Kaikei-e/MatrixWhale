import domain/hazard.{Hazard}
import domain/wis2_observation.{
  type Wis2ObservationFeature, PlausibleObservation, StationNeighbour,
  SubtypeGust, SubtypeLowPressure, SubtypeRain1h, SubtypeRain24h, SubtypeWind,
  Wis2ObservationFeature, Wis2Precip,
}
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/time/timestamp
import gleeunit/should

pub fn plausibility_wind_test() {
  wis2_observation.is_plausible_wind(0.0) |> should.equal(True)
  wis2_observation.is_plausible_wind(50.0) |> should.equal(True)
  wis2_observation.is_plausible_wind(110.0) |> should.equal(True)
  wis2_observation.is_plausible_wind(110.1) |> should.equal(False)
  wis2_observation.is_plausible_wind(-1.0) |> should.equal(False)
}

pub fn plausibility_gust_test() {
  wis2_observation.is_plausible_gust(0.0) |> should.equal(True)
  wis2_observation.is_plausible_gust(80.0) |> should.equal(True)
  wis2_observation.is_plausible_gust(110.0) |> should.equal(True)
  wis2_observation.is_plausible_gust(110.5) |> should.equal(False)
  wis2_observation.is_plausible_gust(-0.1) |> should.equal(False)
}

pub fn plausibility_precip_1h_test() {
  wis2_observation.is_plausible_precip_1h(0.0) |> should.equal(True)
  wis2_observation.is_plausible_precip_1h(250.0) |> should.equal(True)
  wis2_observation.is_plausible_precip_1h(400.0) |> should.equal(True)
  wis2_observation.is_plausible_precip_1h(400.1) |> should.equal(False)
  wis2_observation.is_plausible_precip_1h(-5.0) |> should.equal(False)
}

pub fn plausibility_precip_24h_test() {
  wis2_observation.is_plausible_precip_24h(0.0) |> should.equal(True)
  wis2_observation.is_plausible_precip_24h(1000.0) |> should.equal(True)
  wis2_observation.is_plausible_precip_24h(2000.0) |> should.equal(True)
  wis2_observation.is_plausible_precip_24h(2000.5) |> should.equal(False)
  wis2_observation.is_plausible_precip_24h(-1.0) |> should.equal(False)
}

pub fn plausibility_mslp_test() {
  wis2_observation.is_plausible_mslp_hpa(850.0) |> should.equal(True)
  wis2_observation.is_plausible_mslp_hpa(1013.2) |> should.equal(True)
  wis2_observation.is_plausible_mslp_hpa(1090.0) |> should.equal(True)
  wis2_observation.is_plausible_mslp_hpa(849.9) |> should.equal(False)
  wis2_observation.is_plausible_mslp_hpa(1090.1) |> should.equal(False)
}

pub fn plausibility_gust_period_test() {
  wis2_observation.is_plausible_gust_period(1) |> should.equal(True)
  wis2_observation.is_plausible_gust_period(10) |> should.equal(True)
  wis2_observation.is_plausible_gust_period(60) |> should.equal(True)
  wis2_observation.is_plausible_gust_period(1440) |> should.equal(True)
  wis2_observation.is_plausible_gust_period(0) |> should.equal(False)
  wis2_observation.is_plausible_gust_period(-1) |> should.equal(False)
  wis2_observation.is_plausible_gust_period(-1806) |> should.equal(False)
  wis2_observation.is_plausible_gust_period(1441) |> should.equal(False)
}

pub fn plausibility_precip_period_test() {
  wis2_observation.is_plausible_precip_period(1.0) |> should.equal(True)
  wis2_observation.is_plausible_precip_period(2.0) |> should.equal(True)
  wis2_observation.is_plausible_precip_period(3.0) |> should.equal(True)
  wis2_observation.is_plausible_precip_period(6.0) |> should.equal(True)
  wis2_observation.is_plausible_precip_period(9.0) |> should.equal(True)
  wis2_observation.is_plausible_precip_period(12.0) |> should.equal(True)
  wis2_observation.is_plausible_precip_period(15.0) |> should.equal(True)
  wis2_observation.is_plausible_precip_period(18.0) |> should.equal(True)
  wis2_observation.is_plausible_precip_period(24.0) |> should.equal(True)

  wis2_observation.is_plausible_precip_period(0.0) |> should.equal(False)
  wis2_observation.is_plausible_precip_period(4.0) |> should.equal(False)
  wis2_observation.is_plausible_precip_period(5.0) |> should.equal(False)
  wis2_observation.is_plausible_precip_period(30.1) |> should.equal(False)
  wis2_observation.is_plausible_precip_period(-1.0) |> should.equal(False)
  wis2_observation.is_plausible_precip_period(-30.1) |> should.equal(False)
}

fn valid_sample_feature() -> Wis2ObservationFeature {
  Wis2ObservationFeature(
    data_id: "obs-1",
    centre_id: "rjtd",
    pubtime: "2026-09-25T12:00:00Z",
    station_id: "0-20000-0-47662",
    station_name: Some("Tokyo"),
    lat: 35.68,
    lon: 139.76,
    elevation_m: Some(25.0),
    observed_at: "2026-09-25T12:00:00Z",
    wind_speed_ms: Some(15.0),
    gust_ms: Some(35.0),
    gust_period_min: Some(10),
    precip: [
      Wis2Precip(period_h: 1.0, mm: 45.0),
      Wis2Precip(period_h: 24.0, mm: 180.0),
      Wis2Precip(period_h: 6.0, mm: 40.0),
    ],
    mslp_pa: Some(101_300.0),
  )
}

pub fn filter_plausible_accepts_valid_observation_test() {
  let feature = valid_sample_feature()
  let result = wis2_observation.filter_plausible(feature, 1_700_000_000_000)
  result |> should.be_ok
  let assert Ok(plausible) = result

  plausible.wind_speed_ms |> should.equal(Some(15.0))
  plausible.gust_ms |> should.equal(Some(35.0))
  plausible.precip_1h_mm |> should.equal(Some(45.0))
  plausible.precip_24h_mm |> should.equal(Some(180.0))
  plausible.mslp_hpa |> should.equal(Some(1013.0))
}

pub fn filter_plausible_discards_whole_observation_on_any_invalid_element_test() {
  let base = valid_sample_feature()

  // Implausible wind speed (> 110 m/s) discards entire observation
  wis2_observation.filter_plausible(
    Wis2ObservationFeature(..base, wind_speed_ms: Some(150.0)),
    1_700_000_000_000,
  )
  |> should.be_error

  // Negative wind speed discards entire observation
  wis2_observation.filter_plausible(
    Wis2ObservationFeature(..base, wind_speed_ms: Some(-1.0)),
    1_700_000_000_000,
  )
  |> should.be_error

  // Implausible gust (> 110 m/s) discards entire observation
  wis2_observation.filter_plausible(
    Wis2ObservationFeature(..base, gust_ms: Some(130.0)),
    1_700_000_000_000,
  )
  |> should.be_error

  // Negative gust period discards entire observation
  wis2_observation.filter_plausible(
    Wis2ObservationFeature(..base, gust_period_min: Some(-1806)),
    1_700_000_000_000,
  )
  |> should.be_error

  // Zero gust period discards entire observation
  wis2_observation.filter_plausible(
    Wis2ObservationFeature(..base, gust_period_min: Some(0)),
    1_700_000_000_000,
  )
  |> should.be_error

  // Gust period > 1440 min discards entire observation
  wis2_observation.filter_plausible(
    Wis2ObservationFeature(..base, gust_period_min: Some(1441)),
    1_700_000_000_000,
  )
  |> should.be_error

  // Unaccepted precip period (e.g. 5.0h) discards entire observation
  wis2_observation.filter_plausible(
    Wis2ObservationFeature(..base, precip: [Wis2Precip(period_h: 5.0, mm: 10.0)]),
    1_700_000_000_000,
  )
  |> should.be_error

  // Implausible 1h precip (> 400 mm) discards entire observation
  wis2_observation.filter_plausible(
    Wis2ObservationFeature(..base, precip: [
      Wis2Precip(period_h: 1.0, mm: 450.0),
    ]),
    1_700_000_000_000,
  )
  |> should.be_error

  // Implausible 24h precip (> 2000 mm) discards entire observation
  wis2_observation.filter_plausible(
    Wis2ObservationFeature(..base, precip: [
      Wis2Precip(period_h: 24.0, mm: 2500.0),
    ]),
    1_700_000_000_000,
  )
  |> should.be_error

  // Implausible MSLP (< 850 hPa) discards entire observation
  wis2_observation.filter_plausible(
    Wis2ObservationFeature(..base, mslp_pa: Some(80_000.0)),
    1_700_000_000_000,
  )
  |> should.be_error

  // Implausible MSLP (> 1090 hPa) discards entire observation
  wis2_observation.filter_plausible(
    Wis2ObservationFeature(..base, mslp_pa: Some(115_000.0)),
    1_700_000_000_000,
  )
  |> should.be_error

  // Corrupt Singapore MSS style observation (shifted elements: wind 241.1, gust 408.7)
  let corrupt_sg =
    Wis2ObservationFeature(
      data_id: "corrupt-sg",
      centre_id: "sg-mss",
      pubtime: "2026-09-25T13:00:00Z",
      station_id: "0-20000-0-48698",
      station_name: Some("Singapore Changi"),
      lat: 1.3679,
      lon: 103.982,
      elevation_m: Some(14.0),
      observed_at: "2026-09-25T13:00:00Z",
      wind_speed_ms: Some(241.1),
      gust_ms: Some(408.7),
      gust_period_min: Some(-1806),
      precip: [Wis2Precip(period_h: 24.0, mm: 1469.9)],
      mslp_pa: Some(101_180.0),
    )
  wis2_observation.filter_plausible(corrupt_sg, 1_700_000_000_000)
  |> should.be_error
}

pub fn default_thresholds_test() {
  let t = wis2_observation.default_thresholds()
  t.wind_ms |> should.equal(20.0)
  t.gust_ms |> should.equal(30.0)
  t.rain_1h_mm |> should.equal(50.0)
  t.rain_24h_mm |> should.equal(150.0)
  t.mslp_hpa |> should.equal(970.0)
}

pub fn thresholds_with_lookup_test() {
  let env_map =
    dict.from_list([
      #("WIS2_OBS_WIND_MS", "25.5"),
      #("WIS2_OBS_GUST_MS", "38.0"),
      #("WIS2_OBS_RAIN_1H_MM", "60.0"),
      #("WIS2_OBS_RAIN_24H_MM", "200.0"),
      #("WIS2_OBS_MSLP_HPA", "965.0"),
    ])

  let t =
    wis2_observation.thresholds_with_lookup(fn(k) { dict.get(env_map, k) })

  t.wind_ms |> should.equal(25.5)
  t.gust_ms |> should.equal(38.0)
  t.rain_1h_mm |> should.equal(60.0)
  t.rain_24h_mm |> should.equal(200.0)
  t.mslp_hpa |> should.equal(965.0)

  // Invalid values fall back to defaults
  let invalid_map = dict.from_list([#("WIS2_OBS_WIND_MS", "not-a-number")])
  let t2 =
    wis2_observation.thresholds_with_lookup(fn(k) { dict.get(invalid_map, k) })
  t2.wind_ms |> should.equal(20.0)
}

pub fn detect_exceedances_test() {
  let thresholds = wis2_observation.default_thresholds()
  let obs =
    PlausibleObservation(
      data_id: "obs-2",
      centre_id: "rjtd",
      pubtime: "2026-09-25T12:00:00Z",
      station_id: "0-20000-0-47662",
      station_name: Some("Tokyo"),
      lat: 35.68,
      lon: 139.76,
      elevation_m: Some(25.0),
      observed_at: "2026-09-25T12:00:00Z",
      observed_at_ms: 1_700_000_000_000,
      wind_speed_ms: Some(22.0),
      // exceeds 20.0
      gust_ms: Some(34.2),
      // exceeds 30.0
      precip_1h_mm: Some(40.0),
      // under 50.0
      precip_24h_mm: Some(160.0),
      // exceeds 150.0
      mslp_hpa: Some(962.0),
      // exceeds 970.0 (<= 970)
    )

  let exceedances = wis2_observation.detect_exceedances(obs, thresholds)
  should.equal(4, list.length(exceedances))

  let assert [e1, e2, e3, e4] = exceedances
  e1.subtype |> should.equal(SubtypeWind)
  e1.value |> should.equal(22.0)
  e2.subtype |> should.equal(SubtypeGust)
  e2.value |> should.equal(34.2)
  e3.subtype |> should.equal(SubtypeRain24h)
  e3.value |> should.equal(160.0)
  e4.subtype |> should.equal(SubtypeLowPressure)
  e4.value |> should.equal(962.0)
}

pub fn corroboration_wind_and_gust_test() {
  let thresholds = wis2_observation.default_thresholds()
  let t0 = 1_700_000_000_000
  let tokyo_lat = 35.68
  let tokyo_lon = 139.76

  // Yokohama: ~30 km from Tokyo
  let yokohama_lat = 35.44
  let yokohama_lon = 139.63

  // Sapporo: ~800 km from Tokyo
  let sapporo_lat = 43.06
  let sapporo_lon = 141.35

  let yokohama_neighbour =
    StationNeighbour(
      station_id: "0-20000-0-47670",
      lat: yokohama_lat,
      lon: yokohama_lon,
      wind_speed_ms: Some(15.0),
      // 15.0 >= 0.7 * 20.0 (14.0) -> True
      wind_observed_at_ms: Some(t0 - 3600 * 1000),
      // 1h ago
      gust_ms: Some(22.0),
      // 22.0 >= 0.7 * 30.0 (21.0) -> True
      gust_observed_at_ms: Some(t0 - 3600 * 1000),
      precip_1h_mm: None,
      precip_1h_observed_at_ms: None,
      precip_24h_mm: None,
      precip_24h_observed_at_ms: None,
      mslp_hpa: Some(978.0),
      // 978.0 <= 970 + 10 (980.0) -> True
      mslp_observed_at_ms: Some(t0 - 3600 * 1000),
    )

  // Yokohama corroborates Tokyo wind
  wis2_observation.is_corroborated(
    "0-20000-0-47662",
    tokyo_lat,
    tokyo_lon,
    t0,
    SubtypeWind,
    thresholds,
    [yokohama_neighbour],
  )
  |> should.equal(True)

  // Yokohama corroborates Tokyo gust
  wis2_observation.is_corroborated(
    "0-20000-0-47662",
    tokyo_lat,
    tokyo_lon,
    t0,
    SubtypeGust,
    thresholds,
    [yokohama_neighbour],
  )
  |> should.equal(True)

  // Yokohama corroborates Tokyo MSLP
  wis2_observation.is_corroborated(
    "0-20000-0-47662",
    tokyo_lat,
    tokyo_lon,
    t0,
    SubtypeLowPressure,
    thresholds,
    [yokohama_neighbour],
  )
  |> should.equal(True)

  // Same station does not corroborate itself
  wis2_observation.is_corroborated(
    "0-20000-0-47670",
    // same id as candidate
    tokyo_lat,
    tokyo_lon,
    t0,
    SubtypeWind,
    thresholds,
    [yokohama_neighbour],
  )
  |> should.equal(False)

  // Far away station (Sapporo, 800km) does not corroborate
  let sapporo_neighbour =
    StationNeighbour(
      ..yokohama_neighbour,
      station_id: "0-20000-0-47412",
      lat: sapporo_lat,
      lon: sapporo_lon,
    )
  wis2_observation.is_corroborated(
    "0-20000-0-47662",
    tokyo_lat,
    tokyo_lon,
    t0,
    SubtypeWind,
    thresholds,
    [sapporo_neighbour],
  )
  |> should.equal(False)

  // Old observation (>3h) does not corroborate
  let old_neighbour =
    StationNeighbour(
      ..yokohama_neighbour,
      wind_observed_at_ms: Some(t0 - 4 * 3600 * 1000),
    )
  wis2_observation.is_corroborated(
    "0-20000-0-47662",
    tokyo_lat,
    tokyo_lon,
    t0,
    SubtypeWind,
    thresholds,
    [old_neighbour],
  )
  |> should.equal(False)

  // Value below 70% does not corroborate (13.0 < 14.0 for wind)
  let low_neighbour =
    StationNeighbour(..yokohama_neighbour, wind_speed_ms: Some(13.0))
  wis2_observation.is_corroborated(
    "0-20000-0-47662",
    tokyo_lat,
    tokyo_lon,
    t0,
    SubtypeWind,
    thresholds,
    [low_neighbour],
  )
  |> should.equal(False)

  // MSLP > 980 hPa does not corroborate
  let high_pressure_neighbour =
    StationNeighbour(..yokohama_neighbour, mslp_hpa: Some(985.0))
  wis2_observation.is_corroborated(
    "0-20000-0-47662",
    tokyo_lat,
    tokyo_lon,
    t0,
    SubtypeLowPressure,
    thresholds,
    [high_pressure_neighbour],
  )
  |> should.equal(False)
}

pub fn can_merge_test() {
  let ts = timestamp.from_unix_seconds(1_700_000_000)
  let base_hazard =
    Hazard(
      source: "wis2-rjtd",
      source_id: "0-20000-0-47662/gust/1700000000",
      source_episode_id: None,
      episode_count: 1,
      hazard_type: "observed_extreme",
      hazard_codes: ["wis2:synop", "wis2:extreme:gust"],
      glide: None,
      alert_level: "orange",
      alert_score: None,
      cap_severity: "severe",
      severity_value: Some(34.2),
      severity_unit: Some("m/s"),
      severity_label: Some("Gust"),
      estimate_type: "primary",
      title: "Gust 34.2 m/s at Tokyo",
      description: None,
      countries: [],
      report_url: None,
      external_ids: ["station:0-20000-0-47662"],
      onset_at: ts,
      onset_at_ms: 1_700_000_000_000,
      expires_at: Some(ts),
      expires_at_ms: Some(1_700_000_000_000 + 3 * 3600 * 1000),
      modified_at: ts,
      modified_at_ms: 1_700_000_000_000,
      is_current: True,
      longitude: 139.76,
      latitude: 35.68,
      bbox: None,
      primary_geometry: None,
      geometries: None,
      first_seen_at: ts,
      last_seen_at: ts,
      subtype: Some("gust"),
      confirmed: Some(False),
    )

  // Within 3 hours after modified_at -> can merge
  wis2_observation.can_merge(base_hazard, 1_700_000_000_000 + 2 * 3600 * 1000)
  |> should.equal(True)

  // Exactly at 3 hours -> can merge
  wis2_observation.can_merge(base_hazard, 1_700_000_000_000 + 3 * 3600 * 1000)
  |> should.equal(True)

  // Past 3 hours -> cannot merge
  wis2_observation.can_merge(
    base_hazard,
    1_700_000_000_000 + 3 * 3600 * 1000 + 1,
  )
  |> should.equal(False)

  // When is_current is False -> cannot merge
  let ended_hazard = Hazard(..base_hazard, is_current: False)
  wis2_observation.can_merge(ended_hazard, 1_700_000_000_000 + 1 * 3600 * 1000)
  |> should.equal(False)
}

pub fn merge_severity_value_test() {
  // Gust / Wind / Rain: keeps max
  wis2_observation.merge_severity_value(SubtypeGust, 34.0, 42.0)
  |> should.equal(42.0)
  wis2_observation.merge_severity_value(SubtypeGust, 42.0, 35.0)
  |> should.equal(42.0)

  // Low pressure: keeps min
  wis2_observation.merge_severity_value(SubtypeLowPressure, 965.0, 958.0)
  |> should.equal(958.0)
  wis2_observation.merge_severity_value(SubtypeLowPressure, 958.0, 962.0)
  |> should.equal(958.0)
}

pub fn format_title_test() {
  wis2_observation.format_title(
    SubtypeGust,
    34.2,
    "0-20000-0-47662",
    Some("Tokyo"),
  )
  |> should.equal("Gust 34.2 m/s at Tokyo")

  wis2_observation.format_title(SubtypeGust, 34.2, "0-20000-0-47662", None)
  |> should.equal("Gust 34.2 m/s at 0-20000-0-47662")

  wis2_observation.format_title(
    SubtypeGust,
    34.2,
    "0-20000-0-47662",
    Some("   "),
  )
  |> should.equal("Gust 34.2 m/s at 0-20000-0-47662")

  wis2_observation.format_title(SubtypeWind, 22.0, "0-20000-0-47662", None)
  |> should.equal("Wind 22.0 m/s at 0-20000-0-47662")

  wis2_observation.format_title(SubtypeRain1h, 55.0, "0-20000-0-47662", None)
  |> should.equal("Rain 1h 55.0 mm at 0-20000-0-47662")

  wis2_observation.format_title(SubtypeRain24h, 160.0, "0-20000-0-47662", None)
  |> should.equal("Rain 24h 160.0 mm at 0-20000-0-47662")

  wis2_observation.format_title(
    SubtypeLowPressure,
    960.0,
    "0-20000-0-47662",
    None,
  )
  |> should.equal("MSLP 960.0 hPa at 0-20000-0-47662")
}
