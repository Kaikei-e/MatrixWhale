import domain/earthquake.{type MagnitudeFilter, AllMagnitudes, Minimum}
import domain/event.{type Event, type EventView}
import gleam/dynamic/decode
import gleam/list
import gleam/result
import gleam/string
import pog
import repository/event_writer

pub type TypeFilter {
  EarthquakesOnly
  AllTypes
}

pub fn recent(
  hours: Int,
  minmag: MagnitudeFilter,
  type_: TypeFilter,
  conn: pog.Connection,
) -> Result(List(EventView), String) {
  use rows <- result.try(select_events(hours, minmag, type_, conn))
  rows |> list.try_map(fn(row) { event_writer.to_view(row, conn) })
}

fn select_events(
  hours: Int,
  minmag: MagnitudeFilter,
  type_: TypeFilter,
  conn: pog.Connection,
) -> Result(List(Event), String) {
  let magnitude = case minmag {
    Minimum(value) -> pog.float(value)
    AllMagnitudes -> pog.null()
  }
  let event_type = case type_ {
    EarthquakesOnly -> pog.text("earthquake")
    AllTypes -> pog.null()
  }
  pog.query(
    "SELECT "
    <> event.columns
    <> " FROM sea.event WHERE occurred_at >= now() - ($1 || ' hours')::interval AND status IS DISTINCT FROM 'deleted' AND ($2::double precision IS NULL OR magnitude >= $2) AND ($3::text IS NULL OR event_type=$3) ORDER BY occurred_at DESC, id",
  )
  |> pog.parameter(pog.text(string.inspect(hours)))
  |> pog.parameter(magnitude)
  |> pog.parameter(event_type)
  |> pog.returning(event.row_decoder())
  |> pog.execute(conn)
  |> result.map(fn(x) { x.rows })
  |> result.map_error(fn(x) { "Database error: " <> string.inspect(x) })
}

pub fn by_ids(
  ids: List(Int),
  conn: pog.Connection,
) -> Result(List(EventView), String) {
  use rows <- result.try(select_events_by_ids(ids, conn))
  rows |> list.try_map(fn(row) { event_writer.to_view(row, conn) })
}

fn select_events_by_ids(
  ids: List(Int),
  conn: pog.Connection,
) -> Result(List(Event), String) {
  pog.query("SELECT " <> event.columns <> " FROM sea.event WHERE id = ANY($1)")
  |> pog.parameter(pog.array(pog.int, ids))
  |> pog.returning(event.row_decoder())
  |> pog.execute(conn)
  |> result.map(fn(x) { x.rows })
  |> result.map_error(fn(x) { "Database error: " <> string.inspect(x) })
}

/// ON DELETE CASCADE removes every revision and event membership in the same
/// transaction as its parent projection, so concurrent source revisions
/// cannot become orphans.
pub fn cleanup(conn: pog.Connection) -> Result(Int, String) {
  pog.transaction(conn, fn(tx) {
    use _ <- result.try(
      pog.query(
        "DELETE FROM sea.earthquake WHERE occurred_at <= now() - interval '7 days'",
      )
      |> pog.returning(decode.success(Nil))
      |> pog.execute(tx)
      |> result.map(fn(_) { Nil })
      |> result.map_error(fn(x) { string.inspect(x) }),
    )
    pog.query(
      "DELETE FROM sea.event WHERE occurred_at <= now() - interval '7 days'",
    )
    |> pog.returning(decode.success(Nil))
    |> pog.execute(tx)
    |> result.map(fn(_) { 0 })
    |> result.map_error(fn(x) { string.inspect(x) })
  })
  |> result.map_error(fn(x) { string.inspect(x) })
}
