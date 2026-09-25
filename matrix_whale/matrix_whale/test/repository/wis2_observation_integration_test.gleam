import adapter/streamer
import controller/wis2_controller
import domain/cap
import domain/wis2_observation.{
  type Wis2ObservationFeature, type Wis2Precip, Wis2ObservationFeature,
  Wis2Precip,
}
import dot_env/env
import gleam/bit_array
import gleam/bytes_tree
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleeunit/should
import message/reciever/wis2_reciever
import mist
import repository/wis2_writer
import support/test_db
import wisp/simulate

fn read_mist_body(res: response.Response(mist.ResponseData)) -> String {
  let assert mist.Bytes(tree) = res.body
  let assert Ok(text) = bit_array.to_string(bytes_tree.to_bit_array(tree))
  text
}

fn make_obs(
  station_id: String,
  name: Option(String),
  lat: Float,
  lon: Float,
  time_str: String,
  wind: Option(Float),
  gust: Option(Float),
  precip: List(Wis2Precip),
  mslp: Option(Float),
) -> Wis2ObservationFeature {
  Wis2ObservationFeature(
    data_id: "data-" <> station_id <> "-" <> time_str,
    centre_id: "rjtd",
    pubtime: time_str,
    station_id: station_id,
    station_name: name,
    lat: lat,
    lon: lon,
    elevation_m: Some(10.0),
    observed_at: time_str,
    wind_speed_ms: wind,
    gust_ms: gust,
    gust_period_min: Some(10),
    precip: precip,
    mslp_pa: mslp,
  )
}

// 1. Single exceedance -> unconfirmed episode
pub fn single_exceedance_unconfirmed_episode_test() {
  use conn <- test_db.with_test_db
  let ctx = test_db.integration_context(conn)

  let obs =
    make_obs(
      "0-20000-0-47662",
      Some("Tokyo"),
      35.6895,
      139.6917,
      "2026-09-26T00:00:00Z",
      Some(15.0),
      Some(35.0),
      [],
      None,
    )

  let body =
    json.to_string(wis2_observation.observations_envelope_to_json([obs]))
  let post_req =
    simulate.request(http.Post, "/api/v1/wis2_data/observations")
    |> simulate.string_body(body)
    |> request.set_header("content-type", "application/json")

  let post_resp = wis2_reciever.observations_handler(post_req, ctx)
  post_resp.status |> should.equal(200)
  let resp_body = simulate.read_body(post_resp)
  string.contains(resp_body, "\"written\":1") |> should.equal(True)
  string.contains(resp_body, "\"dropped\":0") |> should.equal(True)

  // Verify station in sea.wis2_station
  test_db.count(conn, "sea.wis2_station") |> should.equal(1)
  let st_name =
    test_db.scalar_text(
      conn,
      "SELECT name FROM sea.wis2_station WHERE station_id = '0-20000-0-47662'",
    )
  st_name |> should.equal("Tokyo")

  // Verify hazard episode in sea.hazard
  test_db.count(conn, "sea.hazard") |> should.equal(1)
  let hazard_type =
    test_db.scalar_text(conn, "SELECT hazard_type FROM sea.hazard LIMIT 1")
  hazard_type |> should.equal("observed_extreme")

  let subtype =
    test_db.scalar_text(conn, "SELECT subtype FROM sea.hazard LIMIT 1")
  subtype |> should.equal("gust")

  let confirmed =
    test_db.scalar_bool(conn, "SELECT confirmed FROM sea.hazard LIMIT 1")
  confirmed |> should.equal(False)

  let is_current =
    test_db.scalar_bool(conn, "SELECT is_current FROM sea.hazard LIMIT 1")
  is_current |> should.equal(True)

  let title = test_db.scalar_text(conn, "SELECT title FROM sea.hazard LIMIT 1")
  string.contains(title, "Gust 35.0 m/s at Tokyo") |> should.equal(True)

  // Verify /api/v1/hazards/recent streamer response
  let recent_req =
    request.new()
    |> request.set_path("/api/v1/hazards/recent")
    |> request.set_method(http.Get)
  let recent_resp = streamer.hazards_response(recent_req, ctx)
  recent_resp.status |> should.equal(200)
  let recent_body = read_mist_body(recent_resp)
  string.contains(recent_body, "\"subtype\":\"gust\"") |> should.equal(True)
  string.contains(recent_body, "\"confirmed\":false") |> should.equal(True)

  // Verify timeline response includes the observed extreme
  let timeline_req =
    request.new()
    |> request.set_path("/api/v1/timeline")
    |> request.set_method(http.Get)
  let timeline_resp = streamer.timeline_response(timeline_req, ctx)
  timeline_resp.status |> should.equal(200)
  let timeline_body = read_mist_body(timeline_resp)
  string.contains(timeline_body, "observed_extreme") |> should.equal(True)
}

// 2. Neighbour with 70% value -> confirmed episode
pub fn neighbour_70_percent_value_confirmed_test() {
  use conn <- test_db.with_test_db
  let ctx = test_db.integration_context(conn)

  // Yokohama: ~28 km from Tokyo, gust 22.0 m/s (>= 70% of 30.0 = 21.0 m/s)
  let obs_neighbour =
    make_obs(
      "0-20000-0-47674",
      Some("Yokohama"),
      35.4437,
      139.638,
      "2026-09-26T00:00:00Z",
      Some(10.0),
      Some(22.0),
      [],
      None,
    )

  // Tokyo: gust 35.0 m/s (exceeds 30.0 m/s)
  let obs_primary =
    make_obs(
      "0-20000-0-47662",
      Some("Tokyo"),
      35.6895,
      139.6917,
      "2026-09-26T00:10:00Z",
      Some(12.0),
      Some(35.0),
      [],
      None,
    )

  let assert Ok(ack) =
    wis2_controller.process_observations(
      None,
      [obs_neighbour, obs_primary],
      2,
      0,
      ctx,
    )
  ack.written |> should.equal(2)

  // Tokyo episode should be confirmed
  let confirmed =
    test_db.scalar_bool(
      conn,
      "SELECT confirmed FROM sea.hazard WHERE external_ids @> ARRAY['station:0-20000-0-47662']",
    )
  confirmed |> should.equal(True)

  // In /api/v1/hazards/recent, hazard is confirmed
  let recent_req =
    request.new()
    |> request.set_path("/api/v1/hazards/recent")
    |> request.set_method(http.Get)
  let recent_resp = streamer.hazards_response(recent_req, ctx)
  recent_resp.status |> should.equal(200)
  let recent_body = read_mist_body(recent_resp)
  string.contains(recent_body, "\"confirmed\":true") |> should.equal(True)
}

// 3. Follow-up exceedance within 3 h extends and updates max
pub fn followup_exceedance_within_3h_extends_and_updates_max_test() {
  use conn <- test_db.with_test_db
  let ctx = test_db.integration_context(conn)

  // Initial observation at T
  let obs1 =
    make_obs(
      "0-20000-0-47662",
      Some("Tokyo"),
      35.6895,
      139.6917,
      "2026-09-26T00:00:00Z",
      None,
      Some(32.0),
      [],
      None,
    )
  let assert Ok(_) =
    wis2_controller.process_observations(None, [obs1], 1, 0, ctx)

  test_db.count(conn, "sea.hazard") |> should.equal(1)
  let count1 =
    test_db.scalar_int(conn, "SELECT episode_count FROM sea.hazard LIMIT 1")
  count1 |> should.equal(1)
  let val1 =
    test_db.scalar_float(conn, "SELECT severity_value FROM sea.hazard LIMIT 1")
  val1 |> should.equal(32.0)

  // Follow-up observation at T + 1.5h with higher gust (38.0 m/s)
  let obs2 =
    make_obs(
      "0-20000-0-47662",
      Some("Tokyo"),
      35.6895,
      139.6917,
      "2026-09-26T01:30:00Z",
      None,
      Some(38.0),
      [],
      None,
    )
  let assert Ok(_) =
    wis2_controller.process_observations(None, [obs2], 1, 0, ctx)

  // Still 1 episode, but count is 2 and severity_value updated to 38.0
  test_db.count(conn, "sea.hazard") |> should.equal(1)
  let count2 =
    test_db.scalar_int(conn, "SELECT episode_count FROM sea.hazard LIMIT 1")
  count2 |> should.equal(2)
  let val2 =
    test_db.scalar_float(conn, "SELECT severity_value FROM sea.hazard LIMIT 1")
  val2 |> should.equal(38.0)

  let title2 = test_db.scalar_text(conn, "SELECT title FROM sea.hazard LIMIT 1")
  string.contains(title2, "Gust 38.0 m/s at Tokyo") |> should.equal(True)

  // Also verify low pressure updates to MINIMUM
  let obs_p1 =
    make_obs(
      "0-20000-0-47662",
      Some("Tokyo"),
      35.6895,
      139.6917,
      "2026-09-26T02:00:00Z",
      None,
      None,
      [],
      Some(96_500.0),
      // 965 hPa <= 970 hPa threshold
    )
  let assert Ok(_) =
    wis2_controller.process_observations(None, [obs_p1], 1, 0, ctx)

  let p_val1 =
    test_db.scalar_float(
      conn,
      "SELECT severity_value FROM sea.hazard WHERE subtype = 'low_pressure'",
    )
  p_val1 |> should.equal(965.0)

  let obs_p2 =
    make_obs(
      "0-20000-0-47662",
      Some("Tokyo"),
      35.6895,
      139.6917,
      "2026-09-26T02:30:00Z",
      None,
      None,
      [],
      Some(95_800.0),
      // 958 hPa (lower pressure)
    )
  let assert Ok(_) =
    wis2_controller.process_observations(None, [obs_p2], 1, 0, ctx)

  let p_val2 =
    test_db.scalar_float(
      conn,
      "SELECT severity_value FROM sea.hazard WHERE subtype = 'low_pressure'",
    )
  p_val2 |> should.equal(958.0)
}

// 4. Sweep ends episode after 3 h
pub fn sweep_ends_episode_after_3h_test() {
  use conn <- test_db.with_test_db
  let ctx = test_db.integration_context(conn)

  let obs =
    make_obs(
      "0-20000-0-47662",
      Some("Tokyo"),
      35.6895,
      139.6917,
      "2026-09-26T00:00:00Z",
      None,
      Some(35.0),
      [],
      None,
    )
  let assert Ok(_) =
    wis2_controller.process_observations(None, [obs], 1, 0, ctx)

  let is_curr1 =
    test_db.scalar_bool(conn, "SELECT is_current FROM sea.hazard LIMIT 1")
  is_curr1 |> should.equal(True)

  // 3h 10m later
  let assert Ok(sweep_time) = cap.parse_rfc3339("2026-09-26T03:10:00Z")
  let assert Ok(ended) = wis2_writer.sweep_expired_episodes(sweep_time, conn)
  list.length(ended) |> should.equal(1)

  let is_curr2 =
    test_db.scalar_bool(conn, "SELECT is_current FROM sea.hazard LIMIT 1")
  is_curr2 |> should.equal(False)

  // No longer in recent active hazards
  let recent_req =
    request.new()
    |> request.set_path("/api/v1/hazards/recent")
    |> request.set_method(http.Get)
  let recent_resp = streamer.hazards_response(recent_req, ctx)
  let recent_body = read_mist_body(recent_resp)
  string.contains(recent_body, "\"hazards\":[]") |> should.equal(True)
}

// 5. Implausible observation discarded as a whole
pub fn implausible_observation_discarded_as_a_whole_test() {
  use conn <- test_db.with_test_db
  let ctx = test_db.integration_context(conn)

  let obs =
    make_obs(
      "0-20000-0-47662",
      Some("Tokyo"),
      35.6895,
      139.6917,
      "2026-09-26T00:00:00Z",
      Some(150.0),
      // implausible > 110 m/s
      Some(130.0),
      // implausible > 110 m/s
      [Wis2Precip(period_h: 1.0, mm: 450.0)],
      // implausible > 400 mm
      Some(80_000.0),
      // implausible < 850 hPa
    )

  let assert Ok(ack) =
    wis2_controller.process_observations(None, [obs], 1, 0, ctx)
  ack.written |> should.equal(0)
  ack.dropped |> should.equal(1)

  // Nothing upserted: sea.wis2_station remains empty
  test_db.count(conn, "sea.wis2_station") |> should.equal(0)

  // No exceedance episodes created in sea.hazard
  test_db.count(conn, "sea.hazard") |> should.equal(0)
}

// 5b. If ANY element fails plausibility, whole observation discarded even with exceedance
pub fn partial_implausible_discards_whole_observation_test() {
  use conn <- test_db.with_test_db
  let ctx = test_db.integration_context(conn)

  // Has gust 35.0 m/s (exceedance), but wind 241.1 m/s (implausible)
  let obs =
    make_obs(
      "0-20000-0-47662",
      Some("Tokyo"),
      35.6895,
      139.6917,
      "2026-09-26T00:00:00Z",
      Some(241.1),
      Some(35.0),
      [],
      None,
    )

  let assert Ok(ack) =
    wis2_controller.process_observations(None, [obs], 1, 0, ctx)
  ack.written |> should.equal(0)
  ack.dropped |> should.equal(1)

  // Nothing upserted, no hazard created
  test_db.count(conn, "sea.wis2_station") |> should.equal(0)
  test_db.count(conn, "sea.hazard") |> should.equal(0)

  // Negative period (-1806 min) also discards whole observation
  let obs_bad_period =
    Wis2ObservationFeature(
      data_id: "obs-bad-period",
      centre_id: "rjtd",
      pubtime: "2026-09-26T00:00:00Z",
      station_id: "0-20000-0-47662",
      station_name: Some("Tokyo"),
      lat: 35.6895,
      lon: 139.6917,
      elevation_m: Some(10.0),
      observed_at: "2026-09-26T00:00:00Z",
      wind_speed_ms: Some(15.0),
      gust_ms: Some(35.0),
      gust_period_min: Some(-1806),
      precip: [],
      mslp_pa: None,
    )

  let assert Ok(ack2) =
    wis2_controller.process_observations(None, [obs_bad_period], 1, 0, ctx)
  ack2.written |> should.equal(0)
  ack2.dropped |> should.equal(1)

  test_db.count(conn, "sea.wis2_station") |> should.equal(0)
  test_db.count(conn, "sea.hazard") |> should.equal(0)
}

// 6. Env override changes a threshold
pub fn env_override_changes_threshold_test() {
  use conn <- test_db.with_test_db
  let ctx = test_db.integration_context(conn)

  // Lower wind threshold from 20.0 to 15.0
  let _ = env.set("WIS2_OBS_WIND_MS", "15.0")

  let obs =
    make_obs(
      "0-20000-0-47662",
      Some("Tokyo"),
      35.6895,
      139.6917,
      "2026-09-26T00:00:00Z",
      Some(16.0),
      // 16.0 < 20.0 default, but >= 15.0 override
      None,
      [],
      None,
    )

  let assert Ok(ack) =
    wis2_controller.process_observations(None, [obs], 1, 0, ctx)
  ack.written |> should.equal(1)

  // Hazard should be created because of the 15.0 m/s threshold
  test_db.count(conn, "sea.hazard") |> should.equal(1)
  let subtype =
    test_db.scalar_text(conn, "SELECT subtype FROM sea.hazard LIMIT 1")
  subtype |> should.equal("wind")

  let val =
    test_db.scalar_float(conn, "SELECT severity_value FROM sea.hazard LIMIT 1")
  val |> should.equal(16.0)

  // Reset env
  let _ = env.set("WIS2_OBS_WIND_MS", "20.0")
  Nil
}

fn int_range(from: Int, to: Int) -> List(Int) {
  case from > to {
    True -> []
    False -> [from, ..int_range(from + 1, to)]
  }
}

// 7. Batch of 500 observations handled in one request
pub fn batch_of_500_observations_handled_in_one_request_test() {
  use conn <- test_db.with_test_db
  let ctx = test_db.integration_context(conn)

  let features =
    int_range(1, 500)
    |> list.map(fn(i) {
      let st_id = "0-20000-0-" <> int.to_string(i)
      let gust = case i {
        42 -> Some(36.0)
        // One station exceeds threshold
        _ -> Some(10.0)
      }
      make_obs(
        st_id,
        Some("Station " <> int.to_string(i)),
        35.0 +. int.to_float(i) *. 0.001,
        139.0 +. int.to_float(i) *. 0.001,
        "2026-09-26T00:00:00Z",
        Some(8.0),
        gust,
        [],
        None,
      )
    })

  let body =
    json.to_string(wis2_observation.observations_envelope_to_json(features))
  let post_req =
    simulate.request(http.Post, "/api/v1/wis2_data/observations")
    |> simulate.string_body(body)
    |> request.set_header("content-type", "application/json")

  let post_resp = wis2_reciever.observations_handler(post_req, ctx)
  post_resp.status |> should.equal(200)

  let resp_body = simulate.read_body(post_resp)
  string.contains(resp_body, "\"received\":500") |> should.equal(True)
  string.contains(resp_body, "\"written\":500") |> should.equal(True)
  string.contains(resp_body, "\"deduped\":0") |> should.equal(True)
  string.contains(resp_body, "\"dropped\":0") |> should.equal(True)

  test_db.count(conn, "sea.wis2_station") |> should.equal(500)
  test_db.count(conn, "sea.hazard") |> should.equal(1)
}
