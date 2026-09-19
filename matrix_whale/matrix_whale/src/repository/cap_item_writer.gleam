import domain/alert
import domain/cap
import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/set
import gleam/string
import gleam/time/duration
import gleam/time/timestamp.{type Timestamp}
import message/reciever/models/cap as models_cap
import pog

pub type IndexAck {
  IndexAck(received: Int, written: Int, deduped: Int, dropped: Int)
}

pub type PendingItem {
  PendingItem(cap_url: String, feed_url: String)
}

type FeedHealthRow {
  FeedHealthRow(
    consecutive_failures: Int,
    last_success_at: Option(Timestamp),
    item_count: Option(Int),
    newest_item_at: Option(Timestamp),
    format: Option(String),
  )
}

fn feed_health_decoder() -> decode.Decoder(FeedHealthRow) {
  use consecutive_failures <- decode.field(0, decode.int)
  use last_success_at <- decode.field(
    1,
    decode.optional(alert.timestamptz_decoder()),
  )
  use item_count <- decode.field(2, decode.optional(decode.int))
  use newest_item_at <- decode.field(
    3,
    decode.optional(alert.timestamptz_decoder()),
  )
  use format <- decode.field(4, decode.optional(decode.string))
  decode.success(FeedHealthRow(
    consecutive_failures:,
    last_success_at:,
    item_count:,
    newest_item_at:,
    format:,
  ))
}

pub fn write_index(
  feed_url_opt: Option(String),
  meta: Option(models_cap.CapPollMeta),
  items: List(models_cap.IndexItem),
  received: Int,
  decode_dropped: Int,
  now: Timestamp,
  conn: pog.Connection,
) -> Result(IndexAck, String) {
  case feed_url_opt {
    None -> Ok(IndexAck(received:, written: 0, deduped: 0, dropped: received))
    Some(feed_url) -> {
      pog.transaction(conn, fn(tx) {
        write_index_tx(feed_url, meta, items, received, decode_dropped, now, tx)
      })
      |> result.map_error(fn(x) {
        case x {
          pog.TransactionQueryError(e) -> err(e)
          pog.TransactionRolledBack(e) -> e
        }
      })
    }
  }
}

fn write_index_tx(
  feed_url: String,
  meta: Option(models_cap.CapPollMeta),
  items: List(models_cap.IndexItem),
  received: Int,
  decode_dropped: Int,
  now: Timestamp,
  tx: pog.Connection,
) -> Result(IndexAck, String) {
  use feed_rows <- result.try(
    pog.query(
      "SELECT consecutive_failures, last_success_at, item_count, newest_item_at, format FROM sea.cap_feed WHERE url = $1 FOR UPDATE",
    )
    |> pog.parameter(pog.text(feed_url))
    |> pog.returning(feed_health_decoder())
    |> pog.execute(tx)
    |> result.map_error(err),
  )

  case list.first(feed_rows.rows) {
    Error(Nil) ->
      // Feed URL is unknown in sea.cap_feed; record nothing and count all items dropped
      Ok(IndexAck(received:, written: 0, deduped: 0, dropped: received))

    Ok(feed) -> {
      let http_status = case meta {
        Some(m) -> m.http_status
        None -> 200
      }
      let error_opt = case meta {
        Some(m) -> m.error
        None -> None
      }
      let format_opt = case meta {
        Some(m) -> m.format
        None -> None
      }

      use _ <- result.try(update_feed_health(
        feed_url,
        feed,
        http_status,
        error_opt,
        format_opt,
        items,
        now,
        tx,
      ))

      case items {
        [] ->
          Ok(IndexAck(
            received:,
            written: 0,
            deduped: 0,
            dropped: decode_dropped,
          ))

        _ -> {
          let urls = list.map(items, fn(i) { i.cap_url })
          use existing_urls_res <- result.try(
            pog.query(
              "SELECT cap_url FROM sea.cap_item WHERE cap_url = ANY($1)",
            )
            |> pog.parameter(pog.array(pog.text, urls))
            |> pog.returning(decode.at([0], decode.string))
            |> pog.execute(tx)
            |> result.map_error(err),
          )
          let existing_set = set.from_list(existing_urls_res.rows)
          let #(known_items, new_items) =
            list.partition(items, fn(i) {
              set.contains(existing_set, i.cap_url)
            })

          use _ <- result.try(touch_known_items(known_items, now, tx))
          use _ <- result.try(insert_new_items(feed_url, new_items, now, tx))

          let written = list.length(new_items)
          let deduped = list.length(known_items)
          let dropped = decode_dropped

          Ok(IndexAck(received:, written:, deduped:, dropped:))
        }
      }
    }
  }
}

fn update_feed_health(
  feed_url: String,
  feed: FeedHealthRow,
  http_status: Int,
  error_opt: Option(String),
  format_opt: Option(String),
  items: List(models_cap.IndexItem),
  now: Timestamp,
  tx: pog.Connection,
) -> Result(Nil, String) {
  let is_success = http_status == 200 || http_status == 304

  let #(
    consecutive_failures,
    last_success_at,
    last_http_status,
    last_error,
    format,
    item_count,
    newest_item_at,
  ) = case is_success {
    True -> {
      let consecutive_failures = 0
      let last_success_at = Some(now)
      let last_http_status = Some(http_status)
      let last_error = error_opt

      case http_status == 200 {
        True -> {
          let format = case format_opt {
            Some(f) -> Some(f)
            None -> feed.format
          }
          let item_count = Some(list.length(items))
          let parseable_dates =
            items
            |> list.filter_map(fn(item) {
              case item.published {
                Some(s) -> cap.parse_published_time(s)
                None -> Error(Nil)
              }
            })
          let newest_item_at = case parseable_dates {
            [] -> None
            [first, ..rest] ->
              Some(
                list.fold(rest, first, fn(latest, t) {
                  case timestamp.compare(t, latest) {
                    order.Gt -> t
                    _ -> latest
                  }
                }),
              )
          }
          #(
            consecutive_failures,
            last_success_at,
            last_http_status,
            last_error,
            format,
            item_count,
            newest_item_at,
          )
        }
        False ->
          // 304 keeps previous item_count, newest_item_at, format
          #(
            consecutive_failures,
            last_success_at,
            last_http_status,
            last_error,
            feed.format,
            feed.item_count,
            feed.newest_item_at,
          )
      }
    }
    False -> {
      // Failure: consecutive_failures + 1 computed in Gleam
      let consecutive_failures = feed.consecutive_failures + 1
      let last_success_at = feed.last_success_at
      let last_http_status = Some(http_status)
      let last_error = error_opt
      #(
        consecutive_failures,
        last_success_at,
        last_http_status,
        last_error,
        feed.format,
        feed.item_count,
        feed.newest_item_at,
      )
    }
  }

  pog.query(
    "UPDATE sea.cap_feed SET
       consecutive_failures = $2,
       last_success_at = $3,
       last_http_status = $4,
       last_error = $5,
       last_polled_at = $6,
       item_count = $7,
       newest_item_at = $8,
       format = $9,
       last_seen_at = $6
     WHERE url = $1",
  )
  |> pog.parameter(pog.text(feed_url))
  |> pog.parameter(pog.int(consecutive_failures))
  |> pog.parameter(pog.nullable(pog.timestamp, last_success_at))
  |> pog.parameter(pog.nullable(pog.int, last_http_status))
  |> pog.parameter(pog.nullable(pog.text, last_error))
  |> pog.parameter(pog.timestamp(now))
  |> pog.parameter(pog.nullable(pog.int, item_count))
  |> pog.parameter(pog.nullable(pog.timestamp, newest_item_at))
  |> pog.parameter(pog.nullable(pog.text, format))
  |> pog.returning(decode.success(Nil))
  |> pog.execute(tx)
  |> result.map(fn(_) { Nil })
  |> result.map_error(err)
}

fn touch_known_items(
  items: List(models_cap.IndexItem),
  now: Timestamp,
  tx: pog.Connection,
) -> Result(Nil, String) {
  case items {
    [] -> Ok(Nil)
    _ -> {
      let urls = list.map(items, fn(i) { i.cap_url })
      pog.query(
        "UPDATE sea.cap_item SET last_seen_at = $2 WHERE cap_url = ANY($1)",
      )
      |> pog.parameter(pog.array(pog.text, urls))
      |> pog.parameter(pog.timestamp(now))
      |> pog.returning(decode.success(Nil))
      |> pog.execute(tx)
      |> result.map(fn(_) { Nil })
      |> result.map_error(err)
    }
  }
}

const insert_cap_item_sql = "
  INSERT INTO sea.cap_item
    (cap_url, feed_url, published_at, state, attempts, last_attempt_at, http_status, error, message_key, first_seen_at, last_seen_at)
  VALUES
    ($1, $2, $3, $4, 0, NULL, NULL, NULL, NULL, $5, $5)
  ON CONFLICT (cap_url) DO UPDATE SET last_seen_at = EXCLUDED.last_seen_at"

fn insert_new_items(
  feed_url: String,
  items: List(models_cap.IndexItem),
  now: Timestamp,
  tx: pog.Connection,
) -> Result(Nil, String) {
  list.try_each(items, fn(item) {
    let state = cap.decide_new_item_state(item.published, now)
    let state_str = cap.item_state_to_string(state)
    let published_at =
      option.then(item.published, fn(s) {
        option.from_result(cap.parse_published_time(s))
      })
    pog.query(insert_cap_item_sql)
    |> pog.parameter(pog.text(item.cap_url))
    |> pog.parameter(pog.text(feed_url))
    |> pog.parameter(pog.nullable(pog.timestamp, published_at))
    |> pog.parameter(pog.text(state_str))
    |> pog.parameter(pog.timestamp(now))
    |> pog.returning(decode.success(Nil))
    |> pog.execute(tx)
    |> result.map(fn(_) { Nil })
    |> result.map_error(err)
  })
}

const pending_sql = "
  SELECT cap_url, feed_url
  FROM sea.cap_item
  WHERE state = 'pending'
     OR (state = 'failed' AND attempts < $1 AND last_attempt_at <= $2)
  ORDER BY first_seen_at DESC
  LIMIT $3"

pub fn pending(
  limit: Int,
  now: Timestamp,
  conn: pog.Connection,
) -> Result(List(PendingItem), String) {
  let cutoff = timestamp.add(now, duration.seconds(-cap.retry_interval_seconds))
  let max_attempts = cap.max_retry_attempts

  pog.query(pending_sql)
  |> pog.parameter(pog.int(max_attempts))
  |> pog.parameter(pog.timestamp(cutoff))
  |> pog.parameter(pog.int(limit))
  |> pog.returning(pending_item_decoder())
  |> pog.execute(conn)
  |> result.map(fn(x) { x.rows })
  |> result.map_error(err)
}

fn pending_item_decoder() -> decode.Decoder(PendingItem) {
  use cap_url <- decode.field(0, decode.string)
  use feed_url <- decode.field(1, decode.string)
  decode.success(PendingItem(cap_url:, feed_url:))
}

pub fn record_fetch_outcome(
  cap_url: String,
  http_status: Int,
  cap_parsed: Bool,
  error: Option(String),
  message_key: Option(String),
  attempt_time: Timestamp,
  now: Timestamp,
  conn: pog.Connection,
) -> Result(Nil, String) {
  update_outcome(
    cap_url,
    http_status,
    error,
    message_key,
    attempt_time,
    now,
    conn,
    fn(current_attempts) {
      cap.decide_fetch_outcome(http_status, cap_parsed, current_attempts)
    },
  )
}

pub fn record_write_failure(
  cap_url: String,
  http_status: Int,
  error: Option(String),
  attempt_time: Timestamp,
  now: Timestamp,
  conn: pog.Connection,
) -> Result(Nil, String) {
  update_outcome(
    cap_url,
    http_status,
    error,
    None,
    attempt_time,
    now,
    conn,
    fn(current_attempts) { cap.decide_write_failure(current_attempts) },
  )
}

fn update_outcome(
  cap_url: String,
  http_status: Int,
  error: Option(String),
  message_key: Option(String),
  attempt_time: Timestamp,
  now: Timestamp,
  conn: pog.Connection,
  decide: fn(Int) -> #(cap.ItemState, Int),
) -> Result(Nil, String) {
  use attempts_res <- result.try(
    pog.query(
      "SELECT attempts, last_attempt_at FROM sea.cap_item WHERE cap_url = $1",
    )
    |> pog.parameter(pog.text(cap_url))
    |> pog.returning(attempts_and_last_attempt_decoder())
    |> pog.execute(conn)
    |> result.map_error(err),
  )

  let #(current_attempts, last_attempt_at) = case
    list.first(attempts_res.rows)
  {
    Ok(#(a, last_ts)) -> #(a, last_ts)
    Error(Nil) -> #(0, None)
  }

  let is_same_attempt = last_attempt_at == Some(attempt_time)

  let #(new_state, new_attempts) = case is_same_attempt {
    True -> {
      let #(st, _) = decide(current_attempts)
      #(st, current_attempts)
    }
    False -> decide(current_attempts)
  }
  let state_str = cap.item_state_to_string(new_state)

  pog.query(
    "UPDATE sea.cap_item SET
       state = $2,
       attempts = $3,
       http_status = $4,
       error = $5,
       last_attempt_at = $6,
       message_key = $7,
       last_seen_at = $8
     WHERE cap_url = $1",
  )
  |> pog.parameter(pog.text(cap_url))
  |> pog.parameter(pog.text(state_str))
  |> pog.parameter(pog.int(new_attempts))
  |> pog.parameter(pog.int(http_status))
  |> pog.parameter(pog.nullable(pog.text, error))
  |> pog.parameter(pog.timestamp(attempt_time))
  |> pog.parameter(pog.nullable(pog.text, message_key))
  |> pog.parameter(pog.timestamp(now))
  |> pog.returning(decode.success(Nil))
  |> pog.execute(conn)
  |> result.map(fn(_) { Nil })
  |> result.map_error(err)
}

fn attempts_and_last_attempt_decoder() -> decode.Decoder(
  #(Int, Option(Timestamp)),
) {
  use attempts <- decode.field(0, decode.int)
  use last_attempt_at <- decode.field(
    1,
    decode.optional(alert.timestamptz_decoder()),
  )
  decode.success(#(attempts, last_attempt_at))
}

pub fn mark_item_fetched(
  cap_url: String,
  message_key: String,
  http_status: Int,
  attempt_time: Timestamp,
  now: Timestamp,
  conn: pog.Connection,
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
  |> pog.execute(conn)
  |> result.map(fn(_) { Nil })
  |> result.map_error(err)
}

fn err(x: pog.QueryError) -> String {
  "Database error: " <> string.inspect(x)
}
