import domain/alert.{AlertRow}
import gleam/option
import gleam/time/timestamp
import gleeunit/should
import repository/alert_writer

fn sample_row(id: String) -> alert.AlertRow {
  let now = timestamp.from_unix_seconds(0)
  AlertRow(
    id: id,
    event: "Test Event",
    severity: "Severe",
    urgency: "Immediate",
    certainty: "Observed",
    message_type: option.None,
    headline: option.None,
    area_desc: "Test Area",
    ugc: [],
    same: [],
    geometry: option.None,
    sent: option.None,
    effective: option.None,
    expires: option.None,
    ends: option.None,
    first_seen_at: now,
    last_seen_at: now,
    ended_at: option.None,
  )
}

pub fn classify_upserted_rows_splits_new_and_updated_test() {
  let new_row = sample_row("new-1")
  let updated_row = sample_row("updated-1")

  let #(new_rows, updated_rows) =
    alert_writer.classify_upserted_rows([
      #(new_row, True),
      #(updated_row, False),
    ])

  new_rows |> should.equal([new_row])
  updated_rows |> should.equal([updated_row])
}

pub fn classify_upserted_rows_handles_empty_list_test() {
  let #(new_rows, updated_rows) = alert_writer.classify_upserted_rows([])

  new_rows |> should.equal([])
  updated_rows |> should.equal([])
}

pub fn classify_upserted_rows_handles_all_new_test() {
  let rows = [#(sample_row("a"), True), #(sample_row("b"), True)]

  let #(new_rows, updated_rows) = alert_writer.classify_upserted_rows(rows)

  new_rows |> should.equal([sample_row("a"), sample_row("b")])
  updated_rows |> should.equal([])
}
