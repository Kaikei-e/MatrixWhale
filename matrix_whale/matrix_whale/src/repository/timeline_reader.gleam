import domain/earthquake.{AllMagnitudes, Minimum}
import domain/timeline.{
  type Kind, type Query, type TimelineItem, AlertKey, Cursor, EarthquakeKey,
  HazardKey,
}
import gleam/dict
import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/string
import pog
import repository/alert_reader
import repository/earthquake_reader
import repository/hazard_reader

pub type Page {
  Page(items: List(TimelineItem), next_cursor: Option(String))
}

pub fn page(query: Query, conn: pog.Connection) -> Result(Page, String) {
  use rows <- result.try(select_keys(query, conn))
  use items <- result.try(fetch_items(rows, conn))
  let next_cursor = case list.length(rows) == query.limit {
    True -> list.last(rows) |> result.map(row_cursor) |> option.from_result
    False -> option.None
  }
  Ok(Page(items:, next_cursor:))
}

type KeyRow {
  KeyRow(kind: Kind, key: String, first_seen_at_text: String)
}

fn row_cursor(row: KeyRow) -> String {
  timeline.encode_cursor(Cursor(
    first_seen_at_text: row.first_seen_at_text,
    kind: row.kind,
    key: row.key,
  ))
}

const keyset_sql = "WITH filtered AS (
  SELECT 'earthquake'::text AS kind, 'earthquake:' || id::text AS key, first_seen_at
    FROM sea.event
   WHERE status IS DISTINCT FROM 'deleted'
     AND ($1::double precision IS NULL OR magnitude >= $1)
     AND (NOT $2::boolean OR magnitude IS NOT NULL)
     AND ($3::double precision IS NULL OR magnitude >= $3)
  UNION ALL
  SELECT 'hazard'::text AS kind, 'hazard:' || source || ':' || source_id AS key, first_seen_at
    FROM sea.hazard
   WHERE hazard_type <> 'earthquake'
     AND ($4::text[] IS NULL OR cap_severity = ANY($4))
  UNION ALL
  SELECT 'alert'::text AS kind, 'alert:' || source || ':' || source_id AS key, first_seen_at
    FROM sea.alert
   WHERE ($5::text[] IS NULL OR severity = ANY($5))
)
SELECT kind, key, first_seen_at::text AS first_seen_at_text
  FROM filtered
 WHERE kind = ANY($6)
   AND ($7::text IS NULL OR ROW(first_seen_at, kind, key) < ROW($7::text::timestamptz, $8, $9))
 ORDER BY first_seen_at DESC, kind DESC, key DESC
 LIMIT $10"

fn select_keys(
  query: Query,
  conn: pog.Connection,
) -> Result(List(KeyRow), String) {
  let floor = timeline.earthquake_floor_for(query.min_severity)
  let minmag = case query.minmag {
    Minimum(value) -> pog.float(value)
    AllMagnitudes -> pog.null()
  }
  let #(cursor_ts, cursor_kind, cursor_key) = case query.before {
    option.None -> #(pog.null(), pog.null(), pog.null())
    option.Some(cursor) -> #(
      pog.text(cursor.first_seen_at_text),
      pog.text(timeline.kind_to_string(cursor.kind)),
      pog.text(cursor.key),
    )
  }
  pog.query(keyset_sql)
  |> pog.parameter(minmag)
  |> pog.parameter(pog.bool(floor.require_magnitude))
  |> pog.parameter(pog.nullable(pog.float, floor.minimum))
  |> pog.parameter(
    nullable_text_array(timeline.hazard_cap_severities_for(query.min_severity)),
  )
  |> pog.parameter(
    nullable_text_array(timeline.alert_severities_for(query.min_severity)),
  )
  |> pog.parameter(pog.array(
    pog.text,
    list.map(query.kinds, timeline.kind_to_string),
  ))
  |> pog.parameter(cursor_ts)
  |> pog.parameter(cursor_kind)
  |> pog.parameter(cursor_key)
  |> pog.parameter(pog.int(query.limit))
  |> pog.returning(key_row_decoder())
  |> pog.execute(conn)
  |> result.map(fn(x) { x.rows })
  |> result.map_error(err)
}

fn nullable_text_array(values: Option(List(String))) -> pog.Value {
  case values {
    option.Some(list) -> pog.array(pog.text, list)
    option.None -> pog.null()
  }
}

fn key_row_decoder() -> decode.Decoder(KeyRow) {
  use kind_text <- decode.field(0, decode.string)
  use key <- decode.field(1, decode.string)
  use first_seen_at_text <- decode.field(2, decode.string)
  case timeline.parse_kind(kind_text) {
    Ok(kind) -> decode.success(KeyRow(kind:, key:, first_seen_at_text:))
    Error(Nil) -> decode.failure(KeyRow(timeline.Earthquake, "", ""), "kind")
  }
}

fn fetch_items(
  rows: List(KeyRow),
  conn: pog.Connection,
) -> Result(List(TimelineItem), String) {
  use parsed <- result.try(
    rows
    |> list.try_map(fn(row) {
      timeline.parse_key(row.key) |> result.map(fn(key) { #(row, key) })
    }),
  )

  let earthquake_ids =
    parsed
    |> list.filter_map(fn(pair) {
      case pair.1 {
        EarthquakeKey(id) -> Ok(id)
        _ -> Error(Nil)
      }
    })
  let hazard_keys =
    parsed
    |> list.filter_map(fn(pair) {
      case pair.1 {
        HazardKey(source, source_id) -> Ok(#(source, source_id))
        _ -> Error(Nil)
      }
    })
  let alert_ids =
    parsed
    |> list.filter_map(fn(pair) {
      case pair.1 {
        AlertKey(source, source_id) -> Ok(source <> ":" <> source_id)
        _ -> Error(Nil)
      }
    })

  use earthquakes <- result.try(earthquake_reader.by_ids(earthquake_ids, conn))
  use hazards <- result.try(hazard_reader.by_keys(hazard_keys, conn))
  use alerts <- result.try(alert_reader.by_ids(alert_ids, conn))

  let items_by_key =
    list.flatten([
      list.map(earthquakes, fn(view) {
        #(
          timeline.earthquake_key(view.event.id),
          timeline.from_earthquake(view),
        )
      }),
      list.map(hazards, fn(row) {
        #(
          timeline.hazard_key(row.source, row.source_id),
          timeline.from_hazard(row),
        )
      }),
      list.map(alerts, fn(row) {
        #(
          timeline.alert_key(row.source, row.source_id),
          timeline.from_alert(row),
        )
      }),
    ])
    |> dict.from_list

  Ok(rows |> list.filter_map(fn(row) { dict.get(items_by_key, row.key) }))
}

fn err(x: pog.QueryError) -> String {
  "Database error: " <> string.inspect(x)
}
