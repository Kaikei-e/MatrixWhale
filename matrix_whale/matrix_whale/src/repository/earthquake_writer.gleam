import domain/earthquake.{type Earthquake}
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/string
import intake/pipeline.{type Written, Written}
import intake/record.{type Incoming, type Key, type Verdict, Key}
import message/reciever/models/earthquake_feature.{type IncomingEarthquake}
import pog
import repository/event_writer.{type EventDiff}

pub type EarthquakeDiff {
  EarthquakeDiff(
    new: List(Earthquake),
    updated: List(Earthquake),
    events: EventDiff,
  )
}

const empty_events = event_writer.EventDiff(new: [], updated: [], matched: 0)

pub fn write_batch(
  records: List(Incoming(IncomingEarthquake)),
  now_ms: Int,
  conn: pog.Connection,
) -> Result(Written(EarthquakeDiff), String) {
  case records {
    [] ->
      Ok(Written(
        EarthquakeDiff(new: [], updated: [], events: empty_events),
        0,
        0,
        0,
        0,
      ))
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
  records: List(Incoming(IncomingEarthquake)),
  now_ms: Int,
  conn: pog.Connection,
) -> Result(Written(EarthquakeDiff), String) {
  use current <- result.try(load_current(records, conn))
  let classified = record.classify(records, current)

  let #(new_pairs, rest) =
    list.partition(classified, fn(pair) { pair.1 == record.New })
  let #(updated_pairs, rest) = list.partition(rest, is_updated)
  let #(unchanged_pairs, stale_pairs) =
    list.partition(rest, fn(pair) { pair.1 == record.Unchanged })

  use #(inserted, insert_lost) <- result.try(insert_new(new_pairs, now_ms, conn))
  use #(updated_rows, update_lost) <- result.try(update_existing(
    updated_pairs,
    now_ms,
    conn,
  ))
  use _ <- result.try(insert_revisions(
    list.append(inserted, updated_rows),
    conn,
  ))
  use _ <- result.try(touch_unchanged(
    list.map(unchanged_pairs, fn(pair) { pair.0.key }),
    now_ms,
    conn,
  ))
  let new_rows = list.map(inserted, fn(pair) { pair.0 })
  let updated_earthquakes = list.map(updated_rows, fn(pair) { pair.0 })
  use events <- result.try(event_writer.link_batch(
    list.append(new_rows, updated_earthquakes),
    conn,
  ))

  Ok(Written(
    result: EarthquakeDiff(new: new_rows, updated: updated_earthquakes, events:),
    new: list.length(inserted),
    updated: list.length(updated_rows),
    unchanged: list.length(unchanged_pairs) + insert_lost + update_lost,
    stale: list.length(stale_pairs),
  ))
}

fn is_updated(pair: #(Incoming(IncomingEarthquake), Verdict)) -> Bool {
  case pair.1 {
    record.Updated(_) -> True
    _ -> False
  }
}

fn load_current(
  records: List(Incoming(IncomingEarthquake)),
  conn: pog.Connection,
) -> Result(Dict(Key, Int), String) {
  group_by_source(list.map(records, fn(r) { r.key }))
  |> dict.to_list
  |> list.try_fold(dict.new(), fn(acc, entry) {
    let #(source, ids) = entry
    use rows <- result.try(select_current(source, ids, conn))
    Ok(
      list.fold(rows, acc, fn(acc, row) {
        let #(source, source_id, updated_at_ms) = row
        dict.insert(acc, Key(source, source_id), updated_at_ms)
      }),
    )
  })
}

fn group_by_source(keys: List(Key)) -> Dict(String, List(String)) {
  list.fold(keys, dict.new(), fn(acc, key) {
    dict.upsert(acc, key.source, fn(existing) {
      case existing {
        option.Some(ids) -> [key.source_id, ..ids]
        option.None -> [key.source_id]
      }
    })
  })
}

fn select_current(
  source: String,
  ids: List(String),
  conn: pog.Connection,
) -> Result(List(#(String, String, Int)), String) {
  pog.query(
    "SELECT source, source_id, updated_at_ms FROM sea.earthquake WHERE source = $1 AND source_id = ANY($2) FOR UPDATE",
  )
  |> pog.parameter(pog.text(source))
  |> pog.parameter(pog.array(pog.text, ids))
  |> pog.returning(current_row_decoder())
  |> pog.execute(conn)
  |> result.map(fn(x) { x.rows })
  |> result.map_error(err)
}

fn current_row_decoder() -> decode.Decoder(#(String, String, Int)) {
  use source <- decode.field(0, decode.string)
  use source_id <- decode.field(1, decode.string)
  use updated_at_ms <- decode.field(2, decode.int)
  decode.success(#(source, source_id, updated_at_ms))
}

const insert_sql = "INSERT INTO sea.earthquake (source,source_id,contributing_ids,sources,net,code,magnitude,magnitude_type,occurred_at,occurred_at_ms,updated_at,updated_at_ms,place,title,status,event_type,tsunami,significance,alert,mmi,cdi,felt,nst,dmin,rms,gap,url,detail,longitude,latitude,depth_km,first_seen_at,last_seen_at) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,to_timestamp($9::double precision/1000),$9,to_timestamp($10::double precision/1000),$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20,$21,$22,$23,$24,$25,$26,$27,$28,$29,to_timestamp($30::double precision/1000),to_timestamp($30::double precision/1000)) ON CONFLICT (source,source_id) DO NOTHING RETURNING "
  <> earthquake.columns

const update_sql = "UPDATE sea.earthquake SET contributing_ids=$3,sources=$4,net=$5,code=$6,magnitude=$7,magnitude_type=$8,occurred_at=to_timestamp($9::double precision/1000),occurred_at_ms=$9,updated_at=to_timestamp($10::double precision/1000),updated_at_ms=$10,place=$11,title=$12,status=$13,event_type=$14,tsunami=$15,significance=$16,alert=$17,mmi=$18,cdi=$19,felt=$20,nst=$21,dmin=$22,rms=$23,gap=$24,url=$25,detail=$26,longitude=$27,latitude=$28,depth_km=$29,last_seen_at=to_timestamp($30::double precision/1000) WHERE source=$1 AND source_id=$2 RETURNING "
  <> earthquake.columns

fn insert_new(
  pairs: List(#(Incoming(IncomingEarthquake), Verdict)),
  now_ms: Int,
  conn: pog.Connection,
) -> Result(#(List(#(Earthquake, String)), Int), String) {
  use results <- result.try(
    pairs
    |> list.try_map(fn(pair) { run_write(insert_sql, pair.0, now_ms, conn) })
    |> result.map_error(err),
  )
  let rows = option.values(results)
  Ok(#(rows, list.length(results) - list.length(rows)))
}

fn update_existing(
  pairs: List(#(Incoming(IncomingEarthquake), Verdict)),
  now_ms: Int,
  conn: pog.Connection,
) -> Result(#(List(#(Earthquake, String)), Int), String) {
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
  incoming: Incoming(IncomingEarthquake),
  now_ms: Int,
  conn: pog.Connection,
) -> Result(Option(#(Earthquake, String)), pog.QueryError) {
  bind_params(pog.query(sql), incoming, now_ms)
  |> pog.returning(earthquake.row_decoder())
  |> pog.execute(conn)
  |> result.map(fn(x) {
    list.first(x.rows)
    |> option.from_result
    |> option.map(fn(row) { #(row, incoming.payload.raw) })
  })
}

fn bind_params(query, incoming: Incoming(IncomingEarthquake), now_ms: Int) {
  let x = incoming.payload
  query
  |> pog.parameter(pog.text(incoming.key.source))
  |> pog.parameter(pog.text(incoming.key.source_id))
  |> pog.parameter(pog.array(pog.text, x.ids))
  |> pog.parameter(pog.array(pog.text, x.sources))
  |> text(x.net)
  |> text(x.code)
  |> float(x.mag)
  |> text(x.mag_type)
  |> pog.parameter(pog.int(x.time))
  |> pog.parameter(pog.int(x.updated))
  |> text(x.place)
  |> text(x.title)
  |> text(x.status)
  |> text(x.type_)
  |> integer(x.tsunami)
  |> integer(x.sig)
  |> text(x.alert)
  |> float(x.mmi)
  |> float(x.cdi)
  |> integer(x.felt)
  |> integer(x.nst)
  |> float(x.dmin)
  |> float(x.rms)
  |> float(x.gap)
  |> text(x.url)
  |> text(x.detail)
  |> pog.parameter(pog.float(x.lon))
  |> pog.parameter(pog.float(x.lat))
  |> float(x.depth)
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

fn insert_revisions(
  rows: List(#(Earthquake, String)),
  conn: pog.Connection,
) -> Result(Nil, String) {
  rows |> list.try_each(fn(pair) { revision(pair.0, pair.1, conn) })
}

fn revision(
  x: Earthquake,
  raw: String,
  conn: pog.Connection,
) -> Result(Nil, String) {
  pog.query(
    "INSERT INTO sea.earthquake_revision(source,source_id,updated_at_ms,earthquake) VALUES($1,$2,$3,$4::jsonb) ON CONFLICT DO NOTHING",
  )
  |> pog.parameter(pog.text(x.source))
  |> pog.parameter(pog.text(x.source_id))
  |> pog.parameter(pog.int(x.updated_at_ms))
  |> pog.parameter(pog.text(raw))
  |> pog.returning(decode.success(Nil))
  |> pog.execute(conn)
  |> result.map(fn(_) { Nil })
  |> result.map_error(err)
}

fn touch_unchanged(
  keys: List(Key),
  now_ms: Int,
  conn: pog.Connection,
) -> Result(Nil, String) {
  case keys {
    [] -> Ok(Nil)
    _ ->
      group_by_source(keys)
      |> dict.to_list
      |> list.try_each(fn(entry) {
        let #(source, ids) = entry
        pog.query(
          "UPDATE sea.earthquake SET last_seen_at = to_timestamp($3::double precision/1000) WHERE source=$1 AND source_id = ANY($2)",
        )
        |> pog.parameter(pog.text(source))
        |> pog.parameter(pog.array(pog.text, ids))
        |> pog.parameter(pog.int(now_ms))
        |> pog.returning(decode.success(Nil))
        |> pog.execute(conn)
        |> result.map(fn(_) { Nil })
      })
      |> result.map_error(err)
  }
}

fn err(x: pog.QueryError) -> String {
  "Database error: " <> string.inspect(x)
}
