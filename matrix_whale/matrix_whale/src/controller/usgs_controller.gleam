import adapter/context.{type Context}
import adapter/earthquake_hub
import domain/source
import gleam/list
import gleam/result
import gleam/time/timestamp
import intake/pipeline
import intake/record.{Incoming, Key}
import message/reciever/models/usgs.{type IncomingEarthquake}
import repository/earthquake_writer

pub type UsgsResult {
  UsgsResult(
    new: Int,
    updated: Int,
    unchanged: Int,
    stale: Int,
    repeats: Int,
    expired: Int,
  )
}

pub fn process(
  features: List(IncomingEarthquake),
  backfill: Bool,
  ctx: Context,
) -> Result(UsgsResult, String) {
  let #(now_seconds, _) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  let now_ms = now_seconds * 1000
  let cutoff_ms = { now_seconds - 7 * 24 * 60 * 60 } * 1000
  let #(features, expired) = split_expired(features, cutoff_ms)

  let records =
    list.map(features, fn(feature) {
      Incoming(
        key: Key(source.usgs.id, feature.source_id),
        revision: feature.updated,
        payload: feature,
      )
    })

  pipeline.run(records, ctx.seen, now_ms, fn(survivors) {
    earthquake_writer.write_batch(survivors, now_ms, ctx.db)
  })
  |> result.map(fn(outcome) {
    earthquake_hub.publish(
      ctx.earthquake_hub,
      outcome.result.new,
      outcome.result.updated,
      backfill,
    )
    UsgsResult(
      new: outcome.new,
      updated: outcome.updated,
      unchanged: outcome.unchanged,
      stale: outcome.stale,
      repeats: outcome.repeats,
      expired: expired,
    )
  })
  |> result.map_error(fn(error) { "USGS database write failed: " <> error })
}

/// Source data outside the retention window is intentionally not sent to the
/// database. It is a dropped record, not an idempotent revision.
pub fn split_expired(
  features: List(IncomingEarthquake),
  cutoff_ms: Int,
) -> #(List(IncomingEarthquake), Int) {
  let #(live, expired) =
    list.partition(features, fn(feature) { feature.time > cutoff_ms })
  #(live, list.length(expired))
}
