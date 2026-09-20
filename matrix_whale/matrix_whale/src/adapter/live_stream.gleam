import adapter/alert_hub
import adapter/context.{type Context}
import adapter/earthquake_hub
import adapter/hazard_hub
import gleam/bytes_tree
import gleam/erlang/process.{type Pid, type Subject}
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import gleam/string_tree
import mist

pub type Hubs {
  Hubs(
    alert_hub: Subject(alert_hub.HubMsg),
    earthquake_hub: Subject(earthquake_hub.EarthquakeHubMsg),
    hazard_hub: Subject(hazard_hub.HazardHubMsg),
  )
}

pub fn hubs_from_context(ctx: Context) -> Hubs {
  Hubs(
    alert_hub: ctx.hub,
    earthquake_hub: ctx.earthquake_hub,
    hazard_hub: ctx.hazard_hub,
  )
}

pub type RawEvent {
  RawEvent(name: String, id: String, data: String)
}

pub type LiveStreamMsg {
  EventMsg(RawEvent)
  SendReconnectResync(last_id: String)
}

pub type BridgeControl {
  Attach(
    actor_subj: Subject(LiveStreamMsg),
    actor_pid: Pid,
    reply: Subject(Nil),
  )
  StopBridge
}

pub type BridgeHandles {
  BridgeHandles(
    bridge_pid: Pid,
    control: Subject(BridgeControl),
    alert_sub_id: Int,
    earthquake_sub_id: Int,
    hazard_sub_id: Int,
  )
}

type BridgeUnattachedMsg {
  UnattachedControl(BridgeControl)
  UnattachedAlert(alert_hub.SSEMessage)
  UnattachedEarthquake(earthquake_hub.SSEMessage)
  UnattachedHazard(hazard_hub.SSEMessage)
}

type BridgeAttachedMsg {
  AttachedControl(BridgeControl)
  AttachedAlert(alert_hub.SSEMessage)
  AttachedEarthquake(earthquake_hub.SSEMessage)
  AttachedHazard(hazard_hub.SSEMessage)
  AttachedActorDown(process.Down)
}

type LiveStreamState {
  LiveStreamState(hubs: Hubs, bridge: BridgeHandles, sent_retry: Bool)
}

pub fn format_alert_event(name: String) -> String {
  case name {
    "alert.new" -> "alerts.new"
    "alert.update" -> "alerts.update"
    "alert.ended" -> "alerts.ended"
    "alerts.new" -> "alerts.new"
    "alerts.update" -> "alerts.update"
    "alerts.ended" -> "alerts.ended"
    "new" -> "alerts.new"
    "update" -> "alerts.update"
    "ended" -> "alerts.ended"
    _ -> {
      case string.starts_with(name, "alert.") {
        True -> "alerts." <> string.drop_start(name, 6)
        False ->
          case string.starts_with(name, "alerts.") {
            True -> name
            False -> "alerts." <> name
          }
      }
    }
  }
}

pub fn format_earthquake_event(name: String) -> String {
  case name {
    "new" -> "earthquakes.new"
    "update" -> "earthquakes.update"
    "earthquakes.new" -> "earthquakes.new"
    "earthquakes.update" -> "earthquakes.update"
    _ -> {
      case string.starts_with(name, "earthquakes.") {
        True -> name
        False -> "earthquakes." <> name
      }
    }
  }
}

pub fn format_hazard_event(name: String) -> String {
  case name {
    "new" -> "hazards.new"
    "update" -> "hazards.update"
    "hazards.new" -> "hazards.new"
    "hazards.update" -> "hazards.update"
    _ -> {
      case string.starts_with(name, "hazards.") {
        True -> name
        False -> "hazards." <> name
      }
    }
  }
}

pub fn alert_msg_to_raw(msg: alert_hub.SSEMessage) -> RawEvent {
  case msg {
    alert_hub.Emit(event, id, data) ->
      RawEvent(format_alert_event(event), int.to_string(id), data)
    alert_hub.Heartbeat(last_id) ->
      RawEvent("alerts.heartbeat", int.to_string(last_id), "{}")
    alert_hub.Resync(last_id) ->
      RawEvent(
        "alerts.resync",
        int.to_string(last_id),
        "{\"reason\":\"event_gap\"}",
      )
  }
}

pub fn earthquake_msg_to_raw(msg: earthquake_hub.SSEMessage) -> RawEvent {
  case msg {
    earthquake_hub.Emit(event, id, data) ->
      RawEvent(format_earthquake_event(event), id, data)
    earthquake_hub.Heartbeat(id) -> RawEvent("earthquakes.heartbeat", id, "{}")
    earthquake_hub.Resync(id) ->
      RawEvent("earthquakes.resync", id, "{\"reason\":\"event_gap\"}")
  }
}

pub fn hazard_msg_to_raw(msg: hazard_hub.SSEMessage) -> RawEvent {
  case msg {
    hazard_hub.Emit(event, id, data) ->
      RawEvent(format_hazard_event(event), id, data)
    hazard_hub.Heartbeat(id) -> RawEvent("hazards.heartbeat", id, "{}")
    hazard_hub.Resync(id) ->
      RawEvent("hazards.resync", id, "{\"reason\":\"event_gap\"}")
  }
}

pub fn reconnect_resync_events(last_id: String) -> List(RawEvent) {
  [
    RawEvent("alerts.resync", last_id, "{\"reason\":\"event_gap\"}"),
    RawEvent("earthquakes.resync", last_id, "{\"reason\":\"event_gap\"}"),
    RawEvent("hazards.resync", last_id, "{\"reason\":\"event_gap\"}"),
  ]
}

pub fn raw_to_sse(raw: RawEvent, retry: Option(Int)) -> mist.SSEEvent {
  let ev =
    mist.event(string_tree.from_string(raw.data))
    |> mist.event_name(raw.name)
    |> mist.event_id(raw.id)
  case retry {
    Some(ms) -> mist.event_retry(ev, ms)
    None -> ev
  }
}

pub fn subscribe_hazard(
  h: Subject(hazard_hub.HazardHubMsg),
  s: Subject(hazard_hub.SSEMessage),
  since: Option(String),
  polyline: Bool,
) -> Int {
  case polyline {
    True -> hazard_hub.subscribe_compact(h, s, since)
    False -> hazard_hub.subscribe(h, s, since)
  }
}

pub fn start_bridge(hubs: Hubs, polyline: Bool) -> BridgeHandles {
  let ack_subj = process.new_subject()
  let _bridge_pid =
    process.spawn(fn() { bridge_worker(hubs, polyline, ack_subj) })
  let assert Ok(handles) = process.receive(ack_subj, 5000)
  handles
}

fn bridge_worker(
  hubs: Hubs,
  polyline: Bool,
  ack_subj: Subject(BridgeHandles),
) -> Nil {
  let control = process.new_subject()
  let alert_sub = process.new_subject()
  let eq_sub = process.new_subject()
  let hz_sub = process.new_subject()

  // Register subscriptions to alerts, earthquakes, and hazards BEFORE signaling ready
  let alert_sub_id = alert_hub.subscribe(hubs.alert_hub, alert_sub, None)
  let eq_sub_id = earthquake_hub.subscribe(hubs.earthquake_hub, eq_sub, None)
  let hz_sub_id = subscribe_hazard(hubs.hazard_hub, hz_sub, None, polyline)

  let handles =
    BridgeHandles(
      bridge_pid: process.self(),
      control: control,
      alert_sub_id: alert_sub_id,
      earthquake_sub_id: eq_sub_id,
      hazard_sub_id: hz_sub_id,
    )

  process.send(ack_subj, handles)

  bridge_unattached_loop(hubs, handles, alert_sub, eq_sub, hz_sub, [])
}

fn bridge_unattached_loop(
  hubs: Hubs,
  handles: BridgeHandles,
  alert_sub: Subject(alert_hub.SSEMessage),
  eq_sub: Subject(earthquake_hub.SSEMessage),
  hz_sub: Subject(hazard_hub.SSEMessage),
  buffered: List(RawEvent),
) -> Nil {
  let sel =
    process.new_selector()
    |> process.select_map(handles.control, UnattachedControl)
    |> process.select_map(alert_sub, UnattachedAlert)
    |> process.select_map(eq_sub, UnattachedEarthquake)
    |> process.select_map(hz_sub, UnattachedHazard)

  case process.selector_receive(sel, 5000) {
    Ok(UnattachedControl(Attach(actor_subj, actor_pid, reply))) -> {
      let mon = process.monitor(actor_pid)
      process.send(reply, Nil)
      list.each(list.reverse(buffered), fn(raw) {
        process.send(actor_subj, EventMsg(raw))
      })
      bridge_attached_loop(
        hubs,
        handles,
        alert_sub,
        eq_sub,
        hz_sub,
        actor_subj,
        mon,
      )
    }
    Ok(UnattachedControl(StopBridge)) -> {
      cleanup_hubs(hubs, handles)
    }
    Ok(UnattachedAlert(msg)) -> {
      bridge_unattached_loop(hubs, handles, alert_sub, eq_sub, hz_sub, [
        alert_msg_to_raw(msg),
        ..buffered
      ])
    }
    Ok(UnattachedEarthquake(msg)) -> {
      bridge_unattached_loop(hubs, handles, alert_sub, eq_sub, hz_sub, [
        earthquake_msg_to_raw(msg),
        ..buffered
      ])
    }
    Ok(UnattachedHazard(msg)) -> {
      bridge_unattached_loop(hubs, handles, alert_sub, eq_sub, hz_sub, [
        hazard_msg_to_raw(msg),
        ..buffered
      ])
    }
    Error(Nil) -> {
      cleanup_hubs(hubs, handles)
    }
  }
}

fn bridge_attached_loop(
  hubs: Hubs,
  handles: BridgeHandles,
  alert_sub: Subject(alert_hub.SSEMessage),
  eq_sub: Subject(earthquake_hub.SSEMessage),
  hz_sub: Subject(hazard_hub.SSEMessage),
  actor_subj: Subject(LiveStreamMsg),
  mon: process.Monitor,
) -> Nil {
  let sel =
    process.new_selector()
    |> process.select_map(handles.control, AttachedControl)
    |> process.select_map(alert_sub, AttachedAlert)
    |> process.select_map(eq_sub, AttachedEarthquake)
    |> process.select_map(hz_sub, AttachedHazard)
    |> process.select_specific_monitor(mon, AttachedActorDown)

  case process.selector_receive_forever(sel) {
    AttachedAlert(msg) -> {
      process.send(actor_subj, EventMsg(alert_msg_to_raw(msg)))
      bridge_attached_loop(
        hubs,
        handles,
        alert_sub,
        eq_sub,
        hz_sub,
        actor_subj,
        mon,
      )
    }
    AttachedEarthquake(msg) -> {
      process.send(actor_subj, EventMsg(earthquake_msg_to_raw(msg)))
      bridge_attached_loop(
        hubs,
        handles,
        alert_sub,
        eq_sub,
        hz_sub,
        actor_subj,
        mon,
      )
    }
    AttachedHazard(msg) -> {
      process.send(actor_subj, EventMsg(hazard_msg_to_raw(msg)))
      bridge_attached_loop(
        hubs,
        handles,
        alert_sub,
        eq_sub,
        hz_sub,
        actor_subj,
        mon,
      )
    }
    AttachedControl(StopBridge) | AttachedActorDown(_) -> {
      cleanup_hubs(hubs, handles)
      process.demonitor_process(mon)
      Nil
    }
    AttachedControl(Attach(new_subj, new_pid, reply)) -> {
      process.demonitor_process(mon)
      let new_mon = process.monitor(new_pid)
      process.send(reply, Nil)
      bridge_attached_loop(
        hubs,
        handles,
        alert_sub,
        eq_sub,
        hz_sub,
        new_subj,
        new_mon,
      )
    }
  }
}

pub fn cleanup_hubs(hubs: Hubs, handles: BridgeHandles) -> Nil {
  alert_hub.unsubscribe(hubs.alert_hub, handles.alert_sub_id)
  earthquake_hub.unsubscribe(hubs.earthquake_hub, handles.earthquake_sub_id)
  hazard_hub.unsubscribe(hubs.hazard_hub, handles.hazard_sub_id)
}

pub fn response(
  req: Request(mist.Connection),
  ctx: Context,
) -> Response(mist.ResponseData) {
  case req.method {
    http.Get -> stream_response(req, ctx)
    _ ->
      response.new(405)
      |> response.set_body(mist.Bytes(bytes_tree.new()))
  }
}

fn stream_response(
  req: Request(mist.Connection),
  ctx: Context,
) -> Response(mist.ResponseData) {
  let hubs = hubs_from_context(ctx)
  let query = request.get_query(req) |> result.unwrap([])
  let polyline = list.key_find(query, "geometry") == Ok("polyline")
  let reconnect_header = request.get_header(req, "last-event-id")

  // Subscribe to all 3 hubs BEFORE signaling ready to client
  let bridge = start_bridge(hubs, polyline)

  let response =
    mist.server_sent_events(
      req,
      response.new(200)
        |> response.set_header("x-accel-buffering", "no"),
      init: fn(actor_subj) {
        let _ =
          process.call(bridge.control, 5000, fn(reply) {
            Attach(actor_subj, process.self(), reply)
          })

        case reconnect_header {
          Ok(last_id) -> process.send(actor_subj, SendReconnectResync(last_id))
          Error(_) -> Nil
        }

        LiveStreamState(hubs: hubs, bridge: bridge, sent_retry: False)
      },
      loop: fn(state, msg, conn) { handle_sse_message(state, msg, conn) },
    )
  // A failed header write never calls init. Ongoing hub events must not keep
  // an unattached bridge subscribed by continually renewing its idle timeout.
  case response.body {
    mist.ServerSentEvents -> Nil
    _ -> process.send(bridge.control, StopBridge)
  }
  response
}

fn handle_sse_message(
  state: LiveStreamState,
  msg: LiveStreamMsg,
  conn: mist.SSEConnection,
) -> actor.Next(LiveStreamState, LiveStreamMsg) {
  case msg {
    SendReconnectResync(last_id) -> {
      let resyncs = reconnect_resync_events(last_id)
      let send_result =
        list.try_fold(resyncs, state.sent_retry, fn(sent_retry, raw) {
          let retry = case sent_retry {
            False -> Some(3000)
            True -> None
          }
          let ev = raw_to_sse(raw, retry)
          case mist.send_event(conn, ev) {
            Ok(Nil) -> Ok(True)
            Error(_) -> Error(Nil)
          }
        })

      case send_result {
        Ok(sent_retry) ->
          actor.continue(LiveStreamState(..state, sent_retry: sent_retry))
        Error(Nil) -> {
          cleanup_and_stop(state)
        }
      }
    }

    EventMsg(raw) -> {
      let retry = case state.sent_retry {
        False -> Some(3000)
        True -> None
      }
      let ev = raw_to_sse(raw, retry)
      case mist.send_event(conn, ev) {
        Ok(Nil) -> actor.continue(LiveStreamState(..state, sent_retry: True))
        Error(_) -> {
          cleanup_and_stop(state)
        }
      }
    }
  }
}

fn cleanup_and_stop(
  state: LiveStreamState,
) -> actor.Next(LiveStreamState, LiveStreamMsg) {
  process.send(state.bridge.control, StopBridge)
  cleanup_hubs(state.hubs, state.bridge)
  actor.stop()
}
