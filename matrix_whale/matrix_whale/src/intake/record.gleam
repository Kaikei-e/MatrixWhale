import gleam/dict.{type Dict}
import gleam/int
import gleam/list

pub type Key {
  Key(source: String, source_id: String)
}

pub type Incoming(a) {
  Incoming(key: Key, revision: Int, payload: a)
}

pub type Verdict {
  New
  Updated(previous: Int)
  Unchanged
  Stale(current: Int)
}

/// Classifies each incoming record against the store's current revisions,
/// deduping within `incoming` itself first: when a key appears more than
/// once, only its highest-revision occurrence is classified against
/// `current` and the rest are marked `Unchanged` (a tie with the winner) or
/// `Stale` (behind the winner).
pub fn classify(
  incoming: List(Incoming(a)),
  current: Dict(Key, Int),
) -> List(#(Incoming(a), Verdict)) {
  let winners = winning_revisions(incoming)
  let #(_, results) =
    list.map_fold(incoming, dict.new(), fn(kept, record) {
      let assert Ok(winner) = dict.get(winners, record.key)
      case record.revision == winner && !dict.has_key(kept, record.key) {
        True -> #(
          dict.insert(kept, record.key, True),
          #(record, classify_one(record, current)),
        )
        False -> #(
          kept,
          #(record, case record.revision == winner {
            True -> Unchanged
            False -> Stale(current: winner)
          }),
        )
      }
    })
  results
}

/// A stable key identifying one exact revision of a record, suitable for
/// short-lived seen-set membership.
pub fn seen_key(key: Key, revision: Int) -> String {
  key.source <> "|" <> key.source_id <> "|" <> int.to_string(revision)
}

fn winning_revisions(incoming: List(Incoming(a))) -> Dict(Key, Int) {
  list.fold(incoming, dict.new(), fn(acc, record) {
    case dict.get(acc, record.key) {
      Ok(existing) if existing >= record.revision -> acc
      _ -> dict.insert(acc, record.key, record.revision)
    }
  })
}

fn classify_one(record: Incoming(a), current: Dict(Key, Int)) -> Verdict {
  case dict.get(current, record.key) {
    Error(Nil) -> New
    Ok(existing) ->
      case record.revision > existing, record.revision == existing {
        True, _ -> Updated(previous: existing)
        _, True -> Unchanged
        _, _ -> Stale(current: existing)
      }
  }
}
