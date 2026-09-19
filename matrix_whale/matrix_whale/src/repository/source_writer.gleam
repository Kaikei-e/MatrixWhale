import domain/source.{type Source}
import gleam/dynamic/decode
import gleam/list
import gleam/result
import gleam/string
import pog

/// Upserts every registry row into `sea.source`. Static reference data, not
/// a decision, so a predicate-free "last writer wins" upsert is fine here.
pub fn sync(conn: pog.Connection) -> Result(Nil, String) {
  source.all |> list.try_each(fn(s) { upsert(s, conn) })
}

pub fn list_all(conn: pog.Connection) -> Result(List(Source), String) {
  pog.query(
    "SELECT id, name, homepage, license, attribution_text, redistributable, priority FROM sea.source ORDER BY priority DESC, id ASC",
  )
  |> pog.returning(source.row_decoder())
  |> pog.execute(conn)
  |> result.map(fn(x) { x.rows })
  |> result.map_error(fn(x) { "Database error: " <> string.inspect(x) })
}

const upsert_sql = "
  INSERT INTO sea.source (id, name, homepage, license, attribution_text, redistributable, priority)
  VALUES ($1, $2, $3, $4, $5, $6, $7)
  ON CONFLICT (id) DO UPDATE SET
    name = EXCLUDED.name,
    homepage = EXCLUDED.homepage,
    license = EXCLUDED.license,
    attribution_text = EXCLUDED.attribution_text,
    redistributable = EXCLUDED.redistributable,
    priority = EXCLUDED.priority"

fn upsert(s: Source, conn: pog.Connection) -> Result(Nil, String) {
  pog.query(upsert_sql)
  |> pog.parameter(pog.text(s.id))
  |> pog.parameter(pog.text(s.name))
  |> pog.parameter(pog.nullable(pog.text, s.homepage))
  |> pog.parameter(pog.text(s.license))
  |> pog.parameter(pog.text(s.attribution_text))
  |> pog.parameter(pog.bool(s.redistributable))
  |> pog.parameter(pog.int(s.priority))
  |> pog.returning(decode.success(Nil))
  |> pog.execute(conn)
  |> result.map(fn(_) { Nil })
  |> result.map_error(fn(x) { "Database error: " <> string.inspect(x) })
}
