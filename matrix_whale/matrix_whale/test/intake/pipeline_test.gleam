import gleam/int
import gleam/list
import gleeunit/should
import intake/pipeline.{Written, WrittenExcept}
import intake/record.{Incoming, Key}
import intake/seen_set

fn incoming(id: String, revision: Int) -> record.Incoming(String) {
  Incoming(key: Key("usgs", id), revision: revision, payload: id)
}

pub fn repeats_are_counted_and_excluded_from_write_test() {
  let set = seen_set.new("pipeline_test_repeats", 10_000)
  seen_set.mark(set, [record.seen_key(Key("usgs", "a"), 1)], 0)

  let assert Ok(outcome) =
    pipeline.run([incoming("a", 1), incoming("b", 1)], set, 0, fn(survivors) {
      survivors |> should.equal([incoming("b", 1)])
      Ok(Written(result: Nil, new: 1, updated: 0, unchanged: 0, stale: 0))
    })

  outcome.repeats |> should.equal(1)
  outcome.new |> should.equal(1)
}

pub fn successful_write_marks_survivors_seen_test() {
  let set = seen_set.new("pipeline_test_mark_on_ok", 10_000)

  let assert Ok(_) =
    pipeline.run([incoming("a", 1)], set, 0, fn(_survivors) {
      Ok(Written(result: Nil, new: 1, updated: 0, unchanged: 0, stale: 0))
    })

  seen_set.unseen(set, [record.seen_key(Key("usgs", "a"), 1)], 0)
  |> should.equal([])
}

pub fn failed_write_does_not_mark_seen_test() {
  let set = seen_set.new("pipeline_test_no_mark_on_error", 10_000)

  let assert Error(_) =
    pipeline.run([incoming("a", 1)], set, 0, fn(_survivors) { Error("boom") })

  seen_set.unseen(set, [record.seen_key(Key("usgs", "a"), 1)], 0)
  |> should.equal([record.seen_key(Key("usgs", "a"), 1)])
}

pub fn written_except_does_not_mark_failed_keys_seen_test() {
  let set = seen_set.new("pipeline_test_written_except", 10_000)

  let assert Ok(outcome) =
    pipeline.run([incoming("a", 1), incoming("b", 1)], set, 0, fn(_survivors) {
      Ok(
        WrittenExcept(
          result: Nil,
          new: 1,
          updated: 0,
          unchanged: 0,
          stale: 0,
          failed_keys: [Key("usgs", "b")],
        ),
      )
    })

  outcome.new |> should.equal(1)
  // "a" was written and marked seen
  seen_set.unseen(set, [record.seen_key(Key("usgs", "a"), 1)], 0)
  |> should.equal([])
  // "b" failed inside writer and was excluded from marking seen
  seen_set.unseen(set, [record.seen_key(Key("usgs", "b"), 1)], 0)
  |> should.equal([record.seen_key(Key("usgs", "b"), 1)])
}

pub fn large_batches_are_split_into_chunks_and_counts_aggregate_test() {
  let set = seen_set.new("pipeline_test_chunking_counts", 10_000)
  let total = pipeline.chunk_size * 2 + 10
  let records = numbered_records(total)

  let assert Ok(outcome) =
    pipeline.run(records, set, 0, fn(survivors) {
      Ok(Written(
        result: list.length(survivors),
        new: list.length(survivors),
        updated: 0,
        unchanged: 0,
        stale: 0,
      ))
    })

  outcome.results
  |> should.equal([pipeline.chunk_size, pipeline.chunk_size, 10])
  outcome.new |> should.equal(total)
}

pub fn a_failing_chunk_stops_the_run_but_leaves_earlier_chunks_marked_seen_test() {
  let set = seen_set.new("pipeline_test_chunking_partial_failure", 10_000)
  let total = pipeline.chunk_size * 2
  let records = numbered_records(total)

  let assert Error(_) =
    pipeline.run(records, set, 0, fn(survivors) {
      case list.any(survivors, fn(r) { r.key.source_id == "300" }) {
        True -> Error("boom")
        False ->
          Ok(Written(
            result: Nil,
            new: list.length(survivors),
            updated: 0,
            unchanged: 0,
            stale: 0,
          ))
      }
    })

  // The first chunk (ids 0..chunk_size-1) committed and was marked seen.
  seen_set.unseen(set, [record.seen_key(Key("usgs", "0"), 1)], 0)
  |> should.equal([])
  // The second, failing chunk (which includes "300") was never marked.
  seen_set.unseen(set, [record.seen_key(Key("usgs", "300"), 1)], 0)
  |> should.equal([record.seen_key(Key("usgs", "300"), 1)])
}

fn numbered_records(count: Int) -> List(record.Incoming(String)) {
  list.repeat(Nil, count)
  |> list.index_map(fn(_, i) { incoming(int.to_string(i), 1) })
}
