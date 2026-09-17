import domain/earthquake.{type Earthquake}
import domain/event.{type MemberView, MemberView}
import domain/source
import gleam/list
import gleam/option.{type Option, Some}

pub type MemberInput {
  MemberInput(earthquake: Earthquake, matched_by: String, misfit: Option(Float))
}

pub type Projection {
  Projection(
    preferred: Earthquake,
    magnitude: Option(Float),
    magnitude_type: Option(String),
    occurred_at_ms: Int,
    updated_at_ms: Int,
    place: Option(String),
    title: Option(String),
    status: Option(String),
    event_type: Option(String),
    longitude: Float,
    latitude: Float,
    depth_km: Option(Float),
    sources: List(String),
    members: List(MemberView),
  )
}

/// Projects an event's cached columns and JSON member list from its current
/// members. `members` must be non-empty: every event has at least the
/// member that created it.
pub fn project(members: List(MemberInput)) -> Projection {
  let non_deleted = list.filter(members, fn(m) { !is_deleted(m.earthquake) })
  let candidates = case non_deleted {
    [] -> members
    _ -> non_deleted
  }
  let assert Ok(preferred) = pick_preferred(candidates)
  let all_deleted = list.all(members, fn(m) { is_deleted(m.earthquake) })
  let status = case all_deleted {
    True -> Some("deleted")
    False -> preferred.earthquake.status
  }
  let updated_at_ms =
    list.fold(members, 0, fn(acc, m) {
      case m.earthquake.updated_at_ms > acc {
        True -> m.earthquake.updated_at_ms
        False -> acc
      }
    })

  Projection(
    preferred: preferred.earthquake,
    magnitude: preferred.earthquake.magnitude,
    magnitude_type: preferred.earthquake.magnitude_type,
    occurred_at_ms: preferred.earthquake.occurred_at_ms,
    updated_at_ms:,
    place: preferred.earthquake.place,
    title: preferred.earthquake.title,
    status:,
    event_type: preferred.earthquake.event_type,
    longitude: preferred.earthquake.longitude,
    latitude: preferred.earthquake.latitude,
    depth_km: preferred.earthquake.depth_km,
    sources: sources_preferred_first(members, preferred.earthquake.source),
    members: list.map(members, to_member_view),
  )
}

fn is_deleted(x: Earthquake) -> Bool {
  x.status == Some("deleted")
}

fn pick_preferred(members: List(MemberInput)) -> Result(MemberInput, Nil) {
  list.fold(members, Error(Nil), fn(acc, m) {
    case acc {
      Error(Nil) -> Ok(m)
      Ok(current) ->
        case is_better(m, current) {
          True -> Ok(m)
          False -> Ok(current)
        }
    }
  })
}

/// Highest `sea.source.priority` wins; a tie goes to the newest
/// `updated_at_ms`.
fn is_better(candidate: MemberInput, current: MemberInput) -> Bool {
  let candidate_priority = priority_of(candidate.earthquake.source)
  let current_priority = priority_of(current.earthquake.source)
  case
    candidate_priority > current_priority,
    candidate_priority == current_priority
  {
    True, _ -> True
    _, True ->
      candidate.earthquake.updated_at_ms > current.earthquake.updated_at_ms
    _, _ -> False
  }
}

fn priority_of(source_id: String) -> Int {
  case source.lookup(source_id) {
    Ok(s) -> s.priority
    Error(Nil) -> 0
  }
}

fn sources_preferred_first(
  members: List(MemberInput),
  preferred_source: String,
) -> List(String) {
  let rest =
    members
    |> list.map(fn(m) { m.earthquake.source })
    |> list.unique
    |> list.filter(fn(s) { s != preferred_source })
  [preferred_source, ..rest]
}

fn to_member_view(m: MemberInput) -> MemberView {
  let eq = m.earthquake
  MemberView(
    source: eq.source,
    source_id: eq.source_id,
    magnitude: eq.magnitude,
    magnitude_type: eq.magnitude_type,
    occurred_at_ms: eq.occurred_at_ms,
    updated_at_ms: eq.updated_at_ms,
    latitude: eq.latitude,
    longitude: eq.longitude,
    depth_km: eq.depth_km,
    place: eq.place,
    status: eq.status,
    url: eq.url,
    matched_by: m.matched_by,
    misfit: m.misfit,
  )
}
