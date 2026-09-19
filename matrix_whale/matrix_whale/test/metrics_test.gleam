import adapter/alert_hub
import adapter/context
import adapter/earthquake_hub
import adapter/hazard_hub
import adapter/reciever
import controller/earthquake_controller
import domain/earthquake
import gleam/erlang/process
import gleam/http
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/time/timestamp
import gleeunit/should
import intake/pipeline
import intake/seen_set
import metrics
import pog
import repository/alert_writer
import wisp/simulate

fn test_context() -> context.Context {
  let assert Ok(alert) = alert_hub.start()
  let assert Ok(earthquake) = earthquake_hub.start()
  let assert Ok(hazard) = hazard_hub.start()
  context.Context(
    secret: "test_secret",
    db: pog.named_connection(process.new_name("unused_metrics_test_db")),
    hub: alert.data,
    earthquake_hub: earthquake.data,
    hazard_hub: hazard.data,
    seen: seen_set.new("metrics_test_seen", 3_600_000),
  )
}

pub fn route_template_test() {
  // Receiver routes
  metrics.route_template(["metrics"])
  |> should.equal("/metrics")
  metrics.route_template(["api", "v1", "health"])
  |> should.equal("/api/v1/health")
  metrics.route_template(["api", "v1", "logs"])
  |> should.equal("/api/v1/logs")
  metrics.route_template(["api", "v1", "noaa_data", "send"])
  |> should.equal("/api/v1/noaa_data/send")
  metrics.route_template(["api", "v1", "usgs_data", "send"])
  |> should.equal("/api/v1/usgs_data/send")
  metrics.route_template(["api", "v1", "emsc_data", "send"])
  |> should.equal("/api/v1/emsc_data/send")
  metrics.route_template(["api", "v1", "gdacs_data", "send"])
  |> should.equal("/api/v1/gdacs_data/send")
  metrics.route_template(["api", "v1", "gdacs_data", "geometry", "pending"])
  |> should.equal("/api/v1/gdacs_data/geometry/pending")
  metrics.route_template(["api", "v1", "gdacs_data", "geometry"])
  |> should.equal("/api/v1/gdacs_data/geometry")
  metrics.route_template(["api", "v1", "cap_data", "registry"])
  |> should.equal("/api/v1/cap_data/registry")
  metrics.route_template(["api", "v1", "cap_data", "feeds"])
  |> should.equal("/api/v1/cap_data/feeds")
  metrics.route_template(["api", "v1", "cap_data", "index"])
  |> should.equal("/api/v1/cap_data/index")
  metrics.route_template(["api", "v1", "cap_data", "pending"])
  |> should.equal("/api/v1/cap_data/pending")
  metrics.route_template(["api", "v1", "cap_data", "alerts"])
  |> should.equal("/api/v1/cap_data/alerts")

  // Streamer routes
  metrics.route_template(["api", "v1", "streamer", "health"])
  |> should.equal("/api/v1/streamer/health")
  metrics.route_template(["api", "v1", "alerts", "active"])
  |> should.equal("/api/v1/alerts/active")
  metrics.route_template(["api", "v1", "alerts", "detail"])
  |> should.equal("/api/v1/alerts/detail")
  metrics.route_template(["api", "v1", "alerts", "stream"])
  |> should.equal("/api/v1/alerts/stream")
  metrics.route_template(["api", "v1", "alerts", "search"])
  |> should.equal("/api/v1/alerts/search")
  metrics.route_template(["api", "v1", "alerts", "history"])
  |> should.equal("/api/v1/alerts/history")
  metrics.route_template(["api", "v1", "cap", "feeds"])
  |> should.equal("/api/v1/cap/feeds")
  metrics.route_template(["api", "v1", "earthquakes", "recent"])
  |> should.equal("/api/v1/earthquakes/recent")
  metrics.route_template(["api", "v1", "earthquakes", "stream"])
  |> should.equal("/api/v1/earthquakes/stream")
  metrics.route_template(["api", "v1", "pipeline", "status"])
  |> should.equal("/api/v1/pipeline/status")
  metrics.route_template(["api", "v1", "sources"])
  |> should.equal("/api/v1/sources")
  metrics.route_template(["api", "v1", "hazards", "recent"])
  |> should.equal("/api/v1/hazards/recent")
  metrics.route_template(["api", "v1", "hazards", "stream"])
  |> should.equal("/api/v1/hazards/stream")
  metrics.route_template(["api", "v1", "hazards", "usgs", "123"])
  |> should.equal("/api/v1/hazards/:source/:id")
  metrics.route_template(["api", "v1", "timeline"])
  |> should.equal("/api/v1/timeline")

  // Unmatched
  metrics.route_template(["api", "v1", "unknown", "path"])
  |> should.equal("unmatched")
  metrics.route_template([])
  |> should.equal("unmatched")
}

pub fn is_stream_route_test() {
  metrics.is_stream_route("/api/v1/alerts/stream")
  |> should.equal(True)

  metrics.is_stream_route("/api/v1/earthquakes/stream")
  |> should.equal(True)

  metrics.is_stream_route("/api/v1/hazards/stream")
  |> should.equal(True)

  metrics.is_stream_route("/api/v1/timeline")
  |> should.equal(False)
}

pub fn lag_clamping_test() {
  // Positive lag
  metrics.calculate_lag(100.0, 95.5)
  |> should.equal(4.5)

  // Exactly zero
  metrics.calculate_lag(100.0, 100.0)
  |> should.equal(0.0)

  // Upstream ahead of clock (negative lag clamped to 0.0)
  metrics.calculate_lag(100.0, 105.0)
  |> should.equal(0.0)
}

pub fn setup_idempotent_and_render_contains_metrics_test() {
  // Calling setup() twice does not crash
  metrics.setup()
  metrics.setup()

  // Make a few observations
  metrics.observe_http(metrics.Ingest, "/metrics", "GET", 200, 0.012)
  metrics.observe_http(
    metrics.Api,
    "/api/v1/earthquakes/stream",
    "GET",
    200,
    1.5,
  )

  let outcome =
    pipeline.Outcome(
      results: [],
      new: 2,
      updated: 1,
      unchanged: 3,
      stale: 0,
      repeats: 1,
    )
  metrics.record_intake("usgs", outcome)

  metrics.observe_ingest_lag("usgs", metrics.LagUpdated, 12.3)
  metrics.observe_ingest_lag("usgs", metrics.LagOccurred, 45.6)

  let timed_result =
    metrics.time_db(metrics.EarthquakeWrite, fn() { "db_done" })
  timed_result |> should.equal("db_done")

  metrics.set_sse_clients(metrics.Earthquakes, 4)
  metrics.observe_sse_publish_delay(metrics.Earthquakes, 0.003)

  let rendered = metrics.render()

  // Verify rendered output contains all metric names
  string.contains(rendered, "matrixwhale_http_requests_total")
  |> should.equal(True)
  string.contains(rendered, "matrixwhale_http_request_duration_seconds")
  |> should.equal(True)
  string.contains(rendered, "matrixwhale_intake_records_total")
  |> should.equal(True)
  string.contains(rendered, "matrixwhale_ingest_lag_seconds")
  |> should.equal(True)
  string.contains(rendered, "matrixwhale_db_duration_seconds")
  |> should.equal(True)
  string.contains(rendered, "matrixwhale_sse_clients")
  |> should.equal(True)
  string.contains(rendered, "matrixwhale_sse_publish_delay_seconds")
  |> should.equal(True)

  // Verify BEAM VM collectors are kept
  string.contains(rendered, "erlang_vm_")
  |> should.equal(True)
}

pub fn receiver_metrics_endpoint_test() {
  let ctx = test_context()
  let request = simulate.request(http.Get, "/metrics")

  let response = reciever.reciever_router(request, ctx)

  response.status
  |> should.equal(200)

  // Check content-type header
  let content_type = list.key_find(response.headers, "content-type")
  content_type
  |> should.equal(Ok("text/plain; version=0.0.4; charset=utf-8"))

  // Check that POST /metrics returns 405
  let post_req = simulate.request(http.Post, "/metrics")
  let post_resp = reciever.reciever_router(post_req, ctx)
  post_resp.status
  |> should.equal(405)
}

fn make_earthquake(occurred_ms: Int, updated_ms: Int) -> earthquake.Earthquake {
  let time = timestamp.from_unix_seconds(0)
  earthquake.Earthquake(
    source: "usgs",
    source_id: "test1",
    contributing_ids: ["test1"],
    sources: ["usgs"],
    net: None,
    code: None,
    magnitude: Some(5.0),
    magnitude_type: None,
    occurred_at: time,
    occurred_at_ms: occurred_ms,
    updated_at: time,
    updated_at_ms: updated_ms,
    place: None,
    title: None,
    status: None,
    event_type: Some("earthquake"),
    tsunami: None,
    significance: None,
    alert: None,
    mmi: None,
    cdi: None,
    felt: None,
    nst: None,
    dmin: None,
    rms: None,
    gap: None,
    url: None,
    detail: None,
    longitude: 0.0,
    latitude: 0.0,
    depth_km: None,
    first_seen_at: time,
    last_seen_at: time,
  )
}

pub fn earthquake_lag_observations_test() {
  let now_seconds = 100.0
  // new quake: occurred at t=70s, updated at t=90s
  let new_quake = make_earthquake(70_000, 90_000)
  // updated quake: occurred at t=10s (3 days ago), updated at t=95s
  let updated_quake = make_earthquake(10_000, 95_000)

  let observations =
    earthquake_controller.lag_observations(
      [new_quake],
      [updated_quake],
      now_seconds,
    )

  // basis="occurred" is observed ONLY for new rows, NOT for updated rows
  // basis="updated" is observed for both new and updated rows
  observations
  |> should.equal([
    #(metrics.LagUpdated, 10.0),
    #(metrics.LagOccurred, 30.0),
    #(metrics.LagUpdated, 5.0),
  ])

  // Missing or non-positive timestamps are skipped
  let missing_ts_quake = make_earthquake(0, 0)
  earthquake_controller.lag_observations([missing_ts_quake], [], now_seconds)
  |> should.equal([])
}

pub fn empty_publish_in_hubs_test() {
  let assert Ok(alert) = alert_hub.start()
  let assert Ok(earthquake) = earthquake_hub.start()
  let assert Ok(hazard) = hazard_hub.start()

  // Publishing empty diff/events skips delay observation and runs cleanly
  alert_hub.publish(
    alert.data,
    alert_writer.AlertDiff(new: [], updated: [], ended: []),
  )
  earthquake_hub.publish(earthquake.data, [], [], False)
  hazard_hub.publish(hazard.data, [], [])
}

pub fn histogram_duration_unit_seconds_test() {
  metrics.setup()
  metrics.observe_ingest_lag("test_src", metrics.LagUpdated, 42.5)

  let rendered = metrics.render()

  string.contains(
    rendered,
    "matrixwhale_ingest_lag_seconds_sum{source=\"test_src\",basis=\"updated\"} 42.5",
  )
  |> should.equal(True)

  string.contains(
    rendered,
    "matrixwhale_ingest_lag_seconds_bucket{source=\"test_src\",basis=\"updated\",le=\"60\"} 1",
  )
  |> should.equal(True)

  string.contains(
    rendered,
    "matrixwhale_ingest_lag_seconds_bucket{source=\"test_src\",basis=\"updated\",le=\"30\"} 0",
  )
  |> should.equal(True)
}
