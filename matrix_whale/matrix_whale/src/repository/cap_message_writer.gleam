import domain/alert
import domain/cap
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/order
import gleam/result
import gleam/string
import gleam/time/timestamp.{type Timestamp}
import intake/pipeline.{type Written, Written, WrittenExcept}
import intake/record.{type Incoming, type Key, Key}
import message/reciever/models/cap as models_cap
import pog
import repository/alert_writer.{type AlertDiff, AlertDiff}
import repository/cap_item_writer

pub type CapItemPayload {
  CapItemPayload(
    result: models_cap.CapFetchResult,
    msg: models_cap.CapMessage,
    owner_source_id: String,
    country_iso3: String,
  )
}

pub type CapBatchResult {
  CapBatchResult(diff: AlertDiff, dropped: Int)
}

type ProcessedOutcome {
  MessageProcessed(diff: AlertDiff, verdict: record.Verdict)
}

pub fn write_batch(
  records: List(Incoming(CapItemPayload)),
  now: Timestamp,
  conn: pog.Connection,
) -> Result(Written(CapBatchResult), String) {
  case records {
    [] ->
      Ok(Written(
        result: CapBatchResult(AlertDiff([], [], []), 0),
        new: 0,
        updated: 0,
        unchanged: 0,
        stale: 0,
      ))
    _ -> {
      let initial_acc = #(AlertDiff([], [], []), 0, 0, 0, 0, 0, [])

      use res <- result.try(
        list.try_fold(records, initial_acc, fn(acc, record) {
          let #(
            diff_acc,
            new_acc,
            up_acc,
            un_acc,
            st_acc,
            dr_acc,
            fail_keys_acc,
          ) = acc
          let payload = record.payload
          let cap_url = payload.result.cap_url
          let attempt_ts =
            cap.parse_rfc3339(payload.result.fetched_at) |> result.unwrap(now)

          case
            pog.transaction(conn, fn(tx) { process_one_record(record, now, tx) })
          {
            Ok(MessageProcessed(diff, verdict)) -> {
              let merged_diff = merge_diff(diff_acc, diff)
              case verdict {
                record.New ->
                  Ok(#(
                    merged_diff,
                    new_acc + 1,
                    up_acc,
                    un_acc,
                    st_acc,
                    dr_acc,
                    fail_keys_acc,
                  ))
                record.Updated(_) ->
                  Ok(#(
                    merged_diff,
                    new_acc,
                    up_acc + 1,
                    un_acc,
                    st_acc,
                    dr_acc,
                    fail_keys_acc,
                  ))
                record.Unchanged ->
                  Ok(#(
                    merged_diff,
                    new_acc,
                    up_acc,
                    un_acc + 1,
                    st_acc,
                    dr_acc,
                    fail_keys_acc,
                  ))
                record.Stale(_) ->
                  Ok(#(
                    merged_diff,
                    new_acc,
                    up_acc,
                    un_acc,
                    st_acc + 1,
                    dr_acc,
                    fail_keys_acc,
                  ))
              }
            }
            Error(tx_err) -> {
              let err_msg = case tx_err {
                pog.TransactionQueryError(e) -> err(e)
                pog.TransactionRolledBack(e) -> e
              }
              let _ =
                cap_item_writer.record_write_failure(
                  cap_url,
                  payload.result.http_status,
                  Some(err_msg),
                  attempt_ts,
                  now,
                  conn,
                )
              Ok(
                #(diff_acc, new_acc, up_acc, un_acc, st_acc, dr_acc + 1, [
                  record.key,
                  ..fail_keys_acc
                ]),
              )
            }
          }
        }),
      )

      let #(diff, new, updated, unchanged, stale, dropped, failed_keys) = res
      let batch_result = CapBatchResult(diff:, dropped:)

      case failed_keys {
        [] ->
          Ok(Written(result: batch_result, new:, updated:, unchanged:, stale:))
        _ ->
          Ok(WrittenExcept(
            result: batch_result,
            new:,
            updated:,
            unchanged:,
            stale:,
            failed_keys: list.reverse(failed_keys),
          ))
      }
    }
  }
}

fn merge_diff(d1: AlertDiff, d2: AlertDiff) -> AlertDiff {
  AlertDiff(
    new: list.append(d1.new, d2.new),
    updated: list.append(d1.updated, d2.updated),
    ended: list.append(d1.ended, d2.ended),
  )
}

fn process_one_record(
  record: Incoming(CapItemPayload),
  now: Timestamp,
  tx: pog.Connection,
) -> Result(ProcessedOutcome, String) {
  let key = case record.key {
    Key(_, k) -> k
  }
  let payload = record.payload
  let attempt_ts =
    cap.parse_rfc3339(payload.result.fetched_at) |> result.unwrap(now)

  use #(current_revs, current_sources) <- result.try(load_current([key], tx))
  let verdict = case record.classify([record], current_revs) {
    [pair] -> pair.1
    _ -> record.New
  }

  case verdict {
    record.Unchanged | record.Stale(_) -> {
      use _ <- result.try(touch_messages([key], now, tx))
      use _ <- result.try(mark_item_fetched(
        payload.result.cap_url,
        key,
        payload.result.http_status,
        attempt_ts,
        now,
        tx,
      ))
      Ok(MessageProcessed(AlertDiff([], [], []), verdict))
    }
    record.New | record.Updated(_) -> {
      let existing_meta =
        dict.get(current_sources, record.key) |> option.from_result
      let #(effective_source, effective_country) = case existing_meta {
        Some(#(src, ctry)) ->
          case ctry {
            "" -> #(src, payload.country_iso3)
            _ -> #(src, ctry)
          }
        None -> #(payload.owner_source_id, payload.country_iso3)
      }
      use diff <- result.try(write_one_message(
        payload,
        effective_source,
        effective_country,
        now,
        tx,
      ))
      Ok(MessageProcessed(diff, verdict))
    }
  }
}

fn split_keys(keys: List(String)) -> #(List(String), List(String)) {
  let pairs =
    list.map(keys, fn(k) {
      case string.split_once(k, ",") {
        Ok(#(s, i)) -> #(s, i)
        Error(Nil) -> #(k, "")
      }
    })
  #(list.map(pairs, fn(p) { p.0 }), list.map(pairs, fn(p) { p.1 }))
}

fn load_current(
  keys: List(String),
  tx: pog.Connection,
) -> Result(#(Dict(Key, Int), Dict(Key, #(String, String))), String) {
  case keys {
    [] -> Ok(#(dict.new(), dict.new()))
    _ -> {
      let #(senders, identifiers) = split_keys(keys)
      pog.query(
        "SELECT m.sender, m.identifier, m.sent_ms, m.source, a.country_iso3
         FROM sea.cap_message m
         LEFT JOIN sea.cap_authority a ON a.source = m.source
         JOIN (
           SELECT unnest($1::text[]) AS sender, unnest($2::text[]) AS identifier
         ) k ON m.sender = k.sender AND m.identifier = k.identifier
         FOR UPDATE OF m",
      )
      |> pog.parameter(pog.array(pog.text, senders))
      |> pog.parameter(pog.array(pog.text, identifiers))
      |> pog.returning(current_message_decoder())
      |> pog.execute(tx)
      |> result.map(fn(x) {
        list.fold(x.rows, #(dict.new(), dict.new()), fn(acc, row) {
          let #(rev_map, src_map) = acc
          let k = Key("cap", row.0)
          #(
            dict.insert(rev_map, k, row.1),
            dict.insert(src_map, k, #(row.2, row.3)),
          )
        })
      })
      |> result.map_error(err)
    }
  }
}

fn current_message_decoder() -> decode.Decoder(#(String, Int, String, String)) {
  use sender <- decode.field(0, decode.string)
  use identifier <- decode.field(1, decode.string)
  use sent_ms <- decode.field(2, decode.int)
  use source <- decode.field(3, decode.string)
  use country_iso3 <- decode.field(4, decode.optional(decode.string))
  let key = cap.message_key(sender, identifier)
  decode.success(#(key, sent_ms, source, option.unwrap(country_iso3, "")))
}

fn touch_messages(
  keys: List(String),
  now: Timestamp,
  tx: pog.Connection,
) -> Result(Nil, String) {
  case keys {
    [] -> Ok(Nil)
    _ -> {
      let #(senders, identifiers) = split_keys(keys)
      pog.query(
        "UPDATE sea.cap_message m
         SET last_seen_at = $3
         FROM (
           SELECT unnest($1::text[]) AS sender, unnest($2::text[]) AS identifier
         ) k
         WHERE m.sender = k.sender AND m.identifier = k.identifier",
      )
      |> pog.parameter(pog.array(pog.text, senders))
      |> pog.parameter(pog.array(pog.text, identifiers))
      |> pog.parameter(pog.timestamp(now))
      |> pog.returning(decode.success(Nil))
      |> pog.execute(tx)
      |> result.map(fn(_) { Nil })
      |> result.map_error(err)
    }
  }
}

const insert_cap_message_sql = "
  INSERT INTO sea.cap_message
    (sender, identifier, sent, sent_ms, status, msg_type, scope, source, feed_url, cap_url,
     reference_keys, cap, raw_xml, normalized, expires_at, first_seen_at, last_seen_at)
  VALUES
    ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10,
     $11, $12::jsonb, $13, $14, $15, $16, $16)
  ON CONFLICT (sender, identifier) DO UPDATE SET
    sent = EXCLUDED.sent,
    sent_ms = EXCLUDED.sent_ms,
    status = EXCLUDED.status,
    msg_type = EXCLUDED.msg_type,
    scope = EXCLUDED.scope,
    feed_url = EXCLUDED.feed_url,
    cap_url = EXCLUDED.cap_url,
    reference_keys = EXCLUDED.reference_keys,
    cap = EXCLUDED.cap,
    raw_xml = EXCLUDED.raw_xml,
    normalized = EXCLUDED.normalized,
    expires_at = EXCLUDED.expires_at,
    last_seen_at = EXCLUDED.last_seen_at"

fn write_one_message(
  payload: CapItemPayload,
  effective_source: String,
  effective_country: String,
  now: Timestamp,
  tx: pog.Connection,
) -> Result(AlertDiff, String) {
  let msg = payload.msg
  let res = payload.result
  let msg_key = cap.message_key(msg.sender, msg.identifier)
  let ref_keys = cap.parse_references(msg.references)
  let attempt_ts = cap.parse_rfc3339(res.fetched_at) |> result.unwrap(now)

  use sent_time <- result.try(
    cap.parse_rfc3339(msg.sent)
    |> result.replace_error("invalid sent timestamp"),
  )
  use expires_at <- result.try(cap.compute_message_expires_at(msg))
  let #(sec, nsec) = timestamp.to_unix_seconds_and_nanoseconds(sent_time)
  let sent_ms = sec * 1000 + nsec / 1_000_000
  let cap_json = option.unwrap(res.raw_cap_json, msg.raw_json)
  let raw_xml = option.unwrap(res.raw_xml, "")

  let norm_res = cap.normalize_alert(msg, effective_source, effective_country)

  let withdraw_instruction =
    alert.EndInstruction(
      source: effective_source,
      source_id: msg_key,
      end_reason: "withdrawn",
      superseded_by: None,
    )

  use #(should_norm, writes, ends) <- result.try(case norm_res {
    Ok(norm_alert) -> {
      let incoming_pub_id =
        cap.public_id(norm_alert.source, norm_alert.source_id)

      use stored_refs <- result.try(load_referencing_messages(msg_key, tx))
      use active_refs <- result.try(load_active_alert_refs(ref_keys, tx))

      let resolution =
        cap.resolve_supersede_and_cancel(
          msg.msg_type,
          msg.status,
          incoming_pub_id,
          stored_refs,
          active_refs,
          now,
        )

      let is_past_due = case timestamp.compare(norm_alert.active_until, now) {
        order.Lt | order.Eq -> True
        order.Gt -> False
      }

      let #(ended_at, end_reason, superseded_by) = case
        resolution.incoming_ending
      {
        cap.NotEnded ->
          case is_past_due {
            True -> #(Some(now), Some("expired"), None)
            False -> #(None, None, None)
          }
        cap.InsertedEnded(ended_at, end_reason, superseded_by) -> #(
          Some(ended_at),
          Some(end_reason),
          superseded_by,
        )
      }

      let alert_write =
        alert.AlertWrite(
          source: norm_alert.source,
          source_id: norm_alert.source_id,
          sender: norm_alert.sender,
          sender_name: norm_alert.sender_name,
          identifier: norm_alert.identifier,
          message_type: Some(norm_alert.message_type),
          event: norm_alert.event,
          category: norm_alert.category,
          severity: norm_alert.severity,
          urgency: norm_alert.urgency,
          certainty: norm_alert.certainty,
          headline: norm_alert.headline,
          description: norm_alert.description,
          instruction: norm_alert.instruction,
          web: norm_alert.web,
          contact: norm_alert.contact,
          language: norm_alert.language,
          area_desc: norm_alert.area_desc,
          geocodes: geocodes_to_json_string(norm_alert.geocodes),
          countries: norm_alert.countries,
          geom: norm_alert.geom,
          reference_keys: norm_alert.reference_keys,
          sent: norm_alert.sent,
          effective: norm_alert.effective,
          onset: norm_alert.onset,
          expires: norm_alert.expires,
          ends: norm_alert.ends,
          active_until: norm_alert.active_until,
          ended_at:,
          end_reason:,
          superseded_by:,
        )

      let end_instructions =
        list.map(resolution.rows_to_end, fn(action) {
          alert.EndInstruction(
            source: action.source,
            source_id: action.source_id,
            end_reason: action.end_reason,
            superseded_by: action.superseded_by,
          )
        })

      Ok(#(True, [alert_write], end_instructions))
    }

    Error(cap.InvalidSent) -> Error("invalid sent in CAP message")

    Error(cap.NoInfo) -> Ok(#(False, [], [withdraw_instruction]))

    Error(cap.NotEligible) -> {
      let is_cancel = string.lowercase(string.trim(msg.msg_type)) == "cancel"
      let is_actual = string.lowercase(string.trim(msg.status)) == "actual"
      case is_cancel && is_actual {
        True -> {
          use active_refs <- result.try(load_active_alert_refs(ref_keys, tx))
          let end_instructions =
            list.map(active_refs, fn(row) {
              alert.EndInstruction(
                source: row.source,
                source_id: row.source_id,
                end_reason: "cancelled",
                superseded_by: None,
              )
            })
          Ok(#(False, [], [withdraw_instruction, ..end_instructions]))
        }
        False -> Ok(#(False, [], [withdraw_instruction]))
      }
    }
  })

  // 1. Write raw sea.cap_message
  use _ <- result.try(
    pog.query(insert_cap_message_sql)
    |> pog.parameter(pog.text(msg.sender))
    |> pog.parameter(pog.text(msg.identifier))
    |> pog.parameter(pog.timestamp(sent_time))
    |> pog.parameter(pog.int(sent_ms))
    |> pog.parameter(pog.text(msg.status))
    |> pog.parameter(pog.text(msg.msg_type))
    |> pog.parameter(pog.text(msg.scope))
    |> pog.parameter(pog.text(effective_source))
    |> pog.parameter(pog.text(res.feed_url))
    |> pog.parameter(pog.text(res.cap_url))
    |> pog.parameter(pog.array(pog.text, ref_keys))
    |> pog.parameter(pog.text(cap_json))
    |> pog.parameter(pog.text(raw_xml))
    |> pog.parameter(pog.bool(should_norm))
    |> pog.parameter(pog.timestamp(expires_at))
    |> pog.parameter(pog.timestamp(now))
    |> pog.returning(decode.success(Nil))
    |> pog.execute(tx)
    |> result.map(fn(_) { Nil })
    |> result.map_error(err),
  )

  // 2. Mark item fetched
  use _ <- result.try(mark_item_fetched(
    res.cap_url,
    msg_key,
    res.http_status,
    attempt_ts,
    now,
    tx,
  ))

  // 3. Write normalized alert rows in the same transaction
  alert_writer.write_cap_rows(writes, ends, now, tx)
}

fn load_referencing_messages(
  key: String,
  tx: pog.Connection,
) -> Result(List(cap.StoredMessageRef), String) {
  pog.query(
    "SELECT sender, identifier, msg_type, status, scope, source, normalized
     FROM sea.cap_message
     WHERE reference_keys @> ARRAY[$1]",
  )
  |> pog.parameter(pog.text(key))
  |> pog.returning(stored_ref_decoder())
  |> pog.execute(tx)
  |> result.map(fn(x) { x.rows })
  |> result.map_error(err)
}

fn stored_ref_decoder() -> decode.Decoder(cap.StoredMessageRef) {
  use sender <- decode.field(0, decode.string)
  use identifier <- decode.field(1, decode.string)
  use msg_type <- decode.field(2, decode.string)
  use status <- decode.field(3, decode.string)
  use scope <- decode.field(4, decode.string)
  use source <- decode.field(5, decode.string)
  use normalized <- decode.field(6, decode.bool)
  let key = cap.message_key(sender, identifier)
  decode.success(cap.StoredMessageRef(
    key:,
    msg_type:,
    status:,
    scope:,
    public_id: cap.public_id(source, key),
    normalized:,
  ))
}

fn load_active_alert_refs(
  ref_keys: List(String),
  tx: pog.Connection,
) -> Result(List(cap.ActiveAlertRef), String) {
  case ref_keys {
    [] -> Ok([])
    _ -> {
      let #(senders, identifiers) = split_keys(list.unique(ref_keys))
      pog.query(
        "SELECT a.source, a.source_id
         FROM sea.alert a
         JOIN (
           SELECT m.source, (m.sender || ',' || m.identifier) AS source_id
           FROM sea.cap_message m
           JOIN (
             SELECT unnest($1::text[]) AS sender, unnest($2::text[]) AS identifier
           ) k ON m.sender = k.sender AND m.identifier = k.identifier
         ) s ON a.source = s.source AND a.source_id = s.source_id
         WHERE a.ended_at IS NULL",
      )
      |> pog.parameter(pog.array(pog.text, senders))
      |> pog.parameter(pog.array(pog.text, identifiers))
      |> pog.returning(active_ref_decoder())
      |> pog.execute(tx)
      |> result.map(fn(x) { x.rows })
      |> result.map_error(err)
    }
  }
}

fn active_ref_decoder() -> decode.Decoder(cap.ActiveAlertRef) {
  use source <- decode.field(0, decode.string)
  use source_id <- decode.field(1, decode.string)
  decode.success(cap.ActiveAlertRef(source:, source_id:))
}

fn mark_item_fetched(
  cap_url: String,
  message_key: String,
  http_status: Int,
  attempt_time: Timestamp,
  now: Timestamp,
  tx: pog.Connection,
) -> Result(Nil, String) {
  pog.query(
    "UPDATE sea.cap_item SET
       state = 'fetched',
       message_key = $2,
       http_status = $3,
       error = NULL,
       last_attempt_at = $4,
       last_seen_at = $5
     WHERE cap_url = $1",
  )
  |> pog.parameter(pog.text(cap_url))
  |> pog.parameter(pog.text(message_key))
  |> pog.parameter(pog.int(http_status))
  |> pog.parameter(pog.timestamp(attempt_time))
  |> pog.parameter(pog.timestamp(now))
  |> pog.returning(decode.success(Nil))
  |> pog.execute(tx)
  |> result.map(fn(_) { Nil })
  |> result.map_error(err)
}

fn geocodes_to_json_string(geocodes: List(models_cap.ValuePair)) -> String {
  geocodes
  |> list.map(fn(vp) {
    json.object([
      #("name", json.string(vp.value_name)),
      #("value", json.string(vp.value)),
    ])
  })
  |> json.preprocessed_array
  |> json.to_string
}

fn err(x: pog.QueryError) -> String {
  "Database error: " <> string.inspect(x)
}
