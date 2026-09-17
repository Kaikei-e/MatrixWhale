import domain/earthquake.{type Earthquake}
import gleam/dynamic/decode
import gleam/result
import gleam/string
import pog

pub type MagnitudeFilter {
  Minimum(Float)
  AllMagnitudes
}

pub type TypeFilter {
  EarthquakesOnly
  AllTypes
}

pub fn recent(
  hours: Int,
  minmag: MagnitudeFilter,
  type_: TypeFilter,
  conn: pog.Connection,
) -> Result(List(Earthquake), String) {
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
    <> earthquake.columns
    <> " FROM sea.earthquake WHERE occurred_at >= now() - ($1 || ' hours')::interval AND status IS DISTINCT FROM 'deleted' AND ($2::double precision IS NULL OR magnitude >= $2) AND ($3::text IS NULL OR event_type=$3) ORDER BY occurred_at DESC, source, source_id",
  )
  |> pog.parameter(pog.text(string.inspect(hours)))
  |> pog.parameter(magnitude)
  |> pog.parameter(event_type)
  |> pog.returning(earthquake.row_decoder())
  |> pog.execute(conn)
  |> result.map(fn(x) { x.rows })
  |> result.map_error(fn(x) { "Database error: " <> string.inspect(x) })
}

/// ON DELETE CASCADE removes every revision in the same transaction as its
/// parent projection, so concurrent source revisions cannot become orphans.
pub fn cleanup(conn: pog.Connection) -> Result(Int, String) {
  pog.transaction(conn, fn(tx) {
    pog.query(
      "DELETE FROM sea.earthquake WHERE occurred_at <= now() - interval '7 days'",
    )
    |> pog.returning(decode.success(Nil))
    |> pog.execute(tx)
    |> result.map(fn(_) { 0 })
    |> result.map_error(fn(x) { string.inspect(x) })
  })
  |> result.map_error(fn(x) { string.inspect(x) })
}
