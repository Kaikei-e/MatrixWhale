import adapter/alert_hub
import adapter/context
import adapter/earthquake_hub
import adapter/streamer
import domain/earthquake
import domain/event
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/json
import gleam/option
import gleam/string
import gleam/time/timestamp
import gleeunit/should
import intake/seen_set
import message/reciever/usgs_reciever
import pog
import repository/earthquake_reader
import wisp/simulate

pub fn snapshot_filters_reject_invalid_values_test() {
  streamer.parse_minmag("all")
  |> should.equal(Ok(earthquake_reader.AllMagnitudes))
  streamer.parse_minmag("2.5")
  |> should.equal(Ok(earthquake_reader.Minimum(2.5)))
  case streamer.parse_minmag("many") {
    Error(_) -> True |> should.equal(True)
    Ok(_) -> False |> should.equal(True)
  }
  case streamer.parse_type("volcano") {
    Error(_) -> True |> should.equal(True)
    Ok(_) -> False |> should.equal(True)
  }
}

pub fn etag_revalidation_accepts_list_and_weak_validators_test() {
  streamer.if_none_match_matches("\"old\", W/\"current\"", "\"current\"")
  |> should.equal(True)
  streamer.if_none_match_matches("*", "\"current\"") |> should.equal(True)
  streamer.if_none_match_matches("\"old\"", "\"current\"")
  |> should.equal(False)
}

pub fn etag_response_returns_200_then_304_test() {
  let body = json.object([#("id", json.string("event"))])
  let first = streamer.etag_json_response(request.new(), body)
  first.status |> should.equal(200)
  let assert Ok(etag) = response.get_header(first, "etag")
  let second =
    streamer.etag_json_response(
      request.new() |> request.set_header("if-none-match", etag),
      body,
    )
  second.status |> should.equal(304)
  response.get_header(second, "cache-control") |> should.equal(Ok("no-cache"))
}

pub fn invalid_snapshot_params_return_400_before_db_access_test() {
  let ctx = test_context()
  let response =
    streamer.earthquakes_response(
      request.new() |> request.set_query([#("hours", "not-a-number")]),
      ctx,
    )
  response.status |> should.equal(400)
  let response =
    streamer.earthquakes_response(
      request.new() |> request.set_query([#("type", "not-a-source")]),
      ctx,
    )
  response.status |> should.equal(400)
}

pub fn usgs_endpoints_reject_wrong_methods_test() {
  streamer.earthquakes_response(
    request.new() |> request.set_method(http.Post),
    test_context(),
  ).status
  |> should.equal(405)
  let req = simulate.request(http.Get, "/api/v1/usgs_data/send")
  usgs_reciever.usgs_data_handler(req, test_context()).status
  |> should.equal(405)
}

pub fn malformed_ingest_envelope_returns_400_test() {
  let req =
    simulate.request(http.Post, "/api/v1/usgs_data/send")
    |> simulate.string_body("{\"features\":{}}")
    |> request.set_header("content-type", "application/json")
  usgs_reciever.usgs_data_handler(req, test_context()).status
  |> should.equal(400)
}

pub fn reconnect_receives_resync_and_heartbeat_test() {
  let assert Ok(hub) = earthquake_hub.start()
  let subject = process.new_subject()
  let _ =
    earthquake_hub.subscribe(hub.data, subject, option.Some("old-process:9"))
  let assert Ok(earthquake_hub.Resync(_)) =
    process.receive(subject, within: 500)
  let assert Ok(earthquake_hub.Heartbeat(_)) =
    process.receive(subject, within: 500)
}

pub fn sse_event_is_flat_and_marks_backfill_test() {
  let assert Ok(hub) = earthquake_hub.start()
  let subject = process.new_subject()
  let _ = earthquake_hub.subscribe(hub.data, subject, option.None)
  let assert Ok(earthquake_hub.Heartbeat(_)) =
    process.receive(subject, within: 500)
  earthquake_hub.publish(hub.data, [sample_row()], [], True)
  let assert Ok(earthquake_hub.Emit("new", _, data)) =
    process.receive(subject, within: 500)
  string.contains(data, "\"is_backfill\":true") |> should.equal(True)
  string.contains(data, "\"event\":") |> should.equal(False)
  string.contains(data, "\"members\":") |> should.equal(True)
}

fn sample_earthquake() -> earthquake.Earthquake {
  let time = timestamp.from_unix_seconds(0)
  earthquake.Earthquake(
    source: "usgs",
    source_id: "sample",
    contributing_ids: ["sample"],
    sources: ["us"],
    net: option.None,
    code: option.None,
    magnitude: option.Some(4.0),
    magnitude_type: option.None,
    occurred_at: time,
    occurred_at_ms: 0,
    updated_at: time,
    updated_at_ms: 1,
    place: option.None,
    title: option.None,
    status: option.None,
    event_type: option.Some("earthquake"),
    tsunami: option.None,
    significance: option.None,
    alert: option.None,
    mmi: option.None,
    cdi: option.None,
    felt: option.None,
    nst: option.None,
    dmin: option.None,
    rms: option.None,
    gap: option.None,
    url: option.None,
    detail: option.None,
    longitude: 1.0,
    latitude: 2.0,
    depth_km: option.None,
    first_seen_at: time,
    last_seen_at: time,
  )
}

fn sample_row() -> event.EventView {
  let eq = sample_earthquake()
  let ev =
    event.Event(
      id: 1,
      kind: "earthquake",
      preferred_source: eq.source,
      preferred_source_id: eq.source_id,
      magnitude: eq.magnitude,
      magnitude_type: eq.magnitude_type,
      occurred_at: eq.occurred_at,
      occurred_at_ms: eq.occurred_at_ms,
      updated_at: eq.updated_at,
      updated_at_ms: eq.updated_at_ms,
      place: eq.place,
      title: eq.title,
      status: eq.status,
      event_type: eq.event_type,
      longitude: eq.longitude,
      latitude: eq.latitude,
      depth_km: eq.depth_km,
      first_seen_at: eq.first_seen_at,
      last_seen_at: eq.last_seen_at,
    )
  let member =
    event.MemberView(
      source: eq.source,
      source_id: eq.source_id,
      magnitude: eq.magnitude,
      magnitude_type: eq.magnitude_type,
      occurred_at_ms: eq.occurred_at_ms,
      updated_at_ms: eq.updated_at_ms,
      latitude: eq.latitude,
      longitude: eq.longitude,
      depth_km: eq.depth_km,
      place: eq.place,
      status: eq.status,
      url: eq.url,
      matched_by: "origin",
      misfit: option.None,
    )
  event.EventView(event: ev, preferred: eq, members: [member], sources: [
    eq.source,
  ])
}

fn test_context() -> context.Context {
  let assert Ok(alert) = alert_hub.start()
  let assert Ok(earthquake) = earthquake_hub.start()
  context.Context(
    secret: "test",
    db: pog.named_connection(process.new_name("unused_snapshot_db")),
    hub: alert.data,
    earthquake_hub: earthquake.data,
    seen: seen_set.new("streamer_earthquake_test_seen", 3_600_000),
  )
}
