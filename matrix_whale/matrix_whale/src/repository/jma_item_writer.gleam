import domain/jma
import gleam/dynamic/decode
import gleam/list
import gleam/option
import gleam/result
import gleam/set
import gleam/string
import gleam/time/duration
import gleam/time/timestamp.{type Timestamp}
import message/reciever/models/jma as models_jma
import pog

pub type IndexAck {
  IndexAck(received: Int, written: Int, deduped: Int, dropped: Int)
}

pub type PendingItem {
  PendingItem(item_url: String, feed_url: String)
}

pub fn write_index(
  items: List(models_jma.JmaIndexItem),
  received: Int,
  decode_dropped: Int,
  now: Timestamp,
  conn: pog.Connection,
) -> Result(IndexAck, String) {
  case items {
    [] ->
      Ok(IndexAck(received:, written: 0, deduped: 0, dropped: decode_dropped))
    _ -> {
      pog.transaction(conn, fn(tx) {
        write_index_tx(items, received, decode_dropped, now, tx)
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
  items: List(models_jma.JmaIndexItem),
  received: Int,
  decode_dropped: Int,
  now: Timestamp,
  tx: pog.Connection,
) -> Result(IndexAck, String) {
  let #(unique_items, batch_dupes) = deduplicate_batch_items(items)
  let urls = list.map(unique_items, fn(i) { i.item_url })
  use existing_urls_res <- result.try(
    pog.query("SELECT item_url FROM sea.jma_item WHERE item_url = ANY($1)")
    |> pog.parameter(pog.array(pog.text, urls))
    |> pog.returning(decode.at([0], decode.string))
    |> pog.execute(tx)
    |> result.map_error(err),
  )

  let existing_set = set.from_list(existing_urls_res.rows)
  let #(known_items, new_items) =
    list.partition(unique_items, fn(i) {
      set.contains(existing_set, i.item_url)
    })

  use _ <- result.try(touch_known_items(known_items, now, tx))
  use _ <- result.try(insert_new_items(new_items, now, tx))

  let written = list.length(new_items)
  let deduped = list.length(known_items) + batch_dupes
  let dropped = decode_dropped

  Ok(IndexAck(received:, written:, deduped:, dropped:))
}

fn deduplicate_batch_items(
  items: List(models_jma.JmaIndexItem),
) -> #(List(models_jma.JmaIndexItem), Int) {
  let #(_, unique_rev, dupes) =
    list.fold(items, #(set.new(), [], 0), fn(acc, item) {
      let #(seen, kept, dupes) = acc
      case set.contains(seen, item.item_url) {
        True -> #(seen, kept, dupes + 1)
        False -> #(set.insert(seen, item.item_url), [item, ..kept], dupes)
      }
    })
  #(list.reverse(unique_rev), dupes)
}

fn touch_known_items(
  items: List(models_jma.JmaIndexItem),
  now: Timestamp,
  tx: pog.Connection,
) -> Result(Nil, String) {
  case items {
    [] -> Ok(Nil)
    _ -> {
      let urls = list.map(items, fn(i) { i.item_url })
      pog.query(
        "UPDATE sea.jma_item SET last_seen_at = $2 WHERE item_url = ANY($1)",
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

const insert_item_sql = "
  INSERT INTO sea.jma_item
    (item_url, feed_url, guid, title, published_at, state, attempts, first_seen_at, last_seen_at)
  VALUES
    ($1, $2, $3, $4, $5, 'pending', 0, $6, $6)
  ON CONFLICT (item_url) DO UPDATE SET last_seen_at = EXCLUDED.last_seen_at"

fn insert_new_items(
  items: List(models_jma.JmaIndexItem),
  now: Timestamp,
  tx: pog.Connection,
) -> Result(Nil, String) {
  list.try_each(items, fn(item) {
    let published_at =
      option.then(item.published, fn(s) {
        option.from_result(jma.parse_rfc3339(s))
      })
    pog.query(insert_item_sql)
    |> pog.parameter(pog.text(item.item_url))
    |> pog.parameter(pog.text(item.feed_url))
    |> pog.parameter(pog.nullable(pog.text, item.guid))
    |> pog.parameter(pog.nullable(pog.text, item.title))
    |> pog.parameter(pog.nullable(pog.timestamp, published_at))
    |> pog.parameter(pog.timestamp(now))
    |> pog.returning(decode.success(Nil))
    |> pog.execute(tx)
    |> result.map(fn(_) { Nil })
    |> result.map_error(err)
  })
}

const pending_sql = "
  SELECT item_url, feed_url
  FROM sea.jma_item
  WHERE state = 'pending'
     OR (state = 'failed' AND attempts < $1 AND last_attempt_at <= $2)
  ORDER BY published_at DESC NULLS LAST, first_seen_at DESC
  LIMIT $3"

pub fn pending(
  limit: Int,
  now: Timestamp,
  conn: pog.Connection,
) -> Result(List(PendingItem), String) {
  let cutoff = timestamp.add(now, duration.seconds(-jma.retry_interval_seconds))
  let max_attempts = jma.max_retry_attempts

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
  use item_url <- decode.field(0, decode.string)
  use feed_url <- decode.field(1, decode.string)
  decode.success(PendingItem(item_url:, feed_url:))
}

fn err(e: pog.QueryError) -> String {
  string.inspect(e)
}
