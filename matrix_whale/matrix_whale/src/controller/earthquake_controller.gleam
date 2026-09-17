import adapter/context.{type Context}
import adapter/earthquake_hub
import domain/source.{type Source}
import gleam/list
import gleam/result
import gleam/time/timestamp
import intake/pipeline
import intake/record.{Incoming, Key}
import message/reciever/models/earthquake_feature.{type IncomingEarthquake}
import repository/earthquake_writer

pub type EarthquakeResult {
  EarthquakeResult(
    new: Int,
    updated: Int,
    unchanged: Int,
    stale: Int,
    repeats: Int,
    expired: Int,
    matched: Int,
  )
}

pub fn process(
  source: Source,
  features: List(IncomingEarthquake),
  backfill: Bool,
  ctx: Context,
) -> Result(EarthquakeResult, String) {
  let #(now_seconds, _) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  let now_ms = now_seconds * 1000
  let cutoff_ms = { now_seconds - 7 * 24 * 60 * 60 } * 1000
  let #(features, expired) = split_expired(features, cutoff_ms)

  let records =
    list.map(features, fn(feature) {
      Incoming(
        key: Key(source.id, feature.source_id),
        revision: feature.updated,
        payload: feature,
      )
    })

  pipeline.run(records, ctx.seen, now_ms, fn(survivors) {
    earthquake_writer.write_batch(survivors, now_ms, ctx.db)
  })
  |> result.map(fn(outcome) {
    let new_events =
      list.flat_map(outcome.results, fn(diff) { diff.events.new })
    let updated_events =
      list.flat_map(outcome.results, fn(diff) { diff.events.updated })
    let matched =
      list.fold(outcome.results, 0, fn(acc, diff) { acc + diff.events.matched })
    earthquake_hub.publish(
      ctx.earthquake_hub,
      new_events,
      updated_events,
      backfill,
    )
    EarthquakeResult(
      new: outcome.new,
      updated: outcome.updated,
      unchanged: outcome.unchanged,
      stale: outcome.stale,
      repeats: outcome.repeats,
      expired: expired,
      matched:,
    )
  })
  |> result.map_error(fn(error) {
    source.name <> " database write failed: " <> error
  })
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
