import domain/alert.{type AlertRow}
import domain/source
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/timestamp.{type Timestamp}
import intake/pipeline.{type Written, Written}
import intake/record.{type Incoming, type Key, type Verdict, Key}
import message/reciever/models/noaa.{type FeatureElement}
import pog

pub type AlertDiff {
  AlertDiff(new: List(AlertRow), updated: List(AlertRow), ended: List(AlertRow))
}

/// Upserts every feature in `records` and returns which alerts are new,
/// which changed, and which have ended, all within a single transaction.
///
/// `all_ids` is every alert id in this poll's snapshot - including ones the
/// seen-set already filtered out of `records` - so revival, the missing
/// sweep and `last_seen_at` all see the full picture. `run_ended_sweep`
/// should only be true when this is a complete, successful poll; a partial
/// or failed one must not end alerts merely absent from it.
pub fn write_batch(
  records: List(Incoming(FeatureElement)),
  run_ended_sweep: Bool,
  all_ids: List(String),
  now: Timestamp,
  conn: pog.Connection,
) -> Result(Written(AlertDiff), String) {
  pog.transaction(conn, fn(tx) {
    write_batch_tx(records, run_ended_sweep, all_ids, now, tx)
  })
  |> result.map_error(fn(x) {
    case x {
      pog.TransactionQueryError(x) -> err(x)
      pog.TransactionRolledBack(x) -> x
    }
  })
}

fn write_batch_tx(
  records: List(Incoming(FeatureElement)),
  run_ended_sweep: Bool,
  all_ids: List(String),
  now: Timestamp,
  conn: pog.Connection,
) -> Result(Written(AlertDiff), String) {
  use current <- result.try(load_current(all_ids, conn))
  let classified = record.classify(records, current)

  let #(new_pairs, rest) =
    list.partition(classified, fn(pair) { pair.1 == record.New })
  let #(updated_pairs, rest) = list.partition(rest, is_updated)
  let #(unchanged_pairs, stale_pairs) =
    list.partition(rest, fn(pair) { pair.1 == record.Unchanged })

  use #(inserted, insert_lost) <- result.try(insert_new(new_pairs, now, conn))
  use #(updated_rows, update_lost) <- result.try(update_existing(
    updated_pairs,
    now,
    conn,
  ))
  use revived <- result.try(revive(all_ids, now, conn))
  use _ <- result.try(touch(all_ids, now, conn))
  use ended <- result.try(case run_ended_sweep {
    True -> sweep_missing(all_ids, now, conn)
    False -> Ok([])
  })
  use expired <- result.try(sweep_expired(now, conn))

  Ok(Written(
    result: AlertDiff(
      new: inserted,
      updated: list.append(updated_rows, revived),
      ended: list.append(ended, expired),
    ),
    new: list.length(inserted),
    updated: list.length(updated_rows),
    unchanged: list.length(unchanged_pairs) + insert_lost + update_lost,
    stale: list.length(stale_pairs),
  ))
}

fn is_updated(pair: #(Incoming(FeatureElement), Verdict)) -> Bool {
  case pair.1 {
    record.Updated(_) -> True
    _ -> False
  }
}

fn load_current(
  ids: List(String),
  conn: pog.Connection,
) -> Result(Dict(Key, Int), String) {
  pog.query("SELECT id, sent FROM sea.alert WHERE id = ANY($1) FOR UPDATE")
  |> pog.parameter(pog.array(pog.text, ids))
  |> pog.returning(current_row_decoder())
  |> pog.execute(conn)
  |> result.map(fn(x) {
    list.fold(x.rows, dict.new(), fn(acc, row) {
      let #(id, revision) = row
      dict.insert(acc, Key(source.noaa.id, id), revision)
    })
  })
  |> result.map_error(err)
}

fn current_row_decoder() -> decode.Decoder(#(String, Int)) {
  use id <- decode.field(0, decode.string)
  use sent <- decode.field(1, decode.optional(alert.timestamptz_decoder()))
  decode.success(#(
    id,
    option.map(sent, noaa.timestamp_to_ms) |> option.unwrap(0),
  ))
}

const insert_sql = "
  INSERT INTO sea.alert
    (id, event, severity, urgency, certainty, message_type, headline,
     area_desc, ugc, same, geometry, sent, effective, expires, ends,
     first_seen_at, last_seen_at, ended_at)
  VALUES
    ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11::jsonb, $12, $13, $14, $15,
     $16, $16, NULL)
  ON CONFLICT (id) DO NOTHING
  RETURNING "
  <> alert.columns

const update_sql = "
  UPDATE sea.alert SET
    event = $2, severity = $3, urgency = $4, certainty = $5,
    message_type = $6, headline = $7, area_desc = $8, ugc = $9, same = $10,
    geometry = $11::jsonb, sent = $12, effective = $13, expires = $14, ends = $15,
    last_seen_at = $16, ended_at = NULL
  WHERE id = $1
  RETURNING "
  <> alert.columns

fn insert_new(
  pairs: List(#(Incoming(FeatureElement), Verdict)),
  now: Timestamp,
  conn: pog.Connection,
) -> Result(#(List(AlertRow), Int), String) {
  use results <- result.try(
    pairs
    |> list.try_map(fn(pair) {
      run_write(insert_sql, pair.0.payload, now, conn)
    })
    |> result.map_error(err),
  )
  let rows = option.values(results)
  Ok(#(rows, list.length(results) - list.length(rows)))
}

fn update_existing(
  pairs: List(#(Incoming(FeatureElement), Verdict)),
  now: Timestamp,
  conn: pog.Connection,
) -> Result(#(List(AlertRow), Int), String) {
  use results <- result.try(
    pairs
    |> list.try_map(fn(pair) {
      run_write(update_sql, pair.0.payload, now, conn)
    })
    |> result.map_error(err),
  )
  let rows = option.values(results)
  Ok(#(rows, list.length(results) - list.length(rows)))
}

fn run_write(
  sql: String,
  feature: FeatureElement,
  now: Timestamp,
  conn: pog.Connection,
) -> Result(Option(AlertRow), pog.QueryError) {
  bind_alert_params(pog.query(sql), feature, now)
  |> pog.returning(alert.row_decoder())
  |> pog.execute(conn)
  |> result.map(fn(x) { list.first(x.rows) |> option.from_result })
}

fn bind_alert_params(query, feature: FeatureElement, now: Timestamp) {
  let properties = feature.properties
  let geometry_json =
    option.map(feature.geometry, fn(geometry) {
      json.to_string(noaa.geometry_to_json(geometry))
    })
  let message_type =
    option.map(properties.message_type, noaa.message_type_to_string)

  query
  |> pog.parameter(pog.text(feature.id))
  |> pog.parameter(pog.text(properties.event))
  |> pog.parameter(pog.text(noaa.severity_to_string(properties.severity)))
  |> pog.parameter(pog.text(noaa.urgency_to_string(properties.urgency)))
  |> pog.parameter(pog.text(noaa.certainty_to_string(properties.certainty)))
  |> pog.parameter(pog.nullable(pog.text, message_type))
  |> pog.parameter(pog.nullable(pog.text, properties.headline))
  |> pog.parameter(pog.text(properties.area_desc))
  |> pog.parameter(pog.array(pog.text, properties.geocode.ugc))
  |> pog.parameter(pog.array(pog.text, properties.geocode.same))
  |> pog.parameter(pog.nullable(pog.text, geometry_json))
  |> pog.parameter(pog.nullable(
    pog.timestamp,
    parse_optional_timestamp(properties.sent),
  ))
  |> pog.parameter(pog.nullable(
    pog.timestamp,
    parse_timestamp(properties.effective),
  ))
  |> pog.parameter(pog.nullable(
    pog.timestamp,
    parse_timestamp(properties.expires),
  ))
  |> pog.parameter(pog.nullable(
    pog.timestamp,
    parse_optional_timestamp(properties.ends),
  ))
  |> pog.parameter(pog.timestamp(now))
}

fn revive(
  all_ids: List(String),
  now: Timestamp,
  conn: pog.Connection,
) -> Result(List(AlertRow), String) {
  pog.query("UPDATE sea.alert SET ended_at = NULL, last_seen_at = $2
     WHERE id = ANY($1) AND ended_at IS NOT NULL
     RETURNING " <> alert.columns)
  |> pog.parameter(pog.array(pog.text, all_ids))
  |> pog.parameter(pog.timestamp(now))
  |> pog.returning(alert.row_decoder())
  |> pog.execute(conn)
  |> result.map(fn(x) { x.rows })
  |> result.map_error(err)
}

fn touch(
  all_ids: List(String),
  now: Timestamp,
  conn: pog.Connection,
) -> Result(Nil, String) {
  pog.query("UPDATE sea.alert SET last_seen_at = $2 WHERE id = ANY($1)")
  |> pog.parameter(pog.array(pog.text, all_ids))
  |> pog.parameter(pog.timestamp(now))
  |> pog.returning(decode.success(Nil))
  |> pog.execute(conn)
  |> result.map(fn(_) { Nil })
  |> result.map_error(err)
}

fn sweep_missing(
  all_ids: List(String),
  now: Timestamp,
  conn: pog.Connection,
) -> Result(List(AlertRow), String) {
  pog.query("UPDATE sea.alert SET ended_at = $2
     WHERE ended_at IS NULL AND NOT (id = ANY($1))
     RETURNING " <> alert.columns)
  |> pog.parameter(pog.array(pog.text, all_ids))
  |> pog.parameter(pog.timestamp(now))
  |> pog.returning(alert.row_decoder())
  |> pog.execute(conn)
  |> result.map(fn(x) { x.rows })
  |> result.map_error(err)
}

fn sweep_expired(
  now: Timestamp,
  conn: pog.Connection,
) -> Result(List(AlertRow), String) {
  pog.query("UPDATE sea.alert SET ended_at = $1
     WHERE ended_at IS NULL AND COALESCE(ends, expires) < $1
     RETURNING " <> alert.columns)
  |> pog.parameter(pog.timestamp(now))
  |> pog.returning(alert.row_decoder())
  |> pog.execute(conn)
  |> result.map(fn(x) { x.rows })
  |> result.map_error(err)
}

fn parse_timestamp(value: String) -> Option(Timestamp) {
  timestamp.parse_rfc3339(value) |> option.from_result
}

fn parse_optional_timestamp(value: Option(String)) -> Option(Timestamp) {
  case value {
    Some(value) -> parse_timestamp(value)
    None -> None
  }
}

fn err(x: pog.QueryError) -> String {
  "Database error: " <> string.inspect(x)
}
