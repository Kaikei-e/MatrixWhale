import gleeunit/should
import intake/pipeline.{Written}
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
