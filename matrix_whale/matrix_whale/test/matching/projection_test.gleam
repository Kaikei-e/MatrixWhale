import domain/earthquake
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/time/timestamp
import gleeunit/should
import matching/projection

pub fn highest_priority_source_wins_over_more_recent_update_test() {
  let projected =
    projection.project([
      member("usgs", "u1", 10, None),
      member("emsc", "e1", 20, None),
    ])
  projected.preferred.source |> should.equal("usgs")
  projected.updated_at_ms |> should.equal(20)
}

pub fn tie_in_priority_breaks_to_newest_update_test() {
  let projected =
    projection.project([
      member("usgs", "u1", 100, None),
      member("noaa", "n1", 200, None),
    ])
  projected.preferred.source |> should.equal("noaa")
}

pub fn all_members_deleted_reports_deleted_status_test() {
  let projected =
    projection.project([
      member("usgs", "u1", 10, Some("deleted")),
      member("emsc", "e1", 20, Some("deleted")),
    ])
  projected.status |> should.equal(Some("deleted"))
}

pub fn deleted_higher_priority_member_is_skipped_for_preferred_test() {
  let projected =
    projection.project([
      member("usgs", "u1", 10, Some("deleted")),
      member("emsc", "e1", 20, Some("automatic")),
    ])
  projected.preferred.source |> should.equal("emsc")
  projected.status |> should.equal(Some("automatic"))
}

pub fn sources_list_is_preferred_first_test() {
  let projected =
    projection.project([
      member("emsc", "e1", 20, None),
      member("usgs", "u1", 10, None),
    ])
  projected.sources |> should.equal(["usgs", "emsc"])
  list.length(projected.members) |> should.equal(2)
}

fn member(
  source: String,
  source_id: String,
  updated_at_ms: Int,
  status: Option(String),
) -> projection.MemberInput {
  projection.MemberInput(
    earthquake: sample(source, source_id, updated_at_ms, status),
    matched_by: "origin",
    misfit: None,
  )
}

fn sample(
  source: String,
  source_id: String,
  updated_at_ms: Int,
  status: Option(String),
) -> earthquake.Earthquake {
  let time = timestamp.from_unix_seconds(0)
  earthquake.Earthquake(
    source:,
    source_id:,
    contributing_ids: [source_id],
    sources: [source],
    net: None,
    code: None,
    magnitude: Some(5.0),
    magnitude_type: None,
    occurred_at: time,
    occurred_at_ms: 0,
    updated_at: time,
    updated_at_ms:,
    place: Some("place-" <> source),
    title: Some("title-" <> source),
    status:,
    event_type: Some("earthquake"),
    tsunami: None,
    significance: None,
    alert: None,
    mmi: None,
    cdi: None,
    felt: None,
    nst: None,
    dmin: None,
    rms: None,
    gap: None,
    url: None,
    detail: None,
    longitude: 1.0,
    latitude: 2.0,
    depth_km: None,
    first_seen_at: time,
    last_seen_at: time,
  )
}
