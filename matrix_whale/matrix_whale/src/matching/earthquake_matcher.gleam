import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set

pub type Candidate {
  Candidate(
    source: String,
    source_id: String,
    contributing_ids: List(String),
    occurred_at_ms: Int,
    latitude: Float,
    longitude: Float,
    magnitude: Option(Float),
  )
}

pub type EventMember {
  EventMember(source: String, source_id: String, contributing_ids: List(String))
}

pub type CandidateEvent {
  CandidateEvent(
    id: Int,
    occurred_at_ms: Int,
    latitude: Float,
    longitude: Float,
    magnitude: Option(Float),
    members: List(EventMember),
  )
}

pub type Decision {
  Attach(event_id: Int, matched_by: String, misfit: Option(Float))
  CreateNew
}

// EMSC EventID webservice defaults: http://www.seismicportal.eu/eventid.html
pub const window_time_s = 60.0

pub const window_deg = 1.5

const km_scale = 105.0

const time_scale = 13.0

const mag_scale = 0.8

const m2_km_scale = 126.0

const m2_time_scale = 15.6

const m2_mag_scale = 0.96

pub fn match(candidate: Candidate, events: List(CandidateEvent)) -> Decision {
  case find_id_match(candidate, events) {
    Some(event) -> Attach(event.id, "id", None)
    None -> match_by_misfit(candidate, events)
  }
}

fn find_id_match(
  candidate: Candidate,
  events: List(CandidateEvent),
) -> Option(CandidateEvent) {
  let candidate_ids =
    set.from_list([candidate.source_id, ..candidate.contributing_ids])
  list.find(events, fn(event) {
    list.any(event.members, fn(member) {
      let member_ids =
        set.from_list([member.source_id, ..member.contributing_ids])
      !set.is_empty(set.intersection(candidate_ids, member_ids))
    })
  })
  |> option.from_result
}

fn match_by_misfit(
  candidate: Candidate,
  events: List(CandidateEvent),
) -> Decision {
  let scored =
    events
    |> list.filter(fn(event) { within_window(candidate, event) })
    |> list.map(fn(event) { score(candidate, event) })

  case pick_best(scored) {
    Some(#(event, misfit, m2)) ->
      case m2 >= 2 && !has_member_from(event, candidate.source) {
        True -> Attach(event.id, "misfit", Some(misfit))
        False -> CreateNew
      }
    None -> CreateNew
  }
}

fn within_window(candidate: Candidate, event: CandidateEvent) -> Bool {
  delta_seconds(candidate.occurred_at_ms, event.occurred_at_ms)
  <=. window_time_s
  && float.absolute_value(candidate.latitude -. event.latitude) <=. window_deg
  && lon_delta(candidate.longitude, event.longitude) <=. window_deg
}

fn score(
  candidate: Candidate,
  event: CandidateEvent,
) -> #(CandidateEvent, Float, Int) {
  let dloc_km =
    haversine_km(
      candidate.latitude,
      candidate.longitude,
      event.latitude,
      event.longitude,
    )
  let dt_s = delta_seconds(candidate.occurred_at_ms, event.occurred_at_ms)
  let #(dmag_term, mag_within) = case candidate.magnitude, event.magnitude {
    Some(a), Some(b) -> {
      let d = float.absolute_value(a -. b)
      #(d /. mag_scale, d <=. m2_mag_scale)
    }
    _, _ -> #(0.0, False)
  }
  let misfit = dloc_km /. km_scale +. dt_s /. time_scale +. dmag_term
  let m2 =
    bool_to_int(dloc_km <=. m2_km_scale)
    + bool_to_int(dt_s <=. m2_time_scale)
    + bool_to_int(mag_within)
  #(event, misfit, m2)
}

fn pick_best(
  scored: List(#(CandidateEvent, Float, Int)),
) -> Option(#(CandidateEvent, Float, Int)) {
  list.fold(scored, None, fn(acc, item) {
    case acc {
      None -> Some(item)
      Some(#(_, best_misfit, _)) -> {
        let #(_, misfit, _) = item
        case misfit <. best_misfit {
          True -> Some(item)
          False -> acc
        }
      }
    }
  })
}

fn has_member_from(event: CandidateEvent, source: String) -> Bool {
  list.any(event.members, fn(member) { member.source == source })
}

fn delta_seconds(a_ms: Int, b_ms: Int) -> Float {
  int.to_float(int.absolute_value(a_ms - b_ms)) /. 1000.0
}

fn lon_delta(a: Float, b: Float) -> Float {
  let raw = float.absolute_value(a -. b)
  float.min(raw, 360.0 -. raw)
}

fn bool_to_int(value: Bool) -> Int {
  case value {
    True -> 1
    False -> 0
  }
}

const earth_radius_km = 6371.0

fn haversine_km(lat1: Float, lon1: Float, lat2: Float, lon2: Float) -> Float {
  let dlat = to_radians(lat2 -. lat1)
  let dlon = to_radians(lon2 -. lon1)
  let a =
    sin2(dlat /. 2.0)
    +. erl_cos(to_radians(lat1))
    *. erl_cos(to_radians(lat2))
    *. sin2(dlon /. 2.0)
  let assert Ok(root) = float.square_root(float.min(1.0, a))
  earth_radius_km *. 2.0 *. erl_asin(root)
}

fn sin2(x: Float) -> Float {
  let s = erl_sin(x)
  s *. s
}

fn to_radians(degrees: Float) -> Float {
  degrees *. 3.141592653589793 /. 180.0
}

@external(erlang, "math", "sin")
fn erl_sin(x: Float) -> Float

@external(erlang, "math", "cos")
fn erl_cos(x: Float) -> Float

@external(erlang, "math", "asin")
fn erl_asin(x: Float) -> Float
