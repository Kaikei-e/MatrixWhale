import adapter/alert_hub
import adapter/context.{type Context}
import gleam/list
import gleam/string
import message/reciever/models/noaa.{type FeatureElement, Test}
import repository/alert_writer
import wisp

pub fn noaa_controller(
  features: List(FeatureElement),
  run_ended_sweep: Bool,
  ctx: Context,
) -> Result(#(String, Int, Int), String) {
  wisp.log_info(
    "Processing " <> string.inspect(list.length(features)) <> " features",
  )

  let live_features =
    features
    |> list.filter(fn(feature) { feature.properties.status != Test })

  wisp.log_info(
    "Removed "
    <> string.inspect(list.length(features) - list.length(live_features))
    <> " test features",
  )

  case alert_writer.upsert_and_diff(live_features, run_ended_sweep, ctx.db) {
    Ok(diff) -> {
      let new_count = list.length(diff.new)
      let updated_count = list.length(diff.updated)
      let ended_count = list.length(diff.ended)

      wisp.log_info(
        "Alerts: "
        <> string.inspect(new_count)
        <> " new, "
        <> string.inspect(updated_count)
        <> " updated, "
        <> string.inspect(ended_count)
        <> " ended",
      )

      alert_hub.record_write(ctx.hub, new_count, updated_count, ended_count)
      alert_hub.publish(ctx.hub, diff)

      Ok(#(
        string.inspect(new_count)
          <> " new, "
          <> string.inspect(updated_count)
          <> " updated, "
          <> string.inspect(ended_count)
          <> " ended",
        new_count,
        updated_count,
      ))
    }
    Error(err) -> {
      wisp.log_error("Error writing alerts to database: " <> err)
      Error(err)
    }
  }
}
