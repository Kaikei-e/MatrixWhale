import domain/earthquake.{type Earthquake}
import gleam/dynamic/decode
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import message/reciever/models/usgs.{type IncomingEarthquake}
import pog

pub type EarthquakeDiff {
  EarthquakeDiff(new: List(Earthquake), updated: List(Earthquake))
}

pub fn upsert_and_diff(
  rows: List(IncomingEarthquake),
  conn: pog.Connection,
) -> Result(EarthquakeDiff, String) {
  pog.transaction(conn, fn(tx) {
    use values <- result.try(
      rows |> list.try_map(fn(row) { write(row, tx) |> result.map_error(err) }),
    )
    use _ <- result.try(
      list.zip(rows, values)
      |> list.try_each(fn(pair) {
        case pair {
          #(source, option.Some(#(row, _))) -> revision(row, source.raw, tx)
          #(_, option.None) -> Ok(Nil)
        }
      }),
    )
    let values =
      values
      |> list.filter_map(fn(value) {
        case value {
          option.Some(x) -> Ok(x)
          option.None -> Error(Nil)
        }
      })
    let #(new, updated) = list.partition(values, fn(x) { x.1 })
    Ok(EarthquakeDiff(
      new: list.map(new, fn(x) { x.0 }),
      updated: list.map(updated, fn(x) { x.0 }),
    ))
  })
  |> result.map_error(fn(x) {
    case x {
      pog.TransactionQueryError(x) -> err(x)
      pog.TransactionRolledBack(x) -> x
    }
  })
}

const sql = "INSERT INTO sea.earthquake (source,source_id,contributing_ids,sources,net,code,magnitude,magnitude_type,occurred_at,occurred_at_ms,updated_at,updated_at_ms,place,title,status,event_type,tsunami,significance,alert,mmi,cdi,felt,nst,dmin,rms,gap,url,detail,longitude,latitude,depth_km,first_seen_at,last_seen_at) VALUES ('usgs',$1,$2,$3,$4,$5,$6,$7,to_timestamp($8::double precision/1000),$8,to_timestamp($9::double precision/1000),$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20,$21,$22,$23,$24,$25,$26,$27,$28,now(),now()) ON CONFLICT (source,source_id) DO UPDATE SET contributing_ids=excluded.contributing_ids,sources=excluded.sources,net=excluded.net,code=excluded.code,magnitude=excluded.magnitude,magnitude_type=excluded.magnitude_type,occurred_at=excluded.occurred_at,occurred_at_ms=excluded.occurred_at_ms,updated_at=excluded.updated_at,updated_at_ms=excluded.updated_at_ms,place=excluded.place,title=excluded.title,status=excluded.status,event_type=excluded.event_type,tsunami=excluded.tsunami,significance=excluded.significance,alert=excluded.alert,mmi=excluded.mmi,cdi=excluded.cdi,felt=excluded.felt,nst=excluded.nst,dmin=excluded.dmin,rms=excluded.rms,gap=excluded.gap,url=excluded.url,detail=excluded.detail,longitude=excluded.longitude,latitude=excluded.latitude,depth_km=excluded.depth_km,last_seen_at=now() WHERE excluded.updated_at_ms > sea.earthquake.updated_at_ms RETURNING "
  <> earthquake.columns
  <> ",(xmax=0)"

fn write(
  x: IncomingEarthquake,
  conn: pog.Connection,
) -> Result(option.Option(#(Earthquake, Bool)), pog.QueryError) {
  pog.query(sql)
  |> pog.parameter(pog.text(x.source_id))
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
  |> pog.returning(decoder())
  |> pog.execute(conn)
  |> result.map(fn(x) { list.first(x.rows) |> option.from_result })
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

fn decoder() -> decode.Decoder(#(Earthquake, Bool)) {
  use row <- decode.then(earthquake.row_decoder())
  use new <- decode.field(33, decode.bool)
  decode.success(#(row, new))
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

fn err(x: pog.QueryError) -> String {
  "Database error: " <> string.inspect(x)
}
