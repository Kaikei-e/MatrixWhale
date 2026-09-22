import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/time/timestamp

const ttl_seconds = 60

const max_entries = 8

const call_timeout = 500

pub type CacheEntry {
  CacheEntry(etag: String, body: String, gzip: BitArray)
}

pub type CacheMsg {
  Get(key: String, reply_to: Subject(#(Option(CacheEntry), Int)))
  Put(key: String, generation: Int, entry: CacheEntry)
  Invalidate
}

type State {
  State(generation: Int, entries: Dict(String, #(CacheEntry, Int, Int)))
}

pub fn start() -> actor.StartResult(Subject(CacheMsg)) {
  actor.new_with_initialiser(500, fn(subject) {
    actor.initialised(State(generation: 0, entries: dict.new()))
    |> actor.returning(subject)
    |> Ok
  })
  |> actor.on_message(handle)
  |> actor.start
}

pub fn get(
  cache: Subject(CacheMsg),
  key: String,
) -> #(Option(CacheEntry), Int) {
  let reply_to = process.new_subject()
  process.send(cache, Get(key, reply_to))
  case process.receive(reply_to, call_timeout) {
    Ok(reply) -> reply
    Error(_) -> #(None, -1)
  }
}

pub fn put(
  cache: Subject(CacheMsg),
  key: String,
  generation: Int,
  entry: CacheEntry,
) -> Nil {
  process.send(cache, Put(key, generation, entry))
}

pub fn invalidate(cache: Subject(CacheMsg)) -> Nil {
  process.send(cache, Invalidate)
}

fn handle(state: State, message: CacheMsg) -> actor.Next(State, CacheMsg) {
  case message {
    Get(key, reply_to) -> {
      let now = now_seconds()
      let result = case dict.get(state.entries, key) {
        Ok(#(entry, gen, stored_at)) ->
          case gen == state.generation && now - stored_at < ttl_seconds {
            True -> Some(entry)
            False -> None
          }
        Error(Nil) -> None
      }
      process.send(reply_to, #(result, state.generation))
      actor.continue(state)
    }

    Put(key, generation, entry) -> {
      case generation == state.generation {
        False -> actor.continue(state)
        True -> {
          let stored = #(entry, generation, now_seconds())
          let entries = case
            !dict.has_key(state.entries, key)
            && dict.size(state.entries) >= max_entries
          {
            True -> evict_oldest(state.entries)
            False -> state.entries
          }
          let entries = dict.insert(entries, key, stored)
          actor.continue(State(..state, entries:))
        }
      }
    }

    Invalidate -> {
      actor.continue(State(
        generation: state.generation + 1,
        entries: dict.new(),
      ))
    }
  }
}

fn now_seconds() -> Int {
  let #(s, _) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  s
}

fn evict_oldest(
  entries: Dict(String, #(CacheEntry, Int, Int)),
) -> Dict(String, #(CacheEntry, Int, Int)) {
  let oldest =
    dict.fold(entries, None, fn(acc, key, value) {
      let #(_, _, stored_at) = value
      case acc {
        None -> Some(#(key, stored_at))
        Some(#(_, min_at)) ->
          case stored_at < min_at {
            True -> Some(#(key, stored_at))
            False -> acc
          }
      }
    })
  case oldest {
    Some(#(key, _)) -> dict.delete(entries, key)
    None -> entries
  }
}
