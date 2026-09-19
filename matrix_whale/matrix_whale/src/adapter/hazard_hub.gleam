import domain/hazard.{type Hazard}
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/time/calendar
import gleam/time/timestamp
import metrics
import repeatedly

const heartbeat_ms = 25_000

pub type SSEMessage {
  Emit(event: String, id: String, data: String)
  Heartbeat(id: String)
  Resync(id: String)
}

pub type HazardHubMsg {
  Subscribe(
    subject: Subject(SSEMessage),
    since: Option(String),
    reply: Subject(Int),
  )
  Unsubscribe(id: Int)
  Publish(new: List(Hazard), updated: List(Hazard), published_at: Int)
  Tick
}

type State {
  State(
    subscribers: Dict(Int, Subject(SSEMessage)),
    next_subscriber: Int,
    next_event: Int,
    epoch: String,
  )
}

pub fn start() -> actor.StartResult(Subject(HazardHubMsg)) {
  actor.new_with_initialiser(1000, fn(subject) {
    let _ =
      repeatedly.call(heartbeat_ms, Nil, fn(_, _) {
        process.send(subject, Tick)
      })
    actor.initialised(State(
      dict.new(),
      1,
      1,
      timestamp.system_time() |> timestamp.to_rfc3339(calendar.utc_offset),
    ))
    |> actor.returning(subject)
    |> Ok
  })
  |> actor.on_message(handle)
  |> actor.start
}

pub fn subscribe(
  h: Subject(HazardHubMsg),
  s: Subject(SSEMessage),
  since: Option(String),
) -> Int {
  process.call(h, 5000, fn(reply) { Subscribe(s, since, reply) })
}

pub fn unsubscribe(h: Subject(HazardHubMsg), id: Int) -> Nil {
  process.send(h, Unsubscribe(id))
}

pub fn publish(
  h: Subject(HazardHubMsg),
  new: List(Hazard),
  updated: List(Hazard),
) -> Nil {
  let published_at = metrics.monotonic_now()
  process.send(h, Publish(new, updated, published_at))
}

fn handle(state: State, msg: HazardHubMsg) -> actor.Next(State, HazardHubMsg) {
  case msg {
    Subscribe(subject, since, reply) -> {
      let id = state.next_subscriber
      // IDs include a process epoch. No event survives restart, therefore a
      // reconnect is explicitly told to refetch rather than silently miss it.
      case since {
        Some(_) -> process.send(subject, Resync(last_id(state)))
        None -> Nil
      }
      process.send(subject, Heartbeat(last_id(state)))
      process.send(reply, id)
      let subscribers = dict.insert(state.subscribers, id, subject)
      metrics.set_sse_clients(metrics.Hazards, dict.size(subscribers))
      actor.continue(
        State(..state, subscribers: subscribers, next_subscriber: id + 1),
      )
    }
    Unsubscribe(id) -> {
      let subscribers = dict.delete(state.subscribers, id)
      metrics.set_sse_clients(metrics.Hazards, dict.size(subscribers))
      actor.continue(State(..state, subscribers: subscribers))
    }
    Publish(new, updated, published_at) -> {
      let #(state, first_events) = events_for(state, new, "new")
      let #(state, second_events) = events_for(state, updated, "update")
      let events = list.append(first_events, second_events)
      case events {
        [] -> Nil
        _ -> {
          dict.values(state.subscribers)
          |> list.each(fn(subject) {
            list.each(events, fn(event) { process.send(subject, event) })
          })
          let delay = metrics.monotonic_elapsed_seconds(published_at)
          metrics.observe_sse_publish_delay(metrics.Hazards, delay)
        }
      }
      actor.continue(state)
    }
    Tick -> {
      let id = last_id(state)
      dict.values(state.subscribers)
      |> list.each(fn(subject) { process.send(subject, Heartbeat(id)) })
      actor.continue(state)
    }
  }
}

fn events_for(
  state: State,
  rows: List(Hazard),
  event_name: String,
) -> #(State, List(SSEMessage)) {
  list.fold(rows, #(state, []), fn(acc, row) {
    let id = acc.0.epoch <> ":" <> int.to_string(acc.0.next_event)
    let data = json.to_string(hazard.to_json(row))
    #(
      State(..acc.0, next_event: acc.0.next_event + 1),
      list.append(acc.1, [Emit(event_name, id, data)]),
    )
  })
}

fn last_id(state: State) -> String {
  state.epoch <> ":" <> int.to_string(state.next_event - 1)
}
