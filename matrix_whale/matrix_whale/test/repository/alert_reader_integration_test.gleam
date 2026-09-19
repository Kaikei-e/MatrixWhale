import domain/alert
import gleam/dict
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleam/time/calendar
import gleam/time/duration
import gleam/time/timestamp
import gleeunit/should
import intake/record
import message/reciever/models/noaa
import repository/alert_reader
import repository/alert_writer
import support/test_db

pub fn list_active_filters_by_source_country_severity_integration_test() {
  test_db.with_test_db(fn(conn) {
    seed_sources(conn)
    let now = timestamp.system_time()
    let active_until = timestamp.add(now, duration.hours(24))

    // 1. NOAA alert in USA with Severe severity
    seed_alert(
      conn,
      "noaa",
      "noaa-1",
      "Hurricane Warning",
      "Severe",
      "Florida Coast",
      "['USA']",
      active_until,
      None,
    )

    // 2. CAP alert in DEU with Moderate severity
    seed_alert(
      conn,
      "cap-test",
      "cap-1",
      "Flood Warning",
      "Moderate",
      "Rhine Valley",
      "['DEU']",
      active_until,
      None,
    )

    // 3. Expired alert
    seed_alert(
      conn,
      "noaa",
      "noaa-expired",
      "Old Gale",
      "Minor",
      "Atlantic",
      "['USA']",
      timestamp.subtract(now, duration.hours(1)),
      None,
    )

    // 4. Ended alert
    seed_alert(
      conn,
      "cap-test",
      "cap-ended",
      "Ended Gale",
      "Extreme",
      "North Sea",
      "['DEU']",
      active_until,
      Some(now),
    )

    // Query all active alerts (no filters) -> should return 2 (noaa-1 and cap-1)
    let assert Ok(all_active) = alert_reader.list_active([], [], [], conn)
    list.length(all_active) |> should.equal(2)

    // Filter by source: ["noaa"] -> should return 1 (noaa-1)
    let assert Ok(noaa_only) = alert_reader.list_active(["noaa"], [], [], conn)
    list.length(noaa_only) |> should.equal(1)
    let assert Ok(first) = list.first(noaa_only)
    first.source_id |> should.equal("noaa-1")

    // Filter by country: ["DEU"] -> should return 1 (cap-1)
    let assert Ok(deu_only) = alert_reader.list_active([], ["DEU"], [], conn)
    list.length(deu_only) |> should.equal(1)
    let assert Ok(first_deu) = list.first(deu_only)
    first_deu.source_id |> should.equal("cap-1")

    // Filter by severity: ["Severe"] -> should return 1 (noaa-1)
    let assert Ok(severe_only) =
      alert_reader.list_active([], [], ["Severe"], conn)
    list.length(severe_only) |> should.equal(1)
    let assert Ok(first_sev) = list.first(severe_only)
    first_sev.source_id |> should.equal("noaa-1")
  })
}

pub fn by_ids_retrieves_matching_alerts_integration_test() {
  test_db.with_test_db(fn(conn) {
    seed_sources(conn)
    let now = timestamp.system_time()
    let active_until = timestamp.add(now, duration.hours(24))

    seed_alert(
      conn,
      "noaa",
      "urn:oid:2.49.0.1.840.0.100",
      "Coastal Flood Warning",
      "Severe",
      "Miami",
      "['USA']",
      active_until,
      None,
    )
    seed_alert(
      conn,
      "cap-test",
      "dwd,item.123",
      "Heavy Snow",
      "Moderate",
      "Alps",
      "['DEU']",
      active_until,
      None,
    )

    let assert Ok(alerts) =
      alert_reader.by_ids(
        ["noaa:urn:oid:2.49.0.1.840.0.100", "cap-test:dwd,item.123"],
        conn,
      )
    list.length(alerts) |> should.equal(2)

    let assert Ok(empty) = alert_reader.by_ids(["unknown:id"], conn)
    list.length(empty) |> should.equal(0)
  })
}

pub fn detail_returns_alert_with_cap_message_integration_test() {
  test_db.with_test_db(fn(conn) {
    seed_sources(conn)
    let now = timestamp.system_time()
    let active_until = timestamp.add(now, duration.hours(24))

    seed_alert(
      conn,
      "cap-test",
      "cap-msg-1",
      "Gale Warning",
      "Severe",
      "Baltic Sea",
      "['DEU']",
      active_until,
      None,
    )

    // Seed feed and cap_message
    test_db.exec(
      conn,
      "INSERT INTO sea.cap_authority (oid, source, name, country_name, country_iso3, first_seen_at, last_seen_at) VALUES ('oid-1', 'cap-test', 'Authority', 'Germany', 'DEU', now(), now()) ON CONFLICT DO NOTHING;",
    )
    test_db.exec(
      conn,
      "INSERT INTO sea.cap_feed (url, authority_oid, authority_oids, subscribed, first_seen_at, last_seen_at) VALUES ('https://example.com/feed.atom', 'oid-1', ARRAY['oid-1'], true, now(), now()) ON CONFLICT DO NOTHING;",
    )
    test_db.exec(
      conn,
      "INSERT INTO sea.cap_message (sender, identifier, sent, sent_ms, status, msg_type, scope, source, feed_url, cap_url, cap, raw_xml, normalized, expires_at, first_seen_at, last_seen_at) VALUES ('sender-1', 'ident-1', now(), 1234567, 'Actual', 'Alert', 'Public', 'cap-test', 'https://example.com/feed.atom', 'https://example.com/cap.xml', '{\"info\": [{\"headline\": \"CAP Info Headline\"}]}'::jsonb, '<alert></alert>', true, now() + INTERVAL '1 day', now(), now());",
    )

    // Update alert to match sender and identifier
    test_db.exec(
      conn,
      "UPDATE sea.alert SET sender = 'sender-1', identifier = 'ident-1' WHERE source = 'cap-test' AND source_id = 'cap-msg-1';",
    )

    let assert Ok(detail_result) =
      alert_reader.detail("cap-test", "cap-msg-1", conn)
    case detail_result {
      None -> False |> should.equal(True)
      Some(#(row, _infos, cap_url, feed_url)) -> {
        row.source_id |> should.equal("cap-msg-1")
        cap_url |> should.equal(Some("https://example.com/cap.xml"))
        feed_url |> should.equal(Some("https://example.com/feed.atom"))
      }
    }
  })
}

pub fn search_matches_headline_event_and_area_desc_integration_test() {
  test_db.with_test_db(fn(conn) {
    seed_sources(conn)
    let now = timestamp.system_time()
    let active_until = timestamp.add(now, duration.hours(24))

    seed_alert(
      conn,
      "noaa",
      "search-1",
      "Tornado Warning",
      "Extreme",
      "Dallas County",
      "['USA']",
      active_until,
      None,
    )
    test_db.exec(
      conn,
      "UPDATE sea.alert SET headline = 'Destructive Tornado Sighted' WHERE source = 'noaa' AND source_id = 'search-1';",
    )

    // Match by event
    let assert Ok(res1) = alert_reader.search("Tornado", conn)
    list.length(res1) |> should.equal(1)

    // Match by area_desc
    let assert Ok(res2) = alert_reader.search("Dallas", conn)
    list.length(res2) |> should.equal(1)

    // Match by headline
    let assert Ok(res3) = alert_reader.search("Destructive", conn)
    list.length(res3) |> should.equal(1)

    // No match
    let assert Ok(res4) = alert_reader.search("Blizzard", conn)
    list.length(res4) |> should.equal(0)
  })
}

pub fn count_active_by_severity_integration_test() {
  test_db.with_test_db(fn(conn) {
    seed_sources(conn)
    let now = timestamp.system_time()
    let active_until = timestamp.add(now, duration.hours(24))

    seed_alert(
      conn,
      "noaa",
      "sev-ext",
      "Tornado",
      "Extreme",
      "Area A",
      "['USA']",
      active_until,
      None,
    )
    seed_alert(
      conn,
      "noaa",
      "sev-sev",
      "Thunderstorm",
      "Severe",
      "Area B",
      "['USA']",
      active_until,
      None,
    )
    seed_alert(
      conn,
      "noaa",
      "sev-mod",
      "Flood",
      "Moderate",
      "Area C",
      "['USA']",
      active_until,
      None,
    )
    seed_alert(
      conn,
      "noaa",
      "sev-min",
      "Frost",
      "Minor",
      "Area D",
      "['USA']",
      active_until,
      None,
    )

    let assert Ok(counts) = alert_reader.count_active_by_severity(conn)
    counts.extreme |> should.equal(1)
    counts.severe |> should.equal(1)
    counts.moderate |> should.equal(1)
    counts.minor |> should.equal(1)
    counts.unknown |> should.equal(0)
  })
}

pub fn geometry_conversion_polygon_to_multipolygon_and_detail_full_precision_integration_test() {
  test_db.with_test_db(fn(conn) {
    seed_sources(conn)
    let now = timestamp.system_time()
    let active_until = timestamp.add(now, duration.hours(24))
    let now_str = timestamp.to_rfc3339(now, calendar.utc_offset)
    let expires_str = timestamp.to_rfc3339(active_until, calendar.utc_offset)

    // NOAA write with Polygon GeoJSON
    let noaa_geom =
      noaa.Geometry(type_: "Polygon", polygons: [
        [
          [
            #(10.123456, 20.123456),
            #(10.123456, 21.123456),
            #(11.123456, 21.123456),
            #(11.123456, 20.123456),
            #(10.123456, 20.123456),
          ],
        ],
      ])

    let noaa_feature =
      noaa.FeatureElement(
        id: "noaa-poly",
        type_: "Feature",
        geometry: Some(noaa_geom),
        properties: noaa.Properties(
          id: Some("noaa-poly-id"),
          type_: Some("Alert"),
          properties_id: None,
          area_desc: "NOAA Polygon Area",
          geocode: noaa.Geocode(same: [], ugc: []),
          affected_zones: [],
          references: [],
          sent: Some(now_str),
          effective: now_str,
          onset: None,
          expires: expires_str,
          ends: None,
          status: noaa.Actual,
          message_type: None,
          category: noaa.Met,
          severity: noaa.Severe,
          certainty: noaa.Observed,
          urgency: noaa.Immediate,
          event: "High Wind",
          sender: noaa.Sender("nws@noaa.gov"),
          sender_name: Some("National Weather Service"),
          headline: Some("High Wind Warning"),
          description: None,
          instruction: None,
          response: noaa.None,
          parameters: dict.new(),
          replaced_by: None,
          replaced_at: None,
        ),
      )
    let noaa_incoming =
      record.Incoming(
        key: record.Key("noaa", "noaa-poly"),
        revision: noaa.sent_revision_ms(noaa_feature.properties),
        payload: noaa_feature,
      )

    let assert Ok(_) =
      alert_writer.write_batch([noaa_incoming], True, ["noaa-poly"], now, conn)

    // CAP write with MultiPolygon GeoJSON text
    let cap_write =
      alert.AlertWrite(
        source: "cap-test",
        source_id: "cap-multi-poly",
        sender: Some("sender@met.de"),
        sender_name: Some("DWD"),
        identifier: Some("dwd-ident-1"),
        message_type: Some("Alert"),
        event: "Heavy Rain",
        category: ["Met"],
        severity: "Severe",
        urgency: "Immediate",
        certainty: "Observed",
        headline: Some("Heavy Rain Warning"),
        description: Some("Flooding expected"),
        instruction: Some("Move to higher ground"),
        web: Some("https://dwd.de"),
        contact: None,
        language: Some("en-US"),
        area_desc: "Bavaria",
        geocodes: "[]",
        countries: ["DEU"],
        geom: Some(
          "{\"type\":\"MultiPolygon\",\"coordinates\":[[[[12.123456,30.123456],[12.123456,31.123456],[13.123456,31.123456],[13.123456,30.123456],[12.123456,30.123456]]],[[[14.123456,30.123456],[14.123456,31.123456],[15.123456,31.123456],[15.123456,30.123456],[14.123456,30.123456]]]]}",
        ),
        reference_keys: [],
        sent: Some(now),
        effective: Some(now),
        onset: None,
        expires: Some(active_until),
        ends: None,
        active_until: active_until,
        ended_at: None,
        end_reason: None,
        superseded_by: None,
      )

    let assert Ok(_) = alert_writer.write_cap_rows([cap_write], [], now, conn)

    // NOAA stored in sea.alert was converted from Polygon to ST_MultiPolygon
    test_db.scalar_text(
      conn,
      "SELECT ST_GeometryType(geom) FROM sea.alert WHERE source='noaa' AND source_id='noaa-poly'",
    )
    |> should.equal("ST_MultiPolygon")

    // List query: list shape JSON geometry
    let assert Ok(active_alerts) = alert_reader.list_active([], [], [], conn)
    let assert Ok(noaa_row) =
      list.find(active_alerts, fn(r) {
        r.source == "noaa" && r.source_id == "noaa-poly"
      })
    let assert Ok(cap_row) =
      list.find(active_alerts, fn(r) {
        r.source == "cap-test" && r.source_id == "cap-multi-poly"
      })

    let cap_json = json.to_string(alert.to_json(cap_row))
    string.contains(cap_json, "\"type\":\"MultiPolygon\"")
    |> should.equal(True)

    let assert Some(noaa_list_geom) = noaa_row.geom
    string.contains(noaa_list_geom, "10.1235") |> should.equal(True)

    // Detail query: alert_reader.detail returns full precision (6 decimals) and MultiPolygon
    let assert Ok(Some(#(noaa_detail, _, _, _))) =
      alert_reader.detail("noaa", "noaa-poly", conn)
    let assert Ok(Some(#(cap_detail, _, _, _))) =
      alert_reader.detail("cap-test", "cap-multi-poly", conn)

    let assert Some(noaa_detail_geom) = noaa_detail.geom
    let assert Some(cap_detail_geom) = cap_detail.geom
    string.contains(noaa_detail_geom, "\"type\":\"MultiPolygon\"")
    |> should.equal(True)
    string.contains(cap_detail_geom, "\"type\":\"MultiPolygon\"")
    |> should.equal(True)
    string.contains(noaa_detail_geom, "10.123456") |> should.equal(True)
    string.contains(cap_detail_geom, "12.123456") |> should.equal(True)
  })
}

fn seed_sources(conn) {
  test_db.exec(
    conn,
    "INSERT INTO sea.source (id, name, license, attribution_text, redistributable, priority) VALUES ('cap-test', 'Test CAP', 'CC-BY', 'Test Attribution', true, 50) ON CONFLICT DO NOTHING;",
  )
}

fn seed_alert(
  conn,
  source: String,
  source_id: String,
  event: String,
  severity: String,
  area_desc: String,
  countries_array: String,
  active_until: timestamp.Timestamp,
  ended_at: option.Option(timestamp.Timestamp),
) {
  let active_until_str =
    "'"
    <> timestamp.to_rfc3339(active_until, calendar.utc_offset)
    <> "'::timestamptz"
  let ended_at_str = case ended_at {
    Some(ts) ->
      "'" <> timestamp.to_rfc3339(ts, calendar.utc_offset) <> "'::timestamptz"
    None -> "NULL"
  }

  test_db.exec(
    conn,
    "INSERT INTO sea.alert (source, source_id, event, severity, urgency, certainty, area_desc, countries, active_until, first_seen_at, last_seen_at, ended_at) VALUES ('"
      <> source
      <> "', '"
      <> source_id
      <> "', '"
      <> event
      <> "', '"
      <> severity
      <> "', 'Immediate', 'Observed', '"
      <> area_desc
      <> "', ARRAY"
      <> countries_array
      <> ", "
      <> active_until_str
      <> ", now(), now(), "
      <> ended_at_str
      <> ");",
  )
}
