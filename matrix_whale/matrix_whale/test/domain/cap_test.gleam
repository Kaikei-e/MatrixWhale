import domain/cap
import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/order
import gleam/time/calendar
import gleam/time/duration
import gleam/time/timestamp
import gleeunit/should
import intake/record
import message/reciever/models/cap as models_cap

pub fn seven_day_skip_boundary_test() {
  let now = timestamp.system_time()
  let six_days_ago =
    timestamp.subtract(now, duration.hours(6 * 24))
    |> timestamp.to_rfc3339(calendar.utc_offset)
  let exactly_seven_days_ago =
    timestamp.subtract(now, duration.hours(7 * 24))
    |> timestamp.to_rfc3339(calendar.utc_offset)
  let seven_days_one_minute_ago =
    timestamp.subtract(
      now,
      duration.add(duration.hours(7 * 24), duration.minutes(1)),
    )
    |> timestamp.to_rfc3339(calendar.utc_offset)
  let rfc1123_ten_days_ago =
    timestamp.subtract(now, duration.hours(10 * 24))
    |> timestamp.to_http_date

  // 6 days ago -> Pending
  cap.decide_new_item_state(Some(six_days_ago), now)
  |> should.equal(cap.Pending)

  // Exactly 7 days ago (diff <= 604,800 s) -> Pending
  cap.decide_new_item_state(Some(exactly_seven_days_ago), now)
  |> should.equal(cap.Pending)

  // Older than 7 days -> Skipped
  cap.decide_new_item_state(Some(seven_days_one_minute_ago), now)
  |> should.equal(cap.Skipped)

  // RFC 1123 older than 7 days -> Skipped
  cap.decide_new_item_state(Some(rfc1123_ten_days_ago), now)
  |> should.equal(cap.Skipped)

  // Missing or unparseable date -> Pending
  cap.decide_new_item_state(None, now)
  |> should.equal(cap.Pending)

  cap.decide_new_item_state(Some("invalid-date-string"), now)
  |> should.equal(cap.Pending)
}

pub fn fetch_outcome_decisions_test() {
  // Successful CAP parse
  cap.decide_fetch_outcome(200, True, 0)
  |> should.equal(#(cap.Fetched, 0))

  // 404 / 410 / 400 permanent failure (attempts = 3)
  cap.decide_fetch_outcome(404, False, 1)
  |> should.equal(#(cap.Failed, 3))

  cap.decide_fetch_outcome(410, False, 0)
  |> should.equal(#(cap.Failed, 3))

  // 200 with non-CAP or invalid document -> permanent failure (attempts = 3)
  cap.decide_fetch_outcome(200, False, 0)
  |> should.equal(#(cap.Failed, 3))

  // 429 rate limited -> transient failure (attempts + 1)
  cap.decide_fetch_outcome(429, False, 0)
  |> should.equal(#(cap.Failed, 1))

  // 500 server error -> transient failure (attempts + 1)
  cap.decide_fetch_outcome(500, False, 1)
  |> should.equal(#(cap.Failed, 2))

  // 0 network error -> transient failure (attempts + 1)
  cap.decide_fetch_outcome(0, False, 2)
  |> should.equal(#(cap.Failed, 3))
}

pub fn write_failure_decisions_test() {
  cap.decide_write_failure(0)
  |> should.equal(#(cap.Failed, 1))

  cap.decide_write_failure(1)
  |> should.equal(#(cap.Failed, 2))

  cap.decide_write_failure(2)
  |> should.equal(#(cap.Failed, 3))
}

pub fn should_normalize_filtering_test() {
  // Only status=Actual, scope=Public, msgType=Alert|Update
  cap.should_normalize("Actual", "Public", "Alert")
  |> should.equal(True)

  cap.should_normalize("actual", "public", "update")
  |> should.equal(True)

  cap.should_normalize("  ACTUAL  ", " PUBLIC ", " UPDATE ")
  |> should.equal(True)

  // Other statuses rejected
  cap.should_normalize("Exercise", "Public", "Alert")
  |> should.equal(False)

  cap.should_normalize("Draft", "Public", "Alert")
  |> should.equal(False)

  cap.should_normalize("Test", "Public", "Alert")
  |> should.equal(False)

  // Other scopes rejected
  cap.should_normalize("Actual", "Restricted", "Alert")
  |> should.equal(False)

  cap.should_normalize("Actual", "Private", "Alert")
  |> should.equal(False)

  // Other msgTypes rejected (Cancel, Ack, Error are never normalized)
  cap.should_normalize("Actual", "Public", "Cancel")
  |> should.equal(False)

  cap.should_normalize("Actual", "Public", "Ack")
  |> should.equal(False)

  cap.should_normalize("Actual", "Public", "Error")
  |> should.equal(False)
}

pub fn canonicalize_enums_test() {
  // Severity case-insensitivity
  cap.canonicalize_severity("extreme") |> should.equal("Extreme")
  cap.canonicalize_severity("SEVERE") |> should.equal("Severe")
  cap.canonicalize_severity("Moderate") |> should.equal("Moderate")
  cap.canonicalize_severity("minor") |> should.equal("Minor")
  cap.canonicalize_severity("unknown_val") |> should.equal("Unknown")

  // Certainty with CAP 1.0 "Very Likely" -> "Likely"
  cap.canonicalize_certainty("Observed") |> should.equal("Observed")
  cap.canonicalize_certainty("likely") |> should.equal("Likely")
  cap.canonicalize_certainty("Very Likely") |> should.equal("Likely")
  cap.canonicalize_certainty("VERY LIKELY") |> should.equal("Likely")
  cap.canonicalize_certainty("possible") |> should.equal("Possible")
  cap.canonicalize_certainty("unlikely") |> should.equal("Unlikely")
  cap.canonicalize_certainty("invalid") |> should.equal("Unknown")

  // Urgency
  cap.canonicalize_urgency("immediate") |> should.equal("Immediate")
  cap.canonicalize_urgency("EXPECTED") |> should.equal("Expected")
  cap.canonicalize_urgency("Future") |> should.equal("Future")
  cap.canonicalize_urgency("Past") |> should.equal("Past")
  cap.canonicalize_urgency("none") |> should.equal("Unknown")
}

pub fn parse_references_test() {
  // Standard triple from §2
  let raw =
    "noreply@met.no,2.49.0.1.578.0.260917220000.7003_1_0,2026-09-17T21:40:35+00:00"
  cap.parse_references(Some(raw))
  |> should.equal(["noreply@met.no,2.49.0.1.578.0.260917220000.7003_1_0"])

  // Extra whitespace, newlines, multiple triples, malformed ones ignored
  let complex_raw =
    "  noreply@met.no,id1,2026-09-17T21:00:00Z \n\t bad,triple \n noreply@met.no,id2,2026-09-17T22:00:00Z   another_bad   "
  cap.parse_references(Some(complex_raw))
  |> should.equal(["noreply@met.no,id1", "noreply@met.no,id2"])

  // None or empty
  cap.parse_references(None) |> should.equal([])
  cap.parse_references(Some("   ")) |> should.equal([])
}

pub fn language_and_info_selection_test() {
  let de_info =
    models_cap.CapInfo(
      language: Some("de"),
      category: ["Met"],
      event: "Starkes Gewitter",
      response_type: [],
      urgency: "Immediate",
      severity: "Moderate",
      certainty: "Likely",
      audience: None,
      event_code: [],
      effective: None,
      onset: None,
      expires: None,
      sender_name: None,
      headline: None,
      description: None,
      instruction: None,
      web: None,
      contact: None,
      parameter: [],
      resource: [],
      area: [],
    )

  let en_info_moderate =
    models_cap.CapInfo(
      language: Some("en-GB"),
      category: ["Met"],
      event: "Severe Thunderstorm",
      response_type: [],
      urgency: "Immediate",
      severity: "Moderate",
      certainty: "Likely",
      audience: None,
      event_code: [],
      effective: None,
      onset: None,
      expires: None,
      sender_name: None,
      headline: None,
      description: None,
      instruction: None,
      web: None,
      contact: None,
      parameter: [],
      resource: [],
      area: [],
    )

  let en_info_severe =
    models_cap.CapInfo(
      language: Some("en"),
      category: ["Met"],
      event: "Severe Thunderstorm Warning",
      response_type: [],
      urgency: "Immediate",
      severity: "Severe",
      certainty: "Observed",
      audience: None,
      event_code: [],
      effective: None,
      onset: None,
      expires: None,
      sender_name: None,
      headline: None,
      description: None,
      instruction: None,
      web: None,
      contact: None,
      parameter: [],
      resource: [],
      area: [],
    )

  let infos = [de_info, en_info_moderate, en_info_severe]

  // Display language prefers first with primary subtag "en"
  cap.display_language(infos) |> should.equal("en-GB")

  // Candidate infos filtered to display language subtag ("en")
  let candidates = cap.candidate_infos(infos)
  list.length(candidates) |> should.equal(2)

  // Chosen info picks highest severity rank (Severe > Moderate)
  let assert Some(chosen) = cap.choose_info(candidates)
  chosen.event |> should.equal("Severe Thunderstorm Warning")
  chosen.severity |> should.equal("Severe")

  // Tie-breaking: when severities are equal, earliest candidate in document order is chosen
  let assert Some(tie_chosen) =
    cap.choose_info([en_info_moderate, en_info_moderate])
  tie_chosen.event |> should.equal("Severe Thunderstorm")
}

pub fn out_of_order_supersede_and_cancel_test() {
  let now = timestamp.system_time()

  // Scenario 1: Update arrived before Alert (out-of-order)
  let stored_update =
    cap.StoredMessageRef(
      key: "sender,update1",
      msg_type: "Update",
      status: "Actual",
      scope: "Public",
      public_id: "cap-auth:sender,update1",
      normalized: True,
    )
  let incoming_alert = "sender,alert1"

  let res1 =
    cap.resolve_supersede_and_cancel(
      "Alert",
      "Actual",
      "cap-auth:" <> incoming_alert,
      [stored_update],
      [],
      now,
    )

  // Incoming alert is inserted already ended as superseded by the Update
  res1.incoming_ending
  |> should.equal(cap.InsertedEnded(
    ended_at: now,
    end_reason: "superseded",
    superseded_by: Some("cap-auth:sender,update1"),
  ))
  res1.rows_to_end |> should.equal([])

  // Scenario 1b: Unnormalized Update arrived before Alert -> does NOT supersede!
  let stored_unnorm_update =
    cap.StoredMessageRef(
      key: "sender,update_unnorm",
      msg_type: "Update",
      status: "Actual",
      scope: "Public",
      public_id: "cap-auth:sender,update_unnorm",
      normalized: False,
    )
  let res1b =
    cap.resolve_supersede_and_cancel(
      "Alert",
      "Actual",
      "cap-auth:" <> incoming_alert,
      [stored_unnorm_update],
      [],
      now,
    )
  res1b.incoming_ending |> should.equal(cap.NotEnded)

  // Scenario 1c: Non-Public (Restricted) Update arrived before Alert -> does NOT supersede!
  let stored_restricted_update =
    cap.StoredMessageRef(
      key: "sender,update_restricted",
      msg_type: "Update",
      status: "Actual",
      scope: "Restricted",
      public_id: "cap-auth:sender,update_restricted",
      normalized: True,
    )
  let res1c =
    cap.resolve_supersede_and_cancel(
      "Alert",
      "Actual",
      "cap-auth:" <> incoming_alert,
      [stored_restricted_update],
      [],
      now,
    )
  res1c.incoming_ending |> should.equal(cap.NotEnded)

  // Scenario 2: Cancel arrived before Alert (out-of-order, normalized=false still cancels)
  let stored_cancel =
    cap.StoredMessageRef(
      key: "sender,cancel1",
      msg_type: "Cancel",
      status: "Actual",
      scope: "Public",
      public_id: "cap-auth:sender,cancel1",
      normalized: False,
    )

  let res2 =
    cap.resolve_supersede_and_cancel(
      "Alert",
      "Actual",
      "cap-auth:" <> incoming_alert,
      [stored_cancel],
      [],
      now,
    )

  // Incoming alert is inserted ended as cancelled
  res2.incoming_ending
  |> should.equal(cap.InsertedEnded(
    ended_at: now,
    end_reason: "cancelled",
    superseded_by: None,
  ))

  // Scenario 2b: Non-Actual (Test) Cancel arrived before Alert -> ignored!
  let stored_test_cancel =
    cap.StoredMessageRef(
      key: "sender,test_cancel",
      msg_type: "Cancel",
      status: "Test",
      scope: "Public",
      public_id: "cap-auth:sender,test_cancel",
      normalized: False,
    )
  let res2b =
    cap.resolve_supersede_and_cancel(
      "Alert",
      "Actual",
      "cap-auth:" <> incoming_alert,
      [stored_test_cancel],
      [],
      now,
    )
  res2b.incoming_ending |> should.equal(cap.NotEnded)

  // Scenario 3: Normal in-order Update supersedes existing active rows
  let active_row =
    cap.ActiveAlertRef(source: "cap-auth", source_id: "sender,old")
  let res3 =
    cap.resolve_supersede_and_cancel(
      "Update",
      "Actual",
      "cap-auth:sender,new_update",
      [],
      [active_row],
      now,
    )

  res3.incoming_ending |> should.equal(cap.NotEnded)
  let assert [end_action] = res3.rows_to_end
  end_action.source |> should.equal("cap-auth")
  end_action.source_id |> should.equal("sender,old")
  end_action.end_reason |> should.equal("superseded")
  end_action.superseded_by |> should.equal(Some("cap-auth:sender,new_update"))

  // Scenario 4: Cancel ends active rows with 'cancelled'
  let res4 =
    cap.resolve_supersede_and_cancel(
      "Cancel",
      "Actual",
      "cap-auth:sender,cancel_msg",
      [],
      [active_row],
      now,
    )
  let assert [cancel_action] = res4.rows_to_end
  cancel_action.end_reason |> should.equal("cancelled")
  cancel_action.superseded_by |> should.equal(None)

  // Scenario 5: Non-Actual (Test) Cancel does NOT end active rows
  let res5 =
    cap.resolve_supersede_and_cancel(
      "Cancel",
      "Test",
      "cap-auth:sender,test_cancel_msg",
      [],
      [active_row],
      now,
    )
  res5.rows_to_end |> should.equal([])
}

pub fn normalize_alert_complete_test() {
  let info =
    models_cap.CapInfo(
      language: Some("en"),
      category: ["Met", "Safety"],
      event: "Coastal Flood Warning",
      response_type: ["Evacuate"],
      urgency: "Immediate",
      severity: "Extreme",
      certainty: "Observed",
      audience: None,
      event_code: [],
      effective: Some("2026-09-19T10:00:00Z"),
      onset: Some("2026-09-19T11:00:00Z"),
      expires: Some("2026-09-19T18:00:00Z"),
      sender_name: Some("National Weather Service Office"),
      headline: Some("Major flooding expected"),
      description: Some("Extensive coastal inundation"),
      instruction: Some("Move to higher ground"),
      web: Some("https://example.org/warnings/123"),
      contact: Some("Duty Forecaster: +1-555-0100"),
      parameter: [],
      resource: [],
      area: [
        models_cap.CapArea(
          area_desc: "Northern Bay",
          polygon: ["10.0,20.0 10.0,25.0 15.0,25.0 15.0,20.0 10.0,20.0"],
          circle: [],
          geocode: [models_cap.ValuePair("UGC", "NCZ001")],
          altitude: None,
          ceiling: None,
        ),
      ],
    )

  let cap_msg =
    models_cap.CapMessage(
      cap_version: Some("1.2"),
      identifier: "CFW-2026-001",
      sender: "alert@agency.gov",
      sent: "2026-09-19T10:00:00Z",
      status: "Actual",
      msg_type: "Alert",
      source: None,
      scope: "Public",
      restriction: None,
      addresses: None,
      code: [],
      note: None,
      references: None,
      incidents: None,
      info: [info],
      raw_json: "{}",
    )

  let assert Ok(norm) =
    cap.normalize_alert(cap_msg, "cap-2.49.0.0.123.0", "USA")

  norm.source |> should.equal("cap-2.49.0.0.123.0")
  norm.source_id |> should.equal("alert@agency.gov,CFW-2026-001")
  norm.event |> should.equal("Coastal Flood Warning")
  norm.severity |> should.equal("Extreme")
  norm.urgency |> should.equal("Immediate")
  norm.certainty |> should.equal("Observed")
  norm.contact |> should.equal(Some("Duty Forecaster: +1-555-0100"))
  norm.area_desc |> should.equal("Northern Bay")
  norm.countries |> should.equal(["USA"])
  should.be_true(option.is_some(norm.geom))
  norm.active_until
  |> should.equal(cap.parse_rfc3339("2026-09-19T18:00:00Z") |> should_ok)

  // When expires is missing, active_until = sent + 24 hours
  let info_no_expires = models_cap.CapInfo(..info, expires: None)
  let msg_no_expires = models_cap.CapMessage(..cap_msg, info: [info_no_expires])
  let assert Ok(norm_no_exp) =
    cap.normalize_alert(msg_no_expires, "cap-auth", "USA")
  let assert Ok(sent_ts) = cap.parse_rfc3339("2026-09-19T10:00:00Z")
  let expected_active = timestamp.add(sent_ts, duration.hours(24))
  norm_no_exp.active_until |> should.equal(expected_active)
}

pub fn record_classify_integration_test() {
  let cap_msg =
    models_cap.CapMessage(
      cap_version: Some("1.2"),
      identifier: "TEST-001",
      sender: "sender@agency.gov",
      sent: "2026-09-19T12:00:00Z",
      status: "Actual",
      msg_type: "Alert",
      source: None,
      scope: "Public",
      restriction: None,
      addresses: None,
      code: [],
      note: None,
      references: None,
      incidents: None,
      info: [],
      raw_json: "{}",
    )

  let assert Ok(incoming) = cap.make_incoming_record(cap_msg, "payload")
  incoming.key
  |> should.equal(record.Key("cap", "sender@agency.gov,TEST-001"))

  // Revision is milliseconds
  let assert Ok(sent_ts) = cap.parse_rfc3339("2026-09-19T12:00:00Z")
  let #(sec, nsec) = timestamp.to_unix_seconds_and_nanoseconds(sent_ts)
  let expected_ms = sec * 1000 + nsec / 1_000_000
  incoming.revision |> should.equal(expected_ms)

  // When classified against empty store -> New
  let classified = record.classify([incoming], dict.new())
  let assert [#(_, record.New)] = classified
}

fn should_ok(res: Result(a, Nil)) -> a {
  let assert Ok(val) = res
  val
}

pub fn parse_rfc1123_forms_test() {
  // All forms should produce the same UTC instant: 2026-09-18T21:40:12Z
  let expected_unix =
    timestamp.to_unix_seconds(
      should_ok(cap.parse_rfc3339("2026-09-18T21:40:12Z")),
    )

  // Standard RFC 1123 with space before offset
  let t1 = should_ok(cap.parse_rfc1123("Fri, 18 Sep 2026 17:40:12 -0400"))
  timestamp.to_unix_seconds(t1) |> should.equal(expected_unix)

  // Offset glued to the time (no space)
  let t2 = should_ok(cap.parse_rfc1123("Fri, 18 Sep 2026 17:40:12-0400"))
  timestamp.to_unix_seconds(t2) |> should.equal(expected_unix)

  // Positive offset +0000
  let expected_utc =
    timestamp.to_unix_seconds(
      should_ok(cap.parse_rfc3339("2026-09-18T17:40:12Z")),
    )
  let t3 = should_ok(cap.parse_rfc1123("Fri, 18 Sep 2026 17:40:12 +0000"))
  timestamp.to_unix_seconds(t3) |> should.equal(expected_utc)

  // +0530 (India) — 17:40:12+0530 = 12:10:12Z
  let expected_ist =
    timestamp.to_unix_seconds(
      should_ok(cap.parse_rfc3339("2026-09-18T12:10:12Z")),
    )
  let t4 = should_ok(cap.parse_rfc1123("Fri, 18 Sep 2026 17:40:12 +0530"))
  timestamp.to_unix_seconds(t4) |> should.equal(expected_ist)

  // GMT named offset
  let t5 = should_ok(cap.parse_rfc1123("Fri, 18 Sep 2026 17:40:12 GMT"))
  timestamp.to_unix_seconds(t5) |> should.equal(expected_utc)

  // UTC named offset
  let t6 = should_ok(cap.parse_rfc1123("Fri, 18 Sep 2026 17:40:12 UTC"))
  timestamp.to_unix_seconds(t6) |> should.equal(expected_utc)

  // Z suffix
  let t7 = should_ok(cap.parse_rfc1123("Fri, 18 Sep 2026 17:40:12 Z"))
  timestamp.to_unix_seconds(t7) |> should.equal(expected_utc)

  // Missing weekday
  let t8 = should_ok(cap.parse_rfc1123("18 Sep 2026 17:40:12 -0400"))
  timestamp.to_unix_seconds(t8) |> should.equal(expected_unix)

  // hh:mm without seconds — 17:40 -0400 = 21:40:00Z
  let expected_no_sec =
    timestamp.to_unix_seconds(
      should_ok(cap.parse_rfc3339("2026-09-18T21:40:00Z")),
    )
  let t9 = should_ok(cap.parse_rfc1123("Fri, 18 Sep 2026 17:40 -0400"))
  timestamp.to_unix_seconds(t9) |> should.equal(expected_no_sec)

  // 2-digit year (18 -> 2018, not 2026, pick a year that's unambiguous)
  // "18 Sep 26 17:40:12 +0000" → year 2026
  let expected_2digit =
    timestamp.to_unix_seconds(
      should_ok(cap.parse_rfc3339("2026-09-18T17:40:12Z")),
    )
  let t10 = should_ok(cap.parse_rfc1123("18 Sep 26 17:40:12 +0000"))
  timestamp.to_unix_seconds(t10) |> should.equal(expected_2digit)
}

pub fn compute_message_expires_at_test() {
  let make_info = fn(lang, expires) {
    models_cap.CapInfo(
      language: lang,
      category: ["Met"],
      event: "Test Event",
      response_type: [],
      urgency: "Immediate",
      severity: "Severe",
      certainty: "Likely",
      audience: None,
      event_code: [],
      effective: None,
      onset: None,
      expires:,
      sender_name: None,
      headline: None,
      description: None,
      instruction: None,
      web: None,
      contact: None,
      parameter: [],
      resource: [],
      area: [],
    )
  }

  let sent = "2026-09-19T10:00:00Z"
  let assert Ok(sent_ts) = cap.parse_rfc3339(sent)
  let floor = timestamp.add(sent_ts, duration.hours(24))

  // No infos: result = sent + 24h
  let msg_no_info =
    models_cap.CapMessage(
      cap_version: None,
      identifier: "X",
      sender: "s@x.gov",
      sent:,
      status: "Actual",
      msg_type: "Alert",
      source: None,
      scope: "Public",
      restriction: None,
      addresses: None,
      code: [],
      note: None,
      references: None,
      incidents: None,
      info: [],
      raw_json: "{}",
    )
  let assert Ok(t_no_info) = cap.compute_message_expires_at(msg_no_info)
  t_no_info |> should.equal(floor)

  // One info with expires earlier than sent+24h: result = sent+24h (floor wins)
  let early_exp = "2026-09-19T20:00:00Z"
  let assert Ok(early_ts) = cap.parse_rfc3339(early_exp)
  should.be_true(timestamp.compare(early_ts, floor) == order.Lt)
  let msg_early =
    models_cap.CapMessage(..msg_no_info, info: [
      make_info(Some("en"), Some(early_exp)),
    ])
  let assert Ok(t_early) = cap.compute_message_expires_at(msg_early)
  t_early |> should.equal(floor)

  // Two infos: chosen (en) expires at 18h, other info expires at 36h → result = 36h
  let later_exp = "2026-09-20T22:00:00Z"
  let assert Ok(later_ts) = cap.parse_rfc3339(later_exp)
  should.be_true(timestamp.compare(later_ts, floor) == order.Gt)
  let msg_two =
    models_cap.CapMessage(..msg_no_info, info: [
      make_info(Some("en"), Some(early_exp)),
      make_info(Some("de"), Some(later_exp)),
    ])
  let assert Ok(t_two) = cap.compute_message_expires_at(msg_two)
  t_two |> should.equal(later_ts)

  // Chosen info has no expires; other info has late expires → max wins
  let msg_chosen_no_exp =
    models_cap.CapMessage(..msg_no_info, info: [
      make_info(Some("en"), None),
      make_info(Some("de"), Some(later_exp)),
    ])
  let assert Ok(t_chosen_no_exp) =
    cap.compute_message_expires_at(msg_chosen_no_exp)
  t_chosen_no_exp |> should.equal(later_ts)
}

pub fn normalize_alert_message_type_test() {
  let make_msg = fn(msg_type) {
    models_cap.CapMessage(
      cap_version: None,
      identifier: "MT-001",
      sender: "s@x.gov",
      sent: "2026-09-19T10:00:00Z",
      status: "Actual",
      msg_type:,
      source: None,
      scope: "Public",
      restriction: None,
      addresses: None,
      code: [],
      note: None,
      references: None,
      incidents: None,
      info: [
        models_cap.CapInfo(
          language: Some("en"),
          category: [],
          event: "Test",
          response_type: [],
          urgency: "Immediate",
          severity: "Minor",
          certainty: "Likely",
          audience: None,
          event_code: [],
          effective: None,
          onset: None,
          expires: None,
          sender_name: None,
          headline: None,
          description: None,
          instruction: None,
          web: None,
          contact: None,
          parameter: [],
          resource: [],
          area: [],
        ),
      ],
      raw_json: "{}",
    )
  }

  // "Alert" (canonical) -> "Alert"
  let assert Ok(n1) = cap.normalize_alert(make_msg("Alert"), "src", "")
  n1.message_type |> should.equal("Alert")

  // "ALERT" (uppercase) -> "Alert"
  let assert Ok(n2) = cap.normalize_alert(make_msg("ALERT"), "src", "")
  n2.message_type |> should.equal("Alert")

  // "update" (lowercase) -> "Update"
  let assert Ok(n3) = cap.normalize_alert(make_msg("update"), "src", "")
  n3.message_type |> should.equal("Update")

  // "UPDATE" (uppercase) -> "Update"
  let assert Ok(n4) = cap.normalize_alert(make_msg("UPDATE"), "src", "")
  n4.message_type |> should.equal("Update")

  // "Update" (canonical) -> "Update"
  let assert Ok(n5) = cap.normalize_alert(make_msg("Update"), "src", "")
  n5.message_type |> should.equal("Update")
}

pub fn normalize_alert_area_desc_dedup_test() {
  let make_area = fn(desc) {
    models_cap.CapArea(
      area_desc: desc,
      polygon: [],
      circle: [],
      geocode: [],
      altitude: None,
      ceiling: None,
    )
  }
  let make_info = fn(lang, areas) {
    models_cap.CapInfo(
      language: lang,
      category: [],
      event: "Test",
      response_type: [],
      urgency: "Immediate",
      severity: "Minor",
      certainty: "Likely",
      audience: None,
      event_code: [],
      effective: None,
      onset: None,
      expires: None,
      sender_name: None,
      headline: None,
      description: None,
      instruction: None,
      web: None,
      contact: None,
      parameter: [],
      resource: [],
      area: areas,
    )
  }
  let base_msg =
    models_cap.CapMessage(
      cap_version: None,
      identifier: "AD-001",
      sender: "s@x.gov",
      sent: "2026-09-19T10:00:00Z",
      status: "Actual",
      msg_type: "Alert",
      source: None,
      scope: "Public",
      restriction: None,
      addresses: None,
      code: [],
      note: None,
      references: None,
      incidents: None,
      info: [],
      raw_json: "{}",
    )

  // No infos → Error (no candidate infos)
  cap.normalize_alert(base_msg, "src", "")
  |> should.be_error()

  // Info with no areas → "Unknown area" fallback
  let msg_no_areas =
    models_cap.CapMessage(..base_msg, info: [make_info(Some("en"), [])])
  let assert Ok(n_unknown) = cap.normalize_alert(msg_no_areas, "src", "")
  n_unknown.area_desc |> should.equal("Unknown area")

  // Single area
  let msg1 =
    models_cap.CapMessage(..base_msg, info: [
      make_info(Some("en"), [make_area("Bay Area")]),
    ])
  let assert Ok(n1) = cap.normalize_alert(msg1, "src", "")
  n1.area_desc |> should.equal("Bay Area")

  // Two areas with duplicate desc → deduplicated
  let msg2 =
    models_cap.CapMessage(..base_msg, info: [
      make_info(Some("en"), [make_area("Bay Area"), make_area("Bay Area")]),
    ])
  let assert Ok(n2) = cap.normalize_alert(msg2, "src", "")
  n2.area_desc |> should.equal("Bay Area")

  // Two areas with different descs → joined
  let msg3 =
    models_cap.CapMessage(..base_msg, info: [
      make_info(Some("en"), [make_area("Bay Area"), make_area("Mountain Zone")]),
    ])
  let assert Ok(n3) = cap.normalize_alert(msg3, "src", "")
  n3.area_desc |> should.equal("Bay Area; Mountain Zone")
}

pub fn severity_tiebreak_different_infos_test() {
  // Two DIFFERENT infos with equal severity — earliest in document order wins
  let make_info = fn(event, severity) {
    models_cap.CapInfo(
      language: Some("en"),
      category: [],
      event:,
      response_type: [],
      urgency: "Immediate",
      severity:,
      certainty: "Likely",
      audience: None,
      event_code: [],
      effective: None,
      onset: None,
      expires: None,
      sender_name: None,
      headline: None,
      description: None,
      instruction: None,
      web: None,
      contact: None,
      parameter: [],
      resource: [],
      area: [],
    )
  }

  let first_info = make_info("First Event", "Severe")
  let second_info = make_info("Second Event", "Severe")

  // When severities are equal, first in document order wins
  let assert Some(chosen1) = cap.choose_info([first_info, second_info])
  chosen1.event |> should.equal("First Event")

  // Also with the order reversed
  let assert Some(chosen2) = cap.choose_info([second_info, first_info])
  chosen2.event |> should.equal("Second Event")

  // Higher severity always beats lower, regardless of order
  let low_info = make_info("Low Event", "Minor")
  let high_info = make_info("High Event", "Extreme")
  let assert Some(chosen3) = cap.choose_info([low_info, high_info])
  chosen3.event |> should.equal("High Event")
}

pub fn non_english_display_language_test() {
  // When no info has primary subtag "en", first info's language is used
  let make_info = fn(lang, event) {
    models_cap.CapInfo(
      language: lang,
      category: [],
      event:,
      response_type: [],
      urgency: "Immediate",
      severity: "Minor",
      certainty: "Likely",
      audience: None,
      event_code: [],
      effective: None,
      onset: None,
      expires: None,
      sender_name: None,
      headline: None,
      description: None,
      instruction: None,
      web: None,
      contact: None,
      parameter: [],
      resource: [],
      area: [],
    )
  }

  let fr_info = make_info(Some("fr-CA"), "Alerte météo")
  let de_info = make_info(Some("de"), "Wetterwarnung")

  // No english infos → display language = first info's language
  cap.display_language([fr_info, de_info]) |> should.equal("fr-CA")

  // Candidates filtered by primary subtag "fr"
  let candidates = cap.candidate_infos([fr_info, de_info])
  list.length(candidates) |> should.equal(1)
  let assert [c] = candidates
  c.event |> should.equal("Alerte météo")

  // Missing language defaults to "en-US" in effective_info_language
  let no_lang_info = make_info(None, "No Language Event")
  cap.effective_info_language(no_lang_info) |> should.equal("en-US")

  // Empty language string also defaults
  let empty_lang_info = make_info(Some(""), "Empty Language")
  cap.effective_info_language(empty_lang_info) |> should.equal("en-US")

  // In candidate selection, None language is treated as "en-US" (primary subtag "en")
  let infos_with_none = [no_lang_info, fr_info]
  cap.display_language(infos_with_none) |> should.equal("en-US")
  let cands = cap.candidate_infos(infos_with_none)
  list.length(cands) |> should.equal(1)
  let assert [nc] = cands
  nc.event |> should.equal("No Language Event")
}
