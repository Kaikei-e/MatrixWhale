import gleam/list
import gleam/set
import intake/record.{type Incoming}
import intake/seen_set.{type SeenSet}

/// What a writer produced from the records it was actually given.
pub type Written(w) {
  Written(result: w, new: Int, updated: Int, unchanged: Int, stale: Int)
}

/// What a full pipeline run produced, including records dropped before
/// ever reaching the writer because their exact revision was seen before.
pub type Outcome(w) {
  Outcome(
    result: w,
    new: Int,
    updated: Int,
    unchanged: Int,
    stale: Int,
    repeats: Int,
  )
}

/// Filters `records` through the seen-set, hands the survivors to `write`,
/// and - only once `write` succeeds - marks those survivors seen. A failed
/// write must never mark anything seen, so a 503 and adapter retry can
/// still land the records on the next attempt.
pub fn run(
  records: List(Incoming(a)),
  seen: SeenSet,
  now_ms: Int,
  write: fn(List(Incoming(a))) -> Result(Written(w), String),
) -> Result(Outcome(w), String) {
  let keyed =
    list.map(records, fn(entry) {
      #(record.seen_key(entry.key, entry.revision), entry)
    })
  let unseen_keys =
    seen_set.unseen(seen, list.map(keyed, fn(pair) { pair.0 }), now_ms)
    |> set.from_list

  let #(survivors, repeats) =
    list.fold(keyed, #([], 0), fn(acc, pair) {
      let #(survivors, repeats) = acc
      case set.contains(unseen_keys, pair.0) {
        True -> #([pair, ..survivors], repeats)
        False -> #(survivors, repeats + 1)
      }
    })
  let survivors = list.reverse(survivors)

  case write(list.map(survivors, fn(pair) { pair.1 })) {
    Ok(written) -> {
      seen_set.mark(seen, list.map(survivors, fn(pair) { pair.0 }), now_ms)
      Ok(Outcome(
        result: written.result,
        new: written.new,
        updated: written.updated,
        unchanged: written.unchanged,
        stale: written.stale,
        repeats: repeats,
      ))
    }
    Error(error) -> Error(error)
  }
}
