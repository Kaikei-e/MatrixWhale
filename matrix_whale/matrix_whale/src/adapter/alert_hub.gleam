import domain/alert.{type AlertRow}
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/json
import gleam/list
import gleam/option.{type Option}
import gleam/otp/actor
import gleam/time/calendar
import gleam/time/timestamp
import message/reciever/models/noaa.{type PollMeta}
import repeatedly
import repository/alert_writer.{type AlertDiff}

const ring_capacity = 500

const heartbeat_interval_ms = 25_000

const call_timeout_ms = 5000

/// Message sent to each SSE connection's own per-connection actor.
pub type SSEMessage {
  Emit(event: String, id: Int, data: String)
  Heartbeat(last_id: Int)
}

pub type PipelineStats {
  PipelineStats(
    last_fetch_at: Option(String),
    last_http_status: Option(Int),
    last_received: Int,
    last_decoded: Int,
    last_dropped: Int,
    last_write_at: Option(String),
    last_new: Int,
    last_updated: Int,
    last_ended: Int,
    sse_clients: Int,
  )
}

pub type HubMsg {
  Subscribe(
    subject: Subject(SSEMessage),
    since_id: Option(Int),
    reply_to: Subject(Int),
  )
  Unsubscribe(id: Int)
  Publish(diff: AlertDiff)
  RecordPoll(meta: PollMeta)
  RecordDecoded(decoded: Int, dropped: Int)
  RecordWrite(new: Int, updated: Int, ended: Int)
  GetStats(reply_to: Subject(PipelineStats))
  Tick
}

type RingEntry {
  RingEntry(id: Int, event: String, data: String)
}

type State {
  State(
    subscribers: Dict(Int, Subject(SSEMessage)),
    next_subscriber_id: Int,
    next_event_id: Int,
    ring: List(RingEntry),
    stats: PipelineStats,
  )
}

/// Starts the hub actor. It owns SSE subscriber registration, the alert
/// event ring buffer, and the pipeline stats surfaced at
/// `/api/v1/pipeline/status`.
pub fn start() -> actor.StartResult(Subject(HubMsg)) {
  actor.new_with_initialiser(1000, fn(subject) {
    let _ =
      repeatedly.call(heartbeat_interval_ms, Nil, fn(_state, _count) {
        process.send(subject, Tick)
      })
    actor.initialised(initial_state())
    |> actor.returning(subject)
    |> Ok
  })
  |> actor.on_message(handle_message)
  |> actor.start
}

pub fn subscribe(
  hub: Subject(HubMsg),
  subject: Subject(SSEMessage),
  since_id: Option(Int),
) -> Int {
  process.call(hub, call_timeout_ms, fn(reply_to) {
    Subscribe(subject, since_id, reply_to)
  })
}

pub fn unsubscribe(hub: Subject(HubMsg), id: Int) -> Nil {
  process.send(hub, Unsubscribe(id))
}

pub fn publish(hub: Subject(HubMsg), diff: AlertDiff) -> Nil {
  process.send(hub, Publish(diff))
}

pub fn record_poll(hub: Subject(HubMsg), meta: PollMeta) -> Nil {
  process.send(hub, RecordPoll(meta))
}

pub fn record_decoded(hub: Subject(HubMsg), decoded: Int, dropped: Int) -> Nil {
  process.send(hub, RecordDecoded(decoded, dropped))
}

pub fn record_write(
  hub: Subject(HubMsg),
  new: Int,
  updated: Int,
  ended: Int,
) -> Nil {
  process.send(hub, RecordWrite(new, updated, ended))
}

pub fn get_stats(hub: Subject(HubMsg)) -> PipelineStats {
  process.call(hub, call_timeout_ms, GetStats)
}

fn initial_state() -> State {
  State(
    subscribers: dict.new(),
    next_subscriber_id: 1,
    next_event_id: 1,
    ring: [],
    stats: PipelineStats(
      last_fetch_at: option.None,
      last_http_status: option.None,
      last_received: 0,
      last_decoded: 0,
      last_dropped: 0,
      last_write_at: option.None,
      last_new: 0,
      last_updated: 0,
      last_ended: 0,
      sse_clients: 0,
    ),
  )
}

fn handle_message(state: State, message: HubMsg) -> actor.Next(State, HubMsg) {
  case message {
    Subscribe(subject, since_id, reply_to) -> {
      let id = state.next_subscriber_id
      let subscribers = dict.insert(state.subscribers, id, subject)

      // Only a reconnecting client (Last-Event-ID) gets a replay; a fresh
      // client has just fetched the snapshot and must not re-see old events.
      case since_id {
        option.Some(since) ->
          state.ring
          |> list.reverse
          |> list.filter(fn(entry) { entry.id > since })
          |> list.each(fn(entry) {
            process.send(subject, Emit(entry.event, entry.id, entry.data))
          })
        option.None -> Nil
      }
      process.send(subject, Heartbeat(state.next_event_id - 1))
      process.send(reply_to, id)

      actor.continue(
        State(
          ..state,
          subscribers: subscribers,
          next_subscriber_id: id + 1,
          stats: PipelineStats(
            ..state.stats,
            sse_clients: dict.size(subscribers),
          ),
        ),
      )
    }

    Unsubscribe(id) -> {
      let subscribers = dict.delete(state.subscribers, id)
      actor.continue(
        State(
          ..state,
          subscribers: subscribers,
          stats: PipelineStats(
            ..state.stats,
            sse_clients: dict.size(subscribers),
          ),
        ),
      )
    }

    Publish(diff) -> {
      let #(new_state, entries) = append_diff(state, diff)
      dict.values(new_state.subscribers)
      |> list.each(fn(subject) {
        list.each(entries, fn(entry) {
          process.send(subject, Emit(entry.event, entry.id, entry.data))
        })
      })
      actor.continue(new_state)
    }

    RecordPoll(meta) -> {
      actor.continue(
        State(
          ..state,
          stats: PipelineStats(
            ..state.stats,
            last_fetch_at: option.Some(now_rfc3339()),
            last_http_status: option.Some(meta.http_status),
          ),
        ),
      )
    }

    RecordDecoded(decoded, dropped) -> {
      actor.continue(
        State(
          ..state,
          stats: PipelineStats(
            ..state.stats,
            last_received: decoded + dropped,
            last_decoded: decoded,
            last_dropped: dropped,
          ),
        ),
      )
    }

    RecordWrite(new, updated, ended) -> {
      actor.continue(
        State(
          ..state,
          stats: PipelineStats(
            ..state.stats,
            last_write_at: option.Some(now_rfc3339()),
            last_new: new,
            last_updated: updated,
            last_ended: ended,
          ),
        ),
      )
    }

    GetStats(reply_to) -> {
      process.send(reply_to, state.stats)
      actor.continue(state)
    }

    Tick -> {
      let last_id = state.next_event_id - 1
      dict.values(state.subscribers)
      |> list.each(fn(subject) { process.send(subject, Heartbeat(last_id)) })
      actor.continue(state)
    }
  }
}

fn append_diff(state: State, diff: AlertDiff) -> #(State, List(RingEntry)) {
  let #(state, new_entries) =
    list.fold(diff.new, #(state, []), fn(acc, row) {
      add_entry(acc, "alert.new", row)
    })
  let #(state, updated_entries) =
    list.fold(diff.updated, #(state, []), fn(acc, row) {
      add_entry(acc, "alert.update", row)
    })
  let #(state, ended_entries) =
    list.fold(diff.ended, #(state, []), fn(acc, row) {
      add_entry(acc, "alert.ended", row)
    })
  #(state, list.flatten([new_entries, updated_entries, ended_entries]))
}

fn add_entry(
  acc: #(State, List(RingEntry)),
  event: String,
  row: AlertRow,
) -> #(State, List(RingEntry)) {
  let #(state, entries) = acc
  let id = state.next_event_id
  let entry =
    RingEntry(id: id, event: event, data: json.to_string(alert.to_json(row)))
  let ring = [entry, ..state.ring] |> list.take(ring_capacity)

  #(
    State(..state, next_event_id: id + 1, ring: ring),
    list.append(entries, [
      entry,
    ]),
  )
}

fn now_rfc3339() -> String {
  timestamp.system_time() |> timestamp.to_rfc3339(calendar.utc_offset)
}
