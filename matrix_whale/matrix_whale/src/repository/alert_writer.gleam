import domain/alert.{type AlertRow, type AlertWrite, type EndInstruction}
import domain/source
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
import gleam/time/duration
import gleam/time/timestamp.{type Timestamp}
import intake/pipeline.{type Written, Written}
import intake/record.{type Incoming, type Key, type Verdict, Key}
import message/reciever/models/noaa.{type FeatureElement}
import pog

pub type AlertDiff {
  AlertDiff(new: List(AlertRow), updated: List(AlertRow), ended: List(AlertRow))
}

pub fn noaa_active_until(
  ends: Option(Timestamp),
  expires: Option(Timestamp),
  sent: Option(Timestamp),
  now: Timestamp,
) -> Timestamp {
  case ends {
    Some(ts) -> ts
    None ->
      case expires {
        Some(ts) -> ts
        None ->
          case sent {
            Some(ts) -> timestamp.add(ts, duration.hours(24))
            None -> timestamp.add(now, duration.hours(24))
          }
      }
  }
}

pub fn noaa_geocodes_json(ugc: List(String), same: List(String)) -> String {
  let ugc_items =
    list.map(ugc, fn(u) {
      json.object([#("name", json.string("UGC")), #("value", json.string(u))])
    })
  let same_items =
    list.map(same, fn(s) {
      json.object([#("name", json.string("SAME")), #("value", json.string(s))])
    })
  json.to_string(json.preprocessed_array(list.append(ugc_items, same_items)))
}

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

  let #(past_due_new, active_new) =
    list.partition(inserted, fn(row) { option.is_some(row.ended_at) })
  let #(past_due_updated, active_updated) =
    list.partition(updated_rows, fn(row) { option.is_some(row.ended_at) })

  Ok(Written(
    result: AlertDiff(
      new: active_new,
      updated: list.append(active_updated, revived),
      ended: list.flatten([ended, past_due_new, past_due_updated]),
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
  pog.query(
    "SELECT source_id, sent FROM sea.alert WHERE source = 'noaa' AND source_id = ANY($1) FOR UPDATE",
  )
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

const insert_noaa_sql = "
  WITH written AS (
    INSERT INTO sea.alert
      (source, source_id, sender, sender_name, identifier, message_type,
       event, category, severity, urgency, certainty, headline, description,
       instruction, web, contact, language, area_desc, geocodes, countries,
       geom, reference_keys, sent, effective, onset, expires, ends,
       active_until, first_seen_at, last_seen_at, ended_at, end_reason, superseded_by)
    VALUES
      ('noaa', $1, $2, $3, $4, $5,
       $6, $7, $8, $9, $10, $11, $12,
       $13, $14, $15, $16, $17, $18::jsonb, $19,
       ST_Multi(ST_CollectionExtract(ST_MakeValid(ST_SetSRID(ST_GeomFromGeoJSON($20::text), 4326)), 3)),
       $21, $22, $23, $24, $25, $26,
       $27, $28, $28, $29, $30, NULL)
    ON CONFLICT (source, source_id) DO NOTHING
    RETURNING *
  )
  SELECT "
  <> alert.columns
  <> "
  FROM written a
  JOIN sea.source s ON s.id = a.source"

const update_noaa_sql = "
  WITH written AS (
    UPDATE sea.alert SET
      sender = $2, sender_name = $3, identifier = $4, message_type = $5,
      event = $6, category = $7, severity = $8, urgency = $9, certainty = $10,
      headline = $11, description = $12, instruction = $13, web = $14, contact = $15,
      language = $16, area_desc = $17, geocodes = $18::jsonb, countries = $19,
      geom = ST_Multi(ST_CollectionExtract(ST_MakeValid(ST_SetSRID(ST_GeomFromGeoJSON($20::text), 4326)), 3)),
      reference_keys = $21, sent = $22, effective = $23, onset = $24, expires = $25, ends = $26,
      active_until = $27, last_seen_at = $28, ended_at = $29, end_reason = $30
    WHERE source = 'noaa' AND source_id = $1
    RETURNING *
  )
  SELECT "
  <> alert.columns
  <> "
  FROM written a
  JOIN sea.source s ON s.id = a.source"

fn insert_new(
  pairs: List(#(Incoming(FeatureElement), Verdict)),
  now: Timestamp,
  conn: pog.Connection,
) -> Result(#(List(AlertRow), Int), String) {
  use results <- result.try(
    pairs
    |> list.try_map(fn(pair) {
      run_write(insert_noaa_sql, pair.0.payload, now, conn)
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
      run_write(update_noaa_sql, pair.0.payload, now, conn)
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
  bind_noaa_params(pog.query(sql), feature, now)
  |> pog.returning(alert.row_decoder())
  |> pog.execute(conn)
  |> result.map(fn(x) { list.first(x.rows) |> option.from_result })
}

fn bind_noaa_params(query, feature: FeatureElement, now: Timestamp) {
  let properties = feature.properties
  let geometry_json =
    option.map(feature.geometry, fn(geometry) {
      json.to_string(noaa.geometry_to_json(geometry))
    })
  let message_type =
    option.map(properties.message_type, noaa.message_type_to_string)

  let sent = parse_optional_timestamp(properties.sent)
  let effective = parse_timestamp(properties.effective)
  let onset = parse_optional_timestamp(properties.onset)
  let expires = parse_timestamp(properties.expires)
  let ends = parse_optional_timestamp(properties.ends)
  let active_until = noaa_active_until(ends, expires, sent, now)
  let geocodes_json =
    noaa_geocodes_json(properties.geocode.ugc, properties.geocode.same)

  let sender = case properties.sender {
    noaa.Sender(s) -> Some(s)
  }
  let category = case properties.category {
    noaa.Met -> ["Met"]
    noaa.UnknownCategory -> []
  }

  let is_past_due = case timestamp.compare(active_until, now) {
    order.Lt | order.Eq -> True
    order.Gt -> False
  }
  let #(ended_at, end_reason) = case is_past_due {
    True -> #(Some(now), Some("expired"))
    False -> #(None, None)
  }

  query
  |> pog.parameter(pog.text(feature.id))
  |> pog.parameter(pog.nullable(pog.text, sender))
  |> pog.parameter(pog.nullable(pog.text, properties.sender_name))
  |> pog.parameter(pog.nullable(pog.text, properties.id))
  |> pog.parameter(pog.nullable(pog.text, message_type))
  |> pog.parameter(pog.text(properties.event))
  |> pog.parameter(pog.array(pog.text, category))
  |> pog.parameter(pog.text(noaa.severity_to_string(properties.severity)))
  |> pog.parameter(pog.text(noaa.urgency_to_string(properties.urgency)))
  |> pog.parameter(pog.text(noaa.certainty_to_string(properties.certainty)))
  |> pog.parameter(pog.nullable(pog.text, properties.headline))
  |> pog.parameter(pog.nullable(pog.text, properties.description))
  |> pog.parameter(pog.nullable(pog.text, properties.instruction))
  |> pog.parameter(pog.nullable(pog.text, None))
  |> pog.parameter(pog.nullable(pog.text, None))
  |> pog.parameter(pog.nullable(pog.text, Some("en-US")))
  |> pog.parameter(pog.text(properties.area_desc))
  |> pog.parameter(pog.text(geocodes_json))
  |> pog.parameter(pog.array(pog.text, ["USA"]))
  |> pog.parameter(pog.nullable(pog.text, geometry_json))
  |> pog.parameter(pog.array(pog.text, []))
  |> pog.parameter(pog.nullable(pog.timestamp, sent))
  |> pog.parameter(pog.nullable(pog.timestamp, effective))
  |> pog.parameter(pog.nullable(pog.timestamp, onset))
  |> pog.parameter(pog.nullable(pog.timestamp, expires))
  |> pog.parameter(pog.nullable(pog.timestamp, ends))
  |> pog.parameter(pog.timestamp(active_until))
  |> pog.parameter(pog.timestamp(now))
  |> pog.parameter(pog.nullable(pog.timestamp, ended_at))
  |> pog.parameter(pog.nullable(pog.text, end_reason))
}

fn revive(
  all_ids: List(String),
  now: Timestamp,
  conn: pog.Connection,
) -> Result(List(AlertRow), String) {
  pog.query("WITH written AS (
       UPDATE sea.alert SET ended_at = NULL, end_reason = NULL, last_seen_at = $2
       WHERE source = 'noaa' AND source_id = ANY($1) AND ended_at IS NOT NULL
         AND active_until > $2
       RETURNING *
     )
     SELECT " <> alert.columns <> "
     FROM written a
     JOIN sea.source s ON s.id = a.source")
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
  pog.query(
    "UPDATE sea.alert SET last_seen_at = $2 WHERE source = 'noaa' AND source_id = ANY($1)",
  )
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
  pog.query("WITH written AS (
       UPDATE sea.alert SET ended_at = $2, end_reason = 'withdrawn'
       WHERE source = 'noaa' AND ended_at IS NULL AND NOT (source_id = ANY($1))
       RETURNING *
     )
     SELECT " <> alert.columns <> "
     FROM written a
     JOIN sea.source s ON s.id = a.source")
  |> pog.parameter(pog.array(pog.text, all_ids))
  |> pog.parameter(pog.timestamp(now))
  |> pog.returning(alert.row_decoder())
  |> pog.execute(conn)
  |> result.map(fn(x) { x.rows })
  |> result.map_error(err)
}

/// Marks all alerts whose `active_until` is in the past as expired.
/// Runs in its own transaction; call from the 60-second timer, not from
/// inside a NOAA write batch.
pub fn expire_due(
  now: Timestamp,
  conn: pog.Connection,
) -> Result(List(AlertRow), String) {
  pog.transaction(conn, fn(tx) {
    pog.query("WITH written AS (
         UPDATE sea.alert SET ended_at = $1, end_reason = 'expired'
         WHERE ended_at IS NULL AND active_until < $1
         RETURNING *
       )
       SELECT " <> alert.columns <> "
       FROM written a
       JOIN sea.source s ON s.id = a.source")
    |> pog.parameter(pog.timestamp(now))
    |> pog.returning(alert.row_decoder())
    |> pog.execute(tx)
    |> result.map(fn(x) { x.rows })
    |> result.map_error(err)
  })
  |> result.map_error(fn(x) {
    case x {
      pog.TransactionQueryError(e) -> err(e)
      pog.TransactionRolledBack(e) -> e
    }
  })
}

const insert_cap_sql = "
  WITH written AS (
    INSERT INTO sea.alert
      (source, source_id, sender, sender_name, identifier, message_type,
       event, category, severity, urgency, certainty, headline, description,
       instruction, web, contact, language, area_desc, geocodes, countries,
       geom, reference_keys, sent, effective, onset, expires, ends,
       active_until, first_seen_at, last_seen_at, ended_at, end_reason, superseded_by)
    VALUES
      ($1, $2, $3, $4, $5, $6,
       $7, $8, $9, $10, $11, $12, $13,
       $14, $15, $16, $17, $18, $19::jsonb, $20,
       ST_Multi(ST_CollectionExtract(ST_MakeValid(ST_SetSRID(ST_GeomFromGeoJSON($21::text), 4326)), 3)),
       $22, $23, $24, $25, $26, $27,
       $28, $29, $29, $30, $31, $32)
    ON CONFLICT (source, source_id) DO UPDATE SET
      sender = EXCLUDED.sender,
      sender_name = EXCLUDED.sender_name,
      identifier = EXCLUDED.identifier,
      message_type = EXCLUDED.message_type,
      event = EXCLUDED.event,
      category = EXCLUDED.category,
      severity = EXCLUDED.severity,
      urgency = EXCLUDED.urgency,
      certainty = EXCLUDED.certainty,
      headline = EXCLUDED.headline,
      description = EXCLUDED.description,
      instruction = EXCLUDED.instruction,
      web = EXCLUDED.web,
      contact = EXCLUDED.contact,
      language = EXCLUDED.language,
      area_desc = EXCLUDED.area_desc,
      geocodes = EXCLUDED.geocodes,
      countries = EXCLUDED.countries,
      geom = EXCLUDED.geom,
      reference_keys = EXCLUDED.reference_keys,
      sent = EXCLUDED.sent,
      effective = EXCLUDED.effective,
      onset = EXCLUDED.onset,
      expires = EXCLUDED.expires,
      ends = EXCLUDED.ends,
      active_until = EXCLUDED.active_until,
      last_seen_at = EXCLUDED.last_seen_at,
      ended_at = EXCLUDED.ended_at,
      end_reason = EXCLUDED.end_reason,
      superseded_by = EXCLUDED.superseded_by
    RETURNING *
  )
  SELECT "
  <> alert.columns
  <> "
  FROM written a
  JOIN sea.source s ON s.id = a.source"

const end_cap_sql = "
  WITH written AS (
    UPDATE sea.alert SET
      ended_at = $3, end_reason = $4, superseded_by = $5
    WHERE source = $1 AND source_id = $2 AND ended_at IS NULL
    RETURNING *
  )
  SELECT "
  <> alert.columns
  <> "
  FROM written a
  JOIN sea.source s ON s.id = a.source"

pub fn write_cap_rows(
  writes: List(AlertWrite),
  ends: List(EndInstruction),
  now: Timestamp,
  conn: pog.Connection,
) -> Result(AlertDiff, String) {
  use written_results <- result.try(
    writes
    |> list.try_map(fn(w) { write_one_cap_row(w, now, conn) }),
  )

  use ended_results <- result.try(
    ends
    |> list.try_map(fn(e) { end_one_cap_row(e, now, conn) }),
  )

  let #(already_ended, active_written) =
    list.partition(written_results, fn(triple) {
      let #(w, _, _) = triple
      option.is_some(w.ended_at)
    })

  let #(new_triples, updated_triples) =
    list.partition(active_written, fn(triple) {
      let #(_, _, is_new) = triple
      is_new
    })

  let ended_from_instructions = option.values(ended_results)
  let ended_from_writes = list.map(already_ended, fn(triple) { triple.1 })

  Ok(AlertDiff(
    new: list.map(new_triples, fn(triple) { triple.1 }),
    updated: list.map(updated_triples, fn(triple) { triple.1 }),
    ended: list.append(ended_from_writes, ended_from_instructions),
  ))
}

fn write_one_cap_row(
  write: AlertWrite,
  now: Timestamp,
  conn: pog.Connection,
) -> Result(#(AlertWrite, AlertRow, Bool), String) {
  use existing <- result.try(
    pog.query(
      "SELECT 1 FROM sea.alert WHERE source = $1 AND source_id = $2 FOR UPDATE",
    )
    |> pog.parameter(pog.text(write.source))
    |> pog.parameter(pog.text(write.source_id))
    |> pog.returning(decode.at([0], decode.int))
    |> pog.execute(conn)
    |> result.map(fn(x) { !list.is_empty(x.rows) })
    |> result.map_error(err),
  )

  use row <- result.try(
    bind_cap_params(pog.query(insert_cap_sql), write, now)
    |> pog.returning(alert.row_decoder())
    |> pog.execute(conn)
    |> result.map_error(err)
    |> result.try(fn(x) {
      case list.first(x.rows) {
        Ok(r) -> Ok(r)
        Error(Nil) ->
          Error(
            "failed to insert/update cap row: "
            <> write.source
            <> ":"
            <> write.source_id,
          )
      }
    }),
  )

  Ok(#(write, row, !existing))
}

fn end_one_cap_row(
  e: EndInstruction,
  now: Timestamp,
  conn: pog.Connection,
) -> Result(Option(AlertRow), String) {
  pog.query(end_cap_sql)
  |> pog.parameter(pog.text(e.source))
  |> pog.parameter(pog.text(e.source_id))
  |> pog.parameter(pog.timestamp(now))
  |> pog.parameter(pog.text(e.end_reason))
  |> pog.parameter(pog.nullable(pog.text, e.superseded_by))
  |> pog.returning(alert.row_decoder())
  |> pog.execute(conn)
  |> result.map(fn(x) { list.first(x.rows) |> option.from_result })
  |> result.map_error(err)
}

fn bind_cap_params(query, w: AlertWrite, now: Timestamp) {
  query
  |> pog.parameter(pog.text(w.source))
  |> pog.parameter(pog.text(w.source_id))
  |> pog.parameter(pog.nullable(pog.text, w.sender))
  |> pog.parameter(pog.nullable(pog.text, w.sender_name))
  |> pog.parameter(pog.nullable(pog.text, w.identifier))
  |> pog.parameter(pog.nullable(pog.text, w.message_type))
  |> pog.parameter(pog.text(w.event))
  |> pog.parameter(pog.array(pog.text, w.category))
  |> pog.parameter(pog.text(w.severity))
  |> pog.parameter(pog.text(w.urgency))
  |> pog.parameter(pog.text(w.certainty))
  |> pog.parameter(pog.nullable(pog.text, w.headline))
  |> pog.parameter(pog.nullable(pog.text, w.description))
  |> pog.parameter(pog.nullable(pog.text, w.instruction))
  |> pog.parameter(pog.nullable(pog.text, w.web))
  |> pog.parameter(pog.nullable(pog.text, w.contact))
  |> pog.parameter(pog.nullable(pog.text, w.language))
  |> pog.parameter(pog.text(w.area_desc))
  |> pog.parameter(pog.text(w.geocodes))
  |> pog.parameter(pog.array(pog.text, w.countries))
  |> pog.parameter(pog.nullable(pog.text, w.geom))
  |> pog.parameter(pog.array(pog.text, w.reference_keys))
  |> pog.parameter(pog.nullable(pog.timestamp, w.sent))
  |> pog.parameter(pog.nullable(pog.timestamp, w.effective))
  |> pog.parameter(pog.nullable(pog.timestamp, w.onset))
  |> pog.parameter(pog.nullable(pog.timestamp, w.expires))
  |> pog.parameter(pog.nullable(pog.timestamp, w.ends))
  |> pog.parameter(pog.timestamp(w.active_until))
  |> pog.parameter(pog.timestamp(now))
  |> pog.parameter(pog.nullable(pog.timestamp, w.ended_at))
  |> pog.parameter(pog.nullable(pog.text, w.end_reason))
  |> pog.parameter(pog.nullable(pog.text, w.superseded_by))
}

pub fn cleanup(cutoff: Timestamp, conn: pog.Connection) -> Result(Nil, String) {
  pog.transaction(conn, fn(tx) {
    use _ <- result.try(
      pog.query("DELETE FROM sea.alert WHERE ended_at < $1")
      |> pog.parameter(pog.timestamp(cutoff))
      |> pog.returning(decode.success(Nil))
      |> pog.execute(tx)
      |> result.map_error(err),
    )
    use _ <- result.try(
      pog.query("DELETE FROM sea.cap_message WHERE expires_at < $1")
      |> pog.parameter(pog.timestamp(cutoff))
      |> pog.returning(decode.success(Nil))
      |> pog.execute(tx)
      |> result.map_error(err),
    )
    pog.query(
      "DELETE FROM sea.cap_item WHERE last_seen_at < $1 AND state <> 'pending'",
    )
    |> pog.parameter(pog.timestamp(cutoff))
    |> pog.returning(decode.success(Nil))
    |> pog.execute(tx)
    |> result.map(fn(_) { Nil })
    |> result.map_error(err)
  })
  |> result.map_error(fn(x) {
    case x {
      pog.TransactionQueryError(e) -> err(e)
      pog.TransactionRolledBack(e) -> e
    }
  })
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
