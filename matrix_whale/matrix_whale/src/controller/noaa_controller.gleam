import adapter/alert_hub
import adapter/context.{type Context}
import domain/source
import gleam/list
import gleam/string
import gleam/time/timestamp
import intake/pipeline
import intake/record.{Incoming, Key}
import message/reciever/models/noaa.{type FeatureElement, Test}
import repository/alert_writer
import wisp

pub type NoaaResult {
  NoaaResult(
    new: Int,
    updated: Int,
    ended: Int,
    unchanged: Int,
    stale: Int,
    repeats: Int,
    test_dropped: Int,
  )
}

pub fn noaa_controller(
  features: List(FeatureElement),
  run_ended_sweep: Bool,
  ctx: Context,
) -> Result(NoaaResult, String) {
  wisp.log_info(
    "Processing " <> string.inspect(list.length(features)) <> " features",
  )

  let live_features =
    list.filter(features, fn(feature) { feature.properties.status != Test })
  let test_dropped = list.length(features) - list.length(live_features)

  wisp.log_info("Removed " <> string.inspect(test_dropped) <> " test features")

  let all_ids = list.map(live_features, fn(feature) { feature.id })
  let records =
    list.map(live_features, fn(feature) {
      Incoming(
        key: Key(source.noaa.id, feature.id),
        revision: noaa.sent_revision_ms(feature.properties),
        payload: feature,
      )
    })

  let now = timestamp.system_time()
  let now_ms = noaa.timestamp_to_ms(now)

  case
    pipeline.run(records, ctx.seen, now_ms, fn(survivors) {
      alert_writer.write_batch(survivors, run_ended_sweep, all_ids, now, ctx.db)
    })
  {
    Ok(outcome) -> {
      let diff =
        alert_writer.AlertDiff(
          new: list.flat_map(outcome.results, fn(d) { d.new }),
          updated: list.flat_map(outcome.results, fn(d) { d.updated }),
          ended: list.flat_map(outcome.results, fn(d) { d.ended }),
        )
      let ended_count = list.length(diff.ended)

      wisp.log_info(
        "Alerts: "
        <> string.inspect(outcome.new)
        <> " new, "
        <> string.inspect(list.length(diff.updated))
        <> " updated, "
        <> string.inspect(ended_count)
        <> " ended",
      )

      alert_hub.record_write(
        ctx.hub,
        outcome.new,
        list.length(diff.updated),
        ended_count,
      )
      alert_hub.publish(ctx.hub, diff)

      Ok(NoaaResult(
        new: outcome.new,
        updated: outcome.updated,
        ended: ended_count,
        unchanged: outcome.unchanged,
        stale: outcome.stale,
        repeats: outcome.repeats,
        test_dropped: test_dropped,
      ))
    }
    Error(error) -> {
      wisp.log_error("Error writing alerts to database: " <> error)
      Error(error)
    }
  }
}
