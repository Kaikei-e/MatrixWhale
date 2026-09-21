import domain/earthquake.{type Earthquake}
import domain/event.{type EventView, EventView}
import gleam/dict
import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import matching/earthquake_matcher as matcher
import matching/projection
import pog

pub type EventDiff {
  EventDiff(new: List(EventView), updated: List(EventView), matched: Int)
}

const empty_diff = EventDiff(new: [], updated: [], matched: 0)

/// Links each just-written earthquake row to a canonical event, in the same
/// transaction as the earthquake writes. `new_rows` skip the member-link
/// lookup entirely: a row inserted earlier in this same transaction cannot
/// already have an `sea.event_member` row (that FK could not exist before
/// the row did), so it goes straight to matching. `updated_rows` check for
/// an existing link first (present for every row linked since this feature
/// shipped) and fall back to matching only when one is missing.
pub fn link_batch(
  new_rows: List(Earthquake),
  updated_rows: List(Earthquake),
  conn: pog.Connection,
) -> Result(EventDiff, String) {
  use diff <- result.try(
    list.try_fold(new_rows, empty_diff, fn(diff, row) {
      link_new(diff, row, conn)
    }),
  )
  list.try_fold(updated_rows, diff, fn(diff, row) {
    link_existing(diff, row, conn)
  })
}

fn link_new(
  diff: EventDiff,
  row: Earthquake,
  conn: pog.Connection,
) -> Result(EventDiff, String) {
  use candidates <- result.try(load_candidates(row, conn))
  case matcher.match(to_candidate(row), candidates) {
    matcher.CreateNew -> {
      use view <- result.try(create_event(row, conn))
      Ok(EventDiff(..diff, new: list.append(diff.new, [view])))
    }
    matcher.Attach(event_id, matched_by, misfit) -> {
      use _ <- result.try(insert_member(event_id, row, matched_by, misfit, conn))
      use view <- result.try(reproject(event_id, conn))
      Ok(
        EventDiff(
          ..diff,
          updated: list.append(diff.updated, [view]),
          matched: diff.matched + 1,
        ),
      )
    }
  }
}

fn link_existing(
  diff: EventDiff,
  row: Earthquake,
  conn: pog.Connection,
) -> Result(EventDiff, String) {
  use existing <- result.try(find_member_link(row, conn))
  case existing {
    Some(event_id) -> {
      use view <- result.try(reproject(event_id, conn))
      Ok(EventDiff(..diff, updated: list.append(diff.updated, [view])))
    }
    None -> link_new(diff, row, conn)
  }
}

/// Renders an already-fetched event row into its current `EventView`,
/// re-projecting from its live members without touching the stored row.
pub fn to_view(
  event_row: event.Event,
  conn: pog.Connection,
) -> Result(EventView, String) {
  use members <- result.try(load_members(event_row.id, conn))
  let projected = projection.project(members)
  Ok(EventView(
    event: event_row,
    preferred: projected.preferred,
    members: projected.members,
    sources: projected.sources,
  ))
}

/// Hydrates a batch of already-fetched event rows into `EventView`s,
/// reading member links and earthquake rows in 2 queries instead of N+M queries,
/// preserving existing `to_view` projection semantics, member metadata, and ordering.
pub fn to_views(
  event_rows: List(event.Event),
  conn: pog.Connection,
) -> Result(List(EventView), String) {
  case event_rows {
    [] -> Ok([])
    _ -> {
      let event_ids = list.map(event_rows, fn(e) { e.id })
      use member_links <- result.try(select_batch_member_links(event_ids, conn))
      use member_inputs <- result.try(hydrate_member_inputs(member_links, conn))
      let grouped =
        list.fold(member_inputs, dict.new(), fn(acc, item) {
          let #(event_id, member_input) = item
          dict.upsert(acc, event_id, fn(existing) {
            case existing {
              Some(members) -> [member_input, ..members]
              None -> [member_input]
            }
          })
        })
      list.try_map(event_rows, fn(event_row) {
        let members = case dict.get(grouped, event_row.id) {
          Ok(m) -> list.reverse(m)
          Error(Nil) -> []
        }
        let projected = projection.project(members)
        Ok(EventView(
          event: event_row,
          preferred: projected.preferred,
          members: projected.members,
          sources: projected.sources,
        ))
      })
    }
  }
}

type BatchMemberLink {
  BatchMemberLink(
    event_id: Int,
    source: String,
    source_id: String,
    matched_by: String,
    misfit: Option(Float),
  )
}

fn select_batch_member_links(
  event_ids: List(Int),
  conn: pog.Connection,
) -> Result(List(BatchMemberLink), String) {
  pog.query(
    "SELECT event_id, source, source_id, matched_by, misfit FROM sea.event_member WHERE event_id = ANY($1)",
  )
  |> pog.parameter(pog.array(pog.int, event_ids))
  |> pog.returning({
    use event_id <- decode.field(0, decode.int)
    use source <- decode.field(1, decode.string)
    use source_id <- decode.field(2, decode.string)
    use matched_by <- decode.field(3, decode.string)
    use misfit <- decode.field(4, decode.optional(decode.float))
    decode.success(BatchMemberLink(
      event_id:,
      source:,
      source_id:,
      matched_by:,
      misfit:,
    ))
  })
  |> pog.execute(conn)
  |> result.map(fn(x) { x.rows })
  |> result.map_error(err)
}

fn hydrate_member_inputs(
  member_links: List(BatchMemberLink),
  conn: pog.Connection,
) -> Result(List(#(Int, projection.MemberInput)), String) {
  case member_links {
    [] -> Ok([])
    _ -> {
      let pairs =
        member_links
        |> list.map(fn(link) { #(link.source, link.source_id) })
        |> list.unique
      let #(sources, source_ids) = list.unzip(pairs)
      use eq_rows <- result.try(select_batch_earthquakes(
        sources,
        source_ids,
        conn,
      ))
      let eq_map =
        list.fold(eq_rows, dict.new(), fn(acc, eq) {
          dict.insert(acc, #(eq.source, eq.source_id), eq)
        })
      list.try_map(member_links, fn(link) {
        case dict.get(eq_map, #(link.source, link.source_id)) {
          Ok(eq) ->
            Ok(#(
              link.event_id,
              projection.MemberInput(
                earthquake: eq,
                matched_by: link.matched_by,
                misfit: link.misfit,
              ),
            ))
          Error(Nil) ->
            Error(
              "event member earthquake row missing for "
              <> link.source
              <> ":"
              <> link.source_id,
            )
        }
      })
    }
  }
}

fn select_batch_earthquakes(
  sources: List(String),
  source_ids: List(String),
  conn: pog.Connection,
) -> Result(List(Earthquake), String) {
  pog.query(
    "SELECT "
    <> earthquake.columns
    <> " FROM sea.earthquake WHERE (source, source_id) IN (SELECT * FROM unnest($1::text[], $2::text[]))",
  )
  |> pog.parameter(pog.array(pog.text, sources))
  |> pog.parameter(pog.array(pog.text, source_ids))
  |> pog.returning(earthquake.row_decoder())
  |> pog.execute(conn)
  |> result.map(fn(x) { x.rows })
  |> result.map_error(err)
}

fn to_candidate(row: Earthquake) -> matcher.Candidate {
  matcher.Candidate(
    source: row.source,
    source_id: row.source_id,
    contributing_ids: row.contributing_ids,
    occurred_at_ms: row.occurred_at_ms,
    latitude: row.latitude,
    longitude: row.longitude,
    magnitude: row.magnitude,
  )
}

fn create_event(
  row: Earthquake,
  conn: pog.Connection,
) -> Result(EventView, String) {
  let member =
    projection.MemberInput(earthquake: row, matched_by: "origin", misfit: None)
  let projected = projection.project([member])
  use event_row <- result.try(insert_event(row, projected, conn))
  use _ <- result.try(insert_member(event_row.id, row, "origin", None, conn))
  Ok(EventView(
    event: event_row,
    preferred: projected.preferred,
    members: projected.members,
    sources: projected.sources,
  ))
}

pub fn reproject(
  event_id: Int,
  conn: pog.Connection,
) -> Result(EventView, String) {
  use members <- result.try(load_members(event_id, conn))
  let projected = projection.project(members)
  use event_row <- result.try(update_event(event_id, projected, conn))
  Ok(EventView(
    event: event_row,
    preferred: projected.preferred,
    members: projected.members,
    sources: projected.sources,
  ))
}

fn find_member_link(
  row: Earthquake,
  conn: pog.Connection,
) -> Result(Option(Int), String) {
  pog.query(
    "SELECT event_id FROM sea.event_member WHERE source = $1 AND source_id = $2",
  )
  |> pog.parameter(pog.text(row.source))
  |> pog.parameter(pog.text(row.source_id))
  |> pog.returning({
    use event_id <- decode.field(0, decode.int)
    decode.success(event_id)
  })
  |> pog.execute(conn)
  |> result.map(fn(x) { list.first(x.rows) |> option.from_result })
  |> result.map_error(err)
}

fn load_candidates(
  row: Earthquake,
  conn: pog.Connection,
) -> Result(List(matcher.CandidateEvent), String) {
  let lo_ms = row.occurred_at_ms - window_ms
  let hi_ms = row.occurred_at_ms + window_ms
  let lo_lat = row.latitude -. matcher.window_deg
  let hi_lat = row.latitude +. matcher.window_deg
  use scalars <- result.try(select_candidate_scalars(
    lo_ms,
    hi_ms,
    lo_lat,
    hi_lat,
    conn,
  ))
  scalars
  |> list.try_map(fn(scalar) {
    use members <- result.try(select_candidate_members(scalar.0, conn))
    Ok(matcher.CandidateEvent(
      id: scalar.0,
      occurred_at_ms: scalar.1,
      latitude: scalar.2,
      longitude: scalar.3,
      magnitude: scalar.4,
      members: members,
    ))
  })
}

const window_ms = 60_000

fn select_candidate_scalars(
  lo_ms: Int,
  hi_ms: Int,
  lo_lat: Float,
  hi_lat: Float,
  conn: pog.Connection,
) -> Result(List(#(Int, Int, Float, Float, Option(Float))), String) {
  pog.query(
    "SELECT id, occurred_at_ms, latitude, longitude, magnitude FROM sea.event WHERE occurred_at_ms BETWEEN $1 AND $2 AND latitude BETWEEN $3 AND $4 AND (status IS NULL OR status <> 'deleted')",
  )
  |> pog.parameter(pog.int(lo_ms))
  |> pog.parameter(pog.int(hi_ms))
  |> pog.parameter(pog.float(lo_lat))
  |> pog.parameter(pog.float(hi_lat))
  |> pog.returning({
    use id <- decode.field(0, decode.int)
    use occurred_at_ms <- decode.field(1, decode.int)
    use latitude <- decode.field(2, decode.float)
    use longitude <- decode.field(3, decode.float)
    use magnitude <- decode.field(4, decode.optional(decode.float))
    decode.success(#(id, occurred_at_ms, latitude, longitude, magnitude))
  })
  |> pog.execute(conn)
  |> result.map(fn(x) { x.rows })
  |> result.map_error(err)
}

fn select_candidate_members(
  event_id: Int,
  conn: pog.Connection,
) -> Result(List(matcher.EventMember), String) {
  pog.query(
    "SELECT em.source, em.source_id, eq.contributing_ids FROM sea.event_member em JOIN sea.earthquake eq ON eq.source = em.source AND eq.source_id = em.source_id WHERE em.event_id = $1",
  )
  |> pog.parameter(pog.int(event_id))
  |> pog.returning({
    use source <- decode.field(0, decode.string)
    use source_id <- decode.field(1, decode.string)
    use contributing_ids <- decode.field(2, decode.list(decode.string))
    decode.success(matcher.EventMember(source:, source_id:, contributing_ids:))
  })
  |> pog.execute(conn)
  |> result.map(fn(x) { x.rows })
  |> result.map_error(err)
}

type MemberLink {
  MemberLink(
    source: String,
    source_id: String,
    matched_by: String,
    misfit: Option(Float),
  )
}

fn load_members(
  event_id: Int,
  conn: pog.Connection,
) -> Result(List(projection.MemberInput), String) {
  use links <- result.try(select_member_links(event_id, conn))
  use rows <- result.try(
    links
    |> list.try_map(fn(link) {
      select_earthquake(link.source, link.source_id, conn)
    }),
  )
  Ok(
    list.zip(links, rows)
    |> list.map(fn(pair) {
      let #(link, row) = pair
      projection.MemberInput(
        earthquake: row,
        matched_by: link.matched_by,
        misfit: link.misfit,
      )
    }),
  )
}

fn select_member_links(
  event_id: Int,
  conn: pog.Connection,
) -> Result(List(MemberLink), String) {
  pog.query(
    "SELECT source, source_id, matched_by, misfit FROM sea.event_member WHERE event_id = $1",
  )
  |> pog.parameter(pog.int(event_id))
  |> pog.returning({
    use source <- decode.field(0, decode.string)
    use source_id <- decode.field(1, decode.string)
    use matched_by <- decode.field(2, decode.string)
    use misfit <- decode.field(3, decode.optional(decode.float))
    decode.success(MemberLink(source:, source_id:, matched_by:, misfit:))
  })
  |> pog.execute(conn)
  |> result.map(fn(x) { x.rows })
  |> result.map_error(err)
}

fn select_earthquake(
  source: String,
  source_id: String,
  conn: pog.Connection,
) -> Result(Earthquake, String) {
  pog.query(
    "SELECT "
    <> earthquake.columns
    <> " FROM sea.earthquake WHERE source = $1 AND source_id = $2",
  )
  |> pog.parameter(pog.text(source))
  |> pog.parameter(pog.text(source_id))
  |> pog.returning(earthquake.row_decoder())
  |> pog.execute(conn)
  |> result.map_error(err)
  |> result.try(fn(x) {
    case x.rows {
      [row] -> Ok(row)
      _ ->
        Error(
          "event member earthquake row missing for "
          <> source
          <> ":"
          <> source_id,
        )
    }
  })
}

const insert_event_sql = "INSERT INTO sea.event (kind,preferred_source,preferred_source_id,magnitude,magnitude_type,occurred_at,occurred_at_ms,updated_at,updated_at_ms,place,title,status,event_type,longitude,latitude,depth_km) VALUES ($1,$2,$3,$4,$5,to_timestamp($6::double precision/1000),$6,to_timestamp($7::double precision/1000),$7,$8,$9,$10,$11,$12,$13,$14) RETURNING "
  <> event.columns

fn insert_event(
  row: Earthquake,
  projected: projection.Projection,
  conn: pog.Connection,
) -> Result(event.Event, String) {
  pog.query(insert_event_sql)
  |> pog.parameter(pog.text("earthquake"))
  |> pog.parameter(pog.text(row.source))
  |> pog.parameter(pog.text(row.source_id))
  |> pog.parameter(pog.nullable(pog.float, projected.magnitude))
  |> pog.parameter(pog.nullable(pog.text, projected.magnitude_type))
  |> pog.parameter(pog.int(projected.occurred_at_ms))
  |> pog.parameter(pog.int(projected.updated_at_ms))
  |> pog.parameter(pog.nullable(pog.text, projected.place))
  |> pog.parameter(pog.nullable(pog.text, projected.title))
  |> pog.parameter(pog.nullable(pog.text, projected.status))
  |> pog.parameter(pog.nullable(pog.text, projected.event_type))
  |> pog.parameter(pog.float(projected.longitude))
  |> pog.parameter(pog.float(projected.latitude))
  |> pog.parameter(pog.nullable(pog.float, projected.depth_km))
  |> pog.returning(event.row_decoder())
  |> pog.execute(conn)
  |> result.map_error(err)
  |> result.try(fn(x) {
    case x.rows {
      [row] -> Ok(row)
      _ -> Error("event insert returned no row")
    }
  })
}

const update_event_sql = "UPDATE sea.event SET preferred_source=$2,preferred_source_id=$3,magnitude=$4,magnitude_type=$5,occurred_at=to_timestamp($6::double precision/1000),occurred_at_ms=$6,updated_at=to_timestamp($7::double precision/1000),updated_at_ms=$7,place=$8,title=$9,status=$10,event_type=$11,longitude=$12,latitude=$13,depth_km=$14,last_seen_at=now() WHERE id=$1 RETURNING "
  <> event.columns

fn update_event(
  event_id: Int,
  projected: projection.Projection,
  conn: pog.Connection,
) -> Result(event.Event, String) {
  pog.query(update_event_sql)
  |> pog.parameter(pog.int(event_id))
  |> pog.parameter(pog.text(projected.preferred.source))
  |> pog.parameter(pog.text(projected.preferred.source_id))
  |> pog.parameter(pog.nullable(pog.float, projected.magnitude))
  |> pog.parameter(pog.nullable(pog.text, projected.magnitude_type))
  |> pog.parameter(pog.int(projected.occurred_at_ms))
  |> pog.parameter(pog.int(projected.updated_at_ms))
  |> pog.parameter(pog.nullable(pog.text, projected.place))
  |> pog.parameter(pog.nullable(pog.text, projected.title))
  |> pog.parameter(pog.nullable(pog.text, projected.status))
  |> pog.parameter(pog.nullable(pog.text, projected.event_type))
  |> pog.parameter(pog.float(projected.longitude))
  |> pog.parameter(pog.float(projected.latitude))
  |> pog.parameter(pog.nullable(pog.float, projected.depth_km))
  |> pog.returning(event.row_decoder())
  |> pog.execute(conn)
  |> result.map_error(err)
  |> result.try(fn(x) {
    case x.rows {
      [row] -> Ok(row)
      _ ->
        Error(
          "event update returned no row for id " <> string.inspect(event_id),
        )
    }
  })
}

fn insert_member(
  event_id: Int,
  row: Earthquake,
  matched_by: String,
  misfit: Option(Float),
  conn: pog.Connection,
) -> Result(Nil, String) {
  pog.query(
    "INSERT INTO sea.event_member (event_id, source, source_id, matched_by, misfit) VALUES ($1,$2,$3,$4,$5) ON CONFLICT DO NOTHING",
  )
  |> pog.parameter(pog.int(event_id))
  |> pog.parameter(pog.text(row.source))
  |> pog.parameter(pog.text(row.source_id))
  |> pog.parameter(pog.text(matched_by))
  |> pog.parameter(pog.nullable(pog.float, misfit))
  |> pog.returning(decode.success(Nil))
  |> pog.execute(conn)
  |> result.map(fn(_) { Nil })
  |> result.map_error(err)
}

fn err(x: pog.QueryError) -> String {
  "Database error: " <> string.inspect(x)
}
