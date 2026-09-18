import adapter/context.{type Context}
import adapter/hazard_hub
import controller/earthquake_controller
import domain/source
import gleam/int
import gleam/list
import gleam/option
import gleam/result
import gleam/time/timestamp
import intake/pipeline
import intake/record.{Incoming, Key}
import message/reciever/models/gdacs.{
  type GdacsFeature, type GdacsGeometryResult,
}
import repository/gdacs_event_writer
import repository/gdacs_geometry_writer
import wisp

pub type GdacsResult {
  GdacsResult(new: Int, updated: Int, unchanged: Int, stale: Int, repeats: Int)
}

pub type GdacsGeometryResultAck {
  GdacsGeometryResultAck(written: Int, deduped: Int, dropped: Int)
}

/// Decodes-and-classifies GDACS list features through the raw/hazard
/// intake pipeline, one transaction per chunk, same as every other source.
/// Unlike the other earthquake sources, this does not also drive the
/// earthquake pipeline: GDACS list endpoints always send an empty
/// `sourceid`, so there is no cross-source id to dual-write with yet - that
/// only becomes available once `process_geometry` backfills it from
/// `getgeometry`.
pub fn process(
  features: List(GdacsFeature),
  ctx: Context,
) -> Result(GdacsResult, String) {
  let now_ms = current_ms()
  let records =
    list.map(features, fn(feature) {
      Incoming(
        key: Key("gdacs", gdacs_key(feature)),
        revision: feature.modified_at_ms,
        payload: feature,
      )
    })

  pipeline.run(records, ctx.seen, now_ms, fn(survivors) {
    gdacs_event_writer.write_batch(survivors, now_ms, ctx.db)
  })
  |> result.map(fn(outcome) {
    let new_hazards = list.flat_map(outcome.results, fn(r) { r.new_hazards })
    let updated_hazards =
      list.flat_map(outcome.results, fn(r) { r.updated_hazards })
    hazard_hub.publish(ctx.hazard_hub, new_hazards, updated_hazards)

    GdacsResult(
      new: outcome.new,
      updated: outcome.updated,
      unchanged: outcome.unchanged,
      stale: outcome.stale,
      repeats: outcome.repeats,
    )
  })
  |> result.map_error(fn(error) { "GDACS database write failed: " <> error })
}

/// Applies fetched geometry results, publishes `update` for whichever
/// hazards actually changed, then drives every applied `EQ` episode's raw
/// row - now possibly carrying a backfilled USGS id - through the existing
/// earthquake pipeline as a third source. A failure in the earthquake path
/// is logged but does not fail this call or change its ack - the geometry
/// write already committed by that point.
pub fn process_geometry(
  results: List(GdacsGeometryResult),
  backfill: Bool,
  ctx: Context,
) -> Result(GdacsGeometryResultAck, String) {
  let now_ms = current_ms()
  gdacs_geometry_writer.apply(results, now_ms, ctx.db)
  |> result.map(fn(outcome) {
    hazard_hub.publish(ctx.hazard_hub, [], outcome.changed_hazards)
    run_geometry_earthquake_path(outcome.applied, backfill, ctx)
    GdacsGeometryResultAck(
      written: outcome.written,
      deduped: outcome.deduped,
      dropped: outcome.dropped,
    )
  })
  |> result.map_error(fn(error) { "GDACS geometry write failed: " <> error })
}

fn run_geometry_earthquake_path(
  applied: List(GdacsGeometryResult),
  backfill: Bool,
  ctx: Context,
) -> Nil {
  let eq_rows =
    applied
    |> list.filter(fn(r) { r.event_type == "EQ" })
    |> list.filter_map(fn(r) { load_eq_feature(r, ctx) })
  let _ = run_earthquake_path(eq_rows, backfill, ctx)
  Nil
}

fn load_eq_feature(
  r: GdacsGeometryResult,
  ctx: Context,
) -> Result(GdacsFeature, Nil) {
  case
    gdacs_event_writer.load_feature(
      r.event_type,
      r.event_id,
      r.episode_id,
      ctx.db,
    )
  {
    Ok(option.Some(feature)) -> Ok(feature)
    Ok(option.None) -> Error(Nil)
    Error(error) -> {
      wisp.log_error("GDACS geometry row load failed: " <> error)
      Error(Nil)
    }
  }
}

fn run_earthquake_path(
  features: List(GdacsFeature),
  backfill: Bool,
  ctx: Context,
) -> Int {
  case option.values(list.map(features, gdacs.to_incoming_earthquake)) {
    [] -> 0
    eq_features ->
      case
        earthquake_controller.process(source.gdacs, eq_features, backfill, ctx)
      {
        Ok(result) -> result.matched
        Error(error) -> {
          wisp.log_error("GDACS earthquake path failed: " <> error)
          0
        }
      }
  }
}

fn gdacs_key(feature: GdacsFeature) -> String {
  feature.event_type
  <> "-"
  <> int.to_string(feature.event_id)
  <> "-"
  <> int.to_string(feature.episode_id)
}

fn current_ms() -> Int {
  let #(seconds, nanoseconds) =
    timestamp.system_time() |> timestamp.to_unix_seconds_and_nanoseconds
  seconds * 1000 + nanoseconds / 1_000_000
}
