import adapter/alert_hub
import adapter/context.{type Context}
import adapter/earthquake_hub
import adapter/response_cache
import gleam/int
import gleam/option.{type Option}
import gleam/result
import gleam/time/timestamp
import message/reciever/models/jma as models_jma
import repository/jma_item_writer.{type PendingItem}
import repository/jma_message_writer

pub type ControllerAck {
  ControllerAck(
    received: Int,
    deduped: Int,
    written: Int,
    dropped: Int,
    message: String,
  )
}

pub fn process_index(
  meta: Option(models_jma.JmaPollMeta),
  items: List(models_jma.JmaIndexItem),
  received: Int,
  decode_dropped: Int,
  ctx: Context,
) -> Result(ControllerAck, String) {
  let now = timestamp.system_time()
  jma_item_writer.write_index(items, received, decode_dropped, now, ctx.db)
  |> result.map(fn(ack) {
    let bytes = option.map(meta, fn(m) { m.bytes }) |> option.unwrap(0)
    let http_status =
      option.map(meta, fn(m) { m.http_status }) |> option.unwrap(200)

    alert_hub.record_source(
      ctx.hub,
      "jma",
      alert_hub.SourceWrite(
        http_status:,
        received:,
        written: ack.written,
        dropped: ack.dropped,
        bytes:,
        dedup_intake: ack.deduped,
        dedup_unchanged: 0,
        dedup_stale: 0,
        matched: 0,
      ),
    )

    ControllerAck(
      received: ack.received,
      deduped: ack.deduped,
      written: ack.written,
      dropped: ack.dropped,
      message: int.to_string(ack.written) <> " items written",
    )
  })
}

pub fn get_pending(
  limit: Int,
  ctx: Context,
) -> Result(List(PendingItem), String) {
  let now = timestamp.system_time()
  jma_item_writer.pending(limit, now, ctx.db)
}

pub fn process_messages(
  results: List(models_jma.JmaFetchResult),
  meta: Option(models_jma.JmaPollMeta),
  received: Int,
  decode_dropped: Int,
  ctx: Context,
) -> Result(ControllerAck, String) {
  let now = timestamp.system_time()
  jma_message_writer.write_batch(results, now, ctx.db)
  |> result.map(fn(res) {
    let bytes = option.map(meta, fn(m) { m.bytes }) |> option.unwrap(0)
    let http_status =
      option.map(meta, fn(m) { m.http_status }) |> option.unwrap(200)
    let dropped = decode_dropped + res.dropped

    alert_hub.record_source(
      ctx.hub,
      "jma",
      alert_hub.SourceWrite(
        http_status:,
        received:,
        written: res.written,
        dropped:,
        bytes:,
        dedup_intake: res.deduped,
        dedup_unchanged: 0,
        dedup_stale: 0,
        matched: 0,
      ),
    )

    // Broadcast live alert updates to frontend SSE
    case
      res.alert_diff.new != []
      || res.alert_diff.updated != []
      || res.alert_diff.ended != []
    {
      True -> {
        alert_hub.publish(ctx.hub, res.alert_diff)
        response_cache.invalidate(ctx.alert_cache)
      }
      False -> Nil
    }

    // Broadcast live earthquake updates to frontend SSE
    case
      res.earthquake_diff.events.new != []
      || res.earthquake_diff.events.updated != []
    {
      True ->
        earthquake_hub.publish(
          ctx.earthquake_hub,
          res.earthquake_diff.events.new,
          res.earthquake_diff.events.updated,
          False,
        )
      False -> Nil
    }

    // Trigger canonical event resync if an orphaned canonical event was removed
    case res.resync_earthquakes {
      True -> earthquake_hub.resync_all(ctx.earthquake_hub)
      False -> Nil
    }

    ControllerAck(
      received: received,
      deduped: res.deduped,
      written: res.written,
      dropped: dropped,
      message: int.to_string(res.written)
        <> " messages written, "
        <> int.to_string(res.deduped)
        <> " deduped",
    )
  })
}
