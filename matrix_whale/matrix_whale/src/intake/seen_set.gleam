/// A shared, TTL-based "have we already written this exact revision"
/// filter, backed by a public named ETS table (`intake_seen_set_ffi.erl`)
/// so every request-handling process sees the same state without going
/// through a single bottleneck actor.
pub opaque type SeenSet {
  SeenSet(table: Table, ttl_ms: Int)
}

pub type Table

@external(erlang, "intake_seen_set_ffi", "new_table")
fn new_table(name: String) -> Table

@external(erlang, "intake_seen_set_ffi", "unseen")
fn ffi_unseen(table: Table, keys: List(String), now_ms: Int) -> List(String)

@external(erlang, "intake_seen_set_ffi", "mark")
fn ffi_mark(table: Table, keys: List(String), expires_at_ms: Int) -> Nil

@external(erlang, "intake_seen_set_ffi", "purge")
fn ffi_purge(table: Table, now_ms: Int) -> Int

@external(erlang, "intake_seen_set_ffi", "size")
fn ffi_size(table: Table) -> Int

pub fn new(name: String, ttl_ms: Int) -> SeenSet {
  SeenSet(table: new_table(name), ttl_ms: ttl_ms)
}

/// Returns the subset of `keys` that are not currently marked seen. An
/// expired entry counts as unseen.
pub fn unseen(set: SeenSet, keys: List(String), now_ms: Int) -> List(String) {
  ffi_unseen(set.table, keys, now_ms)
}

/// Marks every key in `keys` as seen until `now_ms + ttl_ms`.
pub fn mark(set: SeenSet, keys: List(String), now_ms: Int) -> Nil {
  ffi_mark(set.table, keys, now_ms + set.ttl_ms)
}

/// Deletes every expired entry and returns how many were removed.
pub fn purge(set: SeenSet, now_ms: Int) -> Int {
  ffi_purge(set.table, now_ms)
}

pub fn size(set: SeenSet) -> Int {
  ffi_size(set.table)
}
