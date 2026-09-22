import domain/hazard.{type Hazard}
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/string
import intake/pipeline.{type Written, Written}
import intake/record.{type Incoming, type Key, type Verdict, Incoming, Key}
import message/reciever/models/gdacs.{type GdacsFeature}
import pog

pub type GdacsWriteResult {
  GdacsWriteResult(
    written_features: List(GdacsFeature),
    new_hazards: List(Hazard),
    updated_hazards: List(Hazard),
  )
}

const empty_result = GdacsWriteResult(
  written_features: [],
  new_hazards: [],
  updated_hazards: [],
)

pub fn write_batch(
  records: List(Incoming(GdacsFeature)),
  now_ms: Int,
  conn: pog.Connection,
) -> Result(Written(GdacsWriteResult), String) {
  case records {
    [] -> Ok(Written(empty_result, 0, 0, 0, 0))
    _ ->
      pog.transaction(conn, fn(tx) { write_batch_tx(records, now_ms, tx) })
      |> result.map_error(fn(x) {
        case x {
          pog.TransactionQueryError(x) -> err(x)
          pog.TransactionRolledBack(x) -> x
        }
      })
  }
}

fn write_batch_tx(
  records: List(Incoming(GdacsFeature)),
  now_ms: Int,
  conn: pog.Connection,
) -> Result(Written(GdacsWriteResult), String) {
  use #(current, current_origins) <- result.try(load_current(records, conn))
  let classified = record.classify(records, current)

  let #(new_pairs, rest) =
    list.partition(classified, fn(pair) { pair.1 == record.New })
  let #(updated_pairs, rest) = list.partition(rest, is_updated)
  let #(unchanged_pairs, stale_pairs) =
    list.partition(rest, fn(pair) { pair.1 == record.Unchanged })
  let updated_pairs =
    list.map(updated_pairs, fn(pair) {
      #(preserve_origin(pair.0, current_origins), pair.1)
    })

  use #(inserted, insert_lost) <- result.try(insert_new(new_pairs, now_ms, conn))
  use #(updated, update_lost) <- result.try(update_existing(
    updated_pairs,
    now_ms,
    conn,
  ))

  let written = list.append(inserted, updated)
  let affected =
    written
    |> list.map(fn(x) { #(x.1, x.2) })
    |> list.unique

  use hazards <- result.try(
    affected
    |> list.try_map(fn(pair) { recompute_hazard(pair.0, pair.1, now_ms, conn) }),
  )
  let new_hazards =
    list.filter_map(hazards, fn(h) {
      case h {
        New(hazard) -> Ok(hazard)
        Updated(_) | Skipped -> Error(Nil)
      }
    })
  let updated_hazards =
    list.filter_map(hazards, fn(h) {
      case h {
        Updated(hazard) -> Ok(hazard)
        New(_) | Skipped -> Error(Nil)
      }
    })

  Ok(Written(
    result: GdacsWriteResult(
      written_features: list.map(written, fn(x) { x.0 }),
      new_hazards:,
      updated_hazards:,
    ),
    new: list.length(inserted),
    updated: list.length(updated),
    unchanged: list.length(unchanged_pairs) + insert_lost + update_lost,
    stale: list.length(stale_pairs),
  ))
}

pub type HazardRecompute {
  New(Hazard)
  Updated(Hazard)
  Skipped
}

fn is_updated(pair: #(Incoming(GdacsFeature), Verdict)) -> Bool {
  case pair.1 {
    record.Updated(_) -> True
    _ -> False
  }
}

fn composite_key(event_type: String, event_id: Int, episode_id: Int) -> String {
  event_type
  <> "-"
  <> int.to_string(event_id)
  <> "-"
  <> int.to_string(episode_id)
}

type OriginPair =
  #(Option(String), Option(String))

fn load_current(
  records: List(Incoming(GdacsFeature)),
  conn: pog.Connection,
) -> Result(#(Dict(Key, Int), Dict(Key, OriginPair)), String) {
  let keys =
    list.map(records, fn(r) {
      composite_key(
        r.payload.event_type,
        r.payload.event_id,
        r.payload.episode_id,
      )
    })
  pog.query(
    "SELECT event_type, event_id, episode_id, modified_at_ms, origin_source, origin_source_id FROM sea.gdacs_event WHERE (event_type || '-' || event_id::text || '-' || episode_id::text) = ANY($1) FOR UPDATE",
  )
  |> pog.parameter(pog.array(pog.text, keys))
  |> pog.returning({
    use event_type <- decode.field(0, decode.string)
    use event_id <- decode.field(1, decode.int)
    use episode_id <- decode.field(2, decode.int)
    use modified_at_ms <- decode.field(3, decode.int)
    use origin_source <- decode.field(4, decode.optional(decode.string))
    use origin_source_id <- decode.field(5, decode.optional(decode.string))
    decode.success(#(
      event_type,
      event_id,
      episode_id,
      modified_at_ms,
      origin_source,
      origin_source_id,
    ))
  })
  |> pog.execute(conn)
  |> result.map(fn(x) {
    list.fold(x.rows, #(dict.new(), dict.new()), fn(acc, row) {
      let #(
        event_type,
        event_id,
        episode_id,
        modified_at_ms,
        origin_source,
        origin_source_id,
      ) = row
      let key = Key("gdacs", composite_key(event_type, event_id, episode_id))
      #(
        dict.insert(acc.0, key, modified_at_ms),
        dict.insert(acc.1, key, #(origin_source, origin_source_id)),
      )
    })
  })
  |> result.map_error(err)
}

/// Applies `hazard.merge_origin` to an `Updated` record before it is
/// written, so a list poll's perpetually-empty origin never overwrites what
/// `getgeometry` backfilled onto the current row.
fn preserve_origin(
  incoming: Incoming(GdacsFeature),
  current_origins: Dict(Key, OriginPair),
) -> Incoming(GdacsFeature) {
  case dict.get(current_origins, incoming.key) {
    Error(Nil) -> incoming
    Ok(#(current_source, current_source_id)) -> {
      let payload = incoming.payload
      let #(origin_source, origin_source_id) =
        hazard.merge_origin(
          payload.origin_source,
          payload.origin_source_id,
          current_source,
          current_source_id,
        )
      Incoming(
        ..incoming,
        payload: gdacs.GdacsFeature(
          ..payload,
          origin_source:,
          origin_source_id:,
        ),
      )
    }
  }
}

const insert_sql = "INSERT INTO sea.gdacs_event (event_type,event_id,episode_id,alert_level,alert_score,episode_alert_level,episode_alert_score,name,event_name,description,html_description,country,iso3,glide,origin_source,origin_source_id,severity_value,severity_unit,severity_text,from_at,from_at_ms,to_at,to_at_ms,modified_at,modified_at_ms,is_current,is_temporary,longitude,latitude,bbox_west,bbox_south,bbox_east,bbox_north,affected_countries,report_url,geometry_url,icon_url,raw,first_seen_at,last_seen_at) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,to_timestamp($20::double precision/1000),$20,to_timestamp($21::double precision/1000),$21,to_timestamp($22::double precision/1000),$22,$23,$24,$25,$26,$27,$28,$29,$30,$31,$32,$33,$34,$35::jsonb,to_timestamp($36::double precision/1000),to_timestamp($36::double precision/1000)) ON CONFLICT (event_type,event_id,episode_id) DO NOTHING RETURNING event_type, event_id, episode_id"

const update_sql = "UPDATE sea.gdacs_event SET alert_level=$4,alert_score=$5,episode_alert_level=$6,episode_alert_score=$7,name=$8,event_name=$9,description=$10,html_description=$11,country=$12,iso3=$13,glide=$14,origin_source=$15,origin_source_id=$16,severity_value=$17,severity_unit=$18,severity_text=$19,from_at=to_timestamp($20::double precision/1000),from_at_ms=$20,to_at=to_timestamp($21::double precision/1000),to_at_ms=$21,modified_at=to_timestamp($22::double precision/1000),modified_at_ms=$22,is_current=$23,is_temporary=$24,longitude=$25,latitude=$26,bbox_west=$27,bbox_south=$28,bbox_east=$29,bbox_north=$30,affected_countries=$31,report_url=$32,geometry_url=$33,icon_url=$34,raw=$35::jsonb,last_seen_at=to_timestamp($36::double precision/1000) WHERE event_type=$1 AND event_id=$2 AND episode_id=$3 RETURNING event_type, event_id, episode_id"

fn insert_new(
  pairs: List(#(Incoming(GdacsFeature), Verdict)),
  now_ms: Int,
  conn: pog.Connection,
) -> Result(#(List(#(GdacsFeature, String, Int)), Int), String) {
  use results <- result.try(
    pairs
    |> list.try_map(fn(pair) { run_write(insert_sql, pair.0, now_ms, conn) })
    |> result.map_error(err),
  )
  let rows = option.values(results)
  Ok(#(rows, list.length(results) - list.length(rows)))
}

fn update_existing(
  pairs: List(#(Incoming(GdacsFeature), Verdict)),
  now_ms: Int,
  conn: pog.Connection,
) -> Result(#(List(#(GdacsFeature, String, Int)), Int), String) {
  use results <- result.try(
    pairs
    |> list.try_map(fn(pair) { run_write(update_sql, pair.0, now_ms, conn) })
    |> result.map_error(err),
  )
  let rows = option.values(results)
  Ok(#(rows, list.length(results) - list.length(rows)))
}

fn run_write(
  sql: String,
  incoming: Incoming(GdacsFeature),
  now_ms: Int,
  conn: pog.Connection,
) -> Result(Option(#(GdacsFeature, String, Int)), pog.QueryError) {
  bind_params(pog.query(sql), incoming.payload, now_ms)
  |> pog.returning({
    use event_type <- decode.field(0, decode.string)
    use event_id <- decode.field(1, decode.int)
    decode.success(#(event_type, event_id))
  })
  |> pog.execute(conn)
  |> result.map(fn(x) {
    list.first(x.rows)
    |> option.from_result
    |> option.map(fn(row) { #(incoming.payload, row.0, row.1) })
  })
}

fn bind_params(query, x: GdacsFeature, now_ms: Int) {
  query
  |> pog.parameter(pog.text(x.event_type))
  |> pog.parameter(pog.int(x.event_id))
  |> pog.parameter(pog.int(x.episode_id))
  |> pog.parameter(pog.text(x.alert_level))
  |> float(x.alert_score)
  |> text(x.episode_alert_level)
  |> float(x.episode_alert_score)
  |> text(x.name)
  |> text(x.event_name)
  |> text(x.description)
  |> text(x.html_description)
  |> text(x.country)
  |> text(x.iso3)
  |> text(x.glide)
  |> text(x.origin_source)
  |> text(x.origin_source_id)
  |> float(x.severity_value)
  |> text(x.severity_unit)
  |> text(x.severity_text)
  |> pog.parameter(pog.int(x.from_at_ms))
  |> integer(x.to_at_ms)
  |> pog.parameter(pog.int(x.modified_at_ms))
  |> pog.parameter(pog.bool(x.is_current))
  |> pog.parameter(pog.bool(x.is_temporary))
  |> pog.parameter(pog.float(x.longitude))
  |> pog.parameter(pog.float(x.latitude))
  |> float(x.bbox_west)
  |> float(x.bbox_south)
  |> float(x.bbox_east)
  |> float(x.bbox_north)
  |> pog.parameter(pog.array(pog.text, x.affected_countries))
  |> text(x.report_url)
  |> text(x.geometry_url)
  |> text(x.icon_url)
  |> pog.parameter(pog.text(x.raw))
  |> pog.parameter(pog.int(now_ms))
}

fn text(q, x) {
  pog.parameter(q, pog.nullable(pog.text, x))
}

fn float(q, x) {
  pog.parameter(q, pog.nullable(pog.float, x))
}

fn integer(q, x) {
  pog.parameter(q, pog.nullable(pog.int, x))
}

/// Recomputes `sea.hazard` for one GDACS event from all its known episodes,
/// in the same transaction as the raw write that triggered it. Stateless by
/// design: the result depends only on the latest episode row, never on the
/// hazard row's previous contents (besides `first_seen_at`).
pub fn recompute_hazard(
  event_type: String,
  event_id: Int,
  now_ms: Int,
  conn: pog.Connection,
) -> Result(HazardRecompute, String) {
  use rows <- result.try(load_episodes(event_type, event_id, conn))
  let active_rows = hazard.active_episodes(rows)
  case hazard.latest_episode(active_rows) {
    option.None -> Ok(Skipped)
    option.Some(latest) -> {
      let normalized = hazard.normalize(latest, list.length(active_rows))
      write_hazard(normalized, now_ms, conn)
    }
  }
}

fn load_episodes(
  event_type: String,
  event_id: Int,
  conn: pog.Connection,
) -> Result(List(hazard.GdacsEpisodeRow), String) {
  pog.query(
    "SELECT "
    <> hazard.episode_columns
    <> " FROM sea.gdacs_event WHERE event_type = $1 AND event_id = $2",
  )
  |> pog.parameter(pog.text(event_type))
  |> pog.parameter(pog.int(event_id))
  |> pog.returning(hazard.episode_row_decoder())
  |> pog.execute(conn)
  |> result.map(fn(x) { x.rows })
  |> result.map_error(err)
}

fn write_hazard(
  normalized: hazard.NormalizedHazard,
  now_ms: Int,
  conn: pog.Connection,
) -> Result(HazardRecompute, String) {
  use existing <- result.try(hazard_exists(normalized.source_id, conn))
  case existing {
    True ->
      run_hazard_write(hazard_update_sql, normalized, now_ms, conn)
      |> result.map(Updated)
    False ->
      run_hazard_write(hazard_insert_sql, normalized, now_ms, conn)
      |> result.map(New)
  }
}

fn hazard_exists(
  source_id: String,
  conn: pog.Connection,
) -> Result(Bool, String) {
  pog.query(
    "SELECT 1 FROM sea.hazard WHERE source = 'gdacs' AND source_id = $1 FOR UPDATE",
  )
  |> pog.parameter(pog.text(source_id))
  |> pog.returning(decode.success(Nil))
  |> pog.execute(conn)
  |> result.map(fn(x) { !list.is_empty(x.rows) })
  |> result.map_error(err)
}

const hazard_insert_sql = "INSERT INTO sea.hazard (source,source_id,source_episode_id,episode_count,hazard_type,hazard_codes,glide,alert_level,alert_score,cap_severity,severity_value,severity_unit,severity_label,estimate_type,title,description,countries,report_url,external_ids,onset_at,onset_at_ms,expires_at,expires_at_ms,modified_at,modified_at_ms,is_current,centroid,bbox,primary_geometry,geometries,first_seen_at,last_seen_at) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,to_timestamp($20::double precision/1000),$20,to_timestamp($21::double precision/1000),$21,to_timestamp($22::double precision/1000),$22,$23,ST_SetSRID(ST_MakePoint($24,$25),4326),ST_SetSRID(ST_MakeEnvelope($26,$27,$28,$29),4326),ST_SetSRID(ST_GeomFromGeoJSON($30::text),4326),$31::jsonb,to_timestamp($32::double precision/1000),to_timestamp($32::double precision/1000)) RETURNING "
  <> hazard.columns

const hazard_update_sql = "UPDATE sea.hazard SET source_episode_id=$3,episode_count=$4,hazard_type=$5,hazard_codes=$6,glide=$7,alert_level=$8,alert_score=$9,cap_severity=$10,severity_value=$11,severity_unit=$12,severity_label=$13,estimate_type=$14,title=$15,description=$16,countries=$17,report_url=$18,external_ids=$19,onset_at=to_timestamp($20::double precision/1000),onset_at_ms=$20,expires_at=to_timestamp($21::double precision/1000),expires_at_ms=$21,modified_at=to_timestamp($22::double precision/1000),modified_at_ms=$22,is_current=$23,centroid=ST_SetSRID(ST_MakePoint($24,$25),4326),bbox=ST_SetSRID(ST_MakeEnvelope($26,$27,$28,$29),4326),primary_geometry=ST_SetSRID(ST_GeomFromGeoJSON($30::text),4326),geometries=$31::jsonb,last_seen_at=to_timestamp($32::double precision/1000) WHERE source=$1 AND source_id=$2 RETURNING "
  <> hazard.columns

fn run_hazard_write(
  sql: String,
  normalized: hazard.NormalizedHazard,
  now_ms: Int,
  conn: pog.Connection,
) -> Result(Hazard, String) {
  hazard_bind_params(pog.query(sql), normalized, now_ms)
  |> pog.returning(hazard.row_decoder())
  |> pog.execute(conn)
  |> result.map_error(err)
  |> result.try(fn(x) {
    case x.rows {
      [row] -> Ok(row)
      _ -> Error("hazard write returned no row for " <> normalized.source_id)
    }
  })
}

fn hazard_bind_params(query, n: hazard.NormalizedHazard, now_ms: Int) {
  let #(bbox_w, bbox_s, bbox_e, bbox_n) = case n.bbox {
    option.Some(#(w, s, e, n)) -> #(
      option.Some(w),
      option.Some(s),
      option.Some(e),
      option.Some(n),
    )
    option.None -> #(option.None, option.None, option.None, option.None)
  }
  query
  |> pog.parameter(pog.text("gdacs"))
  |> pog.parameter(pog.text(n.source_id))
  |> pog.parameter(pog.text(n.source_episode_id))
  |> pog.parameter(pog.int(n.episode_count))
  |> pog.parameter(pog.text(n.hazard_type))
  |> pog.parameter(pog.array(pog.text, n.hazard_codes))
  |> text(n.glide)
  |> pog.parameter(pog.text(n.alert_level))
  |> float(n.alert_score)
  |> pog.parameter(pog.text(n.cap_severity))
  |> float(n.severity_value)
  |> text(n.severity_unit)
  |> text(n.severity_label)
  |> pog.parameter(pog.text(hazard.estimate_type))
  |> pog.parameter(pog.text(n.title))
  |> text(n.description)
  |> pog.parameter(pog.array(pog.text, n.countries))
  |> text(n.report_url)
  |> pog.parameter(pog.array(pog.text, n.external_ids))
  |> pog.parameter(pog.int(n.onset_at_ms))
  |> integer(n.expires_at_ms)
  |> pog.parameter(pog.int(n.modified_at_ms))
  |> pog.parameter(pog.bool(n.is_current))
  |> pog.parameter(pog.float(n.longitude))
  |> pog.parameter(pog.float(n.latitude))
  |> float(bbox_w)
  |> float(bbox_s)
  |> float(bbox_e)
  |> float(bbox_n)
  |> text(n.primary_geometry)
  |> text(n.geometries)
  |> pog.parameter(pog.int(now_ms))
}

const feature_row_columns = "event_type, event_id, episode_id, alert_level, alert_score, episode_alert_level, episode_alert_score, name, event_name, description, html_description, country, iso3, glide, origin_source, origin_source_id, severity_value, severity_unit, severity_text, from_at_ms, to_at_ms, modified_at_ms, is_current, is_temporary, longitude, latitude, bbox_west, bbox_south, bbox_east, bbox_north, affected_countries, report_url, geometry_url, icon_url, raw::text"

/// Reads one raw episode row back in the same shape the adapter originally
/// sent it in, so it can be re-run through `gdacs.to_incoming_earthquake`
/// after the row has picked up a backfilled `origin_source_id`.
pub fn load_feature(
  event_type: String,
  event_id: Int,
  episode_id: Int,
  conn: pog.Connection,
) -> Result(Option(GdacsFeature), String) {
  pog.query(
    "SELECT "
    <> feature_row_columns
    <> " FROM sea.gdacs_event WHERE event_type = $1 AND event_id = $2 AND episode_id = $3",
  )
  |> pog.parameter(pog.text(event_type))
  |> pog.parameter(pog.int(event_id))
  |> pog.parameter(pog.int(episode_id))
  |> pog.returning(feature_row_decoder())
  |> pog.execute(conn)
  |> result.map(fn(x) { list.first(x.rows) |> option.from_result })
  |> result.map_error(err)
}

fn feature_row_decoder() -> decode.Decoder(GdacsFeature) {
  use event_type <- decode.field(0, decode.string)
  use event_id <- decode.field(1, decode.int)
  use episode_id <- decode.field(2, decode.int)
  use alert_level <- decode.field(3, decode.string)
  use alert_score <- decode.field(4, decode.optional(decode.float))
  use episode_alert_level <- decode.field(5, decode.optional(decode.string))
  use episode_alert_score <- decode.field(6, decode.optional(decode.float))
  use name <- decode.field(7, decode.optional(decode.string))
  use event_name <- decode.field(8, decode.optional(decode.string))
  use description <- decode.field(9, decode.optional(decode.string))
  use html_description <- decode.field(10, decode.optional(decode.string))
  use country <- decode.field(11, decode.optional(decode.string))
  use iso3 <- decode.field(12, decode.optional(decode.string))
  use glide <- decode.field(13, decode.optional(decode.string))
  use origin_source <- decode.field(14, decode.optional(decode.string))
  use origin_source_id <- decode.field(15, decode.optional(decode.string))
  use severity_value <- decode.field(16, decode.optional(decode.float))
  use severity_unit <- decode.field(17, decode.optional(decode.string))
  use severity_text <- decode.field(18, decode.optional(decode.string))
  use from_at_ms <- decode.field(19, decode.int)
  use to_at_ms <- decode.field(20, decode.optional(decode.int))
  use modified_at_ms <- decode.field(21, decode.int)
  use is_current <- decode.field(22, decode.bool)
  use is_temporary <- decode.field(23, decode.bool)
  use longitude <- decode.field(24, decode.float)
  use latitude <- decode.field(25, decode.float)
  use bbox_west <- decode.field(26, decode.optional(decode.float))
  use bbox_south <- decode.field(27, decode.optional(decode.float))
  use bbox_east <- decode.field(28, decode.optional(decode.float))
  use bbox_north <- decode.field(29, decode.optional(decode.float))
  use affected_countries <- decode.field(30, decode.list(decode.string))
  use report_url <- decode.field(31, decode.optional(decode.string))
  use geometry_url <- decode.field(32, decode.optional(decode.string))
  use icon_url <- decode.field(33, decode.optional(decode.string))
  use raw <- decode.field(34, decode.string)
  decode.success(gdacs.GdacsFeature(
    event_type:,
    event_id:,
    episode_id:,
    alert_level:,
    alert_score:,
    episode_alert_level:,
    episode_alert_score:,
    name:,
    event_name:,
    description:,
    html_description:,
    country:,
    iso3:,
    glide:,
    origin_source:,
    origin_source_id:,
    severity_value:,
    severity_unit:,
    severity_text:,
    from_at_ms:,
    to_at_ms:,
    modified_at_ms:,
    is_current:,
    is_temporary:,
    longitude:,
    latitude:,
    bbox_west:,
    bbox_south:,
    bbox_east:,
    bbox_north:,
    affected_countries:,
    report_url:,
    geometry_url:,
    icon_url:,
    raw:,
  ))
}

fn err(x: pog.QueryError) -> String {
  "Database error: " <> string.inspect(x)
}
