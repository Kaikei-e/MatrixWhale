import domain/alert
import gleam/json
import gleam/option.{None, Some}
import gleam/string
import gleam/time/duration
import gleam/time/timestamp
import gleeunit/should
import repository/alert_writer

pub fn noaa_active_until_ends_test() {
  let now = timestamp.from_unix_seconds(1_700_000_000)
  let sent = timestamp.from_unix_seconds(1_700_000_100)
  let expires = timestamp.from_unix_seconds(1_700_000_200)
  let ends = timestamp.from_unix_seconds(1_700_000_300)

  alert_writer.noaa_active_until(Some(ends), Some(expires), Some(sent), now)
  |> should.equal(ends)
}

pub fn noaa_active_until_expires_fallback_test() {
  let now = timestamp.from_unix_seconds(1_700_000_000)
  let sent = timestamp.from_unix_seconds(1_700_000_100)
  let expires = timestamp.from_unix_seconds(1_700_000_200)

  alert_writer.noaa_active_until(None, Some(expires), Some(sent), now)
  |> should.equal(expires)
}

pub fn noaa_active_until_sent_plus_24h_fallback_test() {
  let now = timestamp.from_unix_seconds(1_700_000_000)
  let sent = timestamp.from_unix_seconds(1_700_000_100)

  alert_writer.noaa_active_until(None, None, Some(sent), now)
  |> should.equal(timestamp.add(sent, duration.hours(24)))
}

pub fn noaa_active_until_now_plus_24h_fallback_test() {
  let now = timestamp.from_unix_seconds(1_700_000_000)

  alert_writer.noaa_active_until(None, None, None, now)
  |> should.equal(timestamp.add(now, duration.hours(24)))
}

pub fn noaa_geocodes_json_test() {
  let json_str = alert_writer.noaa_geocodes_json(["VAZ001"], ["051001"])
  json_str |> string.contains("\"name\":\"UGC\"") |> should.equal(True)
  json_str |> string.contains("\"value\":\"VAZ001\"") |> should.equal(True)
  json_str |> string.contains("\"name\":\"SAME\"") |> should.equal(True)
  json_str |> string.contains("\"value\":\"051001\"") |> should.equal(True)
}

pub fn alert_to_json_fields_test() {
  let now = timestamp.from_unix_seconds(1_700_000_000)
  let row =
    alert.AlertRow(
      source: "noaa",
      source_id: "urn:oid:2.49.0.1.840.0.1",
      source_name: "National Weather Service",
      attribution: "NOAA NWS",
      sender: Some("nws@noaa.gov"),
      sender_name: Some("NWS"),
      identifier: Some("urn:oid:2.49.0.1.840.0.1"),
      message_type: Some("Alert"),
      event: "High Wind Warning",
      category: ["Met"],
      severity: "Severe",
      urgency: "Immediate",
      certainty: "Observed",
      headline: Some("High Wind Warning in effect"),
      description: Some("Winds up to 60mph"),
      instruction: Some("Take caution when driving"),
      web: Some("https://weather.gov"),
      contact: Some("helpdesk@weather.gov"),
      language: Some("en-US"),
      area_desc: "Fairfax County",
      geocodes: "[{\"name\":\"UGC\",\"value\":\"VAZ053\"}]",
      countries: ["USA"],
      geom: Some("{\"type\":\"MultiPolygon\",\"coordinates\":[]}"),
      reference_keys: [],
      sent: Some(now),
      effective: Some(now),
      onset: None,
      expires: Some(now),
      ends: None,
      active_until: now,
      first_seen_at: now,
      last_seen_at: now,
      ended_at: None,
      end_reason: None,
      superseded_by: None,
    )

  let json_str = json.to_string(alert.to_json(row))

  // §7.1 public id shape
  json_str
  |> string.contains("\"id\":\"noaa:urn:oid:2.49.0.1.840.0.1\"")
  |> should.equal(True)
  json_str |> string.contains("\"source\":\"noaa\"") |> should.equal(True)
  json_str
  |> string.contains("\"source_id\":\"urn:oid:2.49.0.1.840.0.1\"")
  |> should.equal(True)
  json_str
  |> string.contains("\"source_name\":\"National Weather Service\"")
  |> should.equal(True)
  json_str |> string.contains("\"countries\":[\"USA\"]") |> should.equal(True)
  json_str
  |> string.contains("\"event\":\"High Wind Warning\"")
  |> should.equal(True)
  json_str |> string.contains("\"severity\":\"Severe\"") |> should.equal(True)

  // List shape must NOT contain description, instruction, or contact
  json_str |> string.contains("\"description\"") |> should.equal(False)
  json_str |> string.contains("\"instruction\"") |> should.equal(False)
  json_str |> string.contains("\"contact\"") |> should.equal(False)
}

pub fn alert_to_detail_json_fields_test() {
  let now = timestamp.from_unix_seconds(1_700_000_000)
  let row =
    alert.AlertRow(
      source: "noaa",
      source_id: "urn:oid:2.49.0.1.840.0.1",
      source_name: "National Weather Service",
      attribution: "NOAA NWS",
      sender: Some("nws@noaa.gov"),
      sender_name: Some("NWS"),
      identifier: Some("urn:oid:2.49.0.1.840.0.1"),
      message_type: Some("Alert"),
      event: "High Wind Warning",
      category: ["Met"],
      severity: "Severe",
      urgency: "Immediate",
      certainty: "Observed",
      headline: Some("High Wind Warning in effect"),
      description: Some("Winds up to 60mph"),
      instruction: Some("Take caution when driving"),
      web: Some("https://weather.gov"),
      contact: Some("helpdesk@weather.gov"),
      language: Some("en-US"),
      area_desc: "Fairfax County",
      geocodes: "[{\"name\":\"UGC\",\"value\":\"VAZ053\"}]",
      countries: ["USA"],
      geom: Some("{\"type\":\"MultiPolygon\",\"coordinates\":[]}"),
      reference_keys: [],
      sent: Some(now),
      effective: Some(now),
      onset: None,
      expires: Some(now),
      ends: None,
      active_until: now,
      first_seen_at: now,
      last_seen_at: now,
      ended_at: None,
      end_reason: None,
      superseded_by: None,
    )

  let detail_json_str =
    json.to_string(alert.to_detail_json(
      row,
      json.preprocessed_array([]),
      Some("https://example.com/cap.xml"),
      Some("https://example.com/feed.atom"),
    ))

  // §7.2 detail JSON contains alert, infos, cap_url, feed_url
  detail_json_str |> string.contains("\"alert\":{") |> should.equal(True)
  detail_json_str |> string.contains("\"infos\":[]") |> should.equal(True)
  detail_json_str
  |> string.contains("\"cap_url\":\"https://example.com/cap.xml\"")
  |> should.equal(True)
  detail_json_str
  |> string.contains("\"feed_url\":\"https://example.com/feed.atom\"")
  |> should.equal(True)

  // detail alert object MUST contain description, instruction, contact
  detail_json_str
  |> string.contains("\"description\":\"Winds up to 60mph\"")
  |> should.equal(True)
  detail_json_str
  |> string.contains("\"instruction\":\"Take caution when driving\"")
  |> should.equal(True)
  detail_json_str
  |> string.contains("\"contact\":\"helpdesk@weather.gov\"")
  |> should.equal(True)
}
