import domain/alert.{type AlertRow}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/timestamp.{type Timestamp}
import message/reciever/models/noaa.{type FeatureElement}
import pog

pub type AlertDiff {
  AlertDiff(new: List(AlertRow), updated: List(AlertRow), ended: List(AlertRow))
}

/// Upserts every feature in `features` and returns which alerts are new,
/// which changed, and which have ended, all within a single transaction.
///
/// `run_ended_sweep` should only be true when the poll that produced
/// `features` is known to be a complete, successful snapshot of every
/// currently active alert - otherwise a partial batch would incorrectly
/// end alerts that simply weren't included in it.
pub fn upsert_and_diff(
  features: List(FeatureElement),
  run_ended_sweep: Bool,
  conn: pog.Connection,
) -> Result(AlertDiff, String) {
  pog.transaction(conn, fn(tx) {
    use upserted <- result.try(upsert_features(features, tx))
    let #(new_rows, updated_rows) = classify_upserted_rows(upserted)

    let ids = list.map(features, fn(feature) { feature.id })
    use _ <- result.try(touch_seen(ids, tx))

    use swept <- result.try(case run_ended_sweep {
      True -> sweep_missing(ids, tx)
      False -> Ok([])
    })
    use expired <- result.try(sweep_expired(tx))

    Ok(AlertDiff(
      new: new_rows,
      updated: updated_rows,
      ended: list.append(swept, expired),
    ))
  })
  |> result.map_error(fn(error) {
    case error {
      pog.TransactionQueryError(query_error) ->
        "Database error: " <> string.inspect(query_error)
      pog.TransactionRolledBack(reason) -> reason
    }
  })
}

/// Splits upserted rows into newly-inserted and changed-existing, based on
/// the `is_new` flag each row carries (`xmax = 0` in the upsert query).
/// Pulled out as a pure function so the classification can be unit-tested
/// without a database.
pub fn classify_upserted_rows(
  rows: List(#(AlertRow, Bool)),
) -> #(List(AlertRow), List(AlertRow)) {
  let #(new_pairs, updated_pairs) = list.partition(rows, fn(pair) { pair.1 })
  #(
    list.map(new_pairs, fn(pair) { pair.0 }),
    list.map(updated_pairs, fn(pair) { pair.0 }),
  )
}

fn upsert_features(
  features: List(FeatureElement),
  conn: pog.Connection,
) -> Result(List(#(AlertRow, Bool)), String) {
  use results <- result.try(
    features
    |> list.try_map(fn(feature) { upsert_feature(feature, conn) })
    |> result.map_error(fn(error) {
      "Database error: " <> string.inspect(error)
    }),
  )
  Ok(
    list.filter_map(results, fn(row) {
      case row {
        Some(row) -> Ok(row)
        None -> Error(Nil)
      }
    }),
  )
}

const upsert_sql = "
  INSERT INTO sea.alert
    (id, event, severity, urgency, certainty, message_type, headline,
     area_desc, ugc, same, geometry, sent, effective, expires, ends,
     first_seen_at, last_seen_at, ended_at)
  VALUES
    ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11::jsonb, $12, $13, $14, $15,
     now(), now(), NULL)
  ON CONFLICT (id) DO UPDATE SET
    event = EXCLUDED.event,
    severity = EXCLUDED.severity,
    urgency = EXCLUDED.urgency,
    certainty = EXCLUDED.certainty,
    message_type = EXCLUDED.message_type,
    headline = EXCLUDED.headline,
    area_desc = EXCLUDED.area_desc,
    ugc = EXCLUDED.ugc,
    same = EXCLUDED.same,
    geometry = EXCLUDED.geometry,
    sent = EXCLUDED.sent,
    effective = EXCLUDED.effective,
    expires = EXCLUDED.expires,
    ends = EXCLUDED.ends,
    last_seen_at = now(),
    ended_at = NULL
  WHERE sea.alert.sent IS DISTINCT FROM EXCLUDED.sent
     OR sea.alert.message_type IS DISTINCT FROM EXCLUDED.message_type
     OR sea.alert.ended_at IS NOT NULL
  RETURNING "
  <> alert.columns
  <> ", (xmax = 0) AS is_new"

fn upsert_feature(
  feature: FeatureElement,
  conn: pog.Connection,
) -> Result(Option(#(AlertRow, Bool)), pog.QueryError) {
  let properties = feature.properties
  let geometry_json =
    option.map(feature.geometry, fn(geometry) {
      json.to_string(noaa.geometry_to_json(geometry))
    })
  let message_type =
    option.map(properties.message_type, noaa.message_type_to_string)

  pog.query(upsert_sql)
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
  |> pog.returning(upsert_row_decoder())
  |> pog.execute(conn)
  |> result.map(fn(returned) { list.first(returned.rows) |> option.from_result })
}

fn upsert_row_decoder() -> decode.Decoder(#(AlertRow, Bool)) {
  use row <- decode.then(alert.row_decoder())
  use is_new <- decode.field(18, decode.bool)
  decode.success(#(row, is_new))
}

fn touch_seen(ids: List(String), conn: pog.Connection) -> Result(Nil, String) {
  pog.query(
    "UPDATE sea.alert SET last_seen_at = now(), ended_at = NULL WHERE id = ANY($1)",
  )
  |> pog.parameter(pog.array(pog.text, ids))
  |> pog.returning(decode.success(Nil))
  |> pog.execute(conn)
  |> result.map(fn(_) { Nil })
  |> result.map_error(fn(error) { "Database error: " <> string.inspect(error) })
}

fn sweep_missing(
  ids: List(String),
  conn: pog.Connection,
) -> Result(List(AlertRow), String) {
  pog.query("UPDATE sea.alert SET ended_at = now()
     WHERE ended_at IS NULL AND NOT (id = ANY($1))
     RETURNING " <> alert.columns)
  |> pog.parameter(pog.array(pog.text, ids))
  |> pog.returning(alert.row_decoder())
  |> pog.execute(conn)
  |> result.map(fn(returned) { returned.rows })
  |> result.map_error(fn(error) { "Database error: " <> string.inspect(error) })
}

fn sweep_expired(conn: pog.Connection) -> Result(List(AlertRow), String) {
  pog.query("UPDATE sea.alert SET ended_at = now()
     WHERE ended_at IS NULL AND COALESCE(ends, expires) < now()
     RETURNING " <> alert.columns)
  |> pog.returning(alert.row_decoder())
  |> pog.execute(conn)
  |> result.map(fn(returned) { returned.rows })
  |> result.map_error(fn(error) { "Database error: " <> string.inspect(error) })
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
