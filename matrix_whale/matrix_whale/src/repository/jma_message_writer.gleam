import domain/alert
import domain/jma
import gleam/dict
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
import gleam/time/duration
import gleam/time/timestamp.{type Timestamp}
import intake/record.{Incoming, Key}
import message/reciever/models/earthquake_feature.{IncomingEarthquake}
import message/reciever/models/jma as models_jma
import pog
import repository/alert_writer.{type AlertDiff, AlertDiff}
import repository/earthquake_writer.{type EarthquakeDiff, EarthquakeDiff}
import repository/event_writer.{EventDiff}

pub type JmaBatchResult {
  JmaBatchResult(
    written: Int,
    deduped: Int,
    dropped: Int,
    alert_diff: AlertDiff,
    earthquake_diff: EarthquakeDiff,
    resync_earthquakes: Bool,
  )
}

pub type WatermarkDecision {
  WatermarkProceed
  WatermarkRejectStale
}

pub fn write_batch(
  results: List(models_jma.JmaFetchResult),
  now: Timestamp,
  conn: pog.Connection,
) -> Result(JmaBatchResult, String) {
  case results {
    [] ->
      Ok(JmaBatchResult(
        written: 0,
        deduped: 0,
        dropped: 0,
        alert_diff: AlertDiff([], [], []),
        earthquake_diff: EarthquakeDiff([], [], EventDiff([], [], 0)),
        resync_earthquakes: False,
      ))
    _ -> {
      pog.transaction(conn, fn(tx) { write_batch_tx(results, now, tx) })
      |> result.map_error(fn(x) {
        case x {
          pog.TransactionQueryError(e) -> err(e)
          pog.TransactionRolledBack(e) -> e
        }
      })
    }
  }
}

fn write_batch_tx(
  results: List(models_jma.JmaFetchResult),
  now: Timestamp,
  tx: pog.Connection,
) -> Result(JmaBatchResult, String) {
  let initial = #(
    0,
    0,
    0,
    AlertDiff([], [], []),
    EarthquakeDiff([], [], EventDiff([], [], 0)),
    False,
  )

  use #(written, deduped, dropped, alert_diff, eq_diff, resync_eq) <- result.try(
    list.try_fold(results, initial, fn(acc, res) {
      let #(w_acc, d_acc, dr_acc, ad_acc, ed_acc, resync_acc) = acc
      use item_res <- result.try(process_one_result(res, now, tx))
      let #(w, d, dr, ad, ed, resync) = item_res
      Ok(#(
        w_acc + w,
        d_acc + d,
        dr_acc + dr,
        merge_alert_diff(ad_acc, ad),
        merge_earthquake_diff(ed_acc, ed),
        resync_acc || resync,
      ))
    }),
  )

  Ok(JmaBatchResult(
    written:,
    deduped:,
    dropped:,
    alert_diff:,
    earthquake_diff: eq_diff,
    resync_earthquakes: resync_eq,
  ))
}

fn process_one_result(
  res: models_jma.JmaFetchResult,
  now: Timestamp,
  tx: pog.Connection,
) -> Result(#(Int, Int, Int, AlertDiff, EarthquakeDiff, Bool), String) {
  let empty_eq_diff = EarthquakeDiff([], [], EventDiff([], [], 0))
  let empty_alert_diff = AlertDiff([], [], [])

  // 1. Permanent error (terminal outcome): HTTP 400/404/410 or HTTP 200 with parse error
  let is_terminal = jma.is_terminal_error(res.http_status, res.error)

  case is_terminal {
    True -> {
      use _ <- result.try(ensure_item_exists(
        res.item_url,
        res.feed_url,
        now,
        tx,
      ))
      use is_already_terminal <- result.try(check_item_terminal_or_ingested(
        res.item_url,
        tx,
      ))
      case is_already_terminal {
        True -> Ok(#(0, 1, 0, empty_alert_diff, empty_eq_diff, False))
        False -> {
          let err_msg =
            option.unwrap(
              res.error,
              "HTTP error status " <> string.inspect(res.http_status),
            )
          use _ <- result.try(record_item_terminal(
            res.item_url,
            res.http_status,
            err_msg,
            res.raw_xml,
            now,
            tx,
          ))
          Ok(#(1, 0, 0, empty_alert_diff, empty_eq_diff, False))
        }
      }
    }
    False -> {
      case res.error, res.message {
        Some(err_msg), _ -> {
          // Transient error: retryable in /pending
          use _ <- result.try(ensure_item_exists(
            res.item_url,
            res.feed_url,
            now,
            tx,
          ))
          use _ <- result.try(record_item_failure(
            res.item_url,
            res.http_status,
            err_msg,
            now,
            tx,
          ))
          Ok(#(0, 0, 1, empty_alert_diff, empty_eq_diff, False))
        }
        None, None -> {
          // Missing message payload
          use _ <- result.try(ensure_item_exists(
            res.item_url,
            res.feed_url,
            now,
            tx,
          ))
          use _ <- result.try(record_item_failure(
            res.item_url,
            res.http_status,
            "missing message payload",
            now,
            tx,
          ))
          Ok(#(0, 0, 1, empty_alert_diff, empty_eq_diff, False))
        }
        None, Some(msg) -> {
          // Ensure sea.jma_item exists
          use _ <- result.try(ensure_item_exists(
            res.item_url,
            res.feed_url,
            now,
            tx,
          ))

          // Authoritative sent timestamp MUST be valid RFC3339; never infer now!
          case jma.parse_rfc3339(msg.sent) {
            Error(_) -> {
              use _ <- result.try(record_item_failure(
                res.item_url,
                res.http_status,
                "invalid sent timestamp: " <> msg.sent,
                now,
                tx,
              ))
              Ok(#(0, 0, 1, empty_alert_diff, empty_eq_diff, False))
            }
            Ok(sent_ts) -> {
              let series_key = compute_series_key(msg)

              // Atomic claim on sea.jma_message
              use is_claimed <- result.try(claim_jma_message(
                res,
                msg,
                Some(series_key),
                sent_ts,
                now,
                tx,
              ))

              case is_claimed {
                False -> {
                  // Message already ingested; dedup without re-normalization
                  use _ <- result.try(record_item_ingested(
                    res.item_url,
                    msg.identifier,
                    res.http_status,
                    now,
                    tx,
                  ))
                  Ok(#(0, 1, 0, empty_alert_diff, empty_eq_diff, False))
                }
                True -> {
                  let is_live = jma.is_live_status(msg.status)
                  let is_cancel = jma.is_cancel(msg.info_type)
                  let is_normalizable =
                    jma.is_normalizable_info_type(msg.info_type)

                  case is_live && is_normalizable {
                    False -> {
                      // Drill/test or non-normalizable InfoType:
                      // Archival only in sea.jma_message (normalized = false)
                      use _ <- result.try(record_item_ingested(
                        res.item_url,
                        msg.identifier,
                        res.http_status,
                        now,
                        tx,
                      ))
                      Ok(#(1, 0, 0, empty_alert_diff, empty_eq_diff, False))
                    }
                    True -> {
                      // Live normalizable message! Check report type gating.
                      let is_quake_msg =
                        jma.is_supported_earthquake_report(msg.control_title)
                      let is_alert_msg =
                        jma.is_supported_alert_report(msg.control_title)

                      case is_quake_msg, is_alert_msg {
                        True, _ -> {
                          // Supported earthquake report (震源に関する情報 or 震源・震度に関する情報)
                          let watermark_key =
                            "quake:"
                            <> option.unwrap(msg.event_id, msg.identifier)
                          let watermark_kind = "earthquake"

                          use decision <- result.try(check_and_update_watermark(
                            watermark_key,
                            watermark_kind,
                            sent_ts,
                            is_cancel,
                            msg.info_type,
                            msg.identifier,
                            tx,
                          ))

                          case decision {
                            WatermarkRejectStale -> {
                              use _ <- result.try(record_item_ingested(
                                res.item_url,
                                msg.identifier,
                                res.http_status,
                                now,
                                tx,
                              ))
                              Ok(#(
                                1,
                                0,
                                0,
                                empty_alert_diff,
                                empty_eq_diff,
                                False,
                              ))
                            }
                            WatermarkProceed -> {
                              use #(eq_diff, resync_eq) <- result.try(
                                case is_cancel {
                                  True ->
                                    handle_earthquake_cancellation(
                                      msg,
                                      sent_ts,
                                      tx,
                                    )
                                  False -> {
                                    use diff <- result.try(
                                      handle_earthquake_live(
                                        msg,
                                        res.raw_xml,
                                        res.item_url,
                                        sent_ts,
                                        now,
                                        tx,
                                      ),
                                    )
                                    Ok(#(diff, False))
                                  }
                                },
                              )

                              let has_normalized_content =
                                eq_diff.new != []
                                || eq_diff.updated != []
                                || resync_eq

                              use _ <- result.try(case has_normalized_content {
                                True ->
                                  mark_message_normalized(msg.identifier, tx)
                                False -> Ok(Nil)
                              })

                              use _ <- result.try(record_item_ingested(
                                res.item_url,
                                msg.identifier,
                                res.http_status,
                                now,
                                tx,
                              ))

                              Ok(#(
                                1,
                                0,
                                0,
                                empty_alert_diff,
                                eq_diff,
                                resync_eq,
                              ))
                            }
                          }
                        }
                        False, True -> {
                          // Supported alert report (気象特別警報・警報・注意報 or 気象警報・注意報)
                          let watermark_key = "alert:" <> series_key
                          let watermark_kind = "alert"

                          use decision <- result.try(check_and_update_watermark(
                            watermark_key,
                            watermark_kind,
                            sent_ts,
                            is_cancel,
                            msg.info_type,
                            msg.identifier,
                            tx,
                          ))

                          case decision {
                            WatermarkRejectStale -> {
                              use _ <- result.try(record_item_ingested(
                                res.item_url,
                                msg.identifier,
                                res.http_status,
                                now,
                                tx,
                              ))
                              Ok(#(
                                1,
                                0,
                                0,
                                empty_alert_diff,
                                empty_eq_diff,
                                False,
                              ))
                            }
                            WatermarkProceed -> {
                              use alert_diff <- result.try(case is_cancel {
                                True ->
                                  handle_alert_cancellation(
                                    msg,
                                    Some(series_key),
                                    sent_ts,
                                    now,
                                    tx,
                                  )
                                False ->
                                  handle_alert_live(
                                    msg,
                                    Some(series_key),
                                    sent_ts,
                                    now,
                                    tx,
                                  )
                              })

                              let has_normalized_content =
                                alert_diff.new != []
                                || alert_diff.updated != []
                                || alert_diff.ended != []

                              use _ <- result.try(case has_normalized_content {
                                True ->
                                  mark_message_normalized(msg.identifier, tx)
                                False -> Ok(Nil)
                              })

                              use _ <- result.try(record_item_ingested(
                                res.item_url,
                                msg.identifier,
                                res.http_status,
                                now,
                                tx,
                              ))

                              Ok(#(1, 0, 0, alert_diff, empty_eq_diff, False))
                            }
                          }
                        }
                        False, False -> {
                          // Unsupported report type (e.g. tsunami, volcano).
                          // Archive metadata in sea.jma_message (already claimed),
                          // do NOT touch quake or alert tables or advance watermarks.
                          use _ <- result.try(record_item_ingested(
                            res.item_url,
                            msg.identifier,
                            res.http_status,
                            now,
                            tx,
                          ))
                          Ok(#(1, 0, 0, empty_alert_diff, empty_eq_diff, False))
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}

fn check_and_update_watermark(
  series_key: String,
  kind: String,
  sent_ts: Timestamp,
  is_cancel: Bool,
  info_type: String,
  identifier: String,
  tx: pog.Connection,
) -> Result(WatermarkDecision, String) {
  use existing_res <- result.try(
    pog.query(
      "SELECT latest_sent, is_cancelled, latest_identifier
       FROM sea.jma_series
       WHERE series_key = $1
       FOR UPDATE",
    )
    |> pog.parameter(pog.text(series_key))
    |> pog.returning({
      use latest_sent <- decode.field(0, alert.timestamptz_decoder())
      use is_cancelled <- decode.field(1, decode.bool)
      use latest_identifier <- decode.field(2, decode.string)
      decode.success(#(latest_sent, is_cancelled, latest_identifier))
    })
    |> pog.execute(tx)
    |> result.map_error(err),
  )

  case existing_res.rows {
    [] -> {
      pog.query(
        "INSERT INTO sea.jma_series (series_key, kind, latest_sent, is_cancelled, latest_identifier, updated_at)
         VALUES ($1, $2, $3, $4, $5, now())",
      )
      |> pog.parameter(pog.text(series_key))
      |> pog.parameter(pog.text(kind))
      |> pog.parameter(pog.timestamp(sent_ts))
      |> pog.parameter(pog.bool(is_cancel))
      |> pog.parameter(pog.text(identifier))
      |> pog.returning(decode.success(Nil))
      |> pog.execute(tx)
      |> result.map(fn(_) { WatermarkProceed })
      |> result.map_error(err)
    }
    [#(existing_sent, existing_cancelled, existing_id)] -> {
      case timestamp.compare(sent_ts, existing_sent) {
        order.Lt -> Ok(WatermarkRejectStale)
        order.Gt -> {
          pog.query(
            "UPDATE sea.jma_series
             SET latest_sent = $1, is_cancelled = $2, latest_identifier = $3, updated_at = now()
             WHERE series_key = $4",
          )
          |> pog.parameter(pog.timestamp(sent_ts))
          |> pog.parameter(pog.bool(is_cancel))
          |> pog.parameter(pog.text(identifier))
          |> pog.parameter(pog.text(series_key))
          |> pog.returning(decode.success(Nil))
          |> pog.execute(tx)
          |> result.map(fn(_) { WatermarkProceed })
          |> result.map_error(err)
        }
        order.Eq -> {
          case existing_cancelled {
            True -> Ok(WatermarkRejectStale)
            False -> {
              case is_cancel {
                True -> {
                  pog.query(
                    "UPDATE sea.jma_series
                     SET is_cancelled = true, latest_identifier = $1, updated_at = now()
                     WHERE series_key = $2",
                  )
                  |> pog.parameter(pog.text(identifier))
                  |> pog.parameter(pog.text(series_key))
                  |> pog.returning(decode.success(Nil))
                  |> pog.execute(tx)
                  |> result.map(fn(_) { WatermarkProceed })
                  |> result.map_error(err)
                }
                False -> {
                  case info_type == "訂正" {
                    True -> {
                      case string.compare(identifier, existing_id) {
                        order.Gt | order.Eq -> {
                          pog.query(
                            "UPDATE sea.jma_series
                             SET latest_identifier = $1, updated_at = now()
                             WHERE series_key = $2",
                          )
                          |> pog.parameter(pog.text(identifier))
                          |> pog.parameter(pog.text(series_key))
                          |> pog.returning(decode.success(Nil))
                          |> pog.execute(tx)
                          |> result.map(fn(_) { WatermarkProceed })
                          |> result.map_error(err)
                        }
                        order.Lt -> Ok(WatermarkRejectStale)
                      }
                    }
                    False -> {
                      case string.compare(identifier, existing_id) {
                        order.Gt -> {
                          pog.query(
                            "UPDATE sea.jma_series
                             SET latest_identifier = $1, updated_at = now()
                             WHERE series_key = $2",
                          )
                          |> pog.parameter(pog.text(identifier))
                          |> pog.parameter(pog.text(series_key))
                          |> pog.returning(decode.success(Nil))
                          |> pog.execute(tx)
                          |> result.map(fn(_) { WatermarkProceed })
                          |> result.map_error(err)
                        }
                        order.Lt | order.Eq -> Ok(WatermarkRejectStale)
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
    _ -> Ok(WatermarkProceed)
  }
}

fn check_item_terminal_or_ingested(
  item_url: String,
  tx: pog.Connection,
) -> Result(Bool, String) {
  pog.query("SELECT state FROM sea.jma_item WHERE item_url = $1 FOR UPDATE")
  |> pog.parameter(pog.text(item_url))
  |> pog.returning(decode.at([0], decode.string))
  |> pog.execute(tx)
  |> result.map(fn(res) {
    case res.rows {
      ["terminal"] | ["ingested"] -> True
      _ -> False
    }
  })
  |> result.map_error(err)
}

fn record_item_terminal(
  item_url: String,
  http_status: Int,
  err_msg: String,
  raw_xml: Option(String),
  now: Timestamp,
  tx: pog.Connection,
) -> Result(Nil, String) {
  pog.query(
    "UPDATE sea.jma_item
     SET state = 'terminal', http_status = $1, error = $2, raw_xml = $3, last_attempt_at = $4, last_seen_at = $4
     WHERE item_url = $5",
  )
  |> pog.parameter(pog.int(http_status))
  |> pog.parameter(pog.text(err_msg))
  |> pog.parameter(pog.nullable(pog.text, raw_xml))
  |> pog.parameter(pog.timestamp(now))
  |> pog.parameter(pog.text(item_url))
  |> pog.returning(decode.success(Nil))
  |> pog.execute(tx)
  |> result.map(fn(_) { Nil })
  |> result.map_error(err)
}

fn ensure_item_exists(
  item_url: String,
  feed_url: String,
  now: Timestamp,
  tx: pog.Connection,
) -> Result(Nil, String) {
  pog.query(
    "INSERT INTO sea.jma_item (item_url, feed_url, first_seen_at, last_seen_at)
     VALUES ($1, $2, $3, $3)
     ON CONFLICT (item_url) DO UPDATE SET last_seen_at = EXCLUDED.last_seen_at",
  )
  |> pog.parameter(pog.text(item_url))
  |> pog.parameter(pog.text(feed_url))
  |> pog.parameter(pog.timestamp(now))
  |> pog.returning(decode.success(Nil))
  |> pog.execute(tx)
  |> result.map(fn(_) { Nil })
  |> result.map_error(err)
}

fn compute_series_key(msg: models_jma.JmaMessageContent) -> String {
  case msg.series_key {
    Some(k) -> k
    None -> {
      case msg.event_id {
        Some(eid) -> eid
        None -> {
          case msg.areas {
            [first_area, ..] -> msg.control_title <> ":" <> first_area.geocode
            [] -> msg.control_title
          }
        }
      }
    }
  }
}

const claim_message_sql = "
  INSERT INTO sea.jma_message
    (identifier, item_url, feed_url, control_title, status, info_type, event_id, series_key, sent, headline, description, raw_xml, normalized, first_seen_at, last_seen_at)
  VALUES
    ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, false, $13, $13)
  ON CONFLICT (identifier) DO NOTHING
  RETURNING identifier"

fn claim_jma_message(
  res: models_jma.JmaFetchResult,
  msg: models_jma.JmaMessageContent,
  series_key: Option(String),
  sent_ts: Timestamp,
  now: Timestamp,
  tx: pog.Connection,
) -> Result(Bool, String) {
  let raw_xml = option.unwrap(res.raw_xml, "")

  pog.query(claim_message_sql)
  |> pog.parameter(pog.text(msg.identifier))
  |> pog.parameter(pog.text(res.item_url))
  |> pog.parameter(pog.text(res.feed_url))
  |> pog.parameter(pog.text(msg.control_title))
  |> pog.parameter(pog.text(msg.status))
  |> pog.parameter(pog.text(msg.info_type))
  |> pog.parameter(pog.nullable(pog.text, msg.event_id))
  |> pog.parameter(pog.nullable(pog.text, series_key))
  |> pog.parameter(pog.timestamp(sent_ts))
  |> pog.parameter(pog.nullable(pog.text, msg.headline))
  |> pog.parameter(pog.nullable(pog.text, msg.description))
  |> pog.parameter(pog.text(raw_xml))
  |> pog.parameter(pog.timestamp(now))
  |> pog.returning(decode.at([0], decode.string))
  |> pog.execute(tx)
  |> result.map(fn(query_res) { query_res.rows != [] })
  |> result.map_error(err)
}

fn mark_message_normalized(
  identifier: String,
  tx: pog.Connection,
) -> Result(Nil, String) {
  pog.query(
    "UPDATE sea.jma_message SET normalized = true WHERE identifier = $1",
  )
  |> pog.parameter(pog.text(identifier))
  |> pog.returning(decode.success(Nil))
  |> pog.execute(tx)
  |> result.map(fn(_) { Nil })
  |> result.map_error(err)
}

fn record_item_failure(
  item_url: String,
  http_status: Int,
  err_msg: String,
  now: Timestamp,
  tx: pog.Connection,
) -> Result(Nil, String) {
  pog.query(
    "UPDATE sea.jma_item
     SET state = 'failed', attempts = attempts + 1, last_attempt_at = $1, http_status = $2, error = $3, last_seen_at = $1
     WHERE item_url = $4",
  )
  |> pog.parameter(pog.timestamp(now))
  |> pog.parameter(pog.int(http_status))
  |> pog.parameter(pog.text(err_msg))
  |> pog.parameter(pog.text(item_url))
  |> pog.returning(decode.success(Nil))
  |> pog.execute(tx)
  |> result.map(fn(_) { Nil })
  |> result.map_error(err)
}

fn record_item_ingested(
  item_url: String,
  identifier: String,
  http_status: Int,
  now: Timestamp,
  tx: pog.Connection,
) -> Result(Nil, String) {
  pog.query(
    "UPDATE sea.jma_item
     SET state = 'ingested', identifier = $1, last_attempt_at = $2, http_status = $3, error = NULL, last_seen_at = $2
     WHERE item_url = $4",
  )
  |> pog.parameter(pog.text(identifier))
  |> pog.parameter(pog.timestamp(now))
  |> pog.parameter(pog.int(http_status))
  |> pog.parameter(pog.text(item_url))
  |> pog.returning(decode.success(Nil))
  |> pog.execute(tx)
  |> result.map(fn(_) { Nil })
  |> result.map_error(err)
}

fn handle_earthquake_cancellation(
  msg: models_jma.JmaMessageContent,
  sent_ts: Timestamp,
  tx: pog.Connection,
) -> Result(#(EarthquakeDiff, Bool), String) {
  let eq_id = option.unwrap(msg.event_id, msg.identifier)
  let #(sec, nano) = timestamp.to_unix_seconds_and_nanoseconds(sent_ts)
  let sent_ms = sec * 1000 + nano / 1_000_000

  // 1. Find all canonical events containing this JMA earthquake
  use event_rows <- result.try(
    pog.query(
      "SELECT event_id FROM sea.event_member WHERE source = 'jma' AND source_id = $1",
    )
    |> pog.parameter(pog.text(eq_id))
    |> pog.returning(decode.at([0], decode.int))
    |> pog.execute(tx)
    |> result.map(fn(res) { res.rows })
    |> result.map_error(err),
  )

  // 2. Mark earthquake deleted in sea.earthquake (preserving revision and member links)
  use _ <- result.try(
    pog.query(
      "UPDATE sea.earthquake
       SET status = 'deleted', updated_at = to_timestamp($1::double precision/1000), updated_at_ms = $1, last_seen_at = now()
       WHERE source = 'jma' AND source_id = $2",
    )
    |> pog.parameter(pog.int(sent_ms))
    |> pog.parameter(pog.text(eq_id))
    |> pog.returning(decode.success(Nil))
    |> pog.execute(tx)
    |> result.map(fn(_) { Nil })
    |> result.map_error(err),
  )

  // 3. For each affected event, reproject via event_writer:
  use #(updated_events, has_orphan) <- result.try(
    list.try_fold(event_rows, #([], False), fn(acc, eid) {
      let #(upd_acc, orphan_acc) = acc
      use view <- result.try(event_writer.reproject(eid, tx))
      let is_orphan = view.event.status == Some("deleted")
      Ok(#([view, ..upd_acc], orphan_acc || is_orphan))
    }),
  )

  let eq_diff =
    EarthquakeDiff(
      new: [],
      updated: [],
      events: EventDiff(new: [], updated: updated_events, matched: 0),
    )
  Ok(#(eq_diff, has_orphan))
}

fn handle_earthquake_live(
  msg: models_jma.JmaMessageContent,
  raw_xml: Option(String),
  item_url: String,
  sent_ts: Timestamp,
  now: Timestamp,
  tx: pog.Connection,
) -> Result(EarthquakeDiff, String) {
  let empty = EarthquakeDiff([], [], EventDiff([], [], 0))
  case msg.earthquake {
    None -> Ok(empty)
    Some(eq) -> {
      case eq.latitude, eq.longitude, jma.parse_rfc3339(eq.origin_time) {
        Some(lat), Some(lon), Ok(origin_ts) -> {
          // Bounds check: lat [-90, 90], lon [-180, 180]
          case
            lat >=. -90.0 && lat <=. 90.0 && lon >=. -180.0 && lon <=. 180.0
          {
            False -> Ok(empty)
            True -> {
              let source_id = option.unwrap(msg.event_id, msg.identifier)
              let #(origin_sec, origin_nano) =
                timestamp.to_unix_seconds_and_nanoseconds(origin_ts)
              let #(sent_sec, sent_nano) =
                timestamp.to_unix_seconds_and_nanoseconds(sent_ts)
              let origin_ms = origin_sec * 1000 + origin_nano / 1_000_000
              let sent_ms = sent_sec * 1000 + sent_nano / 1_000_000

              let #(now_sec, now_nano) =
                timestamp.to_unix_seconds_and_nanoseconds(now)
              let now_ms = now_sec * 1000 + now_nano / 1_000_000

              let raw_json =
                json.to_string(
                  json.object([
                    #("source", json.string("jma")),
                    #("identifier", json.string(msg.identifier)),
                    #("raw_xml", json.string(option.unwrap(raw_xml, ""))),
                  ]),
                )

              let incoming_eq =
                IncomingEarthquake(
                  source_id:,
                  ids: [source_id],
                  sources: ["jma"],
                  net: Some("jma"),
                  code: Some(source_id),
                  mag: eq.magnitude,
                  mag_type: eq.magnitude_type,
                  time: origin_ms,
                  updated: sent_ms,
                  place: eq.place,
                  title: msg.headline,
                  status: None,
                  type_: Some("earthquake"),
                  tsunami: None,
                  sig: None,
                  alert: None,
                  mmi: None,
                  cdi: None,
                  felt: None,
                  nst: None,
                  dmin: None,
                  rms: None,
                  gap: None,
                  url: Some(item_url),
                  detail: None,
                  lon:,
                  lat:,
                  depth: eq.depth_km,
                  raw: raw_json,
                )

              let record =
                Incoming(
                  key: Key(source: "jma", source_id:),
                  revision: sent_ms,
                  payload: incoming_eq,
                )

              earthquake_writer.write_batch_tx([record], now_ms, tx)
              |> result.map(fn(written) { written.result })
              |> result.map_error(fn(e) {
                "Failed to write JMA earthquake: " <> e
              })
            }
          }
        }
        _, _, _ -> Ok(empty)
      }
    }
  }
}

fn handle_alert_cancellation(
  msg: models_jma.JmaMessageContent,
  series_key: Option(String),
  sent_ts: Timestamp,
  now: Timestamp,
  tx: pog.Connection,
) -> Result(AlertDiff, String) {
  case msg.alerts {
    [_, ..] -> {
      // Cancellation has explicit alert items
      let keys = list.map(msg.alerts, fn(a) { a.lifecycle_key })
      pog.query("WITH written AS (
           UPDATE sea.alert
           SET ended_at = $1, end_reason = 'cancelled', last_seen_at = $2
           WHERE source = 'jma'
             AND source_id = ANY($3)
             AND ended_at IS NULL
             AND sent <= $1
           RETURNING *
         )
         SELECT " <> alert.columns <> "
         FROM written a
         JOIN sea.source s ON s.id = a.source")
      |> pog.parameter(pog.timestamp(sent_ts))
      |> pog.parameter(pog.timestamp(now))
      |> pog.parameter(pog.array(pog.text, keys))
      |> pog.returning(alert.row_decoder())
      |> pog.execute(tx)
      |> result.map(fn(res) { AlertDiff(new: [], updated: [], ended: res.rows) })
      |> result.map_error(err)
    }
    [] -> {
      // Bodyless bulletin cancellation: cancel prior alerts belonging to this series
      case series_key {
        Some(sk) -> {
          pog.query("WITH written AS (
               UPDATE sea.alert
               SET ended_at = $1, end_reason = 'cancelled', last_seen_at = $2
               WHERE source = 'jma'
                 AND ended_at IS NULL
                 AND sent <= $1
                 AND (
                   $3 = ANY(reference_keys)
                   OR identifier IN (SELECT identifier FROM sea.jma_message WHERE series_key = $3)
                 )
               RETURNING *
             )
             SELECT " <> alert.columns <> "
             FROM written a
             JOIN sea.source s ON s.id = a.source")
          |> pog.parameter(pog.timestamp(sent_ts))
          |> pog.parameter(pog.timestamp(now))
          |> pog.parameter(pog.text(sk))
          |> pog.returning(alert.row_decoder())
          |> pog.execute(tx)
          |> result.map(fn(res) {
            AlertDiff(new: [], updated: [], ended: res.rows)
          })
          |> result.map_error(err)
        }
        None -> {
          let match_id = option.unwrap(msg.event_id, msg.identifier)
          pog.query("WITH written AS (
               UPDATE sea.alert
               SET ended_at = $1, end_reason = 'cancelled', last_seen_at = $2
               WHERE source = 'jma'
                 AND ended_at IS NULL
                 AND sent <= $1
                 AND (
                   $3 = ANY(reference_keys)
                   OR identifier = $3
                 )
               RETURNING *
             )
             SELECT " <> alert.columns <> "
             FROM written a
             JOIN sea.source s ON s.id = a.source")
          |> pog.parameter(pog.timestamp(sent_ts))
          |> pog.parameter(pog.timestamp(now))
          |> pog.parameter(pog.text(match_id))
          |> pog.returning(alert.row_decoder())
          |> pog.execute(tx)
          |> result.map(fn(res) {
            AlertDiff(new: [], updated: [], ended: res.rows)
          })
          |> result.map_error(err)
        }
      }
    }
  }
}

const upsert_alert_sql = "
  WITH written AS (
    INSERT INTO sea.alert (
      source, source_id, identifier, message_type, event, category, severity, urgency, certainty,
      headline, description, language, area_desc, geocodes, countries, geom, reference_keys,
      sent, effective, expires, active_until, first_seen_at, last_seen_at
    ) VALUES (
      'jma', $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, 'ja', $11, $12::jsonb, ARRAY['JPN'],
      (SELECT ST_Multi(ST_Union(ja.geom)) FROM sea.jma_area ja WHERE ja.code = ANY($19)),
      $13, $14, $15, $16, $17, $18, $18
    )
    ON CONFLICT (source, source_id) DO UPDATE SET
      identifier = EXCLUDED.identifier,
      message_type = EXCLUDED.message_type,
      event = EXCLUDED.event,
      category = EXCLUDED.category,
      severity = EXCLUDED.severity,
      urgency = EXCLUDED.urgency,
      certainty = EXCLUDED.certainty,
      headline = EXCLUDED.headline,
      description = EXCLUDED.description,
      area_desc = EXCLUDED.area_desc,
      geocodes = EXCLUDED.geocodes,
      geom = EXCLUDED.geom,
      reference_keys = EXCLUDED.reference_keys,
      sent = EXCLUDED.sent,
      effective = EXCLUDED.effective,
      expires = EXCLUDED.expires,
      active_until = EXCLUDED.active_until,
      last_seen_at = EXCLUDED.last_seen_at,
      ended_at = NULL,
      end_reason = NULL
    WHERE (EXCLUDED.sent > sea.alert.sent)
       OR (EXCLUDED.sent = sea.alert.sent AND (EXCLUDED.message_type = '訂正' OR EXCLUDED.identifier >= sea.alert.identifier))
       OR (sea.alert.sent IS NULL)
    RETURNING *
  )
  SELECT "
  <> alert.columns
  <> "
  FROM written a
  JOIN sea.source s ON s.id = a.source"

fn handle_alert_live(
  msg: models_jma.JmaMessageContent,
  series_key: Option(String),
  sent_ts: Timestamp,
  now: Timestamp,
  tx: pog.Connection,
) -> Result(AlertDiff, String) {
  let effective_ts =
    option.then(msg.effective, fn(s) {
      option.from_result(jma.parse_rfc3339(s))
    })
    |> option.unwrap(sent_ts)
  let expires_ts =
    option.then(msg.expires, fn(s) { option.from_result(jma.parse_rfc3339(s)) })
  let active_until = case expires_ts {
    Some(ts) -> ts
    None -> timestamp.add(sent_ts, duration.hours(24))
  }

  let ref_keys = case series_key {
    Some(sk) -> [sk, msg.identifier]
    None -> [msg.identifier]
  }

  let initial = AlertDiff([], [], [])

  let grouped_alerts = list.group(msg.alerts, fn(a) { a.event }) |> dict.values

  use diff_alerts <- result.try(
    list.try_fold(grouped_alerts, initial, fn(diff_acc, alert_items) {
      let assert [first_alert, ..] = alert_items
      let source_id =
        option.unwrap(series_key, msg.identifier) <> ":" <> first_alert.event

      let all_cancelled = list.all(alert_items, fn(a) { a.status == "解除" })

      case all_cancelled {
        True -> {
          // End the warning completely when all its constituent areas transition to '解除'
          pog.query("WITH written AS (
               UPDATE sea.alert
               SET ended_at = $1, end_reason = 'cancelled', last_seen_at = $2
               WHERE source = 'jma'
                 AND source_id = $3
                 AND ended_at IS NULL
                 AND sent <= $1
               RETURNING *
             )
             SELECT " <> alert.columns <> "
             FROM written a
             JOIN sea.source s ON s.id = a.source")
          |> pog.parameter(pog.timestamp(sent_ts))
          |> pog.parameter(pog.timestamp(now))
          |> pog.parameter(pog.text(source_id))
          |> pog.returning(alert.row_decoder())
          |> pog.execute(tx)
          |> result.map(fn(res) {
            AlertDiff(
              new: diff_acc.new,
              updated: diff_acc.updated,
              ended: list.append(diff_acc.ended, res.rows),
            )
          })
          |> result.map_error(err)
        }
        False -> {
          let active_items =
            list.filter(alert_items, fn(a) {
              jma.is_active_alert_status(a.status)
            })

          case active_items {
            [] -> Ok(diff_acc)
            [active_first, ..] -> {
              let category = [option.unwrap(active_first.category, "Met")]
              let geocode_json =
                json.to_string(
                  json.preprocessed_array(
                    list.map(active_items, fn(a) {
                      json.object([
                        #("name", json.string("JMA")),
                        #("value", json.string(a.geocode)),
                      ])
                    }),
                  ),
                )
              let geocodes =
                list.map(active_items, fn(a) { a.geocode })
                |> list.unique
              let area_desc =
                list.map(active_items, fn(a) { a.area_name })
                |> list.unique
                |> list.sort(string.compare)
                |> string.join(", ")

              use existing_res <- result.try(
                pog.query(
                  "SELECT 1 FROM sea.alert WHERE source = 'jma' AND source_id = $1 FOR UPDATE",
                )
                |> pog.parameter(pog.text(source_id))
                |> pog.returning(decode.at([0], decode.int))
                |> pog.execute(tx)
                |> result.map_error(err),
              )
              let is_existing = existing_res.rows != []

              pog.query(upsert_alert_sql)
              |> pog.parameter(pog.text(source_id))
              |> pog.parameter(pog.text(msg.identifier))
              |> pog.parameter(pog.text(msg.info_type))
              |> pog.parameter(pog.text(active_first.event))
              |> pog.parameter(pog.array(pog.text, category))
              |> pog.parameter(pog.text(active_first.severity))
              |> pog.parameter(pog.text(active_first.urgency))
              |> pog.parameter(pog.text(active_first.certainty))
              |> pog.parameter(pog.nullable(pog.text, msg.headline))
              |> pog.parameter(pog.nullable(pog.text, msg.description))
              |> pog.parameter(pog.text(area_desc))
              |> pog.parameter(pog.text(geocode_json))
              |> pog.parameter(pog.array(pog.text, ref_keys))
              |> pog.parameter(pog.timestamp(sent_ts))
              |> pog.parameter(pog.timestamp(effective_ts))
              |> pog.parameter(pog.nullable(pog.timestamp, expires_ts))
              |> pog.parameter(pog.timestamp(active_until))
              |> pog.parameter(pog.timestamp(now))
              |> pog.parameter(pog.array(pog.text, geocodes))
              |> pog.returning(alert.row_decoder())
              |> pog.execute(tx)
              |> result.map(fn(res) {
                case res.rows {
                  [row] ->
                    case is_existing {
                      True ->
                        AlertDiff(
                          new: diff_acc.new,
                          updated: [row, ..diff_acc.updated],
                          ended: diff_acc.ended,
                        )
                      False ->
                        AlertDiff(
                          new: [row, ..diff_acc.new],
                          updated: diff_acc.updated,
                          ended: diff_acc.ended,
                        )
                    }
                  _ -> diff_acc
                }
              })
              |> result.map_error(err)
            }
          }
        }
      }
    }),
  )

  case msg.cleared_areas, series_key {
    [_, ..], Some(sk) -> {
      pog.query("WITH written AS (
           UPDATE sea.alert
           SET ended_at = $1, end_reason = 'cancelled', last_seen_at = $2
           WHERE source = 'jma'
             AND ended_at IS NULL
             AND sent <= $1
             AND $3 = ANY(reference_keys)
             AND (
               split_part(source_id, ':', 1) = ANY($4)
               OR EXISTS (
                 SELECT 1 FROM jsonb_array_elements(geocodes) elem
                 WHERE elem->>'value' = ANY($4)
               )
             )
           RETURNING *
         )
         SELECT " <> alert.columns <> "
         FROM written a
         JOIN sea.source s ON s.id = a.source")
      |> pog.parameter(pog.timestamp(sent_ts))
      |> pog.parameter(pog.timestamp(now))
      |> pog.parameter(pog.text(sk))
      |> pog.parameter(pog.array(pog.text, msg.cleared_areas))
      |> pog.returning(alert.row_decoder())
      |> pog.execute(tx)
      |> result.map(fn(res) {
        AlertDiff(
          new: diff_alerts.new,
          updated: diff_alerts.updated,
          ended: list.append(diff_alerts.ended, res.rows),
        )
      })
      |> result.map_error(err)
    }
    _, _ -> Ok(diff_alerts)
  }
}

fn merge_alert_diff(a: AlertDiff, b: AlertDiff) -> AlertDiff {
  AlertDiff(
    new: list.append(a.new, b.new),
    updated: list.append(a.updated, b.updated),
    ended: list.append(a.ended, b.ended),
  )
}

fn merge_earthquake_diff(
  a: EarthquakeDiff,
  b: EarthquakeDiff,
) -> EarthquakeDiff {
  EarthquakeDiff(
    new: list.append(a.new, b.new),
    updated: list.append(a.updated, b.updated),
    events: EventDiff(
      new: list.append(a.events.new, b.events.new),
      updated: list.append(a.events.updated, b.events.updated),
      matched: a.events.matched + b.events.matched,
    ),
  )
}

fn err(e: pog.QueryError) -> String {
  string.inspect(e)
}
