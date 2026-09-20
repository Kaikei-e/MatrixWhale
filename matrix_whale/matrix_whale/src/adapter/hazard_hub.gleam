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
  SubscribeCompact(
    subject: Subject(SSEMessage),
    since: Option(String),
    reply: Subject(Int),
  )
  Unsubscribe(id: Int)
  Publish(new: List(Hazard), updated: List(Hazard), published_at: Int)
  Tick
}

type Format {
  Standard
  Compact
}

type State {
  State(
    standard_subscribers: Dict(Int, Subject(SSEMessage)),
    compact_subscribers: Dict(Int, Subject(SSEMessage)),
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
      standard_subscribers: dict.new(),
      compact_subscribers: dict.new(),
      next_subscriber: 1,
      next_event: 1,
      epoch: timestamp.system_time()
        |> timestamp.to_rfc3339(calendar.utc_offset),
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

pub fn subscribe_compact(
  h: Subject(HazardHubMsg),
  s: Subject(SSEMessage),
  since: Option(String),
) -> Int {
  process.call(h, 5000, fn(reply) { SubscribeCompact(s, since, reply) })
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
    Subscribe(subject, since, reply) ->
      handle_subscribe(state, subject, since, reply, Standard)
    SubscribeCompact(subject, since, reply) ->
      handle_subscribe(state, subject, since, reply, Compact)
    Unsubscribe(id) -> {
      let standard = dict.delete(state.standard_subscribers, id)
      let compact = dict.delete(state.compact_subscribers, id)
      let total = dict.size(standard) + dict.size(compact)
      metrics.set_sse_clients(metrics.Hazards, total)
      actor.continue(
        State(
          ..state,
          standard_subscribers: standard,
          compact_subscribers: compact,
        ),
      )
    }
    Publish(new, updated, published_at) -> {
      let total_rows = list.length(new) + list.length(updated)
      case total_rows == 0 {
        True -> actor.continue(state)
        False -> {
          let has_standard = !dict.is_empty(state.standard_subscribers)
          let has_compact = !dict.is_empty(state.compact_subscribers)

          case has_standard {
            True -> {
              let events =
                build_events(
                  state.epoch,
                  state.next_event,
                  new,
                  updated,
                  hazard.to_json,
                )
              dict.values(state.standard_subscribers)
              |> list.each(fn(subject) {
                list.each(events, fn(event) { process.send(subject, event) })
              })
            }
            False -> Nil
          }

          case has_compact {
            True -> {
              let events =
                build_events(
                  state.epoch,
                  state.next_event,
                  new,
                  updated,
                  hazard.to_polyline_json,
                )
              dict.values(state.compact_subscribers)
              |> list.each(fn(subject) {
                list.each(events, fn(event) { process.send(subject, event) })
              })
            }
            False -> Nil
          }

          let delay = metrics.monotonic_elapsed_seconds(published_at)
          metrics.observe_sse_publish_delay(metrics.Hazards, delay)
          actor.continue(
            State(..state, next_event: state.next_event + total_rows),
          )
        }
      }
    }
    Tick -> {
      let id = last_id(state)
      dict.values(state.standard_subscribers)
      |> list.each(fn(subject) { process.send(subject, Heartbeat(id)) })
      dict.values(state.compact_subscribers)
      |> list.each(fn(subject) { process.send(subject, Heartbeat(id)) })
      actor.continue(state)
    }
  }
}

fn handle_subscribe(
  state: State,
  subject: Subject(SSEMessage),
  since: Option(String),
  reply: Subject(Int),
  format: Format,
) -> actor.Next(State, HazardHubMsg) {
  let id = state.next_subscriber
  // IDs include a process epoch. No event survives restart, therefore a
  // reconnect is explicitly told to refetch rather than silently miss it.
  case since {
    Some(_) -> process.send(subject, Resync(last_id(state)))
    None -> Nil
  }
  process.send(subject, Heartbeat(last_id(state)))
  process.send(reply, id)
  let state = case format {
    Standard ->
      State(
        ..state,
        standard_subscribers: dict.insert(
          state.standard_subscribers,
          id,
          subject,
        ),
        next_subscriber: id + 1,
      )
    Compact ->
      State(
        ..state,
        compact_subscribers: dict.insert(state.compact_subscribers, id, subject),
        next_subscriber: id + 1,
      )
  }
  let total =
    dict.size(state.standard_subscribers) + dict.size(state.compact_subscribers)
  metrics.set_sse_clients(metrics.Hazards, total)
  actor.continue(state)
}

fn build_events(
  epoch: String,
  start_event: Int,
  new: List(Hazard),
  updated: List(Hazard),
  encoder: fn(Hazard) -> json.Json,
) -> List(SSEMessage) {
  let #(next_id, rev_first) =
    list.fold(new, #(start_event, []), fn(acc, row) {
      let id = epoch <> ":" <> int.to_string(acc.0)
      let data = json.to_string(encoder(row))
      #(acc.0 + 1, [Emit("new", id, data), ..acc.1])
    })
  let #(_, rev_second) =
    list.fold(updated, #(next_id, rev_first), fn(acc, row) {
      let id = epoch <> ":" <> int.to_string(acc.0)
      let data = json.to_string(encoder(row))
      #(acc.0 + 1, [Emit("update", id, data), ..acc.1])
    })
  list.reverse(rev_second)
}

fn last_id(state: State) -> String {
  state.epoch <> ":" <> int.to_string(state.next_event - 1)
}
