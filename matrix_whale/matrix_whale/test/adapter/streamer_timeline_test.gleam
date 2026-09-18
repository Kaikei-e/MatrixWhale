import adapter/alert_hub
import adapter/context
import adapter/earthquake_hub
import adapter/hazard_hub
import adapter/streamer
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleeunit/should
import intake/seen_set
import pog

pub fn timeline_rejects_non_get_methods_test() {
  streamer.timeline_response(
    request.new() |> request.set_method(http.Post),
    test_context(),
  ).status
  |> should.equal(405)
}

pub fn timeline_returns_400_on_bad_limit_test() {
  streamer.timeline_response(
    request.new() |> request.set_query([#("limit", "0")]),
    test_context(),
  ).status
  |> should.equal(400)
  streamer.timeline_response(
    request.new() |> request.set_query([#("limit", "201")]),
    test_context(),
  ).status
  |> should.equal(400)
}

pub fn timeline_returns_400_on_bad_kinds_test() {
  streamer.timeline_response(
    request.new() |> request.set_query([#("kinds", "")]),
    test_context(),
  ).status
  |> should.equal(400)
  streamer.timeline_response(
    request.new() |> request.set_query([#("kinds", "foo")]),
    test_context(),
  ).status
  |> should.equal(400)
}

pub fn timeline_returns_400_on_bad_min_severity_test() {
  streamer.timeline_response(
    request.new() |> request.set_query([#("min_severity", "huge")]),
    test_context(),
  ).status
  |> should.equal(400)
}

pub fn timeline_returns_400_on_malformed_cursor_test() {
  streamer.timeline_response(
    request.new() |> request.set_query([#("before", "@@@")]),
    test_context(),
  ).status
  |> should.equal(400)
}

fn test_context() -> context.Context {
  let assert Ok(alert) = alert_hub.start()
  let assert Ok(earthquake) = earthquake_hub.start()
  let assert Ok(hazard) = hazard_hub.start()
  context.Context(
    secret: "test",
    db: pog.named_connection(process.new_name("unused_timeline_db")),
    hub: alert.data,
    earthquake_hub: earthquake.data,
    hazard_hub: hazard.data,
    seen: seen_set.new("streamer_timeline_test_seen", 3_600_000),
  )
}
