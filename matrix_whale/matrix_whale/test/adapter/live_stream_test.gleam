import adapter/alert_hub
import adapter/earthquake_hub
import adapter/hazard_hub
import adapter/live_stream.{
  EventMsg, Hubs, RawEvent, alert_msg_to_raw, earthquake_msg_to_raw,
  format_alert_event, format_earthquake_event, format_hazard_event,
  hazard_msg_to_raw, reconnect_resync_events,
}
import domain/alert
import gleam/erlang/process
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/string
import gleam/time/timestamp
import gleeunit/should
import repository/alert_writer

fn sample_alert() -> alert.AlertRow {
  let now = timestamp.from_unix_seconds(1_700_000_000)
  alert.AlertRow(
    source: "noaa",
    source_id: "urn:oid:test-alert",
    source_name: "National Weather Service",
    attribution: "NOAA NWS",
    sender: Some("nws@example.com"),
    sender_name: Some("NWS"),
    identifier: Some("urn:oid:test-alert"),
    message_type: Some("Alert"),
    event: "Gale Warning",
    category: ["Met"],
    severity: "Severe",
    urgency: "Immediate",
    certainty: "Observed",
    headline: Some("Gale Warning in effect"),
    description: Some("Winds up to 45 knots"),
    instruction: Some("Take appropriate action"),
    web: Some("https://weather.gov"),
    contact: Some("helpdesk@example.com"),
    language: Some("en-US"),
    area_desc: "Coastal Waters",
    geocodes: "[]",
    countries: ["USA"],
    geom: None,
    reference_keys: [],
    sent: Some(now),
    effective: Some(now),
    onset: None,
    expires: Some(now),
    ends: None,
    active_until: now,
    first_seen_at: now,
    last_seen_at: now,
    ended_at: None,
    end_reason: None,
    superseded_by: None,
  )
}

pub fn format_alert_event_strips_prefix_test() {
  format_alert_event("alert.new") |> should.equal("alerts.new")
  format_alert_event("alert.update") |> should.equal("alerts.update")
  format_alert_event("alert.ended") |> should.equal("alerts.ended")
  format_alert_event("new") |> should.equal("alerts.new")
  format_alert_event("update") |> should.equal("alerts.update")
  format_alert_event("ended") |> should.equal("alerts.ended")
  format_alert_event("alerts.new") |> should.equal("alerts.new")
  format_alert_event("alerts.update") |> should.equal("alerts.update")
  format_alert_event("alerts.ended") |> should.equal("alerts.ended")
}

pub fn format_earthquake_event_test() {
  format_earthquake_event("new") |> should.equal("earthquakes.new")
  format_earthquake_event("update") |> should.equal("earthquakes.update")
  format_earthquake_event("earthquakes.new") |> should.equal("earthquakes.new")
  format_earthquake_event("earthquakes.update")
  |> should.equal("earthquakes.update")
}

pub fn format_hazard_event_test() {
  format_hazard_event("new") |> should.equal("hazards.new")
  format_hazard_event("update") |> should.equal("hazards.update")
  format_hazard_event("hazards.new") |> should.equal("hazards.new")
  format_hazard_event("hazards.update") |> should.equal("hazards.update")
}

pub fn alert_msg_to_raw_test() {
  alert_msg_to_raw(alert_hub.Emit("alert.new", 101, "{\"id\":101}"))
  |> should.equal(RawEvent("alerts.new", "101", "{\"id\":101}"))

  alert_msg_to_raw(alert_hub.Emit("alert.update", 102, "{\"id\":102}"))
  |> should.equal(RawEvent("alerts.update", "102", "{\"id\":102}"))

  alert_msg_to_raw(alert_hub.Emit("alert.ended", 103, "{\"id\":103}"))
  |> should.equal(RawEvent("alerts.ended", "103", "{\"id\":103}"))

  alert_msg_to_raw(alert_hub.Heartbeat(200))
  |> should.equal(RawEvent("alerts.heartbeat", "200", "{}"))

  alert_msg_to_raw(alert_hub.Resync(200))
  |> should.equal(RawEvent("alerts.resync", "200", "{\"reason\":\"event_gap\"}"))
}

pub fn earthquake_msg_to_raw_test() {
  earthquake_msg_to_raw(earthquake_hub.Emit("new", "epoch:1", "{\"mag\":5.5}"))
  |> should.equal(RawEvent("earthquakes.new", "epoch:1", "{\"mag\":5.5}"))

  earthquake_msg_to_raw(earthquake_hub.Emit(
    "update",
    "epoch:2",
    "{\"mag\":5.6}",
  ))
  |> should.equal(RawEvent("earthquakes.update", "epoch:2", "{\"mag\":5.6}"))

  earthquake_msg_to_raw(earthquake_hub.Heartbeat("epoch:5"))
  |> should.equal(RawEvent("earthquakes.heartbeat", "epoch:5", "{}"))

  earthquake_msg_to_raw(earthquake_hub.Resync("epoch:5"))
  |> should.equal(RawEvent(
    "earthquakes.resync",
    "epoch:5",
    "{\"reason\":\"event_gap\"}",
  ))
}

pub fn hazard_msg_to_raw_test() {
  hazard_msg_to_raw(hazard_hub.Emit("new", "hepoch:1", "{\"type\":\"flood\"}"))
  |> should.equal(RawEvent("hazards.new", "hepoch:1", "{\"type\":\"flood\"}"))

  hazard_msg_to_raw(hazard_hub.Emit(
    "update",
    "hepoch:2",
    "{\"type\":\"flood\"}",
  ))
  |> should.equal(RawEvent("hazards.update", "hepoch:2", "{\"type\":\"flood\"}"))

  hazard_msg_to_raw(hazard_hub.Heartbeat("hepoch:10"))
  |> should.equal(RawEvent("hazards.heartbeat", "hepoch:10", "{}"))

  hazard_msg_to_raw(hazard_hub.Resync("hepoch:10"))
  |> should.equal(RawEvent(
    "hazards.resync",
    "hepoch:10",
    "{\"reason\":\"event_gap\"}",
  ))
}

pub fn reconnect_resync_events_test() {
  let events = reconnect_resync_events("global-cursor:42")
  events
  |> should.equal([
    RawEvent("alerts.resync", "global-cursor:42", "{\"reason\":\"event_gap\"}"),
    RawEvent(
      "earthquakes.resync",
      "global-cursor:42",
      "{\"reason\":\"event_gap\"}",
    ),
    RawEvent("hazards.resync", "global-cursor:42", "{\"reason\":\"event_gap\"}"),
  ])
}

pub fn bridge_lifecycle_with_actual_hubs_test() {
  let assert Ok(actor.Started(_, alert_h)) = alert_hub.start()
  let assert Ok(actor.Started(_, eq_h)) = earthquake_hub.start()
  let assert Ok(actor.Started(_, hz_h)) = hazard_hub.start()
  let hubs = Hubs(alert_hub: alert_h, earthquake_hub: eq_h, hazard_hub: hz_h)

  // 1. Verify that starting the bridge subscribes all 3 hubs BEFORE client ready
  let handles = live_stream.start_bridge(hubs, False)
  alert_hub.get_stats(alert_h).sse_clients |> should.equal(1)

  // 2. Attach a receiver
  let receiver = process.new_subject()
  let Nil =
    process.call(handles.control, 5000, fn(reply) {
      live_stream.Attach(receiver, process.self(), reply)
    })

  // Flush any initial messages emitted on subscribe (e.g. heartbeat)
  let _ = process.receive(receiver, 100)
  let _ = process.receive(receiver, 100)
  let _ = process.receive(receiver, 100)

  // 3. Publish an alert and verify namespacing to alerts.new (strip alert. prefix)
  let diff =
    alert_writer.AlertDiff(new: [sample_alert()], updated: [], ended: [])
  alert_hub.publish(alert_h, diff)

  let assert Ok(EventMsg(raw)) = process.receive(receiver, 1000)
  raw.name |> should.equal("alerts.new")
  raw.data |> string.contains("urn:oid:test-alert") |> should.equal(True)

  // 4. Send Tick to earthquake hub and hazard hub, verify heartbeats arrive
  process.send(eq_h, earthquake_hub.Tick)
  let assert Ok(EventMsg(eq_raw)) = process.receive(receiver, 1000)
  eq_raw.name |> should.equal("earthquakes.heartbeat")

  process.send(hz_h, hazard_hub.Tick)
  let assert Ok(EventMsg(hz_raw)) = process.receive(receiver, 1000)
  hz_raw.name |> should.equal("hazards.heartbeat")

  // 5. Disconnect and verify all 3 hubs unsubscribed and process cleaned up
  live_stream.cleanup_hubs(hubs, handles)
  process.send(handles.control, live_stream.StopBridge)
  process.sleep(50)

  alert_hub.get_stats(alert_h).sse_clients |> should.equal(0)
  process.is_alive(handles.bridge_pid) |> should.equal(False)
}

pub fn bridge_monitor_cleanup_on_actor_exit_test() {
  let assert Ok(actor.Started(_, alert_h)) = alert_hub.start()
  let assert Ok(actor.Started(_, eq_h)) = earthquake_hub.start()
  let assert Ok(actor.Started(_, hz_h)) = hazard_hub.start()
  let hubs = Hubs(alert_hub: alert_h, earthquake_hub: eq_h, hazard_hub: hz_h)

  let handles = live_stream.start_bridge(hubs, False)
  alert_hub.get_stats(alert_h).sse_clients |> should.equal(1)

  // Spawn an actor process to simulate the SSE connection actor
  let parent_ack = process.new_subject()
  let simulated_actor_pid =
    process.spawn_unlinked(fn() {
      let sub = process.new_subject()
      process.send(parent_ack, sub)
      process.sleep_forever()
    })

  let assert Ok(actor_sub) = process.receive(parent_ack, 1000)

  let Nil =
    process.call(handles.control, 5000, fn(reply) {
      live_stream.Attach(actor_sub, simulated_actor_pid, reply)
    })

  alert_hub.get_stats(alert_h).sse_clients |> should.equal(1)

  // Kill the simulated SSE actor process
  process.kill(simulated_actor_pid)
  process.sleep(50)

  // Bridge must detect Down and clean up all 3 hubs and exit
  alert_hub.get_stats(alert_h).sse_clients |> should.equal(0)
  process.is_alive(handles.bridge_pid) |> should.equal(False)
}
