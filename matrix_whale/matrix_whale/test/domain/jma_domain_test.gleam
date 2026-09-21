import domain/jma
import gleam/time/timestamp
import gleeunit/should

pub fn jma_status_checks_test() {
  jma.is_live_status("通常") |> should.be_true
  jma.is_live_status("訓練") |> should.be_false
  jma.is_live_status("試験") |> should.be_false
  jma.is_live_status("その他") |> should.be_false

  jma.is_cancel("取消") |> should.be_true
  jma.is_cancel("発表") |> should.be_false
  jma.is_cancel("訂正") |> should.be_false

  jma.is_correction("訂正") |> should.be_true
  jma.is_correction("発表") |> should.be_false
}

pub fn jma_item_state_test() {
  jma.item_state_to_string(jma.Pending) |> should.equal("pending")
  jma.item_state_to_string(jma.Fetching) |> should.equal("fetching")
  jma.item_state_to_string(jma.Ingested) |> should.equal("ingested")
  jma.item_state_to_string(jma.Failed) |> should.equal("failed")

  jma.string_to_item_state("pending") |> should.equal(jma.Pending)
  jma.string_to_item_state("fetching") |> should.equal(jma.Fetching)
  jma.string_to_item_state("ingested") |> should.equal(jma.Ingested)
  jma.string_to_item_state("failed") |> should.equal(jma.Failed)
  jma.string_to_item_state("other") |> should.equal(jma.Pending)
}

pub fn jma_parse_timestamp_test() {
  let assert Ok(ts1) = jma.parse_rfc3339("2026-09-21T01:25:00+09:00")
  let assert Ok(ts2) = jma.parse_rfc3339("2026-09-20T16:25:00Z")
  // 01:25:00 JST (+09:00) is exactly 16:25:00 UTC previous day
  let #(s1, _) = timestamp.to_unix_seconds_and_nanoseconds(ts1)
  let #(s2, _) = timestamp.to_unix_seconds_and_nanoseconds(ts2)
  s1 |> should.equal(s2)
}
