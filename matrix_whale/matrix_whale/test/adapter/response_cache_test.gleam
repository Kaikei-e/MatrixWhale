import adapter/response_cache.{CacheEntry}
import gleam/option.{None, Some}
import gleeunit/should

pub fn miss_returns_none_plus_generation_0_test() {
  let assert Ok(cache) = response_cache.start()
  let result = response_cache.get(cache.data, "nonexistent")
  result |> should.equal(#(None, 0))
}

pub fn put_then_get_returns_the_entry_test() {
  let assert Ok(cache) = response_cache.start()
  let entry = CacheEntry("etag", "body", <<1, 2, 3>>)

  response_cache.put(cache.data, "my_key", 0, entry)
  let result = response_cache.get(cache.data, "my_key")

  result |> should.equal(#(Some(entry), 0))
}

pub fn invalidate_bumps_generation_and_empties_cache_test() {
  let assert Ok(cache) = response_cache.start()
  let entry = CacheEntry("etag", "body", <<1, 2, 3>>)

  response_cache.put(cache.data, "my_key", 0, entry)
  response_cache.invalidate(cache.data)

  let result = response_cache.get(cache.data, "my_key")
  result |> should.equal(#(None, 1))
}

pub fn put_tagged_with_old_generation_is_ignored_test() {
  let assert Ok(cache) = response_cache.start()
  let entry1 = CacheEntry("etag1", "body1", <<1>>)
  let entry2 = CacheEntry("etag2", "body2", <<2>>)

  response_cache.put(cache.data, "my_key", 0, entry1)
  response_cache.invalidate(cache.data)

  // This put uses the old generation (0)
  response_cache.put(cache.data, "my_key", 0, entry2)

  let result = response_cache.get(cache.data, "my_key")
  // The cache should still be empty (and generation 1)
  result |> should.equal(#(None, 1))
}
