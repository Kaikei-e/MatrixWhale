import gleeunit/should
import intake/seen_set

pub fn unseen_then_marked_becomes_seen_test() {
  let set = seen_set.new("seen_set_test_basic", 10_000)
  seen_set.unseen(set, ["a", "b"], 0) |> should.equal(["a", "b"])
  seen_set.mark(set, ["a"], 0)
  seen_set.unseen(set, ["a", "b"], 0) |> should.equal(["b"])
}

pub fn expired_entries_count_as_unseen_test() {
  let set = seen_set.new("seen_set_test_ttl", 100)
  seen_set.mark(set, ["a"], 0)
  seen_set.unseen(set, ["a"], 0) |> should.equal([])
  seen_set.unseen(set, ["a"], 200) |> should.equal(["a"])
}

pub fn purge_removes_only_expired_entries_and_returns_count_test() {
  let set = seen_set.new("seen_set_test_purge", 100)
  seen_set.mark(set, ["a", "b"], 0)
  seen_set.mark(set, ["c"], 1000)
  seen_set.purge(set, 200) |> should.equal(2)
  seen_set.size(set) |> should.equal(1)
}

pub fn different_names_do_not_interfere_test() {
  let a = seen_set.new("seen_set_test_a", 10_000)
  let b = seen_set.new("seen_set_test_b", 10_000)
  seen_set.mark(a, ["x"], 0)
  seen_set.unseen(a, ["x"], 0) |> should.equal([])
  seen_set.unseen(b, ["x"], 0) |> should.equal(["x"])
}

pub fn new_is_idempotent_for_the_same_name_test() {
  let first = seen_set.new("seen_set_test_idempotent", 10_000)
  seen_set.mark(first, ["a"], 0)
  let second = seen_set.new("seen_set_test_idempotent", 10_000)
  seen_set.unseen(second, ["a"], 0) |> should.equal([])
}
