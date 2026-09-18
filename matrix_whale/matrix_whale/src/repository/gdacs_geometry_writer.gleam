import domain/hazard.{type Hazard}
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import message/reciever/models/gdacs.{type GdacsGeometryResult}
import pog
import repository/gdacs_event_writer

pub type GeometryOutcome {
  GeometryOutcome(
    written: Int,
    deduped: Int,
    dropped: Int,
    changed_hazards: List(Hazard),
    applied: List(GdacsGeometryResult),
  )
}

type ApplyOutcome {
  Applied(Option(Hazard))
  AlreadyFetched
  Unknown
}

/// Episodes whose geometry has never been fetched, newest `datemodified`
/// first, up to `limit`.
pub fn pending(
  limit: Int,
  conn: pog.Connection,
) -> Result(List(#(String, Int, Int)), String) {
  pog.query(
    "SELECT event_type, event_id, episode_id FROM sea.gdacs_event WHERE geometry_fetched_at IS NULL ORDER BY modified_at_ms DESC LIMIT $1",
  )
  |> pog.parameter(pog.int(limit))
  |> pog.returning({
    use event_type <- decode.field(0, decode.string)
    use event_id <- decode.field(1, decode.int)
    use episode_id <- decode.field(2, decode.int)
    decode.success(#(event_type, event_id, episode_id))
  })
  |> pog.execute(conn)
  |> result.map(fn(x) { x.rows })
  |> result.map_error(err)
}

/// Applies fetched (or 204-empty) geometry results to their raw episode
/// rows, in one transaction, then recomputes each affected event's hazard
/// row. A recompute is only surfaced in `changed_hazards` when the episode
/// that just got its geometry is the event's current latest episode - that
/// is the only case the hazard's own `primary_geometry`/`geometries`
/// actually change.
pub fn apply(
  results: List(GdacsGeometryResult),
  now_ms: Int,
  conn: pog.Connection,
) -> Result(GeometryOutcome, String) {
  pog.transaction(conn, fn(tx) { apply_tx(results, now_ms, tx) })
  |> result.map_error(fn(x) {
    case x {
      pog.TransactionQueryError(x) -> err(x)
      pog.TransactionRolledBack(x) -> x
    }
  })
}

fn apply_tx(
  results: List(GdacsGeometryResult),
  now_ms: Int,
  conn: pog.Connection,
) -> Result(GeometryOutcome, String) {
  use outcomes <- result.try(
    list.try_map(results, fn(r) { apply_one(r, now_ms, conn) }),
  )
  let written =
    list.count(outcomes, fn(o) {
      case o {
        Applied(_) -> True
        _ -> False
      }
    })
  let deduped = list.count(outcomes, fn(o) { o == AlreadyFetched })
  let dropped = list.count(outcomes, fn(o) { o == Unknown })
  let changed =
    list.filter_map(outcomes, fn(o) {
      case o {
        Applied(Some(hazard_row)) -> Ok(hazard_row)
        _ -> Error(Nil)
      }
    })
  let applied =
    list.zip(results, outcomes)
    |> list.filter_map(fn(pair) {
      case pair.1 {
        Applied(_) -> Ok(pair.0)
        _ -> Error(Nil)
      }
    })
  Ok(GeometryOutcome(
    written:,
    deduped:,
    dropped:,
    changed_hazards: changed,
    applied:,
  ))
}

fn apply_one(
  r: GdacsGeometryResult,
  now_ms: Int,
  conn: pog.Connection,
) -> Result(ApplyOutcome, String) {
  use applied <- result.try(update_geometry(r, now_ms, conn))
  case applied {
    Some(current_origin_source_id) -> {
      use _ <- result.try(backfill_origin(r, current_origin_source_id, conn))
      use recompute <- result.try(gdacs_event_writer.recompute_hazard(
        r.event_type,
        r.event_id,
        now_ms,
        conn,
      ))
      let hazard_row = case recompute {
        gdacs_event_writer.New(h) -> h
        gdacs_event_writer.Updated(h) -> h
      }
      case hazard_row.source_episode_id == Some(int.to_string(r.episode_id)) {
        True -> Ok(Applied(Some(hazard_row)))
        False -> Ok(Applied(None))
      }
    }
    None -> {
      use exists <- result.try(episode_exists(r, conn))
      case exists {
        True -> Ok(AlreadyFetched)
        False -> Ok(Unknown)
      }
    }
  }
}

/// Applies the geometry write, returning the episode's `origin_source_id`
/// as it stood *before* this call (untouched by this UPDATE) when a row
/// was actually matched, or `None` when it was not (already fetched, or
/// the episode is unknown).
fn update_geometry(
  r: GdacsGeometryResult,
  now_ms: Int,
  conn: pog.Connection,
) -> Result(Option(Option(String)), String) {
  pog.query(
    "UPDATE sea.gdacs_event SET geometry=$4::jsonb, geometry_fetched_at=to_timestamp($5::double precision/1000), geometry_http_status=$6 WHERE event_type=$1 AND event_id=$2 AND episode_id=$3 AND geometry_fetched_at IS NULL RETURNING origin_source_id",
  )
  |> pog.parameter(pog.text(r.event_type))
  |> pog.parameter(pog.int(r.event_id))
  |> pog.parameter(pog.int(r.episode_id))
  |> pog.parameter(pog.nullable(pog.text, r.geometry))
  |> pog.parameter(pog.int(now_ms))
  |> pog.parameter(pog.int(r.http_status))
  |> pog.returning({
    use origin_source_id <- decode.field(0, decode.optional(decode.string))
    decode.success(origin_source_id)
  })
  |> pog.execute(conn)
  |> result.map(fn(x) { list.first(x.rows) |> option.from_result })
  |> result.map_error(err)
}

/// Backfills `origin_source`/`origin_source_id` from the geometry payload
/// when the episode row has none yet. Decided here, not in SQL: GDACS list
/// endpoints always send an empty `sourceid`, but `getgeometry` carries the
/// real cross-source id for NEIC-origin earthquakes.
fn backfill_origin(
  r: GdacsGeometryResult,
  current_origin_source_id: Option(String),
  conn: pog.Connection,
) -> Result(Nil, String) {
  case is_empty(current_origin_source_id), r.geometry {
    True, Some(geometry_json) ->
      case hazard.origin_from_geometry(geometry_json) {
        Some(#(source, source_id)) -> update_origin(r, source, source_id, conn)
        None -> Ok(Nil)
      }
    _, _ -> Ok(Nil)
  }
}

fn is_empty(value: Option(String)) -> Bool {
  case value {
    None -> True
    Some("") -> True
    Some(_) -> False
  }
}

fn update_origin(
  r: GdacsGeometryResult,
  source: String,
  source_id: String,
  conn: pog.Connection,
) -> Result(Nil, String) {
  pog.query(
    "UPDATE sea.gdacs_event SET origin_source=$4, origin_source_id=$5 WHERE event_type=$1 AND event_id=$2 AND episode_id=$3",
  )
  |> pog.parameter(pog.text(r.event_type))
  |> pog.parameter(pog.int(r.event_id))
  |> pog.parameter(pog.int(r.episode_id))
  |> pog.parameter(pog.text(source))
  |> pog.parameter(pog.text(source_id))
  |> pog.returning(decode.success(Nil))
  |> pog.execute(conn)
  |> result.map(fn(_) { Nil })
  |> result.map_error(err)
}

fn episode_exists(
  r: GdacsGeometryResult,
  conn: pog.Connection,
) -> Result(Bool, String) {
  pog.query(
    "SELECT 1 FROM sea.gdacs_event WHERE event_type=$1 AND event_id=$2 AND episode_id=$3",
  )
  |> pog.parameter(pog.text(r.event_type))
  |> pog.parameter(pog.int(r.event_id))
  |> pog.parameter(pog.int(r.episode_id))
  |> pog.returning(decode.success(Nil))
  |> pog.execute(conn)
  |> result.map(fn(x) { !list.is_empty(x.rows) })
  |> result.map_error(err)
}

fn err(x: pog.QueryError) -> String {
  "Database error: " <> string.inspect(x)
}
