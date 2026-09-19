import controller/cap_controller
import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/time/calendar
import gleam/time/duration
import gleam/time/timestamp
import gleeunit/should
import message/reciever/models/cap as models_cap
import pog
import repository/alert_reader
import repository/cap_feed_reader
import support/test_db

fn rfc3339_at(now: timestamp.Timestamp, offset_seconds: Int) -> String {
  timestamp.add(now, duration.seconds(offset_seconds))
  |> timestamp.to_rfc3339(calendar.utc_offset)
}

fn sample_registry_item(
  guid: String,
  title: String,
  country_iso3: String,
  feeds: List(models_cap.RegistryFeed),
) -> models_cap.RegistryItem {
  models_cap.RegistryItem(
    guid: guid,
    title: Some(title),
    country_iso3: Some(country_iso3),
    link: Some("https://alertingauthority.wmo.int/authorities.php"),
    description: Some(
      "Authority description for hazard threats of these CAP categories: Met Other.",
    ),
    pub_date: Some("Thu, 17 Sep 2026 05:57:50 +0000"),
    abbrev: Some("test"),
    feeds: feeds,
  )
}

fn sample_cap_json(
  identifier: String,
  sender: String,
  sent: String,
  msg_type: String,
  status: String,
  references: Option(String),
) -> String {
  let expires = case timestamp.parse_rfc3339(sent) {
    Ok(t) ->
      timestamp.add(t, duration.hours(48))
      |> timestamp.to_rfc3339(calendar.utc_offset)
    Error(_) -> "2099-01-01T00:00:00Z"
  }
  sample_cap_json_with_expires(
    identifier,
    sender,
    sent,
    msg_type,
    status,
    references,
    expires,
  )
}

fn sample_cap_json_with_expires(
  identifier: String,
  sender: String,
  sent: String,
  msg_type: String,
  status: String,
  references: Option(String),
  expires: String,
) -> String {
  let ref_field = case references {
    Some(r) -> ",\"references\":\"" <> r <> "\""
    None -> ""
  }
  "{\"cap_version\":\"1.2\",\"identifier\":\""
  <> identifier
  <> "\",\"sender\":\""
  <> sender
  <> "\",\"sent\":\""
  <> sent
  <> "\",\"status\":\""
  <> status
  <> "\",\"msgType\":\""
  <> msg_type
  <> "\",\"scope\":\"Public\""
  <> ref_field
  <> ",\"info\":[{\"language\":\"en\",\"category\":[\"Met\"],\"event\":\"Severe Gale Warning\",\"urgency\":\"Immediate\",\"severity\":\"Severe\",\"certainty\":\"Observed\",\"effective\":\""
  <> sent
  <> "\",\"expires\":\""
  <> expires
  <> "\",\"headline\":\"High Wind Warning\",\"description\":\"Gusts up to 120 km/h\",\"area\":[{\"areaDesc\":\"Coastal Zone\",\"polygon\":[\"48.0,11.0 48.0,12.0 49.0,12.0 49.0,11.0 48.0,11.0\"],\"circle\":[],\"geocode\":[{\"valueName\":\"WARNCELLID\",\"value\":\"108000\"}]}]}]}"
}

fn make_fetch_result(
  cap_url: String,
  feed_url: String,
  http_status: Int,
  cap_json_str: Option(String),
) -> models_cap.CapFetchResult {
  let fetched_at =
    timestamp.system_time() |> timestamp.to_rfc3339(calendar.utc_offset)
  make_fetch_result_at(cap_url, feed_url, http_status, cap_json_str, fetched_at)
}

fn make_fetch_result_at(
  cap_url: String,
  feed_url: String,
  http_status: Int,
  cap_json_str: Option(String),
  fetched_at: String,
) -> models_cap.CapFetchResult {
  let #(cap_msg, raw_json) = case cap_json_str {
    Some(json_str) -> {
      let assert Ok(msg) = models_cap.decode_cap_json(json_str)
      #(Some(msg), Some(json_str))
    }
    None -> #(None, None)
  }
  models_cap.CapFetchResult(
    cap_url: cap_url,
    feed_url: feed_url,
    fetched_at: fetched_at,
    http_status: http_status,
    error: case http_status {
      200 -> None
      status -> Some(string_status(status))
    },
    cap: cap_msg,
    raw_cap_json: raw_json,
    raw_xml: Some("<alert>raw</alert>"),
  )
}

fn string_status(status: Int) -> String {
  case status {
    404 -> "404 Not Found"
    500 -> "500 Internal Server Error"
    _ -> "error"
  }
}

pub fn registry_to_feeds_nws_and_language_and_removal_integration_test() {
  test_db.with_test_db(fn(conn) {
    let ctx = test_db.integration_context(conn)

    // Authority 1: DWD with EN and DE feeds (language rule -> DE excluded)
    let dwd =
      sample_registry_item(
        "urn:oid:2.49.0.0.276.0",
        "Germany: Deutscher Wetterdienst",
        "DEU",
        [
          models_cap.RegistryFeed("https://dwd.de/en.rss", Some("en")),
          models_cap.RegistryFeed("https://dwd.de/de.rss", Some("de")),
        ],
      )

    // Authority 2: NWS feed (nws rule -> excluded)
    let nws =
      sample_registry_item(
        "urn:oid:2.49.0.0.840.0",
        "United States: NWS",
        "USA",
        [
          models_cap.RegistryFeed(
            "https://alerts.weather.gov/cap.atom",
            Some("en"),
          ),
        ],
      )

    // Authority 3: Ghana with single feed
    let gha =
      sample_registry_item(
        "urn:oid:2.49.0.0.288.0",
        "Ghana: Ghana Meteorological Agency",
        "GHA",
        [models_cap.RegistryFeed("https://meteo.gov.gh/rss.xml", Some("en"))],
      )

    let assert Ok(ack1) =
      cap_controller.process_registry([dwd, nws, gha], 3, 0, ctx)
    ack1.written |> should.equal(3)
    ack1.deduped |> should.equal(0)
    ack1.dropped |> should.equal(0)

    test_db.count(conn, "sea.cap_authority") |> should.equal(3)
    test_db.count(conn, "sea.cap_feed") |> should.equal(4)

    // Check subscribed feeds
    let assert Ok(sub_feeds) = cap_controller.get_feeds(ctx)
    list.length(sub_feeds) |> should.equal(2)
    let sub_urls = list.map(sub_feeds, fn(f) { f.url })
    should.be_true(list.contains(sub_urls, "https://dwd.de/en.rss"))
    should.be_true(list.contains(sub_urls, "https://meteo.gov.gh/rss.xml"))
    should.be_false(list.contains(sub_urls, "https://dwd.de/de.rss"))
    should.be_false(list.contains(
      sub_urls,
      "https://alerts.weather.gov/cap.atom",
    ))

    // Check exclusion reasons in DB
    let de_reason =
      test_db.scalar_text(
        conn,
        "SELECT exclusion_reason FROM sea.cap_feed WHERE url = 'https://dwd.de/de.rss'",
      )
    de_reason |> should.equal("language")

    let nws_reason =
      test_db.scalar_text(
        conn,
        "SELECT exclusion_reason FROM sea.cap_feed WHERE url = 'https://alerts.weather.gov/cap.atom'",
      )
    nws_reason |> should.equal("nws")

    // Second registry run: GHA authority disappears
    let assert Ok(ack2) = cap_controller.process_registry([dwd, nws], 2, 0, ctx)
    ack2.written |> should.equal(0)
    ack2.deduped |> should.equal(2)
    ack2.dropped |> should.equal(0)

    // GHA authority marked removed
    let gha_removed =
      test_db.scalar_text(
        conn,
        "SELECT CASE WHEN removed_at IS NOT NULL THEN 'removed' ELSE 'active' END FROM sea.cap_authority WHERE oid = '2.49.0.0.288.0'",
      )
    gha_removed |> should.equal("removed")

    // GHA feed marked unsubscribed and removed
    let gha_feed_sub =
      test_db.scalar_int(
        conn,
        "SELECT CASE WHEN subscribed THEN 1 ELSE 0 END FROM sea.cap_feed WHERE url = 'https://meteo.gov.gh/rss.xml'",
      )
    gha_feed_sub |> should.equal(0)

    let gha_feed_reason =
      test_db.scalar_text(
        conn,
        "SELECT exclusion_reason FROM sea.cap_feed WHERE url = 'https://meteo.gov.gh/rss.xml'",
      )
    gha_feed_reason |> should.equal("removed")

    // Now get_feeds only returns DWD EN
    let assert Ok(sub_feeds2) = cap_controller.get_feeds(ctx)
    list.length(sub_feeds2) |> should.equal(1)
  })
}

pub fn index_processing_states_and_health_integration_test() {
  test_db.with_test_db(fn(conn) {
    let ctx = test_db.integration_context(conn)

    // Set up DWD authority and feed
    let dwd =
      sample_registry_item(
        "urn:oid:2.49.0.0.276.0",
        "Germany: Deutscher Wetterdienst",
        "DEU",
        [models_cap.RegistryFeed("https://dwd.de/en.rss", Some("en"))],
      )
    let assert Ok(_) = cap_controller.process_registry([dwd], 1, 0, ctx)

    // 1. Unknown feed POST drops all
    let assert Ok(ack_unknown) =
      cap_controller.process_index(
        Some("https://unknown.org/feed.xml"),
        None,
        [
          models_cap.IndexItem(
            Some("guid-1"),
            Some("Title"),
            "https://unknown.org/cap/1.xml",
            None,
          ),
        ],
        1,
        0,
        ctx,
      )
    ack_unknown.dropped |> should.equal(1)
    ack_unknown.written |> should.equal(0)
    test_db.count(conn, "sea.cap_item") |> should.equal(0)

    let now = timestamp.system_time()

    // 2. Known feed POST with new recent item and old item (>7 days)
    let item_new =
      models_cap.IndexItem(
        Some("guid-new"),
        Some("New Alert"),
        "https://dwd.de/cap/new.xml",
        Some(rfc3339_at(now, -3600)),
      )
    let item_old =
      models_cap.IndexItem(
        Some("guid-old"),
        Some("Old Alert"),
        "https://dwd.de/cap/old.xml",
        Some(rfc3339_at(now, -86_400 * 8)),
      )

    let meta200 =
      models_cap.CapPollMeta(
        fetched_at: rfc3339_at(now, 0),
        http_status: 200,
        feature_count: 2,
        bytes: 1024,
        backfill: False,
        feed_url: Some("https://dwd.de/en.rss"),
        error: None,
        format: Some("rss"),
      )

    let assert Ok(ack_index) =
      cap_controller.process_index(
        Some("https://dwd.de/en.rss"),
        Some(meta200),
        [item_new, item_old],
        2,
        0,
        ctx,
      )
    ack_index.written |> should.equal(2)
    ack_index.dropped |> should.equal(0)

    // Check states: new is pending, old is skipped
    let new_state =
      test_db.scalar_text(
        conn,
        "SELECT state FROM sea.cap_item WHERE cap_url = 'https://dwd.de/cap/new.xml'",
      )
    new_state |> should.equal("pending")

    let old_state =
      test_db.scalar_text(
        conn,
        "SELECT state FROM sea.cap_item WHERE cap_url = 'https://dwd.de/cap/old.xml'",
      )
    old_state |> should.equal("skipped")

    // Feed health columns updated
    let item_count =
      test_db.scalar_int(
        conn,
        "SELECT item_count FROM sea.cap_feed WHERE url = 'https://dwd.de/en.rss'",
      )
    item_count |> should.equal(2)

    // 3. Conditional GET 304 keeps counts
    let meta304 =
      models_cap.CapPollMeta(
        fetched_at: rfc3339_at(now, 300),
        http_status: 304,
        feature_count: 0,
        bytes: 0,
        backfill: False,
        feed_url: Some("https://dwd.de/en.rss"),
        error: None,
        format: None,
      )
    let assert Ok(ack_304) =
      cap_controller.process_index(
        Some("https://dwd.de/en.rss"),
        Some(meta304),
        [],
        0,
        0,
        ctx,
      )
    ack_304.written |> should.equal(0)

    let item_count_after_304 =
      test_db.scalar_int(
        conn,
        "SELECT item_count FROM sea.cap_feed WHERE url = 'https://dwd.de/en.rss'",
      )
    item_count_after_304 |> should.equal(2)

    // 4. Failure increments consecutive_failures
    let meta500 =
      models_cap.CapPollMeta(
        fetched_at: rfc3339_at(now, 600),
        http_status: 500,
        feature_count: 0,
        bytes: 0,
        backfill: False,
        feed_url: Some("https://dwd.de/en.rss"),
        error: Some("Server error"),
        format: None,
      )
    let assert Ok(_) =
      cap_controller.process_index(
        Some("https://dwd.de/en.rss"),
        Some(meta500),
        [],
        0,
        0,
        ctx,
      )

    let failures =
      test_db.scalar_int(
        conn,
        "SELECT consecutive_failures FROM sea.cap_feed WHERE url = 'https://dwd.de/en.rss'",
      )
    failures |> should.equal(1)
  })
}

pub fn pending_ordering_and_retry_cutoff_integration_test() {
  test_db.with_test_db(fn(conn) {
    let ctx = test_db.integration_context(conn)

    // Setup feed
    let dwd =
      sample_registry_item("urn:oid:2.49.0.0.276.0", "Germany: DWD", "DEU", [
        models_cap.RegistryFeed("https://dwd.de/feed.xml", Some("en")),
      ])
    let assert Ok(_) = cap_controller.process_registry([dwd], 1, 0, ctx)

    let now = timestamp.system_time()
    let old_attempt = timestamp.add(now, duration.seconds(-1200))
    // 20 min ago
    let recent_attempt = timestamp.add(now, duration.seconds(-300))
    // 5 min ago

    // Insert pending row
    test_db.exec(
      conn,
      "INSERT INTO sea.cap_item (cap_url, feed_url, state, attempts, first_seen_at, last_seen_at)
       VALUES ('https://dwd.de/cap/pending1.xml', 'https://dwd.de/feed.xml', 'pending', 0, now() - interval '1 hour', now())",
    )

    // Insert failed row eligible for retry (attempts=1, attempt 20 min ago)
    let assert Ok(_) =
      pog.query(
        "INSERT INTO sea.cap_item (cap_url, feed_url, state, attempts, last_attempt_at, first_seen_at, last_seen_at)
         VALUES ('https://dwd.de/cap/retry-eligible.xml', 'https://dwd.de/feed.xml', 'failed', 1, $1, now() - interval '2 hour', now())",
      )
      |> pog.parameter(pog.timestamp(old_attempt))
      |> pog.returning(decode.success(Nil))
      |> pog.execute(conn)

    // Insert failed row NOT eligible (attempts=1, attempt only 5 min ago)
    let assert Ok(_) =
      pog.query(
        "INSERT INTO sea.cap_item (cap_url, feed_url, state, attempts, last_attempt_at, first_seen_at, last_seen_at)
         VALUES ('https://dwd.de/cap/retry-ineligible-time.xml', 'https://dwd.de/feed.xml', 'failed', 1, $1, now() - interval '3 hour', now())",
      )
      |> pog.parameter(pog.timestamp(recent_attempt))
      |> pog.returning(decode.success(Nil))
      |> pog.execute(conn)

    // Insert failed row NOT eligible (attempts=3 exhausted)
    let assert Ok(_) =
      pog.query(
        "INSERT INTO sea.cap_item (cap_url, feed_url, state, attempts, last_attempt_at, first_seen_at, last_seen_at)
         VALUES ('https://dwd.de/cap/retry-exhausted.xml', 'https://dwd.de/feed.xml', 'failed', 3, $1, now() - interval '4 hour', now())",
      )
      |> pog.parameter(pog.timestamp(old_attempt))
      |> pog.returning(decode.success(Nil))
      |> pog.execute(conn)

    let assert Ok(pending_items) = cap_controller.get_pending(50, ctx)
    list.length(pending_items) |> should.equal(2)

    let urls = list.map(pending_items, fn(p) { p.cap_url })
    should.be_true(list.contains(urls, "https://dwd.de/cap/pending1.xml"))
    should.be_true(list.contains(urls, "https://dwd.de/cap/retry-eligible.xml"))
    should.be_false(list.contains(
      urls,
      "https://dwd.de/cap/retry-ineligible-time.xml",
    ))
    should.be_false(list.contains(
      urls,
      "https://dwd.de/cap/retry-exhausted.xml",
    ))

    // Check order: first_seen_at DESC (pending1 is 1h ago, retry-eligible is 2h ago)
    let assert [first, second] = pending_items
    first.cap_url |> should.equal("https://dwd.de/cap/pending1.xml")
    second.cap_url |> should.equal("https://dwd.de/cap/retry-eligible.xml")
  })
}

pub fn alerts_lifecycle_supersede_cancel_and_dedup_integration_test() {
  test_db.with_test_db(fn(conn) {
    let ctx = test_db.integration_context(conn)
    let now = timestamp.system_time()
    let t1 = rfc3339_at(now, -3600)
    let t2 = rfc3339_at(now, -1800)
    let t3 = rfc3339_at(now, -600)
    let t4 = rfc3339_at(now, 0)

    // Setup registry
    let dwd =
      sample_registry_item("urn:oid:2.49.0.0.276.0", "Germany: DWD", "DEU", [
        models_cap.RegistryFeed("https://dwd.de/feed1.xml", Some("en")),
        models_cap.RegistryFeed("https://dwd.de/feed2.xml", Some("en")),
      ])
    let assert Ok(_) = cap_controller.process_registry([dwd], 1, 0, ctx)

    // Add cap_items
    let item1 =
      models_cap.IndexItem(None, None, "https://dwd.de/alert1.xml", Some(t1))
    let assert Ok(_) =
      cap_controller.process_index(
        Some("https://dwd.de/feed1.xml"),
        None,
        [item1],
        1,
        0,
        ctx,
      )

    // 1. Post initial normal Alert
    let cap1 =
      sample_cap_json("alert-001", "dwd@dwd.de", t1, "Alert", "Actual", None)
    let fetch1 =
      make_fetch_result(
        "https://dwd.de/alert1.xml",
        "https://dwd.de/feed1.xml",
        200,
        Some(cap1),
      )

    let assert Ok(ack1) =
      cap_controller.process_alerts([fetch1], None, 1, 0, ctx)
    ack1.written |> should.equal(1)
    ack1.deduped |> should.equal(0)
    ack1.dropped |> should.equal(0)

    // Alert appears in alert_reader.list_active
    let assert Ok(active1) = alert_reader.list_active([], [], [], conn)
    list.length(active1) |> should.equal(1)
    let assert [alert_row1] = active1
    alert_row1.source_id |> should.equal("dwd@dwd.de,alert-001")
    alert_row1.source |> should.equal("cap-2.49.0.0.276.0")
    alert_row1.severity |> should.equal("Severe")

    // Check cap_item state is fetched with message_key
    let item_state =
      test_db.scalar_text(
        conn,
        "SELECT state FROM sea.cap_item WHERE cap_url = 'https://dwd.de/alert1.xml'",
      )
    item_state |> should.equal("fetched")

    let item_msg_key =
      test_db.scalar_text(
        conn,
        "SELECT message_key FROM sea.cap_item WHERE cap_url = 'https://dwd.de/alert1.xml'",
      )
    item_msg_key |> should.equal("dwd@dwd.de,alert-001")

    // 2. Same alert delivered via second feed is deduped
    let fetch_dedup =
      make_fetch_result(
        "https://dwd.de/alert1_copy.xml",
        "https://dwd.de/feed2.xml",
        200,
        Some(cap1),
      )
    let assert Ok(ack_dedup) =
      cap_controller.process_alerts([fetch_dedup], None, 1, 0, ctx)
    ack_dedup.written |> should.equal(0)
    ack_dedup.deduped |> should.equal(1)

    // 3. Newer sent timestamp updates the alert
    let cap1_newer =
      sample_cap_json("alert-001", "dwd@dwd.de", t2, "Alert", "Actual", None)
    let fetch_newer =
      make_fetch_result(
        "https://dwd.de/alert1.xml",
        "https://dwd.de/feed1.xml",
        200,
        Some(cap1_newer),
      )
    let assert Ok(ack_newer) =
      cap_controller.process_alerts([fetch_newer], None, 1, 0, ctx)
    ack_newer.written |> should.equal(1)
    ack_newer.deduped |> should.equal(0)

    // 4. Update supersedes old alert
    let cap_update =
      sample_cap_json(
        "update-001",
        "dwd@dwd.de",
        t3,
        "Update",
        "Actual",
        Some("dwd@dwd.de,alert-001," <> t2),
      )
    let fetch_update =
      make_fetch_result(
        "https://dwd.de/update1.xml",
        "https://dwd.de/feed1.xml",
        200,
        Some(cap_update),
      )
    let assert Ok(ack_up) =
      cap_controller.process_alerts([fetch_update], None, 1, 0, ctx)
    ack_up.written |> should.equal(1)

    // Old row is ended with superseded
    let old_end_reason =
      test_db.scalar_text(
        conn,
        "SELECT end_reason FROM sea.alert WHERE source_id = 'dwd@dwd.de,alert-001'",
      )
    old_end_reason |> should.equal("superseded")

    let old_superseded_by =
      test_db.scalar_text(
        conn,
        "SELECT superseded_by FROM sea.alert WHERE source_id = 'dwd@dwd.de,alert-001'",
      )
    old_superseded_by
    |> should.equal("cap-2.49.0.0.276.0:dwd@dwd.de,update-001")

    // Only update alert is now active
    let assert Ok(active2) = alert_reader.list_active([], [], [], conn)
    list.length(active2) |> should.equal(1)
    let assert [alert_row2] = active2
    alert_row2.source_id |> should.equal("dwd@dwd.de,update-001")

    // 5. Cancel cancels the update
    let cap_cancel =
      sample_cap_json(
        "cancel-001",
        "dwd@dwd.de",
        t4,
        "Cancel",
        "Actual",
        Some("dwd@dwd.de,update-001," <> t3),
      )
    let fetch_cancel =
      make_fetch_result(
        "https://dwd.de/cancel1.xml",
        "https://dwd.de/feed1.xml",
        200,
        Some(cap_cancel),
      )
    let assert Ok(ack_canc) =
      cap_controller.process_alerts([fetch_cancel], None, 1, 0, ctx)
    ack_canc.written |> should.equal(1)

    // Update row is ended with cancelled
    let update_end_reason =
      test_db.scalar_text(
        conn,
        "SELECT end_reason FROM sea.alert WHERE source_id = 'dwd@dwd.de,update-001'",
      )
    update_end_reason |> should.equal("cancelled")

    // Cancel raw message is stored in sea.cap_message
    test_db.scalar_int(
      conn,
      "SELECT count(*) FROM sea.cap_message WHERE identifier = 'cancel-001'",
    )
    |> should.equal(1)

    // Cancel message is not in sea.alert
    test_db.scalar_int(
      conn,
      "SELECT count(*) FROM sea.alert WHERE source_id = 'dwd@dwd.de,cancel-001'",
    )
    |> should.equal(0)

    // Active list is now empty
    let assert Ok(active3) = alert_reader.list_active([], [], [], conn)
    list.length(active3) |> should.equal(0)
  })
}

pub fn alerts_out_of_order_update_before_alert_integration_test() {
  test_db.with_test_db(fn(conn) {
    let ctx = test_db.integration_context(conn)
    let now = timestamp.system_time()
    let t_late = rfc3339_at(now, -3600)
    let t_early = rfc3339_at(now, -1800)

    let dwd =
      sample_registry_item("urn:oid:2.49.0.0.276.0", "Germany: DWD", "DEU", [
        models_cap.RegistryFeed("https://dwd.de/feed.xml", Some("en")),
      ])
    let assert Ok(_) = cap_controller.process_registry([dwd], 1, 0, ctx)

    // 1. Send Update FIRST, referencing alert-late
    let cap_update =
      sample_cap_json(
        "update-early",
        "dwd@dwd.de",
        t_early,
        "Update",
        "Actual",
        Some("dwd@dwd.de,alert-late," <> t_late),
      )
    let fetch_update =
      make_fetch_result(
        "https://dwd.de/up.xml",
        "https://dwd.de/feed.xml",
        200,
        Some(cap_update),
      )
    let assert Ok(_) =
      cap_controller.process_alerts([fetch_update], None, 1, 0, ctx)

    // 2. Later send the Alert that was superseded
    let cap_alert =
      sample_cap_json(
        "alert-late",
        "dwd@dwd.de",
        t_late,
        "Alert",
        "Actual",
        None,
      )
    let fetch_alert =
      make_fetch_result(
        "https://dwd.de/al.xml",
        "https://dwd.de/feed.xml",
        200,
        Some(cap_alert),
      )
    let assert Ok(_) =
      cap_controller.process_alerts([fetch_alert], None, 1, 0, ctx)

    // The late alert must be inserted already ended as superseded!
    let late_end_reason =
      test_db.scalar_text(
        conn,
        "SELECT end_reason FROM sea.alert WHERE source_id = 'dwd@dwd.de,alert-late'",
      )
    late_end_reason |> should.equal("superseded")

    let late_superseded_by =
      test_db.scalar_text(
        conn,
        "SELECT superseded_by FROM sea.alert WHERE source_id = 'dwd@dwd.de,alert-late'",
      )
    late_superseded_by
    |> should.equal("cap-2.49.0.0.276.0:dwd@dwd.de,update-early")
  })
}

pub fn alerts_exercise_not_normalized_integration_test() {
  test_db.with_test_db(fn(conn) {
    let ctx = test_db.integration_context(conn)
    let now = timestamp.system_time()

    let dwd =
      sample_registry_item("urn:oid:2.49.0.0.276.0", "Germany: DWD", "DEU", [
        models_cap.RegistryFeed("https://dwd.de/feed.xml", Some("en")),
      ])
    let assert Ok(_) = cap_controller.process_registry([dwd], 1, 0, ctx)

    let cap_ex =
      sample_cap_json(
        "ex-001",
        "dwd@dwd.de",
        rfc3339_at(now, -600),
        "Alert",
        "Exercise",
        None,
      )
    let fetch_ex =
      make_fetch_result(
        "https://dwd.de/ex.xml",
        "https://dwd.de/feed.xml",
        200,
        Some(cap_ex),
      )

    let assert Ok(ack) =
      cap_controller.process_alerts([fetch_ex], None, 1, 0, ctx)
    ack.written |> should.equal(1)
    ack.dropped |> should.equal(0)

    // Stored in cap_message with normalized = false
    let norm =
      test_db.scalar_int(
        conn,
        "SELECT CASE WHEN normalized THEN 1 ELSE 0 END FROM sea.cap_message WHERE identifier = 'ex-001'",
      )
    norm |> should.equal(0)

    // Not in sea.alert
    test_db.count(conn, "sea.alert") |> should.equal(0)
  })
}

pub fn alerts_fetch_outcomes_404_and_500_integration_test() {
  test_db.with_test_db(fn(conn) {
    let ctx = test_db.integration_context(conn)
    let now = timestamp.system_time()

    let dwd =
      sample_registry_item("urn:oid:2.49.0.0.276.0", "Germany: DWD", "DEU", [
        models_cap.RegistryFeed("https://dwd.de/feed.xml", Some("en")),
      ])
    let assert Ok(_) = cap_controller.process_registry([dwd], 1, 0, ctx)

    // Pre-insert pending items
    let item404 =
      models_cap.IndexItem(
        None,
        None,
        "https://dwd.de/404.xml",
        Some(rfc3339_at(now, -3600)),
      )
    let item500 =
      models_cap.IndexItem(
        None,
        None,
        "https://dwd.de/500.xml",
        Some(rfc3339_at(now, -3600)),
      )
    let assert Ok(_) =
      cap_controller.process_index(
        Some("https://dwd.de/feed.xml"),
        None,
        [item404, item500],
        2,
        0,
        ctx,
      )

    let fetch404 =
      make_fetch_result(
        "https://dwd.de/404.xml",
        "https://dwd.de/feed.xml",
        404,
        None,
      )
    let fetch500 =
      make_fetch_result(
        "https://dwd.de/500.xml",
        "https://dwd.de/feed.xml",
        500,
        None,
      )

    let assert Ok(ack) =
      cap_controller.process_alerts([fetch404, fetch500], None, 2, 0, ctx)
    ack.dropped |> should.equal(2)
    ack.written |> should.equal(0)

    // 404 fails permanently: attempts = 3
    let attempts404 =
      test_db.scalar_int(
        conn,
        "SELECT attempts FROM sea.cap_item WHERE cap_url = 'https://dwd.de/404.xml'",
      )
    attempts404 |> should.equal(3)

    let state404 =
      test_db.scalar_text(
        conn,
        "SELECT state FROM sea.cap_item WHERE cap_url = 'https://dwd.de/404.xml'",
      )
    state404 |> should.equal("failed")

    // 500 retries: attempts = 1
    let attempts500 =
      test_db.scalar_int(
        conn,
        "SELECT attempts FROM sea.cap_item WHERE cap_url = 'https://dwd.de/500.xml'",
      )
    attempts500 |> should.equal(1)

    let state500 =
      test_db.scalar_text(
        conn,
        "SELECT state FROM sea.cap_item WHERE cap_url = 'https://dwd.de/500.xml'",
      )
    state500 |> should.equal("failed")
  })
}

pub fn cap_feeds_view_health_classification_integration_test() {
  test_db.with_test_db(fn(conn) {
    let ctx = test_db.integration_context(conn)

    let dwd =
      sample_registry_item("urn:oid:2.49.0.0.276.0", "Germany: DWD", "DEU", [
        models_cap.RegistryFeed("https://dwd.de/feed_ok.xml", Some("en")),
        models_cap.RegistryFeed("https://dwd.de/feed_ex.xml", Some("de")),
      ])
    let assert Ok(_) = cap_controller.process_registry([dwd], 1, 0, ctx)

    let now = timestamp.system_time()
    let assert Ok(view1) = cap_feed_reader.view(now, conn)

    // feed_ex is excluded; feed_ok is pending (never polled)
    view1.counts.excluded |> should.equal(1)
    view1.counts.pending |> should.equal(1)

    // Poll feed_ok with 200 and items
    let meta_ok =
      models_cap.CapPollMeta(
        fetched_at: rfc3339_at(now, 0),
        http_status: 200,
        feature_count: 1,
        bytes: 500,
        backfill: False,
        feed_url: Some("https://dwd.de/feed_ok.xml"),
        error: None,
        format: Some("rss"),
      )
    let item =
      models_cap.IndexItem(
        None,
        None,
        "https://dwd.de/alert.xml",
        Some(rfc3339_at(now, -1800)),
      )
    let item_fail =
      models_cap.IndexItem(
        None,
        None,
        "https://dwd.de/alert_fail.xml",
        Some(rfc3339_at(now, -1800)),
      )
    let assert Ok(_) =
      cap_controller.process_index(
        Some("https://dwd.de/feed_ok.xml"),
        Some(meta_ok),
        [item, item_fail],
        2,
        0,
        ctx,
      )

    let cap_valid =
      sample_cap_json(
        "feed-ok-001",
        "dwd@dwd.de",
        rfc3339_at(now, -600),
        "Alert",
        "Actual",
        None,
      )
    let fetch_valid =
      make_fetch_result(
        "https://dwd.de/alert.xml",
        "https://dwd.de/feed_ok.xml",
        200,
        Some(cap_valid),
      )
    let fetch_failed =
      make_fetch_result(
        "https://dwd.de/alert_fail.xml",
        "https://dwd.de/feed_ok.xml",
        500,
        None,
      )
    let assert Ok(_) =
      cap_controller.process_alerts(
        [fetch_valid, fetch_failed],
        None,
        2,
        0,
        ctx,
      )

    let assert Ok(view2) = cap_feed_reader.view(now, conn)
    view2.counts.ok |> should.equal(1)
    view2.counts.excluded |> should.equal(1)
    view2.counts.pending |> should.equal(0)
    should.be_true(option.is_some(view2.registry_fetched_at))

    let assert Ok(feed_ok) =
      list.find(view2.feeds, fn(f) { f.url == "https://dwd.de/feed_ok.xml" })
    feed_ok.active_alerts |> should.equal(1)
    feed_ok.failed_items |> should.equal(1)
  })
}

pub fn bad_message_rolls_back_and_fails_permanently_while_valid_succeeds_integration_test() {
  test_db.with_test_db(fn(conn) {
    let ctx = test_db.integration_context(conn)
    let now = timestamp.system_time()
    let dwd =
      sample_registry_item("urn:oid:2.49.0.0.276.0", "Germany: DWD", "DEU", [
        models_cap.RegistryFeed("https://dwd.de/feed.xml", Some("en")),
      ])
    let assert Ok(_) = cap_controller.process_registry([dwd], 1, 0, ctx)

    let bad_item =
      models_cap.IndexItem(
        None,
        None,
        "https://dwd.de/bad.xml",
        Some(rfc3339_at(now, -3600)),
      )
    let good_item =
      models_cap.IndexItem(
        None,
        None,
        "https://dwd.de/good.xml",
        Some(rfc3339_at(now, -3600)),
      )
    let assert Ok(_) =
      cap_controller.process_index(
        Some("https://dwd.de/feed.xml"),
        None,
        [bad_item, good_item],
        2,
        0,
        ctx,
      )

    // Message with invalid sent timestamp
    let bad_cap_json =
      "{\"cap_version\":\"1.2\",\"identifier\":\"bad-001\",\"sender\":\"dwd@dwd.de\",\"sent\":\"invalid-time\",\"status\":\"Actual\",\"msgType\":\"Alert\",\"scope\":\"Public\",\"info\":[{\"language\":\"en\",\"category\":[\"Met\"],\"event\":\"Wind\",\"urgency\":\"Immediate\",\"severity\":\"Severe\",\"certainty\":\"Observed\",\"effective\":\"invalid-time\",\"expires\":\"2099-01-01T00:00:00Z\",\"area\":[{\"areaDesc\":\"Zone\",\"polygon\":[\"48.0,11.0 48.0,12.0 49.0,12.0 49.0,11.0 48.0,11.0\"],\"circle\":[],\"geocode\":[]}]}]}"

    let good_cap_json =
      sample_cap_json(
        "good-001",
        "dwd@dwd.de",
        rfc3339_at(now, -1800),
        "Alert",
        "Actual",
        None,
      )

    let fetch_bad =
      make_fetch_result(
        "https://dwd.de/bad.xml",
        "https://dwd.de/feed.xml",
        200,
        Some(bad_cap_json),
      )
    let fetch_good =
      make_fetch_result(
        "https://dwd.de/good.xml",
        "https://dwd.de/feed.xml",
        200,
        Some(good_cap_json),
      )

    let assert Ok(ack) =
      cap_controller.process_alerts([fetch_bad, fetch_good], None, 2, 0, ctx)

    ack.received |> should.equal(2)
    ack.written |> should.equal(1)
    ack.dropped |> should.equal(1)

    // Bad item rolled back: not in sea.cap_message
    test_db.scalar_int(
      conn,
      "SELECT count(*) FROM sea.cap_message WHERE identifier = 'bad-001'",
    )
    |> should.equal(0)

    // Bad item permanently failed: attempts = 3, state = 'failed'
    test_db.scalar_text(
      conn,
      "SELECT state FROM sea.cap_item WHERE cap_url = 'https://dwd.de/bad.xml'",
    )
    |> should.equal("failed")
    test_db.scalar_int(
      conn,
      "SELECT attempts FROM sea.cap_item WHERE cap_url = 'https://dwd.de/bad.xml'",
    )
    |> should.equal(3)

    // Good item succeeded: state = 'fetched', present in cap_message and alert
    test_db.scalar_text(
      conn,
      "SELECT state FROM sea.cap_item WHERE cap_url = 'https://dwd.de/good.xml'",
    )
    |> should.equal("fetched")
    test_db.scalar_int(
      conn,
      "SELECT count(*) FROM sea.cap_message WHERE identifier = 'good-001'",
    )
    |> should.equal(1)
    test_db.scalar_int(
      conn,
      "SELECT count(*) FROM sea.alert WHERE source_id = 'dwd@dwd.de,good-001'",
    )
    |> should.equal(1)

    // NoInfo update: stores raw with normalized = false, written to raw layer without error
    let noinfo_cap_json =
      "{\"cap_version\":\"1.2\",\"identifier\":\"noinfo-001\",\"sender\":\"dwd@dwd.de\",\"sent\":\""
      <> rfc3339_at(now, -600)
      <> "\",\"status\":\"Actual\",\"msgType\":\"Update\",\"scope\":\"Public\",\"info\":[]}"

    let fetch_noinfo =
      make_fetch_result(
        "https://dwd.de/noinfo.xml",
        "https://dwd.de/feed.xml",
        200,
        Some(noinfo_cap_json),
      )

    let assert Ok(ack_noinfo) =
      cap_controller.process_alerts([fetch_noinfo], None, 1, 0, ctx)

    ack_noinfo.written |> should.equal(1)
    ack_noinfo.dropped |> should.equal(0)

    test_db.scalar_int(
      conn,
      "SELECT count(*) FROM sea.cap_message WHERE identifier = 'noinfo-001'",
    )
    |> should.equal(1)
    test_db.scalar_int(
      conn,
      "SELECT CASE WHEN normalized THEN 1 ELSE 0 END FROM sea.cap_message WHERE identifier = 'noinfo-001'",
    )
    |> should.equal(0)
    test_db.scalar_int(
      conn,
      "SELECT count(*) FROM sea.alert WHERE source_id = 'dwd@dwd.de,noinfo-001'",
    )
    |> should.equal(0)
  })
}

pub fn intra_batch_ordering_alert_then_update_and_update_then_alert_integration_test() {
  test_db.with_test_db(fn(conn) {
    let ctx = test_db.integration_context(conn)
    let now = timestamp.system_time()
    let dwd =
      sample_registry_item("urn:oid:2.49.0.0.276.0", "Germany: DWD", "DEU", [
        models_cap.RegistryFeed("https://dwd.de/feed.xml", Some("en")),
      ])
    let assert Ok(_) = cap_controller.process_registry([dwd], 1, 0, ctx)

    // Order 1: [Alert, Update] in SAME batch
    let t1 = rfc3339_at(now, -3600)
    let t2 = rfc3339_at(now, -1800)
    let cap_alert1 =
      sample_cap_json("order1-alert", "dwd@dwd.de", t1, "Alert", "Actual", None)
    let cap_update1 =
      sample_cap_json(
        "order1-update",
        "dwd@dwd.de",
        t2,
        "Update",
        "Actual",
        Some("dwd@dwd.de,order1-alert," <> t1),
      )
    let fetch_a1 =
      make_fetch_result(
        "https://dwd.de/order1_alert.xml",
        "https://dwd.de/feed.xml",
        200,
        Some(cap_alert1),
      )
    let fetch_u1 =
      make_fetch_result(
        "https://dwd.de/order1_update.xml",
        "https://dwd.de/feed.xml",
        200,
        Some(cap_update1),
      )

    let assert Ok(ack1) =
      cap_controller.process_alerts([fetch_a1, fetch_u1], None, 2, 0, ctx)
    ack1.written |> should.equal(2)

    // Alert was superseded by Update
    test_db.scalar_text(
      conn,
      "SELECT end_reason FROM sea.alert WHERE source_id = 'dwd@dwd.de,order1-alert'",
    )
    |> should.equal("superseded")
    test_db.scalar_text(
      conn,
      "SELECT superseded_by FROM sea.alert WHERE source_id = 'dwd@dwd.de,order1-alert'",
    )
    |> should.equal("cap-2.49.0.0.276.0:dwd@dwd.de,order1-update")

    // Update is active
    test_db.scalar_text(
      conn,
      "SELECT (ended_at IS NULL)::text FROM sea.alert WHERE source_id = 'dwd@dwd.de,order1-update'",
    )
    |> should.equal("true")

    // Order 2: [Update, Alert] in SAME batch
    let t3 = rfc3339_at(now, -3000)
    let t4 = rfc3339_at(now, -1000)
    let cap_update2 =
      sample_cap_json(
        "order2-update",
        "dwd@dwd.de",
        t4,
        "Update",
        "Actual",
        Some("dwd@dwd.de,order2-alert," <> t3),
      )
    let cap_alert2 =
      sample_cap_json("order2-alert", "dwd@dwd.de", t3, "Alert", "Actual", None)
    let fetch_u2 =
      make_fetch_result(
        "https://dwd.de/order2_update.xml",
        "https://dwd.de/feed.xml",
        200,
        Some(cap_update2),
      )
    let fetch_a2 =
      make_fetch_result(
        "https://dwd.de/order2_alert.xml",
        "https://dwd.de/feed.xml",
        200,
        Some(cap_alert2),
      )

    let assert Ok(ack2) =
      cap_controller.process_alerts([fetch_u2, fetch_a2], None, 2, 0, ctx)
    ack2.written |> should.equal(2)

    // Alert was inserted already ended (superseded by Update)
    test_db.scalar_text(
      conn,
      "SELECT end_reason FROM sea.alert WHERE source_id = 'dwd@dwd.de,order2-alert'",
    )
    |> should.equal("superseded")
    test_db.scalar_text(
      conn,
      "SELECT superseded_by FROM sea.alert WHERE source_id = 'dwd@dwd.de,order2-alert'",
    )
    |> should.equal("cap-2.49.0.0.276.0:dwd@dwd.de,order2-update")

    // Update is active
    test_db.scalar_text(
      conn,
      "SELECT (ended_at IS NULL)::text FROM sea.alert WHERE source_id = 'dwd@dwd.de,order2-update'",
    )
    |> should.equal("true")
  })
}

pub fn test_status_cancel_does_not_cancel_active_alert_integration_test() {
  test_db.with_test_db(fn(conn) {
    let ctx = test_db.integration_context(conn)
    let now = timestamp.system_time()
    let dwd =
      sample_registry_item("urn:oid:2.49.0.0.276.0", "Germany: DWD", "DEU", [
        models_cap.RegistryFeed("https://dwd.de/feed.xml", Some("en")),
      ])
    let assert Ok(_) = cap_controller.process_registry([dwd], 1, 0, ctx)

    let t1 = rfc3339_at(now, -1800)
    let t2 = rfc3339_at(now, -600)
    let cap_actual =
      sample_cap_json("alert-actual", "dwd@dwd.de", t1, "Alert", "Actual", None)
    let fetch_actual =
      make_fetch_result(
        "https://dwd.de/act.xml",
        "https://dwd.de/feed.xml",
        200,
        Some(cap_actual),
      )
    let assert Ok(_) =
      cap_controller.process_alerts([fetch_actual], None, 1, 0, ctx)

    // Send a Cancel with status = "Test" referencing the Actual alert
    let cap_cancel_test =
      sample_cap_json(
        "cancel-test",
        "dwd@dwd.de",
        t2,
        "Cancel",
        "Test",
        Some("dwd@dwd.de,alert-actual," <> t1),
      )
    let fetch_cancel_test =
      make_fetch_result(
        "https://dwd.de/canc_test.xml",
        "https://dwd.de/feed.xml",
        200,
        Some(cap_cancel_test),
      )
    let assert Ok(ack) =
      cap_controller.process_alerts([fetch_cancel_test], None, 1, 0, ctx)
    ack.written |> should.equal(1)

    // The Actual alert is STILL active!
    test_db.scalar_text(
      conn,
      "SELECT (ended_at IS NULL)::text FROM sea.alert WHERE source_id = 'dwd@dwd.de,alert-actual'",
    )
    |> should.equal("true")

    // The Test cancel was stored in sea.cap_message with normalized = false
    test_db.scalar_int(
      conn,
      "SELECT CASE WHEN normalized THEN 1 ELSE 0 END FROM sea.cap_message WHERE identifier = 'cancel-test'",
    )
    |> should.equal(0)
  })
}

pub fn seen_set_repeat_marks_cap_item_fetched_with_message_key_integration_test() {
  test_db.with_test_db(fn(conn) {
    let ctx = test_db.integration_context(conn)
    let now = timestamp.system_time()
    let dwd =
      sample_registry_item("urn:oid:2.49.0.0.276.0", "Germany: DWD", "DEU", [
        models_cap.RegistryFeed("https://dwd.de/feed1.xml", Some("en")),
        models_cap.RegistryFeed("https://dwd.de/feed2.xml", Some("en")),
      ])
    let assert Ok(_) = cap_controller.process_registry([dwd], 1, 0, ctx)

    // Index item 1 on feed 1, item 2 on feed 2
    let item1 =
      models_cap.IndexItem(
        None,
        None,
        "https://dwd.de/item1.xml",
        Some(rfc3339_at(now, -3600)),
      )
    let item2 =
      models_cap.IndexItem(
        None,
        None,
        "https://dwd.de/item2.xml",
        Some(rfc3339_at(now, -3600)),
      )
    let assert Ok(_) =
      cap_controller.process_index(
        Some("https://dwd.de/feed1.xml"),
        None,
        [item1],
        1,
        0,
        ctx,
      )
    let assert Ok(_) =
      cap_controller.process_index(
        Some("https://dwd.de/feed2.xml"),
        None,
        [item2],
        1,
        0,
        ctx,
      )

    let cap_json =
      sample_cap_json(
        "repeat-alert",
        "dwd@dwd.de",
        rfc3339_at(now, -1800),
        "Alert",
        "Actual",
        None,
      )

    // First fetch: writes alert and populates seen-set
    let fetch1 =
      make_fetch_result(
        "https://dwd.de/item1.xml",
        "https://dwd.de/feed1.xml",
        200,
        Some(cap_json),
      )
    let assert Ok(ack1) =
      cap_controller.process_alerts([fetch1], None, 1, 0, ctx)
    ack1.written |> should.equal(1)
    ack1.deduped |> should.equal(0)

    // Second fetch: same payload delivered via feed 2 -> seen-set repeat!
    let fetch2 =
      make_fetch_result(
        "https://dwd.de/item2.xml",
        "https://dwd.de/feed2.xml",
        200,
        Some(cap_json),
      )
    let assert Ok(ack2) =
      cap_controller.process_alerts([fetch2], None, 1, 0, ctx)
    ack2.written |> should.equal(0)
    ack2.deduped |> should.equal(1)

    // Item 2 must have its state updated to 'fetched' with message_key set!
    test_db.scalar_text(
      conn,
      "SELECT state FROM sea.cap_item WHERE cap_url = 'https://dwd.de/item2.xml'",
    )
    |> should.equal("fetched")
    test_db.scalar_text(
      conn,
      "SELECT message_key FROM sea.cap_item WHERE cap_url = 'https://dwd.de/item2.xml'",
    )
    |> should.equal("dwd@dwd.de,repeat-alert")
  })
}

pub fn first_feed_wins_newer_revision_via_another_authority_retains_source_integration_test() {
  test_db.with_test_db(fn(conn) {
    let ctx = test_db.integration_context(conn)
    let now = timestamp.system_time()

    let auth1 =
      sample_registry_item("urn:oid:2.49.0.0.1.0", "Auth One", "DEU", [
        models_cap.RegistryFeed("https://auth1.org/feed.xml", Some("en")),
      ])
    let auth2 =
      sample_registry_item("urn:oid:2.49.0.0.2.0", "Auth Two", "FRA", [
        models_cap.RegistryFeed("https://auth2.org/feed.xml", Some("en")),
      ])
    let assert Ok(_) =
      cap_controller.process_registry([auth1, auth2], 2, 0, ctx)

    let t1 = rfc3339_at(now, -3600)
    let t2 = rfc3339_at(now, -1800)

    let cap1 =
      sample_cap_json("shared-001", "shared@org", t1, "Alert", "Actual", None)
    let fetch1 =
      make_fetch_result(
        "https://auth1.org/item.xml",
        "https://auth1.org/feed.xml",
        200,
        Some(cap1),
      )
    let assert Ok(ack1) =
      cap_controller.process_alerts([fetch1], None, 1, 0, ctx)
    ack1.written |> should.equal(1)

    // Original row owned by auth1
    test_db.scalar_text(
      conn,
      "SELECT source FROM sea.alert WHERE source_id = 'shared@org,shared-001'",
    )
    |> should.equal("cap-2.49.0.0.1.0")

    // Newer revision arrives via auth2
    let cap2 =
      sample_cap_json("shared-001", "shared@org", t2, "Alert", "Actual", None)
    let fetch2 =
      make_fetch_result(
        "https://auth2.org/item.xml",
        "https://auth2.org/feed.xml",
        200,
        Some(cap2),
      )
    let assert Ok(ack2) =
      cap_controller.process_alerts([fetch2], None, 1, 0, ctx)
    ack2.written |> should.equal(1)

    // Stored source must STILL be cap-2.49.0.0.1.0 (first feed wins)
    test_db.scalar_text(
      conn,
      "SELECT source FROM sea.alert WHERE source_id = 'shared@org,shared-001'",
    )
    |> should.equal("cap-2.49.0.0.1.0")

    // Countries must STILL be {DEU} from auth1
    test_db.scalar_text(
      conn,
      "SELECT countries::text FROM sea.alert WHERE source_id = 'shared@org,shared-001'",
    )
    |> should.equal("{DEU}")

    // No duplicate alert row exists
    test_db.scalar_int(
      conn,
      "SELECT count(*) FROM sea.alert WHERE source_id = 'shared@org,shared-001'",
    )
    |> should.equal(1)
  })
}

pub fn registry_validation_zero_authorities_and_excessive_removal_rejected_integration_test() {
  test_db.with_test_db(fn(conn) {
    let ctx = test_db.integration_context(conn)

    // 1. Zero authorities parsed is rejected
    let res_empty = cap_controller.process_registry([], 0, 0, ctx)
    should.be_error(res_empty)
    test_db.count(conn, "sea.cap_authority") |> should.equal(0)

    // 2. Register 4 authorities
    let auth1 =
      sample_registry_item("urn:oid:2.49.0.0.1.0", "A1", "DEU", [
        models_cap.RegistryFeed("https://a1.org/feed.xml", Some("en")),
      ])
    let auth2 =
      sample_registry_item("urn:oid:2.49.0.0.2.0", "A2", "FRA", [
        models_cap.RegistryFeed("https://a2.org/feed.xml", Some("en")),
      ])
    let auth3 =
      sample_registry_item("urn:oid:2.49.0.0.3.0", "A3", "ESP", [
        models_cap.RegistryFeed("https://a3.org/feed.xml", Some("en")),
      ])
    let auth4 =
      sample_registry_item("urn:oid:2.49.0.0.4.0", "A4", "ITA", [
        models_cap.RegistryFeed("https://a4.org/feed.xml", Some("en")),
      ])

    let assert Ok(ack) =
      cap_controller.process_registry([auth1, auth2, auth3, auth4], 4, 0, ctx)
    ack.written |> should.equal(4)
    test_db.count(conn, "sea.cap_authority") |> should.equal(4)

    // 3. Post registry with only 1 authority (would remove 3 out of 4 = 75% > 50%)
    let res_excessive = cap_controller.process_registry([auth1], 1, 0, ctx)
    should.be_error(res_excessive)

    // None were marked removed because the whole batch was rejected
    test_db.scalar_int(
      conn,
      "SELECT count(*) FROM sea.cap_authority WHERE removed_at IS NULL",
    )
    |> should.equal(4)
  })
}

pub fn feedless_authority_not_removed_on_second_registry_post_integration_test() {
  test_db.with_test_db(fn(conn) {
    let ctx = test_db.integration_context(conn)

    // Authority with no feeds (e.g. Colombia)
    let colombia =
      sample_registry_item(
        "urn:oid:2.49.0.0.170.0",
        "Colombia: IDEAM",
        "COL",
        [],
      )
    let assert Ok(ack1) = cap_controller.process_registry([colombia], 1, 0, ctx)
    ack1.written |> should.equal(1)
    test_db.count(conn, "sea.cap_authority") |> should.equal(1)

    // Second registry POST still has Colombia with no feeds
    let assert Ok(ack2) = cap_controller.process_registry([colombia], 1, 0, ctx)
    ack2.written |> should.equal(0)
    ack2.deduped |> should.equal(1)

    // Authority must NOT be marked removed!
    test_db.scalar_text(
      conn,
      "SELECT (removed_at IS NULL)::text FROM sea.cap_authority WHERE oid = '2.49.0.0.170.0'",
    )
    |> should.equal("true")
  })
}

pub fn feed_health_metrics_preserved_on_second_registry_post_integration_test() {
  test_db.with_test_db(fn(conn) {
    let ctx = test_db.integration_context(conn)
    let now = timestamp.system_time()

    let dwd =
      sample_registry_item("urn:oid:2.49.0.0.276.0", "Germany: DWD", "DEU", [
        models_cap.RegistryFeed("https://dwd.de/feed.xml", Some("en")),
      ])
    let assert Ok(_) = cap_controller.process_registry([dwd], 1, 0, ctx)

    // Poll with failure to set consecutive_failures = 1
    let meta500 =
      models_cap.CapPollMeta(
        fetched_at: rfc3339_at(now, 0),
        http_status: 500,
        feature_count: 0,
        bytes: 0,
        backfill: False,
        feed_url: Some("https://dwd.de/feed.xml"),
        error: Some("Server Error"),
        format: None,
      )
    let assert Ok(_) =
      cap_controller.process_index(
        Some("https://dwd.de/feed.xml"),
        Some(meta500),
        [],
        0,
        0,
        ctx,
      )

    test_db.scalar_int(
      conn,
      "SELECT consecutive_failures FROM sea.cap_feed WHERE url = 'https://dwd.de/feed.xml'",
    )
    |> should.equal(1)

    // Second registry POST must NOT reset consecutive_failures to 0 or last_polled_at to NULL!
    let assert Ok(_) = cap_controller.process_registry([dwd], 1, 0, ctx)

    test_db.scalar_int(
      conn,
      "SELECT consecutive_failures FROM sea.cap_feed WHERE url = 'https://dwd.de/feed.xml'",
    )
    |> should.equal(1)

    test_db.scalar_text(
      conn,
      "SELECT (last_polled_at IS NOT NULL)::text FROM sea.cap_feed WHERE url = 'https://dwd.de/feed.xml'",
    )
    |> should.equal("true")
  })
}

pub fn mixed_batch_ack_balance_integration_test() {
  test_db.with_test_db(fn(conn) {
    let ctx = test_db.integration_context(conn)
    let now = timestamp.system_time()
    let dwd =
      sample_registry_item("urn:oid:2.49.0.0.276.0", "Germany: DWD", "DEU", [
        models_cap.RegistryFeed("https://dwd.de/feed.xml", Some("en")),
      ])
    let assert Ok(_) = cap_controller.process_registry([dwd], 1, 0, ctx)

    // 1. One fetch failure (500)
    let fetch_fail =
      make_fetch_result(
        "https://dwd.de/fail.xml",
        "https://dwd.de/feed.xml",
        500,
        None,
      )

    // 2. One valid alert
    let cap_valid =
      sample_cap_json(
        "valid-001",
        "dwd@dwd.de",
        rfc3339_at(now, -600),
        "Alert",
        "Actual",
        None,
      )
    let fetch_valid =
      make_fetch_result(
        "https://dwd.de/valid.xml",
        "https://dwd.de/feed.xml",
        200,
        Some(cap_valid),
      )

    // 3 total received, 1 decode dropped by adapter, 2 results submitted
    let assert Ok(ack) =
      cap_controller.process_alerts([fetch_fail, fetch_valid], None, 3, 1, ctx)

    ack.received |> should.equal(3)
    ack.written |> should.equal(1)
    ack.dropped |> should.equal(2)
    ack.deduped |> should.equal(0)
    { ack.received == ack.deduped + ack.written + ack.dropped }
    |> should.equal(True)
  })
}

pub fn pending_limit_clamp_integration_test() {
  test_db.with_test_db(fn(conn) {
    let ctx = test_db.integration_context(conn)
    let dwd =
      sample_registry_item("urn:oid:2.49.0.0.276.0", "Germany: DWD", "DEU", [
        models_cap.RegistryFeed("https://dwd.de/feed.xml", Some("en")),
      ])
    let assert Ok(_) = cap_controller.process_registry([dwd], 1, 0, ctx)

    // Insert 5 pending items
    test_db.exec(
      conn,
      "INSERT INTO sea.cap_item (cap_url, feed_url, state, attempts, first_seen_at, last_seen_at)
       VALUES
         ('https://dwd.de/p1.xml', 'https://dwd.de/feed.xml', 'pending', 0, now() - interval '5 min', now()),
         ('https://dwd.de/p2.xml', 'https://dwd.de/feed.xml', 'pending', 0, now() - interval '4 min', now()),
         ('https://dwd.de/p3.xml', 'https://dwd.de/feed.xml', 'pending', 0, now() - interval '3 min', now()),
         ('https://dwd.de/p4.xml', 'https://dwd.de/feed.xml', 'pending', 0, now() - interval '2 min', now()),
         ('https://dwd.de/p5.xml', 'https://dwd.de/feed.xml', 'pending', 0, now() - interval '1 min', now())",
    )

    // Clamp <= 0 to 1
    let assert Ok(items_neg) = cap_controller.get_pending(-5, ctx)
    list.length(items_neg) |> should.equal(1)

    let assert Ok(items_zero) = cap_controller.get_pending(0, ctx)
    list.length(items_zero) |> should.equal(1)

    // Clamp > 200 returns up to 200 (all 5 available)
    let assert Ok(items_large) = cap_controller.get_pending(500, ctx)
    list.length(items_large) |> should.equal(5)
  })
}

pub fn in_transaction_failure_rolls_back_records_outcome_and_repost_succeeds_integration_test() {
  test_db.with_test_db(fn(conn) {
    let ctx = test_db.integration_context(conn)
    let now = timestamp.system_time()
    let dwd =
      sample_registry_item("urn:oid:2.49.0.0.276.0", "Germany: DWD", "DEU", [
        models_cap.RegistryFeed("https://dwd.de/feed.xml", Some("en")),
      ])
    let assert Ok(_) = cap_controller.process_registry([dwd], 1, 0, ctx)

    let item_good =
      models_cap.IndexItem(
        None,
        None,
        "https://dwd.de/good-tx.xml",
        Some(rfc3339_at(now, -3600)),
      )
    let item_bad =
      models_cap.IndexItem(
        None,
        None,
        "https://dwd.de/bad-tx.xml",
        Some(rfc3339_at(now, -3600)),
      )
    let assert Ok(_) =
      cap_controller.process_index(
        Some("https://dwd.de/feed.xml"),
        None,
        [item_good, item_bad],
        2,
        0,
        ctx,
      )

    let good_cap_json =
      sample_cap_json(
        "good-tx-001",
        "dwd@dwd.de",
        rfc3339_at(now, -600),
        "Alert",
        "Actual",
        None,
      )
    let bad_cap_json =
      sample_cap_json(
        "bad-tx-001",
        "dwd@dwd.de",
        rfc3339_at(now, -600),
        "Alert",
        "Actual",
        None,
      )

    let fetch_good =
      make_fetch_result(
        "https://dwd.de/good-tx.xml",
        "https://dwd.de/feed.xml",
        200,
        Some(good_cap_json),
      )
    let fetch_bad =
      models_cap.CapFetchResult(
        ..make_fetch_result(
          "https://dwd.de/bad-tx.xml",
          "https://dwd.de/feed.xml",
          200,
          Some(bad_cap_json),
        ),
        raw_xml: Some("<alert>\u{0000}bad</alert>"),
      )

    let assert Ok(ack1) =
      cap_controller.process_alerts([fetch_good, fetch_bad], None, 2, 0, ctx)

    ack1.received |> should.equal(2)
    ack1.written |> should.equal(1)
    ack1.deduped |> should.equal(0)
    ack1.dropped |> should.equal(1)

    // Valid message is normalized and committed
    test_db.scalar_int(
      conn,
      "SELECT count(*) FROM sea.cap_message WHERE identifier = 'good-tx-001'",
    )
    |> should.equal(1)
    test_db.scalar_int(
      conn,
      "SELECT count(*) FROM sea.alert WHERE source_id = 'dwd@dwd.de,good-tx-001'",
    )
    |> should.equal(1)

    // Failing item is rolled back: not in sea.cap_message
    test_db.scalar_int(
      conn,
      "SELECT count(*) FROM sea.cap_message WHERE identifier = 'bad-tx-001'",
    )
    |> should.equal(0)

    // Failing item in sea.cap_item is state = failed, attempts = 1 (retryable)
    test_db.scalar_text(
      conn,
      "SELECT state FROM sea.cap_item WHERE cap_url = 'https://dwd.de/bad-tx.xml'",
    )
    |> should.equal("failed")
    test_db.scalar_int(
      conn,
      "SELECT attempts FROM sea.cap_item WHERE cap_url = 'https://dwd.de/bad-tx.xml'",
    )
    |> should.equal(1)
    test_db.scalar_int(
      conn,
      "SELECT http_status FROM sea.cap_item WHERE cap_url = 'https://dwd.de/bad-tx.xml'",
    )
    |> should.equal(200)

    // Re-POSTing failing item with valid XML succeeds and is not treated as a seen repeat
    let fetch_fixed =
      models_cap.CapFetchResult(
        ..make_fetch_result(
          "https://dwd.de/bad-tx.xml",
          "https://dwd.de/feed.xml",
          200,
          Some(bad_cap_json),
        ),
        raw_xml: Some("<alert>fixed</alert>"),
      )

    let assert Ok(ack2) =
      cap_controller.process_alerts([fetch_fixed], None, 1, 0, ctx)

    ack2.received |> should.equal(1)
    ack2.written |> should.equal(1)
    ack2.deduped |> should.equal(0)
    ack2.dropped |> should.equal(0)

    test_db.scalar_text(
      conn,
      "SELECT state FROM sea.cap_item WHERE cap_url = 'https://dwd.de/bad-tx.xml'",
    )
    |> should.equal("fetched")
    test_db.scalar_int(
      conn,
      "SELECT count(*) FROM sea.cap_message WHERE identifier = 'bad-tx-001'",
    )
    |> should.equal(1)
    test_db.scalar_int(
      conn,
      "SELECT count(*) FROM sea.alert WHERE source_id = 'dwd@dwd.de,bad-tx-001'",
    )
    |> should.equal(1)
  })
}

pub fn cap_message_with_past_active_until_inserted_ended_as_expired_integration_test() {
  test_db.with_test_db(fn(conn) {
    let ctx = test_db.integration_context(conn)
    let now = timestamp.system_time()
    let dwd =
      sample_registry_item("urn:oid:2.49.0.0.276.0", "Germany: DWD", "DEU", [
        models_cap.RegistryFeed("https://dwd.de/feed.xml", Some("en")),
      ])
    let assert Ok(_) = cap_controller.process_registry([dwd], 1, 0, ctx)

    let item_past =
      models_cap.IndexItem(
        None,
        None,
        "https://dwd.de/past-alert.xml",
        Some(rfc3339_at(now, -7200)),
      )
    let assert Ok(_) =
      cap_controller.process_index(
        Some("https://dwd.de/feed.xml"),
        None,
        [item_past],
        1,
        0,
        ctx,
      )

    let past_cap_json =
      sample_cap_json_with_expires(
        "past-001",
        "dwd@dwd.de",
        rfc3339_at(now, -7200),
        "Alert",
        "Actual",
        None,
        rfc3339_at(now, -3600),
      )
    let fetch_past =
      make_fetch_result(
        "https://dwd.de/past-alert.xml",
        "https://dwd.de/feed.xml",
        200,
        Some(past_cap_json),
      )

    let assert Ok(ack) =
      cap_controller.process_alerts([fetch_past], None, 1, 0, ctx)

    ack.written |> should.equal(1)

    test_db.scalar_text(
      conn,
      "SELECT (ended_at IS NOT NULL)::text FROM sea.alert WHERE source_id = 'dwd@dwd.de,past-001'",
    )
    |> should.equal("true")

    test_db.scalar_text(
      conn,
      "SELECT end_reason FROM sea.alert WHERE source_id = 'dwd@dwd.de,past-001'",
    )
    |> should.equal("expired")

    test_db.scalar_int(
      conn,
      "SELECT count(*) FROM sea.cap_message WHERE identifier = 'past-001'",
    )
    |> should.equal(1)
  })
}

pub fn newer_revision_ineligible_withdraws_active_alert_integration_test() {
  test_db.with_test_db(fn(conn) {
    let ctx = test_db.integration_context(conn)
    let now = timestamp.system_time()
    let dwd =
      sample_registry_item("urn:oid:2.49.0.0.276.0", "Germany: DWD", "DEU", [
        models_cap.RegistryFeed("https://dwd.de/feed.xml", Some("en")),
      ])
    let assert Ok(_) = cap_controller.process_registry([dwd], 1, 0, ctx)

    // 1. Initial normal active alert
    let cap1 =
      sample_cap_json(
        "rev-withdraw-001",
        "dwd@dwd.de",
        rfc3339_at(now, -3600),
        "Alert",
        "Actual",
        None,
      )
    let fetch1 =
      make_fetch_result(
        "https://dwd.de/rev1.xml",
        "https://dwd.de/feed.xml",
        200,
        Some(cap1),
      )
    let assert Ok(ack1) =
      cap_controller.process_alerts([fetch1], None, 1, 0, ctx)
    ack1.written |> should.equal(1)

    test_db.scalar_text(
      conn,
      "SELECT (ended_at IS NULL)::text FROM sea.alert WHERE source_id = 'dwd@dwd.de,rev-withdraw-001'",
    )
    |> should.equal("true")

    // 2. Newer revision has empty <info> (NoInfo)
    let noinfo_cap_json =
      "{\"cap_version\":\"1.2\",\"identifier\":\"rev-withdraw-001\",\"sender\":\"dwd@dwd.de\",\"sent\":\""
      <> rfc3339_at(now, -1800)
      <> "\",\"status\":\"Actual\",\"msgType\":\"Update\",\"scope\":\"Public\",\"info\":[]}"
    let fetch2 =
      make_fetch_result(
        "https://dwd.de/rev2.xml",
        "https://dwd.de/feed.xml",
        200,
        Some(noinfo_cap_json),
      )
    let assert Ok(ack2) =
      cap_controller.process_alerts([fetch2], None, 1, 0, ctx)
    ack2.written |> should.equal(1)

    // Stored alert row is now ended with end_reason = 'withdrawn'
    test_db.scalar_text(
      conn,
      "SELECT (ended_at IS NOT NULL)::text FROM sea.alert WHERE source_id = 'dwd@dwd.de,rev-withdraw-001'",
    )
    |> should.equal("true")

    test_db.scalar_text(
      conn,
      "SELECT end_reason FROM sea.alert WHERE source_id = 'dwd@dwd.de,rev-withdraw-001'",
    )
    |> should.equal("withdrawn")
  })
}

pub fn registry_duplicate_guid_deduplicated_first_wins_integration_test() {
  test_db.with_test_db(fn(conn) {
    let ctx = test_db.integration_context(conn)
    let auth1 =
      sample_registry_item(
        "urn:oid:2.49.0.0.777.0",
        "Authority Original",
        "DEU",
        [models_cap.RegistryFeed("https://auth1.de/feed.xml", Some("en"))],
      )
    let auth2 =
      sample_registry_item(
        "urn:oid:2.49.0.0.777.0",
        "Authority Duplicate",
        "FRA",
        [models_cap.RegistryFeed("https://auth2.de/feed.xml", Some("fr"))],
      )

    let assert Ok(ack) =
      cap_controller.process_registry([auth1, auth2], 2, 0, ctx)

    ack.received |> should.equal(2)
    ack.written |> should.equal(1)
    ack.dropped |> should.equal(1)
    ack.deduped |> should.equal(0)

    test_db.scalar_text(
      conn,
      "SELECT name FROM sea.cap_authority WHERE oid = '2.49.0.0.777.0'",
    )
    |> should.equal("Authority Original")
  })
}
