import gleam/list
import gleam/result
import gleam/set
import intake/record.{type Incoming}
import intake/seen_set.{type SeenSet}

/// The most records handed to one `write` call. A single write is one DB
/// transaction, so this bounds how long any one transaction can run
/// regardless of how large an upstream batch (e.g. a multi-thousand-row
/// backfill) is.
pub const chunk_size = 250

/// What a writer produced from the records it was actually given.
pub type Written(w) {
  Written(result: w, new: Int, updated: Int, unchanged: Int, stale: Int)
  WrittenExcept(
    result: w,
    new: Int,
    updated: Int,
    unchanged: Int,
    stale: Int,
    failed_keys: List(record.Key),
  )
}

/// What a full pipeline run produced, including records dropped before
/// ever reaching the writer because their exact revision was seen before.
/// `results` holds one entry per chunk actually written, in order, so a
/// caller can fold each writer's own result type (e.g. concatenating diff
/// lists) without the pipeline needing to know how to combine them.
pub type Outcome(w) {
  Outcome(
    results: List(w),
    new: Int,
    updated: Int,
    unchanged: Int,
    stale: Int,
    repeats: Int,
  )
}

type Progress(w) {
  Progress(results: List(w), new: Int, updated: Int, unchanged: Int, stale: Int)
}

/// Filters `records` through the seen-set, then hands the survivors to
/// `write` in chunks of at most `chunk_size`, marking each chunk's keys seen
/// only once its own write succeeds. A writer may use one transaction per
/// chunk or one transaction per record. Writers returning `WrittenExcept`
/// provide `failed_keys`, which are excluded from being marked seen so they
/// remain pending and are retried on subsequent runs, while successfully
/// written keys in the chunk are marked seen. A failing chunk returning
/// `Error` stops the run without touching later chunks, but earlier chunks
/// stay committed and marked seen, so an adapter retry of the same batch sees
/// them as repeats rather than writing them twice.
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
  let chunks = list.sized_chunk(survivors, chunk_size)

  use progress <- result.try(
    list.try_fold(chunks, empty_progress(), fn(progress, chunk) {
      write(list.map(chunk, fn(pair) { pair.1 }))
      |> result.map(fn(written) {
        let keys_to_mark = case written {
          Written(..) -> list.map(chunk, fn(pair) { pair.0 })
          WrittenExcept(failed_keys:, ..) -> {
            let failed_set = set.from_list(failed_keys)
            chunk
            |> list.filter(fn(pair) {
              !set.contains(failed_set, { pair.1 }.key)
            })
            |> list.map(fn(pair) { pair.0 })
          }
        }
        seen_set.mark(seen, keys_to_mark, now_ms)
        append_written(progress, written)
      })
    }),
  )

  Ok(Outcome(
    results: list.reverse(progress.results),
    new: progress.new,
    updated: progress.updated,
    unchanged: progress.unchanged,
    stale: progress.stale,
    repeats: repeats,
  ))
}

fn empty_progress() -> Progress(w) {
  Progress(results: [], new: 0, updated: 0, unchanged: 0, stale: 0)
}

fn append_written(progress: Progress(w), written: Written(w)) -> Progress(w) {
  case written {
    Written(result:, new:, updated:, unchanged:, stale:)
    | WrittenExcept(result:, new:, updated:, unchanged:, stale:, ..) ->
      Progress(
        results: [result, ..progress.results],
        new: progress.new + new,
        updated: progress.updated + updated,
        unchanged: progress.unchanged + unchanged,
        stale: progress.stale + stale,
      )
  }
}
