import adapter/alert_hub
import adapter/context.{type Context}
import domain/cap
import gleam/dict
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set
import gleam/string
import gleam/time/timestamp
import intake/pipeline
import intake/record
import intake/seen_set
import message/reciever/models/cap as models_cap
import pog
import repository/alert_writer.{AlertDiff}
import repository/cap_feed_reader.{type SubscribedFeed}
import repository/cap_item_writer.{type IndexAck, type PendingItem}
import repository/cap_message_writer.{CapItemPayload}
import repository/cap_registry_writer.{type RegistryAck}

pub type AlertsAck {
  AlertsAck(
    received: Int,
    written: Int,
    deduped: Int,
    dropped: Int,
    message: String,
  )
}

pub fn process_registry(
  items: List(models_cap.RegistryItem),
  received: Int,
  decode_dropped: Int,
  ctx: Context,
) -> Result(RegistryAck, String) {
  let now = timestamp.system_time()
  cap_registry_writer.write_registry(
    items,
    received,
    decode_dropped,
    now,
    ctx.db,
  )
}

pub fn get_feeds(ctx: Context) -> Result(List(SubscribedFeed), String) {
  cap_feed_reader.list_subscribed(ctx.db)
}

pub fn process_index(
  feed_url: Option(String),
  meta: Option(models_cap.CapPollMeta),
  items: List(models_cap.IndexItem),
  received: Int,
  decode_dropped: Int,
  ctx: Context,
) -> Result(IndexAck, String) {
  let now = timestamp.system_time()
  cap_item_writer.write_index(
    feed_url,
    meta,
    items,
    received,
    decode_dropped,
    now,
    ctx.db,
  )
}

pub fn get_pending(
  limit: Int,
  ctx: Context,
) -> Result(List(PendingItem), String) {
  let clamped_limit = int.clamp(limit, 1, 200)
  let now = timestamp.system_time()
  cap_item_writer.pending(clamped_limit, now, ctx.db)
}

pub fn process_alerts(
  features: List(models_cap.CapFetchResult),
  meta: Option(models_cap.CapPollMeta),
  received: Int,
  decode_dropped: Int,
  ctx: Context,
) -> Result(AlertsAck, String) {
  let now = timestamp.system_time()
  let #(sec, nsec) = timestamp.to_unix_seconds_and_nanoseconds(now)
  let now_ms = sec * 1000 + nsec / 1_000_000

  let feed_urls =
    features
    |> list.map(fn(r) { r.feed_url })
    |> list.unique

  use owners_map <- result.try(load_feed_owners(feed_urls, ctx.db))

  // Partition results into fetch failures vs candidates
  let #(failures, candidates) =
    list.partition(features, fn(r) {
      r.http_status != 200 || option.is_none(r.cap)
    })

  // Record outcome for fetch failures (idempotent for same fetched_at)
  use _ <- result.try(
    list.try_each(failures, fn(r) {
      let attempt_ts = cap.parse_rfc3339(r.fetched_at) |> result.unwrap(now)
      cap_item_writer.record_fetch_outcome(
        r.cap_url,
        r.http_status,
        False,
        r.error,
        None,
        attempt_ts,
        now,
        ctx.db,
      )
    }),
  )

  let failed_dropped = list.length(failures)

  // Process candidates: verify feed owner and valid timestamps
  use #(records, candidate_dropped) <- result.try(
    list.try_fold(candidates, #([], 0), fn(acc, r) {
      let #(recs, dropped) = acc
      let assert Some(msg) = r.cap
      let attempt_ts = cap.parse_rfc3339(r.fetched_at) |> result.unwrap(now)
      case dict.get(owners_map, r.feed_url) {
        Error(Nil) -> {
          use _ <- result.try(cap_item_writer.record_fetch_outcome(
            r.cap_url,
            r.http_status,
            False,
            Some("unknown feed owner"),
            None,
            attempt_ts,
            now,
            ctx.db,
          ))
          Ok(#(recs, dropped + 1))
        }
        Ok(#(owner_source_id, country_iso3)) -> {
          case cap.compute_message_expires_at(msg) {
            Error(_) -> {
              use _ <- result.try(cap_item_writer.record_fetch_outcome(
                r.cap_url,
                r.http_status,
                False,
                Some("invalid CAP sent/expires"),
                None,
                attempt_ts,
                now,
                ctx.db,
              ))
              Ok(#(recs, dropped + 1))
            }
            Ok(_) -> {
              let payload =
                CapItemPayload(
                  result: r,
                  msg: msg,
                  owner_source_id: owner_source_id,
                  country_iso3: country_iso3,
                )
              case cap.make_incoming_record(msg, payload) {
                Error(_) -> {
                  use _ <- result.try(cap_item_writer.record_fetch_outcome(
                    r.cap_url,
                    r.http_status,
                    False,
                    Some("invalid CAP sent"),
                    None,
                    attempt_ts,
                    now,
                    ctx.db,
                  ))
                  Ok(#(recs, dropped + 1))
                }
                Ok(incoming_rec) -> Ok(#([incoming_rec, ..recs], dropped))
              }
            }
          }
        }
      }
    }),
  )
  let records = list.reverse(records)
  let direct_dropped = decode_dropped + failed_dropped + candidate_dropped

  let meta_status = case meta {
    Some(m) -> m.http_status
    None -> 200
  }
  let meta_bytes = case meta {
    Some(m) -> m.bytes
    None -> 0
  }

  case records {
    [] -> {
      alert_hub.record_source(
        ctx.hub,
        "cap",
        alert_hub.SourceWrite(
          http_status: meta_status,
          received: received,
          written: 0,
          dropped: direct_dropped,
          bytes: meta_bytes,
          dedup_intake: 0,
          dedup_unchanged: 0,
          dedup_stale: 0,
          matched: 0,
        ),
      )
      Ok(AlertsAck(
        received: received,
        written: 0,
        deduped: 0,
        dropped: direct_dropped,
        message: "0 messages written",
      ))
    }

    _ -> {
      let seen_keys =
        list.map(records, fn(rec) { record.seen_key(rec.key, rec.revision) })
      let unseen =
        seen_set.unseen(ctx.seen, seen_keys, now_ms)
        |> set.from_list
      let repeats =
        list.filter(records, fn(rec) {
          !set.contains(unseen, record.seen_key(rec.key, rec.revision))
        })

      use outcome <- result.try(
        pipeline.run(records, ctx.seen, now_ms, fn(chunk) {
          cap_message_writer.write_batch(chunk, now, ctx.db)
        })
        |> result.map_error(fn(error) { "CAP database write failed: " <> error }),
      )

      let diff =
        AlertDiff(
          new: list.flat_map(outcome.results, fn(r) { r.diff.new }),
          updated: list.flat_map(outcome.results, fn(r) { r.diff.updated }),
          ended: list.flat_map(outcome.results, fn(r) { r.diff.ended }),
        )

      alert_hub.publish(ctx.hub, diff)

      // Mark repeats fetched (non-repeats are marked inside their transaction)
      use _ <- result.try(
        list.try_each(repeats, fn(rec) {
          let payload = rec.payload
          let cap_url = payload.result.cap_url
          let msg_key =
            cap.message_key(payload.msg.sender, payload.msg.identifier)
          let attempt_ts =
            cap.parse_rfc3339(payload.result.fetched_at)
            |> result.unwrap(now)
          cap_item_writer.mark_item_fetched(
            cap_url,
            msg_key,
            payload.result.http_status,
            attempt_ts,
            now,
            ctx.db,
          )
        }),
      )

      let batch_dropped =
        list.fold(outcome.results, 0, fn(acc, r) { acc + r.dropped })
      let written = outcome.new + outcome.updated
      let deduped = outcome.unchanged + outcome.stale + outcome.repeats
      let dropped = direct_dropped + batch_dropped

      alert_hub.record_source(
        ctx.hub,
        "cap",
        alert_hub.SourceWrite(
          http_status: meta_status,
          received: received,
          written: written,
          dropped: dropped,
          bytes: meta_bytes,
          dedup_intake: outcome.repeats,
          dedup_unchanged: outcome.unchanged,
          dedup_stale: outcome.stale,
          matched: 0,
        ),
      )

      Ok(AlertsAck(
        received: received,
        written: written,
        deduped: deduped,
        dropped: dropped,
        message: int.to_string(written)
          <> " written ("
          <> int.to_string(outcome.new)
          <> " new, "
          <> int.to_string(outcome.updated)
          <> " updated)",
      ))
    }
  }
}

fn load_feed_owners(
  feed_urls: List(String),
  conn: pog.Connection,
) -> Result(dict.Dict(String, #(String, String)), String) {
  case feed_urls {
    [] -> Ok(dict.new())
    _ -> {
      pog.query(
        "SELECT f.url, a.source, a.country_iso3
         FROM sea.cap_feed f
         JOIN sea.cap_authority a ON a.oid = f.authority_oid
         WHERE f.url = ANY($1)",
      )
      |> pog.parameter(pog.array(pog.text, feed_urls))
      |> pog.returning(feed_owner_decoder())
      |> pog.execute(conn)
      |> result.map(fn(x) {
        list.fold(x.rows, dict.new(), fn(acc, row) {
          dict.insert(acc, row.0, #(row.1, row.2))
        })
      })
      |> result.map_error(fn(e) { "Database error: " <> string.inspect(e) })
    }
  }
}

fn feed_owner_decoder() -> decode.Decoder(#(String, String, String)) {
  use url <- decode.field(0, decode.string)
  use source <- decode.field(1, decode.string)
  use country_iso3 <- decode.field(2, decode.string)
  decode.success(#(url, source, country_iso3))
}
