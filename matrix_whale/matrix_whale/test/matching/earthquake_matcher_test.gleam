import gleam/float
import gleam/option
import gleeunit/should
import matching/earthquake_matcher as matcher

pub fn id_match_wins_over_closer_misfit_candidate_test() {
  let candidate =
    matcher.Candidate(
      source: "emsc",
      source_id: "e2",
      contributing_ids: [],
      occurred_at_ms: 1_000_000,
      latitude: 10.0,
      longitude: 20.0,
      magnitude: option.Some(5.0),
    )
  let id_matched_event =
    matcher.CandidateEvent(
      id: 1,
      occurred_at_ms: 1_000_000 + 500_000,
      latitude: 80.0,
      longitude: -170.0,
      magnitude: option.None,
      members: [
        matcher.EventMember(source: "usgs", source_id: "us1", contributing_ids: [
          "e2",
        ]),
      ],
    )
  let closer_event =
    matcher.CandidateEvent(
      id: 2,
      occurred_at_ms: 1_000_000,
      latitude: 10.0,
      longitude: 20.0,
      magnitude: option.Some(5.0),
      members: [
        matcher.EventMember(
          source: "usgs",
          source_id: "us2",
          contributing_ids: [],
        ),
      ],
    )
  matcher.match(candidate, [closer_event, id_matched_event])
  |> should.equal(matcher.Attach(1, "id", option.None))
}

pub fn identical_location_time_and_magnitude_attaches_by_misfit_test() {
  let candidate =
    matcher.Candidate(
      source: "emsc",
      source_id: "e1",
      contributing_ids: [],
      occurred_at_ms: 1_000_000,
      latitude: 10.0,
      longitude: 20.0,
      magnitude: option.Some(5.0),
    )
  let event = existing_event(1, 1_000_000, 10.0, 20.0, option.Some(5.0), "usgs")
  matcher.match(candidate, [event])
  |> should.equal(matcher.Attach(1, "misfit", option.Some(0.0)))
}

pub fn candidate_outside_time_window_creates_new_test() {
  let candidate =
    matcher.Candidate(
      source: "emsc",
      source_id: "e1",
      contributing_ids: [],
      occurred_at_ms: 1_061_000,
      latitude: 10.0,
      longitude: 20.0,
      magnitude: option.Some(5.0),
    )
  let event = existing_event(1, 1_000_000, 10.0, 20.0, option.Some(5.0), "usgs")
  matcher.match(candidate, [event]) |> should.equal(matcher.CreateNew)
}

pub fn only_one_delta_within_m2_scale_creates_new_test() {
  // ~133km latitude offset (>126km m2 scale), no time offset, no magnitude:
  // only the time delta counts toward m2, so m2 = 1 and the match is rejected.
  let candidate =
    matcher.Candidate(
      source: "emsc",
      source_id: "e1",
      contributing_ids: [],
      occurred_at_ms: 1_000_000,
      latitude: 10.0,
      longitude: 20.0,
      magnitude: option.None,
    )
  let event = existing_event(1, 1_000_000, 11.2, 20.0, option.None, "usgs")
  matcher.match(candidate, [event]) |> should.equal(matcher.CreateNew)
}

pub fn exactly_two_deltas_within_m2_scale_attaches_test() {
  // Same location, 10s apart (within the 15.6s m2 scale), magnitude 2.0
  // apart (outside the 0.96 m2 scale): m2 = 2, so misfit accepts.
  let candidate =
    matcher.Candidate(
      source: "emsc",
      source_id: "e1",
      contributing_ids: [],
      occurred_at_ms: 1_000_010_000,
      latitude: 10.0,
      longitude: 20.0,
      magnitude: option.Some(5.0),
    )
  let event =
    existing_event(1, 1_000_000_000, 10.0, 20.0, option.Some(7.0), "usgs")
  let assert matcher.Attach(1, "misfit", option.Some(misfit)) =
    matcher.match(candidate, [event])
  assert_close(misfit, 10.0 /. 13.0 +. 2.0 /. 0.8, 0.001)
}

pub fn longitude_wraps_around_the_antimeridian_test() {
  let candidate =
    matcher.Candidate(
      source: "emsc",
      source_id: "e1",
      contributing_ids: [],
      occurred_at_ms: 1_000_000,
      latitude: 0.0,
      longitude: 179.9,
      magnitude: option.Some(5.0),
    )
  let event =
    existing_event(1, 1_000_000, 0.0, -179.9, option.Some(5.0), "usgs")
  let assert matcher.Attach(1, "misfit", option.Some(misfit)) =
    matcher.match(candidate, [event])
  // ~22.2km apart (haversine wraps the antimeridian correctly) / 105km scale.
  assert_close(misfit, 0.212, 0.01)
}

pub fn existing_member_from_same_source_blocks_attach_test() {
  let candidate =
    matcher.Candidate(
      source: "usgs",
      source_id: "us2",
      contributing_ids: [],
      occurred_at_ms: 1_000_000,
      latitude: 10.0,
      longitude: 20.0,
      magnitude: option.Some(5.0),
    )
  let event = existing_event(1, 1_000_000, 10.0, 20.0, option.Some(5.0), "usgs")
  matcher.match(candidate, [event]) |> should.equal(matcher.CreateNew)
}

pub fn missing_magnitude_on_one_side_still_allows_a_match_test() {
  let candidate =
    matcher.Candidate(
      source: "emsc",
      source_id: "e1",
      contributing_ids: [],
      occurred_at_ms: 1_000_000,
      latitude: 10.0,
      longitude: 20.0,
      magnitude: option.None,
    )
  let event = existing_event(1, 1_000_000, 10.0, 20.0, option.Some(5.0), "usgs")
  matcher.match(candidate, [event])
  |> should.equal(matcher.Attach(1, "misfit", option.Some(0.0)))
}

fn existing_event(
  id: Int,
  occurred_at_ms: Int,
  latitude: Float,
  longitude: Float,
  magnitude: option.Option(Float),
  member_source: String,
) -> matcher.CandidateEvent {
  matcher.CandidateEvent(
    id:,
    occurred_at_ms:,
    latitude:,
    longitude:,
    magnitude:,
    members: [
      matcher.EventMember(
        source: member_source,
        source_id: member_source <> "_member",
        contributing_ids: [],
      ),
    ],
  )
}

fn assert_close(actual: Float, expected: Float, tolerance: Float) -> Nil {
  { float.absolute_value(actual -. expected) <. tolerance }
  |> should.equal(True)
}
