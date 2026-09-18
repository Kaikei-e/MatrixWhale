import domain/earthquake
import domain/hazard.{type Hazard, type HazardEpisode}
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/string
import pog

/// Hazards modified within the last `hours`, optionally filtered to a set
/// of GDACS type codes (e.g. `["EQ", "TC"]`, translated to `hazard_type`)
/// and/or a set of alert levels (`["orange", "red"]`), newest first.
pub fn recent(
  hours: Int,
  types: List(String),
  levels: List(String),
  conn: pog.Connection,
) -> Result(List(Hazard), String) {
  let type_filter = case types {
    [] -> pog.null()
    codes -> pog.array(pog.text, list.map(codes, hazard.hazard_type_for))
  }
  let level_filter = case levels {
    [] -> pog.null()
    ls -> pog.array(pog.text, list.map(ls, string.lowercase))
  }
  pog.query(
    "SELECT "
    <> hazard.columns
    <> " FROM sea.hazard WHERE modified_at >= now() - ($1 || ' hours')::interval AND ($2::text[] IS NULL OR hazard_type = ANY($2)) AND ($3::text[] IS NULL OR alert_level = ANY($3)) ORDER BY modified_at_ms DESC",
  )
  |> pog.parameter(pog.text(string.inspect(hours)))
  |> pog.parameter(type_filter)
  |> pog.parameter(level_filter)
  |> pog.returning(hazard.row_decoder())
  |> pog.execute(conn)
  |> result.map(fn(x) { x.rows })
  |> result.map_error(err)
}

/// Hazards by exact `(source, source_id)` key, in no particular order.
pub fn by_keys(
  keys: List(#(String, String)),
  conn: pog.Connection,
) -> Result(List(Hazard), String) {
  let sources = list.map(keys, fn(key) { key.0 })
  let source_ids = list.map(keys, fn(key) { key.1 })
  pog.query(
    "SELECT "
    <> hazard.columns
    <> " FROM sea.hazard WHERE (source, source_id) IN (SELECT * FROM unnest($1::text[], $2::text[]))",
  )
  |> pog.parameter(pog.array(pog.text, sources))
  |> pog.parameter(pog.array(pog.text, source_ids))
  |> pog.returning(hazard.row_decoder())
  |> pog.execute(conn)
  |> result.map(fn(x) { x.rows })
  |> result.map_error(err)
}

/// A hazard's full detail (including `geometries`) plus its raw episode
/// history. `episodes` is only populated for GDACS-sourced hazards, whose
/// `source_id` is `"<event_type>-<event_id>"`.
pub fn detail(
  source: String,
  source_id: String,
  conn: pog.Connection,
) -> Result(Option(#(Hazard, List(HazardEpisode))), String) {
  use maybe_hazard <- result.try(select_hazard(source, source_id, conn))
  case maybe_hazard {
    option.None -> Ok(option.None)
    option.Some(h) -> {
      use episodes <- result.try(episodes_for(source, source_id, conn))
      Ok(option.Some(#(h, episodes)))
    }
  }
}

fn select_hazard(
  source: String,
  source_id: String,
  conn: pog.Connection,
) -> Result(Option(Hazard), String) {
  pog.query(
    "SELECT "
    <> hazard.columns
    <> " FROM sea.hazard WHERE source = $1 AND source_id = $2",
  )
  |> pog.parameter(pog.text(source))
  |> pog.parameter(pog.text(source_id))
  |> pog.returning(hazard.row_decoder())
  |> pog.execute(conn)
  |> result.map(fn(x) { list.first(x.rows) |> option.from_result })
  |> result.map_error(err)
}

fn episodes_for(
  source: String,
  source_id: String,
  conn: pog.Connection,
) -> Result(List(HazardEpisode), String) {
  case source, string.split_once(source_id, "-") {
    "gdacs", Ok(#(event_type, event_id_text)) ->
      case int.parse(event_id_text) {
        Ok(event_id) -> select_episodes(event_type, event_id, conn)
        Error(Nil) -> Ok([])
      }
    _, _ -> Ok([])
  }
}

fn select_episodes(
  event_type: String,
  event_id: Int,
  conn: pog.Connection,
) -> Result(List(HazardEpisode), String) {
  pog.query(
    "SELECT episode_id, alert_level, alert_score, severity_value, severity_text, from_at, to_at, modified_at, (geometry IS NOT NULL) FROM sea.gdacs_event WHERE event_type = $1 AND event_id = $2 ORDER BY episode_id DESC",
  )
  |> pog.parameter(pog.text(event_type))
  |> pog.parameter(pog.int(event_id))
  |> pog.returning(episode_row_decoder())
  |> pog.execute(conn)
  |> result.map(fn(x) { x.rows })
  |> result.map_error(err)
}

fn episode_row_decoder() -> decode.Decoder(HazardEpisode) {
  use episode_id <- decode.field(0, decode.int)
  use alert_level <- decode.field(1, decode.string)
  use alert_score <- decode.field(2, decode.optional(decode.float))
  use severity_value <- decode.field(3, decode.optional(decode.float))
  use severity_label <- decode.field(4, decode.optional(decode.string))
  use from_at <- decode.field(5, earthquake.timestamptz_decoder())
  use to_at <- decode.field(
    6,
    decode.optional(earthquake.timestamptz_decoder()),
  )
  use modified_at <- decode.field(7, earthquake.timestamptz_decoder())
  use has_geometry <- decode.field(8, decode.bool)
  decode.success(hazard.HazardEpisode(
    episode_id:,
    alert_level: string.lowercase(alert_level),
    alert_score:,
    severity_value:,
    severity_label:,
    from_at:,
    to_at:,
    modified_at:,
    has_geometry:,
  ))
}

fn err(x: pog.QueryError) -> String {
  "Database error: " <> string.inspect(x)
}
