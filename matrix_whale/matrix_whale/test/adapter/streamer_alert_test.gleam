import adapter/alert_hub
import adapter/context
import adapter/earthquake_hub
import adapter/hazard_hub
import adapter/streamer
import gleam/erlang/process
import gleam/http/request
import gleeunit/should
import intake/seen_set
import pog

pub fn alert_detail_returns_404_when_missing_id_test() {
  let ctx = test_context()
  let req = request.new()
  let resp = streamer.alert_detail_response(req, ctx)
  resp.status |> should.equal(404)
}

pub fn alert_detail_returns_404_when_id_has_no_colon_test() {
  let ctx = test_context()
  let req = request.new() |> request.set_query([#("id", "nocolon")])
  let resp = streamer.alert_detail_response(req, ctx)
  resp.status |> should.equal(404)
}

pub fn alert_active_returns_400_on_bogus_min_severity_test() {
  let ctx = test_context()
  let req = request.new() |> request.set_query([#("min_severity", "bogus")])
  let resp = streamer.active_response(req, ctx)
  resp.status |> should.equal(400)
}

fn test_context() -> context.Context {
  let assert Ok(alert) = alert_hub.start()
  let assert Ok(earthquake) = earthquake_hub.start()
  let assert Ok(hazard) = hazard_hub.start()
  context.Context(
    secret: "test",
    db: pog.named_connection(process.new_name("unused_streamer_alert_db")),
    hub: alert.data,
    earthquake_hub: earthquake.data,
    hazard_hub: hazard.data,
    seen: seen_set.new("streamer_alert_test_seen", 3_600_000),
  )
}
