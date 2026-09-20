import gleam/int
import gleam/time/timestamp
import intake/pipeline

pub type Listener {
  Ingest
  Api
}

pub fn listener_to_string(listener: Listener) -> String {
  case listener {
    Ingest -> "ingest"
    Api -> "api"
  }
}

pub type Stream {
  Alerts
  Earthquakes
  Hazards
}

pub fn stream_to_string(stream: Stream) -> String {
  case stream {
    Alerts -> "alerts"
    Earthquakes -> "earthquakes"
    Hazards -> "hazards"
  }
}

pub type DbOp {
  EarthquakeWrite
  NoaaAlertWrite
  GdacsEventWrite
  GdacsGeometryWrite
  CapMessageWrite
  CapIndexWrite
  CapRegistryWrite
  EarthquakeCleanup
  AlertExpire
  AlertCleanup
}

pub fn db_op_to_string(op: DbOp) -> String {
  case op {
    EarthquakeWrite -> "earthquake_write"
    NoaaAlertWrite -> "noaa_alert_write"
    GdacsEventWrite -> "gdacs_event_write"
    GdacsGeometryWrite -> "gdacs_geometry_write"
    CapMessageWrite -> "cap_message_write"
    CapIndexWrite -> "cap_index_write"
    CapRegistryWrite -> "cap_registry_write"
    EarthquakeCleanup -> "earthquake_cleanup"
    AlertExpire -> "alert_expire"
    AlertCleanup -> "alert_cleanup"
  }
}

pub type LagBasis {
  LagUpdated
  LagOccurred
}

pub fn lag_basis_to_string(basis: LagBasis) -> String {
  case basis {
    LagUpdated -> "updated"
    LagOccurred -> "occurred"
  }
}

pub type IntakeOutcome {
  IntakeNew
  IntakeUpdated
  IntakeUnchanged
  IntakeStale
  IntakeRepeat
}

pub fn intake_outcome_to_string(outcome: IntakeOutcome) -> String {
  case outcome {
    IntakeNew -> "new"
    IntakeUpdated -> "updated"
    IntakeUnchanged -> "unchanged"
    IntakeStale -> "stale"
    IntakeRepeat -> "repeat"
  }
}

@external(erlang, "metrics_ffi", "setup")
pub fn setup() -> Nil

@external(erlang, "metrics_ffi", "render")
pub fn render() -> String

@external(erlang, "metrics_ffi", "monotonic_now")
pub fn monotonic_now() -> Int

@external(erlang, "metrics_ffi", "monotonic_elapsed_seconds")
pub fn monotonic_elapsed_seconds(start: Int) -> Float

@external(erlang, "metrics_ffi", "counter_inc")
fn ffi_counter_inc(name: String, labels: List(String)) -> Nil

@external(erlang, "metrics_ffi", "counter_inc_by")
fn ffi_counter_inc_by(name: String, labels: List(String), amount: Int) -> Nil

@external(erlang, "metrics_ffi", "histogram_observe")
fn ffi_histogram_observe(
  name: String,
  labels: List(String),
  value: Float,
) -> Nil

@external(erlang, "metrics_ffi", "gauge_set")
fn ffi_gauge_set(name: String, labels: List(String), value: Int) -> Nil

pub fn route_template(segments: List(String)) -> String {
  case segments {
    ["metrics"] -> "/metrics"
    ["api", "v1", "health"] -> "/api/v1/health"
    ["api", "v1", "logs"] -> "/api/v1/logs"
    ["api", "v1", "noaa_data", "send"] -> "/api/v1/noaa_data/send"
    ["api", "v1", "usgs_data", "send"] -> "/api/v1/usgs_data/send"
    ["api", "v1", "emsc_data", "send"] -> "/api/v1/emsc_data/send"
    ["api", "v1", "gdacs_data", "send"] -> "/api/v1/gdacs_data/send"
    ["api", "v1", "gdacs_data", "geometry", "pending"] ->
      "/api/v1/gdacs_data/geometry/pending"
    ["api", "v1", "gdacs_data", "geometry"] -> "/api/v1/gdacs_data/geometry"
    ["api", "v1", "cap_data", "registry"] -> "/api/v1/cap_data/registry"
    ["api", "v1", "cap_data", "feeds"] -> "/api/v1/cap_data/feeds"
    ["api", "v1", "cap_data", "index"] -> "/api/v1/cap_data/index"
    ["api", "v1", "cap_data", "pending"] -> "/api/v1/cap_data/pending"
    ["api", "v1", "cap_data", "alerts"] -> "/api/v1/cap_data/alerts"
    ["api", "v1", "streamer", "health"] -> "/api/v1/streamer/health"
    ["api", "v1", "alerts", "active"] -> "/api/v1/alerts/active"
    ["api", "v1", "alerts", "detail"] -> "/api/v1/alerts/detail"
    ["api", "v1", "alerts", "stream"] -> "/api/v1/alerts/stream"
    ["api", "v1", "alerts", "search"] -> "/api/v1/alerts/search"
    ["api", "v1", "alerts", "history"] -> "/api/v1/alerts/history"
    ["api", "v1", "cap", "feeds"] -> "/api/v1/cap/feeds"
    ["api", "v1", "earthquakes", "recent"] -> "/api/v1/earthquakes/recent"
    ["api", "v1", "earthquakes", "stream"] -> "/api/v1/earthquakes/stream"
    ["api", "v1", "pipeline", "status"] -> "/api/v1/pipeline/status"
    ["api", "v1", "sources"] -> "/api/v1/sources"
    ["api", "v1", "hazards", "recent"] -> "/api/v1/hazards/recent"
    ["api", "v1", "hazards", "stream"] -> "/api/v1/hazards/stream"
    ["api", "v1", "hazards", _source, _id] -> "/api/v1/hazards/:source/:id"
    ["api", "v1", "timeline"] -> "/api/v1/timeline"
    ["api", "v1", "stream"] -> "/api/v1/stream"
    _ -> "unmatched"
  }
}

pub fn is_stream_route(route: String) -> Bool {
  case route {
    "/api/v1/alerts/stream"
    | "/api/v1/earthquakes/stream"
    | "/api/v1/hazards/stream"
    | "/api/v1/stream" -> True
    _ -> False
  }
}

pub fn calculate_lag(now_seconds: Float, upstream_seconds: Float) -> Float {
  let lag = now_seconds -. upstream_seconds
  case lag <. 0.0 {
    True -> 0.0
    False -> lag
  }
}

pub fn now_seconds() -> Float {
  let #(sec, nsec) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  int.to_float(sec) +. int.to_float(nsec) /. 1_000_000_000.0
}

pub fn timestamp_to_seconds(ts: timestamp.Timestamp) -> Float {
  let #(sec, nsec) = timestamp.to_unix_seconds_and_nanoseconds(ts)
  int.to_float(sec) +. int.to_float(nsec) /. 1_000_000_000.0
}

pub fn ms_to_seconds(ms: Int) -> Float {
  int.to_float(ms) /. 1000.0
}

pub fn observe_http(
  listener: Listener,
  route: String,
  method: String,
  code: Int,
  seconds: Float,
) -> Nil {
  let listener_str = listener_to_string(listener)
  let code_str = int.to_string(code)
  ffi_counter_inc("matrixwhale_http_requests_total", [
    listener_str,
    route,
    method,
    code_str,
  ])
  case is_stream_route(route) {
    True -> Nil
    False ->
      ffi_histogram_observe(
        "matrixwhale_http_request_duration_seconds",
        [listener_str, route],
        seconds,
      )
  }
}

pub fn record_intake(source: String, outcome: pipeline.Outcome(a)) -> Nil {
  record_intake_count(source, IntakeNew, outcome.new)
  record_intake_count(source, IntakeUpdated, outcome.updated)
  record_intake_count(source, IntakeUnchanged, outcome.unchanged)
  record_intake_count(source, IntakeStale, outcome.stale)
  record_intake_count(source, IntakeRepeat, outcome.repeats)
}

pub fn record_intake_count(
  source: String,
  outcome: IntakeOutcome,
  count: Int,
) -> Nil {
  case count > 0 {
    True ->
      ffi_counter_inc_by(
        "matrixwhale_intake_records_total",
        [source, intake_outcome_to_string(outcome)],
        count,
      )
    False -> Nil
  }
}

pub fn observe_ingest_lag(
  source: String,
  basis: LagBasis,
  seconds: Float,
) -> Nil {
  ffi_histogram_observe(
    "matrixwhale_ingest_lag_seconds",
    [source, lag_basis_to_string(basis)],
    seconds,
  )
}

pub fn time_db(op: DbOp, f: fn() -> a) -> a {
  let start = monotonic_now()
  let res = f()
  let elapsed = monotonic_elapsed_seconds(start)
  observe_db(op, elapsed)
  res
}

fn observe_db(op: DbOp, seconds: Float) -> Nil {
  ffi_histogram_observe(
    "matrixwhale_db_duration_seconds",
    [db_op_to_string(op)],
    seconds,
  )
}

pub fn set_sse_clients(stream: Stream, n: Int) -> Nil {
  ffi_gauge_set("matrixwhale_sse_clients", [stream_to_string(stream)], n)
}

pub fn observe_sse_publish_delay(stream: Stream, seconds: Float) -> Nil {
  ffi_histogram_observe(
    "matrixwhale_sse_publish_delay_seconds",
    [stream_to_string(stream)],
    seconds,
  )
}
