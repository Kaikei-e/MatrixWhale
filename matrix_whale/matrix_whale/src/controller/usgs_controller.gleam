import adapter/context.{type Context}
import adapter/earthquake_hub
import gleam/list
import gleam/result
import gleam/time/timestamp
import message/reciever/models/usgs.{type IncomingEarthquake}
import repository/earthquake_writer

pub fn process(
  features: List(IncomingEarthquake),
  backfill: Bool,
  ctx: Context,
) -> Result(#(Int, Int, Int), String) {
  let #(now_seconds, _) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  let cutoff_ms = { now_seconds - 7 * 24 * 60 * 60 } * 1000
  let #(features, expired) = split_expired(features, cutoff_ms)
  earthquake_writer.upsert_and_diff(features, ctx.db)
  |> result.map(fn(diff) {
    earthquake_hub.publish(ctx.earthquake_hub, diff.new, diff.updated, backfill)
    #(list.length(diff.new), list.length(diff.updated), expired)
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
