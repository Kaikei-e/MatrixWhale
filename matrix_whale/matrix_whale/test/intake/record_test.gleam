import gleam/dict
import gleeunit/should
import intake/record.{
  type Incoming, Incoming, Key, New, Stale, Unchanged, Updated,
}

fn incoming(source_id: String, revision: Int) -> Incoming(String) {
  Incoming(key: Key("usgs", source_id), revision: revision, payload: source_id)
}

pub fn classify_against_empty_current_is_always_new_test() {
  record.classify([incoming("a", 1)], dict.new())
  |> should.equal([#(incoming("a", 1), New)])
}

pub fn classify_higher_revision_is_updated_test() {
  let current = dict.from_list([#(Key("usgs", "a"), 1)])
  record.classify([incoming("a", 2)], current)
  |> should.equal([#(incoming("a", 2), Updated(previous: 1))])
}

pub fn classify_equal_revision_is_unchanged_test() {
  let current = dict.from_list([#(Key("usgs", "a"), 1)])
  record.classify([incoming("a", 1)], current)
  |> should.equal([#(incoming("a", 1), Unchanged)])
}

pub fn classify_lower_revision_is_stale_test() {
  let current = dict.from_list([#(Key("usgs", "a"), 5)])
  record.classify([incoming("a", 1)], current)
  |> should.equal([#(incoming("a", 1), Stale(current: 5))])
}

pub fn classify_empty_batch_is_empty_test() {
  record.classify([], dict.new())
  |> should.equal([])
}

pub fn classify_deduplicates_within_batch_keeping_highest_revision_test() {
  let result =
    record.classify(
      [incoming("a", 1), incoming("a", 3), incoming("a", 2)],
      dict.new(),
    )

  result
  |> should.equal([
    #(incoming("a", 1), Stale(current: 3)),
    #(incoming("a", 3), New),
    #(incoming("a", 2), Stale(current: 3)),
  ])
}

pub fn classify_in_batch_ties_mark_extras_unchanged_test() {
  let result = record.classify([incoming("a", 2), incoming("a", 2)], dict.new())

  result
  |> should.equal([#(incoming("a", 2), New), #(incoming("a", 2), Unchanged)])
}

pub fn classify_independent_keys_do_not_interfere_test() {
  let current = dict.from_list([#(Key("usgs", "a"), 1)])
  record.classify([incoming("a", 2), incoming("b", 1)], current)
  |> should.equal([
    #(incoming("a", 2), Updated(previous: 1)),
    #(incoming("b", 1), New),
  ])
}

pub fn seen_key_combines_source_id_and_revision_test() {
  record.seen_key(Key("usgs", "abc"), 42) |> should.equal("usgs|abc|42")
}
