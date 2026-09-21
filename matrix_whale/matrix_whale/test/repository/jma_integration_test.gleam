import adapter/earthquake_hub
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/time/calendar
import gleam/time/duration
import gleam/time/timestamp
import gleeunit/should
import intake/record
import message/reciever/models/earthquake_feature
import message/reciever/models/jma as models_jma
import pog
import repository/earthquake_writer
import repository/jma_item_writer
import repository/jma_message_writer
import support/test_db

pub fn jma_index_deduplication_test() {
  use conn <- test_db.with_test_db
  let now = timestamp.system_time()

  let item1 =
    models_jma.JmaIndexItem(
      item_url: "https://example.com/xml/item1.xml",
      feed_url: "https://example.com/feed/eqvol.xml",
      guid: Some("guid-1"),
      title: Some("震源・震度に関する情報"),
      published: Some("2026-09-21T01:00:00+09:00"),
    )
  let item2 =
    models_jma.JmaIndexItem(
      item_url: "https://example.com/xml/item2.xml",
      feed_url: "https://example.com/feed/eqvol.xml",
      guid: Some("guid-2"),
      title: Some("気象警報・注意報"),
      published: Some("2026-09-21T02:00:00+09:00"),
    )

  // 1. Initial write
  let assert Ok(ack1) =
    jma_item_writer.write_index([item1, item2], 2, 0, now, conn)
  ack1.written |> should.equal(2)
  ack1.deduped |> should.equal(0)

  // 2. Re-write with duplicate item1 and new item3
  let item3 =
    models_jma.JmaIndexItem(
      item_url: "https://example.com/xml/item3.xml",
      feed_url: "https://example.com/feed/eqvol.xml",
      guid: Some("guid-3"),
      title: Some("津波警報"),
      published: Some("2026-09-21T03:00:00+09:00"),
    )
  let assert Ok(ack2) =
    jma_item_writer.write_index([item1, item3], 2, 0, now, conn)
  ack2.written |> should.equal(1)
  ack2.deduped |> should.equal(1)

  // 3. Fetch pending: should be ordered published_at DESC (item3, then item2, then item1)
  let assert Ok(pending) = jma_item_writer.pending(10, now, conn)
  list.length(pending) |> should.equal(3)
  case pending {
    [p1, p2, p3] -> {
      p1.item_url |> should.equal("https://example.com/xml/item3.xml")
      p2.item_url |> should.equal("https://example.com/xml/item2.xml")
      p3.item_url |> should.equal("https://example.com/xml/item1.xml")
    }
    _ -> False |> should.equal(True)
  }
}

pub fn jma_live_earthquake_and_cancellation_orphan_test() {
  use conn <- test_db.with_test_db
  let now = timestamp.system_time()

  let eq =
    models_jma.JmaEarthquake(
      origin_time: "2026-09-21T01:20:00+09:00",
      latitude: Some(35.68),
      longitude: Some(139.76),
      depth_km: Some(10.0),
      magnitude: Some(4.5),
      magnitude_type: Some("Mj"),
      place: Some("東京湾"),
      max_intensity: Some("3"),
    )

  let live_msg =
    models_jma.JmaMessageContent(
      identifier: "20260921012500_VXSE53_01",
      control_title: "震源・震度に関する情報",
      status: "通常",
      info_type: "発表",
      event_id: Some("eq-20260921-001"),
      series_key: Some("震源・震度に関する情報:気象庁:eq-20260921-001"),
      sent: "2026-09-21T01:25:00+09:00",
      effective: Some("2026-09-21T01:25:00+09:00"),
      expires: None,
      headline: Some("東京湾で地震"),
      description: Some("震源は東京湾"),
      areas: [],
      alerts: [],
      cleared_areas: [],
      earthquake: Some(eq),
    )

  let fetch_res =
    models_jma.JmaFetchResult(
      item_url: "https://example.com/xml/eq1.xml",
      feed_url: "https://example.com/feed/eqvol.xml",
      fetched_at: "2026-09-21T01:25:05Z",
      http_status: 200,
      error: None,
      raw_xml: Some("<xml>earthquake data</xml>"),
      message: Some(live_msg),
    )

  // Ingest live earthquake
  let assert Ok(res1) = jma_message_writer.write_batch([fetch_res], now, conn)
  res1.written |> should.equal(1)
  res1.deduped |> should.equal(0)
  list.length(res1.earthquake_diff.new) |> should.equal(1)
  list.length(res1.earthquake_diff.events.new) |> should.equal(1)

  // Verify earthquake in DB
  let assert Ok(eq_rows) =
    pog.query(
      "SELECT source_id, magnitude FROM sea.earthquake WHERE source = 'jma'",
    )
    |> pog.returning({
      use sid <- decode.field(0, decode.string)
      use mag <- decode.field(1, decode.float)
      decode.success(#(sid, mag))
    })
    |> pog.execute(conn)
  case eq_rows.rows {
    [#(sid, mag)] -> {
      sid |> should.equal("eq-20260921-001")
      mag |> should.equal(4.5)
    }
    _ -> False |> should.equal(True)
  }

  // Duplicate replay of same message should early return with 0 side effects
  let assert Ok(res_dup) =
    jma_message_writer.write_batch([fetch_res], now, conn)
  res_dup.written |> should.equal(0)
  res_dup.deduped |> should.equal(1)
  res_dup.earthquake_diff.new |> should.equal([])

  // Now send a cancellation telegram (info_type = "取消")
  let cancel_msg =
    models_jma.JmaMessageContent(
      identifier: "20260921013000_VXSE53_02",
      control_title: "震源・震度に関する情報",
      status: "通常",
      info_type: "取消",
      event_id: Some("eq-20260921-001"),
      series_key: Some("震源・震度に関する情報:気象庁:eq-20260921-001"),
      sent: "2026-09-21T01:30:00+09:00",
      effective: Some("2026-09-21T01:30:00+09:00"),
      expires: None,
      headline: Some("先ほどの地震情報は取り消されました"),
      description: Some("誤報のため取消"),
      areas: [],
      alerts: [],
      cleared_areas: [],
      earthquake: None,
    )

  let cancel_fetch_res =
    models_jma.JmaFetchResult(
      item_url: "https://example.com/xml/eq1_cancel.xml",
      feed_url: "https://example.com/feed/eqvol.xml",
      fetched_at: "2026-09-21T01:30:05Z",
      http_status: 200,
      error: None,
      raw_xml: Some("<xml>cancel</xml>"),
      message: Some(cancel_msg),
    )

  let assert Ok(res_cancel) =
    jma_message_writer.write_batch([cancel_fetch_res], now, conn)
  res_cancel.written |> should.equal(1)
  res_cancel.resync_earthquakes |> should.equal(True)

  // Live earthquake and event should be marked deleted
  let assert Ok(check_active_eq) =
    pog.query(
      "SELECT count(*) FROM sea.earthquake WHERE source = 'jma' AND (status IS NULL OR status <> 'deleted')",
    )
    |> pog.returning(decode.at([0], decode.int))
    |> pog.execute(conn)
  check_active_eq.rows |> should.equal([0])

  let assert Ok(check_eq_status) =
    pog.query("SELECT status FROM sea.earthquake WHERE source = 'jma'")
    |> pog.returning(decode.at([0], decode.optional(decode.string)))
    |> pog.execute(conn)
  check_eq_status.rows |> should.equal([Some("deleted")])

  let assert Ok(check_event_status) =
    pog.query("SELECT status FROM sea.event")
    |> pog.returning(decode.at([0], decode.optional(decode.string)))
    |> pog.execute(conn)
  check_event_status.rows |> should.equal([Some("deleted")])
}

pub fn jma_non_live_drill_does_not_affect_live_data_test() {
  use conn <- test_db.with_test_db
  let now = timestamp.system_time()

  // 1. Ingest a real live alert
  let alert1 =
    models_jma.JmaAlertItem(
      lifecycle_key: "130000:大雨警報",
      area_name: "東京地方",
      geocode: "130000",
      event: "大雨警報",
      category: Some("Met"),
      status: "発表",
      severity: "Severe",
      urgency: "Expected",
      certainty: "Observed",
    )
  let live_msg =
    models_jma.JmaMessageContent(
      identifier: "20260921020000_VPWW53_01",
      control_title: "気象警報・注意報",
      status: "通常",
      info_type: "発表",
      event_id: None,
      series_key: Some("気象警報・注意報:東京管区気象台:130000"),
      sent: "2026-09-21T02:00:00+09:00",
      effective: Some("2026-09-21T02:00:00+09:00"),
      expires: None,
      headline: Some("大雨警報"),
      description: Some("土砂災害に警戒"),
      areas: [models_jma.JmaArea(area_name: "東京地方", geocode: "130000")],
      alerts: [alert1],
      cleared_areas: [],
      earthquake: None,
    )
  let live_res =
    models_jma.JmaFetchResult(
      item_url: "https://example.com/xml/alert_live.xml",
      feed_url: "https://example.com/feed/extra.xml",
      fetched_at: "2026-09-21T02:00:05Z",
      http_status: 200,
      error: None,
      raw_xml: Some("<xml>alert</xml>"),
      message: Some(live_msg),
    )
  let assert Ok(live_write) =
    jma_message_writer.write_batch([live_res], now, conn)
  list.length(live_write.alert_diff.new) |> should.equal(1)

  // 2. Ingest a DRILL cancellation message (status = "訓練", info_type = "取消")
  let drill_cancel_msg =
    models_jma.JmaMessageContent(
      identifier: "20260921020500_VPWW53_drill_cancel",
      control_title: "気象警報・注意報",
      status: "訓練",
      info_type: "取消",
      event_id: None,
      series_key: Some("気象警報・注意報:東京管区気象台:130000"),
      sent: "2026-09-21T02:05:00+09:00",
      effective: None,
      expires: None,
      headline: Some("これは訓練です：取消"),
      description: Some("訓練取消"),
      areas: [],
      alerts: [],
      cleared_areas: [],
      earthquake: None,
    )
  let drill_res =
    models_jma.JmaFetchResult(
      item_url: "https://example.com/xml/drill_cancel.xml",
      feed_url: "https://example.com/feed/extra.xml",
      fetched_at: "2026-09-21T02:05:05Z",
      http_status: 200,
      error: None,
      raw_xml: Some("<xml>drill cancel</xml>"),
      message: Some(drill_cancel_msg),
    )
  let assert Ok(drill_write) =
    jma_message_writer.write_batch([drill_res], now, conn)
  drill_write.written |> should.equal(1)
  // Must NOT cancel the live alert!
  drill_write.alert_diff.ended |> should.equal([])

  // Verify the live alert is STILL active and untouched
  let assert Ok(check_alert) =
    pog.query(
      "SELECT ended_at FROM sea.alert WHERE source = 'jma' AND source_id = '気象警報・注意報:東京管区気象台:130000:大雨警報'",
    )
    |> pog.returning(decode.at([0], decode.optional(decode.string)))
    |> pog.execute(conn)
  check_alert.rows |> should.equal([None])
}

pub fn jma_missing_body_alert_cancellation_test() {
  use conn <- test_db.with_test_db
  let now = timestamp.system_time()

  // 1. Issue live alert
  let alert1 =
    models_jma.JmaAlertItem(
      lifecycle_key: "130000:暴風警報",
      area_name: "東京地方",
      geocode: "130000",
      event: "暴風警報",
      category: Some("Met"),
      status: "発表",
      severity: "Severe",
      urgency: "Expected",
      certainty: "Observed",
    )
  let live_msg =
    models_jma.JmaMessageContent(
      identifier: "20260921030000_VPWW53_01",
      control_title: "気象警報・注意報",
      status: "通常",
      info_type: "発表",
      event_id: None,
      series_key: Some("気象警報・注意報:東京管区気象台:130000"),
      sent: "2026-09-21T03:00:00+09:00",
      effective: Some("2026-09-21T03:00:00+09:00"),
      expires: None,
      headline: Some("暴風警報"),
      description: Some("暴風に警戒"),
      areas: [models_jma.JmaArea(area_name: "東京地方", geocode: "130000")],
      alerts: [alert1],
      cleared_areas: [],
      earthquake: None,
    )
  let live_res =
    models_jma.JmaFetchResult(
      item_url: "https://example.com/xml/alert_gale.xml",
      feed_url: "https://example.com/feed/extra.xml",
      fetched_at: "2026-09-21T03:00:05Z",
      http_status: 200,
      error: None,
      raw_xml: Some("<xml>alert</xml>"),
      message: Some(live_msg),
    )
  let assert Ok(_) = jma_message_writer.write_batch([live_res], now, conn)

  // 2. Issue a missing-body cancellation (alerts: []) for that series_key
  let cancel_msg =
    models_jma.JmaMessageContent(
      identifier: "20260921031000_VPWW53_02",
      control_title: "気象警報・注意報",
      status: "通常",
      info_type: "取消",
      event_id: None,
      series_key: Some("気象警報・注意報:東京管区気象台:130000"),
      sent: "2026-09-21T03:10:00+09:00",
      effective: None,
      expires: None,
      headline: Some("警報取消"),
      description: Some("警報を取り消します"),
      areas: [],
      alerts: [],
      cleared_areas: [],
      earthquake: None,
    )
  let cancel_res =
    models_jma.JmaFetchResult(
      item_url: "https://example.com/xml/alert_gale_cancel.xml",
      feed_url: "https://example.com/feed/extra.xml",
      fetched_at: "2026-09-21T03:10:05Z",
      http_status: 200,
      error: None,
      raw_xml: Some("<xml>cancel</xml>"),
      message: Some(cancel_msg),
    )
  let assert Ok(cancel_write) =
    jma_message_writer.write_batch([cancel_res], now, conn)
  list.length(cancel_write.alert_diff.ended) |> should.equal(1)

  // Verify alert ended in DB
  let assert Ok(check_alert) =
    pog.query(
      "SELECT end_reason FROM sea.alert WHERE source = 'jma' AND source_id = '気象警報・注意報:東京管区気象台:130000:暴風警報'",
    )
    |> pog.returning(decode.at([0], decode.optional(decode.string)))
    |> pog.execute(conn)
  check_alert.rows |> should.equal([Some("cancelled")])
}

pub fn jma_stale_alert_watermark_test() {
  use conn <- test_db.with_test_db
  let now = timestamp.system_time()

  // 1. Ingest newer alert at 04:00
  let alert_newer =
    models_jma.JmaAlertItem(
      lifecycle_key: "130000:大雪警報",
      area_name: "東京地方",
      geocode: "130000",
      event: "大雪警報",
      category: Some("Met"),
      status: "発表",
      severity: "Severe",
      urgency: "Expected",
      certainty: "Observed",
    )
  let newer_msg =
    models_jma.JmaMessageContent(
      identifier: "20260921040000_VPWW53_01",
      control_title: "気象警報・注意報",
      status: "通常",
      info_type: "発表",
      event_id: None,
      series_key: Some("気象警報・注意報:東京管区気象台:130000"),
      sent: "2026-09-21T04:00:00+09:00",
      effective: Some("2026-09-21T04:00:00+09:00"),
      expires: None,
      headline: Some("NEWER: 大雪警報"),
      description: Some("Newer description"),
      areas: [models_jma.JmaArea(area_name: "東京地方", geocode: "130000")],
      alerts: [alert_newer],
      cleared_areas: [],
      earthquake: None,
    )
  let newer_res =
    models_jma.JmaFetchResult(
      item_url: "https://example.com/xml/alert_newer.xml",
      feed_url: "https://example.com/feed/extra.xml",
      fetched_at: "2026-09-21T04:00:05Z",
      http_status: 200,
      error: None,
      raw_xml: Some("<xml>newer</xml>"),
      message: Some(newer_msg),
    )
  let assert Ok(_) = jma_message_writer.write_batch([newer_res], now, conn)

  // 2. Ingest older alert at 03:00 (arrived late)
  let alert_older =
    models_jma.JmaAlertItem(
      lifecycle_key: "130000:大雪警報",
      area_name: "東京地方",
      geocode: "130000",
      event: "大雪警報",
      category: Some("Met"),
      status: "発表",
      severity: "Moderate",
      urgency: "Expected",
      certainty: "Observed",
    )
  let older_msg =
    models_jma.JmaMessageContent(
      identifier: "20260921030000_VPWW53_00",
      control_title: "気象警報・注意報",
      status: "通常",
      info_type: "発表",
      event_id: None,
      series_key: Some("気象警報・注意報:東京管区気象台:130000"),
      sent: "2026-09-21T03:00:00+09:00",
      effective: Some("2026-09-21T03:00:00+09:00"),
      expires: None,
      headline: Some("OLDER: 大雪警報"),
      description: Some("Older description"),
      areas: [models_jma.JmaArea(area_name: "東京地方", geocode: "130000")],
      alerts: [alert_older],
      cleared_areas: [],
      earthquake: None,
    )
  let older_res =
    models_jma.JmaFetchResult(
      item_url: "https://example.com/xml/alert_older.xml",
      feed_url: "https://example.com/feed/extra.xml",
      fetched_at: "2026-09-21T04:05:00Z",
      http_status: 200,
      error: None,
      raw_xml: Some("<xml>older</xml>"),
      message: Some(older_msg),
    )
  let assert Ok(_) = jma_message_writer.write_batch([older_res], now, conn)

  // The alert in DB must retain the NEWER headline and severity!
  let assert Ok(check_alert) =
    pog.query(
      "SELECT headline, severity FROM sea.alert WHERE source = 'jma' AND source_id = '気象警報・注意報:東京管区気象台:130000:大雪警報'",
    )
    |> pog.returning({
      use h <- decode.field(0, decode.optional(decode.string))
      use s <- decode.field(1, decode.string)
      decode.success(#(h, s))
    })
    |> pog.execute(conn)
  check_alert.rows |> should.equal([#(Some("NEWER: 大雪警報"), "Severe")])
}

// 1. live -> cancel -> previously UNSEEN older
pub fn jma_live_cancel_then_unseen_older_rejected_test() {
  use conn <- test_db.with_test_db
  let now = timestamp.system_time()

  let live_eq =
    models_jma.JmaEarthquake(
      origin_time: "2026-09-21T01:20:00+09:00",
      latitude: Some(35.68),
      longitude: Some(139.76),
      depth_km: Some(10.0),
      magnitude: Some(4.5),
      magnitude_type: Some("Mj"),
      place: Some("東京湾"),
      max_intensity: Some("3"),
    )
  let live_msg =
    models_jma.JmaMessageContent(
      identifier: "20260921012500_VXSE53_01",
      control_title: "震源・震度に関する情報",
      status: "通常",
      info_type: "発表",
      event_id: Some("eq-series-001"),
      series_key: Some("震源・震度に関する情報:気象庁:eq-series-001"),
      sent: "2026-09-21T01:25:00+09:00",
      effective: Some("2026-09-21T01:25:00+09:00"),
      expires: None,
      headline: Some("東京湾で地震"),
      description: Some("震源は東京湾"),
      areas: [],
      alerts: [],
      cleared_areas: [],
      earthquake: Some(live_eq),
    )
  let live_res =
    models_jma.JmaFetchResult(
      item_url: "https://example.com/xml/live.xml",
      feed_url: "https://example.com/feed/eqvol.xml",
      fetched_at: "2026-09-21T01:25:05Z",
      http_status: 200,
      error: None,
      raw_xml: Some("<xml>live</xml>"),
      message: Some(live_msg),
    )
  let assert Ok(res_live) =
    jma_message_writer.write_batch([live_res], now, conn)
  res_live.written |> should.equal(1)

  // 2. Cancellation bulletin at 01:30
  let cancel_msg =
    models_jma.JmaMessageContent(
      identifier: "20260921013000_VXSE53_02",
      control_title: "震源・震度に関する情報",
      status: "通常",
      info_type: "取消",
      event_id: Some("eq-series-001"),
      series_key: Some("震源・震度に関する情報:気象庁:eq-series-001"),
      sent: "2026-09-21T01:30:00+09:00",
      effective: None,
      expires: None,
      headline: Some("取消"),
      description: Some("誤報のため取消"),
      areas: [],
      alerts: [],
      cleared_areas: [],
      earthquake: None,
    )
  let cancel_res =
    models_jma.JmaFetchResult(
      item_url: "https://example.com/xml/cancel.xml",
      feed_url: "https://example.com/feed/eqvol.xml",
      fetched_at: "2026-09-21T01:30:05Z",
      http_status: 200,
      error: None,
      raw_xml: Some("<xml>cancel</xml>"),
      message: Some(cancel_msg),
    )
  let assert Ok(res_cancel) =
    jma_message_writer.write_batch([cancel_res], now, conn)
  res_cancel.written |> should.equal(1)
  res_cancel.resync_earthquakes |> should.equal(True)

  // Verify status is deleted in DB
  let assert Ok(check_status) =
    pog.query(
      "SELECT status FROM sea.earthquake WHERE source = 'jma' AND source_id = 'eq-series-001'",
    )
    |> pog.returning(decode.at([0], decode.optional(decode.string)))
    |> pog.execute(conn)
  check_status.rows |> should.equal([Some("deleted")])

  // 3. Previously UNSEEN older bulletin arrives with sent = 01:20
  let older_eq =
    models_jma.JmaEarthquake(
      origin_time: "2026-09-21T01:20:00+09:00",
      latitude: Some(35.68),
      longitude: Some(139.76),
      depth_km: Some(10.0),
      magnitude: Some(4.3),
      magnitude_type: Some("Mj"),
      place: Some("東京湾"),
      max_intensity: Some("2"),
    )
  let older_msg =
    models_jma.JmaMessageContent(
      identifier: "20260921012000_VXSE52_01",
      control_title: "震源に関する情報",
      status: "通常",
      info_type: "発表",
      event_id: Some("eq-series-001"),
      series_key: Some("震源に関する情報:気象庁:eq-series-001"),
      sent: "2026-09-21T01:20:00+09:00",
      effective: Some("2026-09-21T01:20:00+09:00"),
      expires: None,
      headline: Some("震源に関する情報"),
      description: Some("震源情報"),
      areas: [],
      alerts: [],
      cleared_areas: [],
      earthquake: Some(older_eq),
    )
  let older_res =
    models_jma.JmaFetchResult(
      item_url: "https://example.com/xml/older_unseen.xml",
      feed_url: "https://example.com/feed/eqvol.xml",
      fetched_at: "2026-09-21T01:35:05Z",
      http_status: 200,
      error: None,
      raw_xml: Some("<xml>older unseen</xml>"),
      message: Some(older_msg),
    )
  let assert Ok(res_older) =
    jma_message_writer.write_batch([older_res], now, conn)
  // Watermark rejects stale bulletin from live mutation, but telegram is durably archived!
  res_older.written |> should.equal(1)
  res_older.dropped |> should.equal(0)
  res_older.earthquake_diff.new |> should.equal([])
  res_older.earthquake_diff.updated |> should.equal([])

  // Verify archived in sea.jma_message
  let assert Ok(archive_check) =
    pog.query(
      "SELECT identifier FROM sea.jma_message WHERE identifier = '20260921012000_VXSE52_01'",
    )
    |> pog.returning(decode.at([0], decode.string))
    |> pog.execute(conn)
  archive_check.rows |> should.equal(["20260921012000_VXSE52_01"])

  // Verify earthquake in DB has NOT been resurrected!
  let assert Ok(check_still_deleted) =
    pog.query(
      "SELECT status FROM sea.earthquake WHERE source = 'jma' AND source_id = 'eq-series-001'",
    )
    |> pog.returning(decode.at([0], decode.optional(decode.string)))
    |> pog.execute(conn)
  check_still_deleted.rows |> should.equal([Some("deleted")])

  let assert Ok(check_active) =
    pog.query(
      "SELECT count(*) FROM sea.earthquake WHERE source = 'jma' AND (status IS NULL OR status <> 'deleted')",
    )
    |> pog.returning(decode.at([0], decode.int))
    |> pog.execute(conn)
  check_active.rows |> should.equal([0])
}

// 2. cancel arrives BEFORE original (tombstone rejects original when it arrives later)
pub fn jma_cancel_before_original_tombstone_test() {
  use conn <- test_db.with_test_db
  let now = timestamp.system_time()

  // 1. Cancellation bulletin arrives first at sent = 02:00
  let cancel_msg =
    models_jma.JmaMessageContent(
      identifier: "20260921020000_VXSE53_cancel",
      control_title: "震源・震度に関する情報",
      status: "通常",
      info_type: "取消",
      event_id: Some("eq-future-001"),
      series_key: Some("震源・震度に関する情報:気象庁:eq-future-001"),
      sent: "2026-09-21T02:00:00+09:00",
      effective: None,
      expires: None,
      headline: Some("取消"),
      description: Some("誤報のため取消"),
      areas: [],
      alerts: [],
      cleared_areas: [],
      earthquake: None,
    )
  let cancel_res =
    models_jma.JmaFetchResult(
      item_url: "https://example.com/xml/early_cancel.xml",
      feed_url: "https://example.com/feed/eqvol.xml",
      fetched_at: "2026-09-21T02:00:05Z",
      http_status: 200,
      error: None,
      raw_xml: Some("<xml>cancel</xml>"),
      message: Some(cancel_msg),
    )
  let assert Ok(res_cancel) =
    jma_message_writer.write_batch([cancel_res], now, conn)
  res_cancel.written |> should.equal(1)

  // Verify tombstone was created in sea.jma_series
  let assert Ok(tombstone_check) =
    pog.query(
      "SELECT is_cancelled FROM sea.jma_series WHERE series_key = 'quake:eq-future-001'",
    )
    |> pog.returning(decode.at([0], decode.bool))
    |> pog.execute(conn)
  tombstone_check.rows |> should.equal([True])

  // 2. Original live bulletin arrives later with sent = 01:50 (< 02:00)
  let orig_eq =
    models_jma.JmaEarthquake(
      origin_time: "2026-09-21T01:50:00+09:00",
      latitude: Some(35.68),
      longitude: Some(139.76),
      depth_km: Some(10.0),
      magnitude: Some(4.8),
      magnitude_type: Some("Mj"),
      place: Some("東京湾"),
      max_intensity: Some("3"),
    )
  let orig_msg =
    models_jma.JmaMessageContent(
      identifier: "20260921015000_VXSE53_01",
      control_title: "震源・震度に関する情報",
      status: "通常",
      info_type: "発表",
      event_id: Some("eq-future-001"),
      series_key: Some("震源・震度に関する情報:気象庁:eq-future-001"),
      sent: "2026-09-21T01:50:00+09:00",
      effective: Some("2026-09-21T01:50:00+09:00"),
      expires: None,
      headline: Some("東京湾で地震"),
      description: Some("震源は東京湾"),
      areas: [],
      alerts: [],
      cleared_areas: [],
      earthquake: Some(orig_eq),
    )
  let orig_res =
    models_jma.JmaFetchResult(
      item_url: "https://example.com/xml/original_late.xml",
      feed_url: "https://example.com/feed/eqvol.xml",
      fetched_at: "2026-09-21T02:05:05Z",
      http_status: 200,
      error: None,
      raw_xml: Some("<xml>original</xml>"),
      message: Some(orig_msg),
    )
  let assert Ok(res_orig) =
    jma_message_writer.write_batch([orig_res], now, conn)
  // Watermark tombstone blocks live mutation, but telegram is durably archived!
  res_orig.written |> should.equal(1)
  res_orig.dropped |> should.equal(0)
  res_orig.earthquake_diff.new |> should.equal([])

  // Verify archived in sea.jma_message
  let assert Ok(archive_check) =
    pog.query(
      "SELECT identifier FROM sea.jma_message WHERE identifier = '20260921015000_VXSE53_01'",
    )
    |> pog.returning(decode.at([0], decode.string))
    |> pog.execute(conn)
  archive_check.rows |> should.equal(["20260921015000_VXSE53_01"])

  // Verify no live earthquake was created
  let assert Ok(check_no_eq) =
    pog.query(
      "SELECT count(*) FROM sea.earthquake WHERE source_id = 'eq-future-001'",
    )
    |> pog.returning(decode.at([0], decode.int))
    |> pog.execute(conn)
  check_no_eq.rows |> should.equal([0])
}

// 3. newer quake -> older cancel (watermark rejects older cancel)
pub fn jma_newer_quake_beats_older_cancel_test() {
  use conn <- test_db.with_test_db
  let now = timestamp.system_time()

  // 1. Live quake arrives at sent = 03:00
  let newer_eq =
    models_jma.JmaEarthquake(
      origin_time: "2026-09-21T02:55:00+09:00",
      latitude: Some(35.68),
      longitude: Some(139.76),
      depth_km: Some(10.0),
      magnitude: Some(5.2),
      magnitude_type: Some("Mj"),
      place: Some("東京湾"),
      max_intensity: Some("4"),
    )
  let newer_msg =
    models_jma.JmaMessageContent(
      identifier: "20260921030000_VXSE53_01",
      control_title: "震源・震度に関する情報",
      status: "通常",
      info_type: "発表",
      event_id: Some("eq-order-001"),
      series_key: Some("震源・震度に関する情報:気象庁:eq-order-001"),
      sent: "2026-09-21T03:00:00+09:00",
      effective: Some("2026-09-21T03:00:00+09:00"),
      expires: None,
      headline: Some("新震源速報"),
      description: Some("新震源"),
      areas: [],
      alerts: [],
      cleared_areas: [],
      earthquake: Some(newer_eq),
    )
  let newer_res =
    models_jma.JmaFetchResult(
      item_url: "https://example.com/xml/newer_eq.xml",
      feed_url: "https://example.com/feed/eqvol.xml",
      fetched_at: "2026-09-21T03:00:05Z",
      http_status: 200,
      error: None,
      raw_xml: Some("<xml>newer eq</xml>"),
      message: Some(newer_msg),
    )
  let assert Ok(res_newer) =
    jma_message_writer.write_batch([newer_res], now, conn)
  res_newer.written |> should.equal(1)

  // 2. Delayed older cancel bulletin arrives with sent = 02:50 (< 03:00)
  let older_cancel_msg =
    models_jma.JmaMessageContent(
      identifier: "20260921025000_VXSE53_cancel",
      control_title: "震源・震度に関する情報",
      status: "通常",
      info_type: "取消",
      event_id: Some("eq-order-001"),
      series_key: Some("震源・震度に関する情報:気象庁:eq-order-001"),
      sent: "2026-09-21T02:50:00+09:00",
      effective: None,
      expires: None,
      headline: Some("旧取消"),
      description: Some("古い取消"),
      areas: [],
      alerts: [],
      cleared_areas: [],
      earthquake: None,
    )
  let older_cancel_res =
    models_jma.JmaFetchResult(
      item_url: "https://example.com/xml/older_cancel.xml",
      feed_url: "https://example.com/feed/eqvol.xml",
      fetched_at: "2026-09-21T03:05:05Z",
      http_status: 200,
      error: None,
      raw_xml: Some("<xml>older cancel</xml>"),
      message: Some(older_cancel_msg),
    )
  let assert Ok(res_cancel) =
    jma_message_writer.write_batch([older_cancel_res], now, conn)
  res_cancel.written |> should.equal(1)
  res_cancel.dropped |> should.equal(0)
  res_cancel.earthquake_diff.updated |> should.equal([])

  // Verify newer quake is STILL active and NOT cancelled!
  let assert Ok(check_newer) =
    pog.query(
      "SELECT status FROM sea.earthquake WHERE source_id = 'eq-order-001'",
    )
    |> pog.returning(decode.at([0], decode.optional(decode.string)))
    |> pog.execute(conn)
  check_newer.rows |> should.equal([None])
}

// 5. mixed-source event preservation (surviving USGS member preferred)
pub fn jma_mixed_source_event_preservation_test() {
  use conn <- test_db.with_test_db
  let now = timestamp.system_time()
  let #(now_sec, _) = timestamp.to_unix_seconds_and_nanoseconds(now)
  let now_ms = now_sec * 1000

  // 1. Insert USGS earthquake
  let usgs_record =
    usgs_incoming("us-tokyo-50", now_ms, now_ms, 35.68, 139.76, 5.0)
  let assert Ok(usgs_write) =
    earthquake_writer.write_batch([usgs_record], now_ms, conn)
  list.length(usgs_write.result.events.new) |> should.equal(1)

  // 2. Ingest matching JMA earthquake with origin time matching now_ms
  let origin_rfc =
    timestamp.from_unix_seconds(now_sec)
    |> timestamp.to_rfc3339(calendar.utc_offset)
  let sent_rfc =
    timestamp.from_unix_seconds(now_sec + 30)
    |> timestamp.to_rfc3339(calendar.utc_offset)

  let jma_eq =
    models_jma.JmaEarthquake(
      origin_time: origin_rfc,
      latitude: Some(35.68),
      longitude: Some(139.76),
      depth_km: Some(10.0),
      magnitude: Some(4.9),
      magnitude_type: Some("Mj"),
      place: Some("東京湾"),
      max_intensity: Some("3"),
    )
  let jma_msg =
    models_jma.JmaMessageContent(
      identifier: "20260921040000_VXSE53_01",
      control_title: "震源・震度に関する情報",
      status: "通常",
      info_type: "発表",
      event_id: Some("jma-tokyo-50"),
      series_key: Some("震源・震度に関する情報:気象庁:jma-tokyo-50"),
      sent: sent_rfc,
      effective: Some(sent_rfc),
      expires: None,
      headline: Some("東京湾地震"),
      description: Some("東京湾"),
      areas: [],
      alerts: [],
      cleared_areas: [],
      earthquake: Some(jma_eq),
    )
  let jma_res =
    models_jma.JmaFetchResult(
      item_url: "https://example.com/xml/jma_tokyo_50.xml",
      feed_url: "https://example.com/feed/eqvol.xml",
      fetched_at: sent_rfc,
      http_status: 200,
      error: None,
      raw_xml: Some("<xml>jma</xml>"),
      message: Some(jma_msg),
    )
  let assert Ok(jma_write) =
    jma_message_writer.write_batch([jma_res], now, conn)
  jma_write.written |> should.equal(1)

  // Verify canonical event has USGS as preferred
  let assert Ok(ev_check) =
    pog.query("SELECT preferred_source, status FROM sea.event")
    |> pog.returning({
      use ps <- decode.field(0, decode.string)
      use st <- decode.field(1, decode.optional(decode.string))
      decode.success(#(ps, st))
    })
    |> pog.execute(conn)
  ev_check.rows |> should.equal([#("usgs", Some("reviewed"))])

  // 3. JMA sends a cancellation telegram
  let cancel_sent_rfc =
    timestamp.from_unix_seconds(now_sec + 60)
    |> timestamp.to_rfc3339(calendar.utc_offset)
  let cancel_msg =
    models_jma.JmaMessageContent(
      identifier: "20260921040100_VXSE53_cancel",
      control_title: "震源・震度に関する情報",
      status: "通常",
      info_type: "取消",
      event_id: Some("jma-tokyo-50"),
      series_key: Some("震源・震度に関する情報:気象庁:jma-tokyo-50"),
      sent: cancel_sent_rfc,
      effective: None,
      expires: None,
      headline: Some("JMA取消"),
      description: Some("JMA誤報のため取消"),
      areas: [],
      alerts: [],
      cleared_areas: [],
      earthquake: None,
    )
  let cancel_res =
    models_jma.JmaFetchResult(
      item_url: "https://example.com/xml/jma_cancel_50.xml",
      feed_url: "https://example.com/feed/eqvol.xml",
      fetched_at: cancel_sent_rfc,
      http_status: 200,
      error: None,
      raw_xml: Some("<xml>cancel</xml>"),
      message: Some(cancel_msg),
    )
  let assert Ok(cancel_write) =
    jma_message_writer.write_batch([cancel_res], now, conn)
  cancel_write.written |> should.equal(1)
  // Because USGS survived, resync_earthquakes is False
  cancel_write.resync_earthquakes |> should.equal(False)

  // Verify: JMA row in sea.earthquake is 'deleted', USGS row is intact
  let assert Ok(eq_rows) =
    pog.query("SELECT source, status FROM sea.earthquake ORDER BY source")
    |> pog.returning({
      use s <- decode.field(0, decode.string)
      use st <- decode.field(1, decode.optional(decode.string))
      decode.success(#(s, st))
    })
    |> pog.execute(conn)
  eq_rows.rows
  |> should.equal([#("jma", Some("deleted")), #("usgs", Some("reviewed"))])

  // Verify: Canonical event in sea.event SURVIVED and is NOT deleted!
  let assert Ok(event_survived) =
    pog.query("SELECT preferred_source, status FROM sea.event")
    |> pog.returning({
      use ps <- decode.field(0, decode.string)
      use st <- decode.field(1, decode.optional(decode.string))
      decode.success(#(ps, st))
    })
    |> pog.execute(conn)
  event_survived.rows |> should.equal([#("usgs", Some("reviewed"))])
}

// 6. duplicate input & same-batch duplicate index counts
pub fn jma_duplicate_input_and_same_batch_counts_test() {
  use conn <- test_db.with_test_db
  let now = timestamp.system_time()

  let item_a =
    models_jma.JmaIndexItem(
      item_url: "https://example.com/xml/itemA.xml",
      feed_url: "https://example.com/feed/extra.xml",
      guid: Some("guid-A"),
      title: Some("Title A"),
      published: Some("2026-09-21T01:00:00Z"),
    )
  let item_b =
    models_jma.JmaIndexItem(
      item_url: "https://example.com/xml/itemB.xml",
      feed_url: "https://example.com/feed/extra.xml",
      guid: Some("guid-B"),
      title: Some("Title B"),
      published: Some("2026-09-21T01:05:00Z"),
    )

  // Batch containing itemA twice and itemB once: total 3 received
  let assert Ok(ack1) =
    jma_item_writer.write_index([item_a, item_a, item_b], 3, 0, now, conn)
  ack1.received |> should.equal(3)
  ack1.written |> should.equal(2)
  ack1.deduped |> should.equal(1)

  // Second batch re-sending itemA and itemB: both already exist in DB
  let assert Ok(ack2) =
    jma_item_writer.write_index([item_a, item_b], 2, 0, now, conn)
  ack2.received |> should.equal(2)
  ack2.written |> should.equal(0)
  ack2.deduped |> should.equal(2)
}

// 7. bodyless cancellation scope: cancels only alerts matching series_key
pub fn jma_bodyless_cancellation_scope_test() {
  use conn <- test_db.with_test_db
  let now = timestamp.system_time()

  // Alert 1: Tokyo series
  let alert_tokyo =
    models_jma.JmaAlertItem(
      lifecycle_key: "130000:大雨警報",
      area_name: "東京地方",
      geocode: "130000",
      event: "大雨警報",
      category: Some("Met"),
      status: "発表",
      severity: "Severe",
      urgency: "Expected",
      certainty: "Observed",
    )
  let msg_tokyo =
    models_jma.JmaMessageContent(
      identifier: "20260921050000_VPWW53_tokyo",
      control_title: "気象警報・注意報",
      status: "通常",
      info_type: "発表",
      event_id: None,
      series_key: Some("気象警報・注意報:東京管区気象台:130000"),
      sent: "2026-09-21T05:00:00+09:00",
      effective: Some("2026-09-21T05:00:00+09:00"),
      expires: None,
      headline: Some("東京大雨"),
      description: Some("東京"),
      areas: [models_jma.JmaArea(area_name: "東京地方", geocode: "130000")],
      alerts: [alert_tokyo],
      cleared_areas: [],
      earthquake: None,
    )
  let res_tokyo =
    models_jma.JmaFetchResult(
      item_url: "https://example.com/xml/alert_tokyo.xml",
      feed_url: "https://example.com/feed/extra.xml",
      fetched_at: "2026-09-21T05:00:05Z",
      http_status: 200,
      error: None,
      raw_xml: Some("<xml>tokyo</xml>"),
      message: Some(msg_tokyo),
    )

  // Alert 2: Yokohama series
  let alert_yokohama =
    models_jma.JmaAlertItem(
      lifecycle_key: "140000:大雨警報",
      area_name: "神奈川地方",
      geocode: "140000",
      event: "大雨警報",
      category: Some("Met"),
      status: "発表",
      severity: "Severe",
      urgency: "Expected",
      certainty: "Observed",
    )
  let msg_yokohama =
    models_jma.JmaMessageContent(
      identifier: "20260921050000_VPWW53_yokohama",
      control_title: "気象警報・注意報",
      status: "通常",
      info_type: "発表",
      event_id: None,
      series_key: Some("気象警報・注意報:横浜地方気象台:140000"),
      sent: "2026-09-21T05:00:00+09:00",
      effective: Some("2026-09-21T05:00:00+09:00"),
      expires: None,
      headline: Some("横浜大雨"),
      description: Some("横浜"),
      areas: [models_jma.JmaArea(area_name: "神奈川地方", geocode: "140000")],
      alerts: [alert_yokohama],
      cleared_areas: [],
      earthquake: None,
    )
  let res_yokohama =
    models_jma.JmaFetchResult(
      item_url: "https://example.com/xml/alert_yokohama.xml",
      feed_url: "https://example.com/feed/extra.xml",
      fetched_at: "2026-09-21T05:00:05Z",
      http_status: 200,
      error: None,
      raw_xml: Some("<xml>yokohama</xml>"),
      message: Some(msg_yokohama),
    )

  let assert Ok(_) =
    jma_message_writer.write_batch([res_tokyo, res_yokohama], now, conn)

  // Bodyless cancellation bulletin ONLY for Tokyo series
  let cancel_tokyo_msg =
    models_jma.JmaMessageContent(
      identifier: "20260921051000_VPWW53_tokyo_cancel",
      control_title: "気象警報・注意報",
      status: "通常",
      info_type: "取消",
      event_id: None,
      series_key: Some("気象警報・注意報:東京管区気象台:130000"),
      sent: "2026-09-21T05:10:00+09:00",
      effective: None,
      expires: None,
      headline: Some("東京取消"),
      description: Some("東京取消"),
      areas: [],
      alerts: [],
      cleared_areas: [],
      earthquake: None,
    )
  let cancel_tokyo_res =
    models_jma.JmaFetchResult(
      item_url: "https://example.com/xml/cancel_tokyo.xml",
      feed_url: "https://example.com/feed/extra.xml",
      fetched_at: "2026-09-21T05:10:05Z",
      http_status: 200,
      error: None,
      raw_xml: Some("<xml>cancel</xml>"),
      message: Some(cancel_tokyo_msg),
    )
  let assert Ok(cancel_write) =
    jma_message_writer.write_batch([cancel_tokyo_res], now, conn)
  list.length(cancel_write.alert_diff.ended) |> should.equal(1)

  // Tokyo alert is cancelled
  let assert Ok(tokyo_check) =
    pog.query(
      "SELECT (CASE WHEN ended_at IS NOT NULL THEN 'ended' ELSE NULL END), end_reason FROM sea.alert WHERE source_id = '気象警報・注意報:東京管区気象台:130000:大雨警報'",
    )
    |> pog.returning({
      use ea <- decode.field(0, decode.optional(decode.string))
      use er <- decode.field(1, decode.optional(decode.string))
      decode.success(#(ea, er))
    })
    |> pog.execute(conn)
  case tokyo_check.rows {
    [#(Some(_), Some("cancelled"))] -> True |> should.equal(True)
    _ -> False |> should.equal(True)
  }

  // Yokohama alert is UNTOUCHED (still active)
  let assert Ok(yokohama_check) =
    pog.query(
      "SELECT ended_at FROM sea.alert WHERE source_id = '気象警報・注意報:横浜地方気象台:140000:大雨警報'",
    )
    |> pog.returning(decode.at([0], decode.optional(decode.string)))
    |> pog.execute(conn)
  yokohama_check.rows |> should.equal([None])
}

// 8. integer number decode
pub fn jma_integer_number_decode_integration_test() {
  let json_str =
    "{\"features\": [
        {
          \"item_url\": \"https://example.com/xml/int_eq.xml\",
          \"feed_url\": \"https://example.com/feed/eqvol.xml\",
          \"fetched_at\": \"2026-09-21T05:00:00Z\",
          \"http_status\": 200,
          \"message\": {
            \"identifier\": \"20260921050000_VXSE53_int\",
            \"control_title\": \"震源・震度に関する情報\",
            \"status\": \"通常\",
            \"info_type\": \"発表\",
            \"sent\": \"2026-09-21T05:00:00+09:00\",
            \"earthquake\": {
              \"origin_time\": \"2026-09-21T04:55:00+09:00\",
              \"latitude\": 36,
              \"longitude\": 140,
              \"depth_km\": 20,
              \"magnitude\": 5
            }
          }
        }
      ]}"

  let assert Ok(dyn) = json.parse(json_str, decode.dynamic)
  let assert Ok(#(_meta, items, received, dropped)) =
    models_jma.decode_messages_body(dyn)

  received |> should.equal(1)
  dropped |> should.equal(0)
  let assert [res] = items
  let assert Some(msg) = res.message
  let assert Some(eq) = msg.earthquake
  eq.latitude |> should.equal(Some(36.0))
  eq.longitude |> should.equal(Some(140.0))
  eq.depth_km |> should.equal(Some(20.0))
  eq.magnitude |> should.equal(Some(5.0))
}

// 9. terminal errors removed from pending / raw preserved
pub fn jma_terminal_errors_removed_from_pending_test() {
  use conn <- test_db.with_test_db
  let now = timestamp.system_time()

  let item_404 =
    models_jma.JmaIndexItem(
      item_url: "https://example.com/xml/item_404.xml",
      feed_url: "https://example.com/feed/extra.xml",
      guid: Some("guid-404"),
      title: Some("404 item"),
      published: Some("2026-09-21T06:00:00Z"),
    )
  let item_parse =
    models_jma.JmaIndexItem(
      item_url: "https://example.com/xml/item_parse.xml",
      feed_url: "https://example.com/feed/extra.xml",
      guid: Some("guid-parse"),
      title: Some("Parse error item"),
      published: Some("2026-09-21T06:01:00Z"),
    )
  let item_500 =
    models_jma.JmaIndexItem(
      item_url: "https://example.com/xml/item_500.xml",
      feed_url: "https://example.com/feed/extra.xml",
      guid: Some("guid-500"),
      title: Some("500 retry item"),
      published: Some("2026-09-21T06:02:00Z"),
    )

  // 1. Initial write to index (all 3 become pending)
  let assert Ok(_) =
    jma_item_writer.write_index(
      [item_404, item_parse, item_500],
      3,
      0,
      now,
      conn,
    )

  // 2. Fetch results: 404 terminal, 200 with XML parse error (terminal), 500 transient
  let res_404 =
    models_jma.JmaFetchResult(
      item_url: "https://example.com/xml/item_404.xml",
      feed_url: "https://example.com/feed/extra.xml",
      fetched_at: "2026-09-21T06:05:00Z",
      http_status: 404,
      error: Some("Not Found"),
      raw_xml: None,
      message: None,
    )
  let res_parse =
    models_jma.JmaFetchResult(
      item_url: "https://example.com/xml/item_parse.xml",
      feed_url: "https://example.com/feed/extra.xml",
      fetched_at: "2026-09-21T06:05:00Z",
      http_status: 200,
      error: Some("XML parse error: unclosed tag"),
      raw_xml: Some("<broken_xml>"),
      message: None,
    )
  let res_500 =
    models_jma.JmaFetchResult(
      item_url: "https://example.com/xml/item_500.xml",
      feed_url: "https://example.com/feed/extra.xml",
      fetched_at: "2026-09-21T06:05:00Z",
      http_status: 500,
      error: Some("Internal Server Error"),
      raw_xml: None,
      message: None,
    )

  let assert Ok(batch_res) =
    jma_message_writer.write_batch([res_404, res_parse, res_500], now, conn)
  batch_res.written |> should.equal(2)
  batch_res.dropped |> should.equal(1)
  batch_res.deduped |> should.equal(0)

  // Verify terminal states and raw_xml preserved in DB
  let assert Ok(item_rows) =
    pog.query(
      "SELECT item_url, state, raw_xml FROM sea.jma_item ORDER BY item_url",
    )
    |> pog.returning({
      use url <- decode.field(0, decode.string)
      use st <- decode.field(1, decode.string)
      use rx <- decode.field(2, decode.optional(decode.string))
      decode.success(#(url, st, rx))
    })
    |> pog.execute(conn)
  item_rows.rows
  |> should.equal([
    #("https://example.com/xml/item_404.xml", "terminal", None),
    #("https://example.com/xml/item_500.xml", "failed", None),
    #(
      "https://example.com/xml/item_parse.xml",
      "terminal",
      Some("<broken_xml>"),
    ),
  ])

  // Verify /pending returns ONLY the transient 500 failure once retry interval elapses!
  let future_now = timestamp.add(now, duration.seconds(400))
  let assert Ok(pending_items) = jma_item_writer.pending(10, future_now, conn)
  list.length(pending_items) |> should.equal(1)
  let assert [pending_item] = pending_items
  pending_item.item_url |> should.equal("https://example.com/xml/item_500.xml")

  // Re-reporting terminal 404 should dedupe (written = 0, deduped = 1)
  let assert Ok(dup_res) = jma_message_writer.write_batch([res_404], now, conn)
  dup_res.written |> should.equal(0)
  dup_res.deduped |> should.equal(1)
}

// 10. SSE resync reconnect behavior
pub fn jma_sse_resync_reconnect_behavior_test() {
  let assert Ok(hub) = earthquake_hub.start()
  let subject_a = process.new_subject()

  // Client A subscribes without 'since'
  let _sub_a_id = earthquake_hub.subscribe(hub.data, subject_a, None)
  let assert Ok(earthquake_hub.Heartbeat(initial_id)) =
    process.receive(subject_a, 1000)

  // Trigger ResyncAll
  earthquake_hub.resync_all(hub.data)

  // Client A receives Resync with new rotated epoch ID
  let assert Ok(earthquake_hub.Resync(rotated_id)) =
    process.receive(subject_a, 1000)
  should.be_true(rotated_id != initial_id)

  // Client B connects reconnecting with old cursor 'initial_id'
  let subject_b = process.new_subject()
  let _sub_b_id =
    earthquake_hub.subscribe(hub.data, subject_b, Some(initial_id))
  let assert Ok(earthquake_hub.Resync(b_resync_id)) =
    process.receive(subject_b, 1000)
  b_resync_id |> should.equal(rotated_id)
}

// 11. Deterministic tie-breaking policy test
pub fn jma_tie_breaking_policy_test() {
  use conn <- test_db.with_test_db
  let now = timestamp.system_time()

  // Tie test 1: Cancellation beats publication at exact same timestamp
  let pub_msg =
    models_jma.JmaMessageContent(
      identifier: "20260921070000_VPWW53_01",
      control_title: "気象警報・注意報",
      status: "通常",
      info_type: "発表",
      event_id: None,
      series_key: Some("気象警報・注意報:東京管区気象台:tie_test"),
      sent: "2026-09-21T07:00:00+09:00",
      effective: Some("2026-09-21T07:00:00+09:00"),
      expires: None,
      headline: Some("通常発表"),
      description: Some("通常"),
      areas: [],
      alerts: [],
      cleared_areas: [],
      earthquake: None,
    )
  let pub_res =
    models_jma.JmaFetchResult(
      item_url: "https://example.com/xml/tie_pub.xml",
      feed_url: "https://example.com/feed/extra.xml",
      fetched_at: "2026-09-21T07:00:05Z",
      http_status: 200,
      error: None,
      raw_xml: Some("<xml>pub</xml>"),
      message: Some(pub_msg),
    )
  let assert Ok(_) = jma_message_writer.write_batch([pub_res], now, conn)

  // Cancellation arrives with exact same sent timestamp: wins!
  let cancel_tie_msg =
    models_jma.JmaMessageContent(
      identifier: "20260921070000_VPWW53_02",
      control_title: "気象警報・注意報",
      status: "通常",
      info_type: "取消",
      event_id: None,
      series_key: Some("気象警報・注意報:東京管区気象台:tie_test"),
      sent: "2026-09-21T07:00:00+09:00",
      effective: None,
      expires: None,
      headline: Some("取消"),
      description: Some("取消"),
      areas: [],
      alerts: [],
      cleared_areas: [],
      earthquake: None,
    )
  let cancel_tie_res =
    models_jma.JmaFetchResult(
      item_url: "https://example.com/xml/tie_cancel.xml",
      feed_url: "https://example.com/feed/extra.xml",
      fetched_at: "2026-09-21T07:00:05Z",
      http_status: 200,
      error: None,
      raw_xml: Some("<xml>cancel</xml>"),
      message: Some(cancel_tie_msg),
    )
  let assert Ok(tie_cancel_write) =
    jma_message_writer.write_batch([cancel_tie_res], now, conn)
  tie_cancel_write.written |> should.equal(1)

  // Another publication at same timestamp arrives: rejected because cancellation beat it
  let pub_tie_late_msg =
    models_jma.JmaMessageContent(
      identifier: "20260921070000_VPWW53_03",
      control_title: "気象警報・注意報",
      status: "通常",
      info_type: "発表",
      event_id: None,
      series_key: Some("気象警報・注意報:東京管区気象台:tie_test"),
      sent: "2026-09-21T07:00:00+09:00",
      effective: Some("2026-09-21T07:00:00+09:00"),
      expires: None,
      headline: Some("再発表"),
      description: Some("再発表"),
      areas: [],
      alerts: [],
      cleared_areas: [],
      earthquake: None,
    )
  let pub_tie_late_res =
    models_jma.JmaFetchResult(
      item_url: "https://example.com/xml/tie_pub_late.xml",
      feed_url: "https://example.com/feed/extra.xml",
      fetched_at: "2026-09-21T07:00:05Z",
      http_status: 200,
      error: None,
      raw_xml: Some("<xml>pub</xml>"),
      message: Some(pub_tie_late_msg),
    )
  let assert Ok(late_pub_write) =
    jma_message_writer.write_batch([pub_tie_late_res], now, conn)
  late_pub_write.written |> should.equal(1)
  late_pub_write.dropped |> should.equal(0)
  late_pub_write.alert_diff.new |> should.equal([])
  late_pub_write.alert_diff.updated |> should.equal([])
}

fn usgs_incoming(
  id: String,
  time_ms: Int,
  updated_ms: Int,
  lat: Float,
  lon: Float,
  mag: Float,
) -> record.Incoming(earthquake_feature.IncomingEarthquake) {
  record.Incoming(
    key: record.Key("usgs", id),
    revision: updated_ms,
    payload: earthquake_feature.IncomingEarthquake(
      source_id: id,
      ids: [id],
      sources: ["us"],
      net: Some("us"),
      code: Some(id),
      mag: Some(mag),
      mag_type: Some("mww"),
      time: time_ms,
      updated: updated_ms,
      place: Some("Tokyo Bay"),
      title: Some("M 5.0 Tokyo Bay"),
      status: Some("reviewed"),
      type_: Some("earthquake"),
      tsunami: None,
      sig: None,
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
      lon:,
      lat:,
      depth: Some(10.0),
      raw: "{\"type\":\"Feature\",\"id\":\"" <> id <> "\"}",
    ),
  )
}

// Cleared areas: two municipalities alerts -> one cleared
pub fn jma_cleared_areas_one_of_two_cleared_test() {
  use conn <- test_db.with_test_db
  let now = timestamp.system_time()

  // Two alerts in the same series: Area 1 (1310100) and Area 2 (1310200)
  let alert1 =
    models_jma.JmaAlertItem(
      lifecycle_key: "1310100:大雨警報",
      area_name: "千代田区",
      geocode: "1310100",
      event: "大雨警報",
      category: Some("Met"),
      status: "発表",
      severity: "Severe",
      urgency: "Expected",
      certainty: "Observed",
    )
  let alert2 =
    models_jma.JmaAlertItem(
      lifecycle_key: "1310200:大雨警報",
      area_name: "中央区",
      geocode: "1310200",
      event: "大雨警報",
      category: Some("Met"),
      status: "発表",
      severity: "Severe",
      urgency: "Expected",
      certainty: "Observed",
    )
  let msg1 =
    models_jma.JmaMessageContent(
      identifier: "20260921080000_VPWW53_01",
      control_title: "気象警報・注意報",
      status: "通常",
      info_type: "発表",
      event_id: None,
      series_key: Some("気象警報・注意報:東京管区気象台:130000"),
      sent: "2026-09-21T08:00:00+09:00",
      effective: Some("2026-09-21T08:00:00+09:00"),
      expires: None,
      headline: Some("大雨警報発表"),
      description: Some("大雨警報"),
      areas: [
        models_jma.JmaArea(area_name: "千代田区", geocode: "1310100"),
        models_jma.JmaArea(area_name: "中央区", geocode: "1310200"),
      ],
      alerts: [alert1, alert2],
      cleared_areas: [],
      earthquake: None,
    )
  let res1 =
    models_jma.JmaFetchResult(
      item_url: "https://example.com/xml/alert_two_areas.xml",
      feed_url: "https://example.com/feed/extra.xml",
      fetched_at: "2026-09-21T08:00:05Z",
      http_status: 200,
      error: None,
      raw_xml: Some("<xml>two areas</xml>"),
      message: Some(msg1),
    )
  let assert Ok(write1) = jma_message_writer.write_batch([res1], now, conn)
  list.length(write1.alert_diff.new) |> should.equal(1)
  // merged into 1

  // Bulletin 2 at 08:30: cleared_areas contains ["1310100"] (千代田区 is cleared)
  // JMA always resends active warnings, so Area 2 is still in alerts.
  let msg2 =
    models_jma.JmaMessageContent(
      identifier: "20260921083000_VPWW53_02",
      control_title: "気象警報・注意報",
      status: "通常",
      info_type: "発表",
      event_id: None,
      series_key: Some("気象警報・注意報:東京管区気象台:130000"),
      sent: "2026-09-21T08:30:00+09:00",
      effective: Some("2026-09-21T08:30:00+09:00"),
      expires: None,
      headline: Some("千代田区警報解除"),
      description: Some("千代田区は警報解除"),
      areas: [models_jma.JmaArea(area_name: "中央区", geocode: "1310200")],
      alerts: [alert2],
      cleared_areas: ["1310100"],
      earthquake: None,
    )
  let res2 =
    models_jma.JmaFetchResult(
      item_url: "https://example.com/xml/alert_clear_one.xml",
      feed_url: "https://example.com/feed/extra.xml",
      fetched_at: "2026-09-21T08:30:05Z",
      http_status: 200,
      error: None,
      raw_xml: Some("<xml>clear one</xml>"),
      message: Some(msg2),
    )
  let assert Ok(write2) = jma_message_writer.write_batch([res2], now, conn)
  // Because it's merged, we don't end an alert, we update it.
  list.length(write2.alert_diff.ended) |> should.equal(0)
  list.length(write2.alert_diff.updated) |> should.equal(1)

  // Check DB: The alert should still be active, but only cover Area 2.
  let assert Ok(check_a2) =
    pog.query(
      "SELECT ended_at, area_desc FROM sea.alert WHERE source_id = '気象警報・注意報:東京管区気象台:130000:大雨警報'",
    )
    |> pog.returning({
      use ea <- decode.field(0, decode.optional(decode.string))
      use ad <- decode.field(1, decode.string)
      decode.success(#(ea, ad))
    })
    |> pog.execute(conn)
  check_a2.rows |> should.equal([#(None, "中央区")])

  // Duplicate clear replay should early return with deduped = 1 and 0 side effects
  let assert Ok(write_dup) = jma_message_writer.write_batch([res2], now, conn)
  write_dup.written |> should.equal(0)
  write_dup.deduped |> should.equal(1)
  write_dup.alert_diff.updated |> should.equal([])
}

// Cleared areas: stale clear ignored and clear before old issue blocks resurrection
pub fn jma_cleared_areas_watermark_and_resurrection_fencing_test() {
  use conn <- test_db.with_test_db
  let now = timestamp.system_time()

  // 1. Issue warning at 09:00
  let alert_a =
    models_jma.JmaAlertItem(
      lifecycle_key: "1310300:大雨警報",
      area_name: "港区",
      geocode: "1310300",
      event: "大雨警報",
      category: Some("Met"),
      status: "発表",
      severity: "Severe",
      urgency: "Expected",
      certainty: "Observed",
    )
  let msg1 =
    models_jma.JmaMessageContent(
      identifier: "20260921090000_VPWW53_01",
      control_title: "気象警報・注意報",
      status: "通常",
      info_type: "発表",
      event_id: None,
      series_key: Some("気象警報・注意報:東京管区気象台:130000"),
      sent: "2026-09-21T09:00:00+09:00",
      effective: Some("2026-09-21T09:00:00+09:00"),
      expires: None,
      headline: Some("大雨警報"),
      description: Some("大雨"),
      areas: [models_jma.JmaArea(area_name: "港区", geocode: "1310300")],
      alerts: [alert_a],
      cleared_areas: [],
      earthquake: None,
    )
  let res1 =
    models_jma.JmaFetchResult(
      item_url: "https://example.com/xml/alert_minato.xml",
      feed_url: "https://example.com/feed/extra.xml",
      fetched_at: "2026-09-21T09:00:05Z",
      http_status: 200,
      error: None,
      raw_xml: Some("<xml>minato</xml>"),
      message: Some(msg1),
    )
  let assert Ok(_) = jma_message_writer.write_batch([res1], now, conn)

  // 2. Delayed STALE clear arrives at sent = 08:50 (< 09:00)
  let stale_clear_msg =
    models_jma.JmaMessageContent(
      identifier: "20260921085000_VPWW53_stale_clear",
      control_title: "気象警報・注意報",
      status: "通常",
      info_type: "発表",
      event_id: None,
      series_key: Some("気象警報・注意報:東京管区気象台:130000"),
      sent: "2026-09-21T08:50:00+09:00",
      effective: None,
      expires: None,
      headline: Some("過去解除"),
      description: Some("過去解除"),
      areas: [],
      alerts: [],
      cleared_areas: ["1310300"],
      earthquake: None,
    )
  let stale_clear_res =
    models_jma.JmaFetchResult(
      item_url: "https://example.com/xml/stale_clear.xml",
      feed_url: "https://example.com/feed/extra.xml",
      fetched_at: "2026-09-21T09:05:05Z",
      http_status: 200,
      error: None,
      raw_xml: Some("<xml>stale clear</xml>"),
      message: Some(stale_clear_msg),
    )
  let assert Ok(stale_write) =
    jma_message_writer.write_batch([stale_clear_res], now, conn)
  // Stale watermark rejected from live mutation, but telegram is durably archived!
  stale_write.written |> should.equal(1)
  stale_write.dropped |> should.equal(0)
  stale_write.alert_diff.ended |> should.equal([])

  // Alert is STILL active in DB
  let assert Ok(check_still_active) =
    pog.query(
      "SELECT ended_at FROM sea.alert WHERE source_id = '気象警報・注意報:東京管区気象台:130000:大雨警報'",
    )
    |> pog.returning(decode.at([0], decode.optional(decode.string)))
    |> pog.execute(conn)
  check_still_active.rows |> should.equal([None])

  // 3. Proper clear arrives at 09:30
  let clear_msg =
    models_jma.JmaMessageContent(
      identifier: "20260921093000_VPWW53_02",
      control_title: "気象警報・注意報",
      status: "通常",
      info_type: "発表",
      event_id: None,
      series_key: Some("気象警報・注意報:東京管区気象台:130000"),
      sent: "2026-09-21T09:30:00+09:00",
      effective: None,
      expires: None,
      headline: Some("解除"),
      description: Some("解除"),
      areas: [],
      alerts: [],
      cleared_areas: ["1310300"],
      earthquake: None,
    )
  let clear_res =
    models_jma.JmaFetchResult(
      item_url: "https://example.com/xml/valid_clear.xml",
      feed_url: "https://example.com/feed/extra.xml",
      fetched_at: "2026-09-21T09:30:05Z",
      http_status: 200,
      error: None,
      raw_xml: Some("<xml>clear</xml>"),
      message: Some(clear_msg),
    )
  let assert Ok(clear_write) =
    jma_message_writer.write_batch([clear_res], now, conn)
  list.length(clear_write.alert_diff.ended) |> should.equal(1)

  // 4. Delayed older bulletin from 09:20 arrives trying to issue warning for 1310300
  let delayed_issue_msg =
    models_jma.JmaMessageContent(
      identifier: "20260921092000_VPWW53_delayed",
      control_title: "気象警報・注意報",
      status: "通常",
      info_type: "発表",
      event_id: None,
      series_key: Some("気象警報・注意報:東京管区気象台:130000"),
      sent: "2026-09-21T09:20:00+09:00",
      effective: Some("2026-09-21T09:20:00+09:00"),
      expires: None,
      headline: Some("遅延発行"),
      description: Some("遅延発行"),
      areas: [models_jma.JmaArea(area_name: "港区", geocode: "1310300")],
      alerts: [alert_a],
      cleared_areas: [],
      earthquake: None,
    )
  let delayed_issue_res =
    models_jma.JmaFetchResult(
      item_url: "https://example.com/xml/delayed_issue.xml",
      feed_url: "https://example.com/feed/extra.xml",
      fetched_at: "2026-09-21T09:35:05Z",
      http_status: 200,
      error: None,
      raw_xml: Some("<xml>delayed</xml>"),
      message: Some(delayed_issue_msg),
    )
  let assert Ok(delayed_write) =
    jma_message_writer.write_batch([delayed_issue_res], now, conn)
  // Watermark rejects stale older bulletin from live mutation, but telegram is durably archived!
  delayed_write.written |> should.equal(1)
  delayed_write.dropped |> should.equal(0)
  delayed_write.alert_diff.new |> should.equal([])
  delayed_write.alert_diff.updated |> should.equal([])

  // Verify alert is STILL cancelled
  let assert Ok(check_resurrection) =
    pog.query(
      "SELECT (CASE WHEN ended_at IS NOT NULL THEN 'ended' ELSE NULL END), end_reason FROM sea.alert WHERE source_id = '気象警報・注意報:東京管区気象台:130000:大雨警報'",
    )
    |> pog.returning({
      use ea <- decode.field(0, decode.optional(decode.string))
      use er <- decode.field(1, decode.optional(decode.string))
      decode.success(#(ea, er))
    })
    |> pog.execute(conn)
  case check_resurrection.rows {
    [#(Some(_), Some("cancelled"))] -> True |> should.equal(True)
    _ -> False |> should.equal(True)
  }
}

// Cleared areas: drill clear has no effect on live alerts
pub fn jma_drill_clear_does_not_affect_live_alerts_test() {
  use conn <- test_db.with_test_db
  let now = timestamp.system_time()

  // 1. Live alert
  let alert1 =
    models_jma.JmaAlertItem(
      lifecycle_key: "1310400:大雨警報",
      area_name: "新宿区",
      geocode: "1310400",
      event: "大雨警報",
      category: Some("Met"),
      status: "発表",
      severity: "Severe",
      urgency: "Expected",
      certainty: "Observed",
    )
  let live_msg =
    models_jma.JmaMessageContent(
      identifier: "20260921100000_VPWW53_01",
      control_title: "気象警報・注意報",
      status: "通常",
      info_type: "発表",
      event_id: None,
      series_key: Some("気象警報・注意報:東京管区気象台:130000"),
      sent: "2026-09-21T10:00:00+09:00",
      effective: Some("2026-09-21T10:00:00+09:00"),
      expires: None,
      headline: Some("大雨警報"),
      description: Some("新宿区大雨"),
      areas: [models_jma.JmaArea(area_name: "新宿区", geocode: "1310400")],
      alerts: [alert1],
      cleared_areas: [],
      earthquake: None,
    )
  let live_res =
    models_jma.JmaFetchResult(
      item_url: "https://example.com/xml/live_shinjuku.xml",
      feed_url: "https://example.com/feed/extra.xml",
      fetched_at: "2026-09-21T10:00:05Z",
      http_status: 200,
      error: None,
      raw_xml: Some("<xml>live</xml>"),
      message: Some(live_msg),
    )
  let assert Ok(_) = jma_message_writer.write_batch([live_res], now, conn)

  // 2. Drill bulletin with cleared_areas: ["1310400"]
  let drill_msg =
    models_jma.JmaMessageContent(
      identifier: "20260921100500_VPWW53_drill_clear",
      control_title: "気象警報・注意報",
      status: "訓練",
      info_type: "発表",
      event_id: None,
      series_key: Some("気象警報・注意報:東京管区気象台:130000"),
      sent: "2026-09-21T10:05:00+09:00",
      effective: None,
      expires: None,
      headline: Some("訓練：解除"),
      description: Some("訓練解除"),
      areas: [],
      alerts: [],
      cleared_areas: ["1310400"],
      earthquake: None,
    )
  let drill_res =
    models_jma.JmaFetchResult(
      item_url: "https://example.com/xml/drill_clear.xml",
      feed_url: "https://example.com/feed/extra.xml",
      fetched_at: "2026-09-21T10:05:05Z",
      http_status: 200,
      error: None,
      raw_xml: Some("<xml>drill clear</xml>"),
      message: Some(drill_msg),
    )
  let assert Ok(drill_write) =
    jma_message_writer.write_batch([drill_res], now, conn)
  drill_write.written |> should.equal(1)
  drill_write.alert_diff.ended |> should.equal([])

  // Live alert is STILL ACTIVE
  let assert Ok(check_active) =
    pog.query(
      "SELECT ended_at FROM sea.alert WHERE source_id = '気象警報・注意報:東京管区気象台:130000:大雨警報'",
    )
    |> pog.returning(decode.at([0], decode.optional(decode.string)))
    |> pog.execute(conn)
  check_active.rows |> should.equal([None])
}

// Quake + tsunami cancellation test: tsunami 取消 with same event_id does NOT remove quake or advance quake watermark
pub fn jma_tsunami_cancel_leaves_earthquake_intact_test() {
  use conn <- test_db.with_test_db
  let now = timestamp.system_time()

  // 1. Ingest real earthquake with event_id: "eq-shared-tsunami-01"
  let eq =
    models_jma.JmaEarthquake(
      origin_time: "2026-09-21T11:00:00+09:00",
      latitude: Some(35.68),
      longitude: Some(139.76),
      depth_km: Some(10.0),
      magnitude: Some(5.0),
      magnitude_type: Some("Mj"),
      place: Some("東京湾"),
      max_intensity: Some("3"),
    )
  let eq_msg =
    models_jma.JmaMessageContent(
      identifier: "20260921110500_VXSE53_01",
      control_title: "震源・震度に関する情報",
      status: "通常",
      info_type: "発表",
      event_id: Some("eq-shared-tsunami-01"),
      series_key: Some("震源・震度に関する情報:気象庁:eq-shared-tsunami-01"),
      sent: "2026-09-21T11:05:00+09:00",
      effective: Some("2026-09-21T11:05:00+09:00"),
      expires: None,
      headline: Some("東京湾地震"),
      description: Some("東京湾地震"),
      areas: [],
      alerts: [],
      cleared_areas: [],
      earthquake: Some(eq),
    )
  let eq_res =
    models_jma.JmaFetchResult(
      item_url: "https://example.com/xml/shared_eq.xml",
      feed_url: "https://example.com/feed/eqvol.xml",
      fetched_at: "2026-09-21T11:05:05Z",
      http_status: 200,
      error: None,
      raw_xml: Some("<xml>quake</xml>"),
      message: Some(eq_msg),
    )
  let assert Ok(_) = jma_message_writer.write_batch([eq_res], now, conn)

  // 2. Ingest a TSUNAMI cancellation telegram with the exact same event_id: "eq-shared-tsunami-01"
  let tsunami_cancel_msg =
    models_jma.JmaMessageContent(
      identifier: "20260921111500_VTSE41_cancel",
      control_title: "津波警報・注意報・予報",
      status: "通常",
      info_type: "取消",
      event_id: Some("eq-shared-tsunami-01"),
      series_key: Some("津波警報・注意報・予報:気象庁:eq-shared-tsunami-01"),
      sent: "2026-09-21T11:15:00+09:00",
      effective: None,
      expires: None,
      headline: Some("津波注意報解除"),
      description: Some("津波注意報を取り消します"),
      areas: [],
      alerts: [],
      cleared_areas: [],
      earthquake: None,
    )
  let tsunami_cancel_res =
    models_jma.JmaFetchResult(
      item_url: "https://example.com/xml/tsunami_cancel.xml",
      feed_url: "https://example.com/feed/eqvol.xml",
      fetched_at: "2026-09-21T11:15:05Z",
      http_status: 200,
      error: None,
      raw_xml: Some("<xml>tsunami cancel</xml>"),
      message: Some(tsunami_cancel_msg),
    )
  let assert Ok(tsunami_write) =
    jma_message_writer.write_batch([tsunami_cancel_res], now, conn)
  tsunami_write.written |> should.equal(1)
  tsunami_write.resync_earthquakes |> should.equal(False)

  // Verify: Tsunami telegram metadata is archived in sea.jma_message
  let assert Ok(msg_check) =
    pog.query(
      "SELECT control_title FROM sea.jma_message WHERE identifier = '20260921111500_VTSE41_cancel'",
    )
    |> pog.returning(decode.at([0], decode.string))
    |> pog.execute(conn)
  msg_check.rows |> should.equal(["津波警報・注意報・予報"])

  // CRITICAL VERIFICATION: Earthquake in sea.earthquake is STILL ACTIVE and NOT DELETED!
  let assert Ok(check_eq) =
    pog.query(
      "SELECT status FROM sea.earthquake WHERE source_id = 'eq-shared-tsunami-01'",
    )
    |> pog.returning(decode.at([0], decode.optional(decode.string)))
    |> pog.execute(conn)
  check_eq.rows |> should.equal([None])

  // Quake watermark was NOT cancelled or advanced by tsunami cancel!
  let assert Ok(watermark_check) =
    pog.query(
      "SELECT is_cancelled FROM sea.jma_series WHERE series_key = 'quake:eq-shared-tsunami-01'",
    )
    |> pog.returning(decode.at([0], decode.bool))
    |> pog.execute(conn)
  watermark_check.rows |> should.equal([False])
}

// VXSE51 (震度速報) must archive-only (including 取消) and must NOT alter VXSE53 quake/watermark
pub fn jma_vxse51_archive_only_leaves_earthquake_and_watermark_intact_test() {
  use conn <- test_db.with_test_db
  let now = timestamp.system_time()

  // 1. Ingest real earthquake via VXSE53
  let eq =
    models_jma.JmaEarthquake(
      origin_time: "2026-09-21T12:00:00+09:00",
      latitude: Some(35.68),
      longitude: Some(139.76),
      depth_km: Some(10.0),
      magnitude: Some(5.0),
      magnitude_type: Some("Mj"),
      place: Some("東京湾"),
      max_intensity: Some("3"),
    )
  let eq_msg =
    models_jma.JmaMessageContent(
      identifier: "20260921120500_VXSE53_01",
      control_title: "震源・震度に関する情報",
      status: "通常",
      info_type: "発表",
      event_id: Some("eq-shared-vxse51-01"),
      series_key: Some("震源・震度に関する情報:気象庁:eq-shared-vxse51-01"),
      sent: "2026-09-21T12:05:00+09:00",
      effective: Some("2026-09-21T12:05:00+09:00"),
      expires: None,
      headline: Some("東京湾地震"),
      description: Some("東京湾地震"),
      areas: [],
      alerts: [],
      cleared_areas: [],
      earthquake: Some(eq),
    )
  let eq_res =
    models_jma.JmaFetchResult(
      item_url: "https://example.com/xml/vxse53_shared.xml",
      feed_url: "https://example.com/feed/eqvol.xml",
      fetched_at: "2026-09-21T12:05:05Z",
      http_status: 200,
      error: None,
      raw_xml: Some("<xml>quake</xml>"),
      message: Some(eq_msg),
    )
  let assert Ok(_) = jma_message_writer.write_batch([eq_res], now, conn)

  // 2. Ingest VXSE51 publication with exact same event_id: must archive only
  let vxse51_pub_msg =
    models_jma.JmaMessageContent(
      identifier: "20260921120000_VXSE51_01",
      control_title: "震度速報",
      status: "通常",
      info_type: "発表",
      event_id: Some("eq-shared-vxse51-01"),
      series_key: Some("震度速報:気象庁:eq-shared-vxse51-01"),
      sent: "2026-09-21T12:00:00+09:00",
      effective: Some("2026-09-21T12:00:00+09:00"),
      expires: None,
      headline: Some("震度速報"),
      description: Some("各地の震度"),
      areas: [],
      alerts: [],
      cleared_areas: [],
      earthquake: None,
    )
  let vxse51_pub_res =
    models_jma.JmaFetchResult(
      item_url: "https://example.com/xml/vxse51_pub.xml",
      feed_url: "https://example.com/feed/eqvol.xml",
      fetched_at: "2026-09-21T12:00:05Z",
      http_status: 200,
      error: None,
      raw_xml: Some("<xml>vxse51 pub</xml>"),
      message: Some(vxse51_pub_msg),
    )
  let assert Ok(pub_write) =
    jma_message_writer.write_batch([vxse51_pub_res], now, conn)
  pub_write.written |> should.equal(1)
  pub_write.dropped |> should.equal(0)
  pub_write.resync_earthquakes |> should.equal(False)

  // 3. Ingest VXSE51 cancellation with exact same event_id: must archive only, NOT alter quake
  let vxse51_cancel_msg =
    models_jma.JmaMessageContent(
      identifier: "20260921121000_VXSE51_cancel",
      control_title: "震度速報",
      status: "通常",
      info_type: "取消",
      event_id: Some("eq-shared-vxse51-01"),
      series_key: Some("震度速報:気象庁:eq-shared-vxse51-01"),
      sent: "2026-09-21T12:10:00+09:00",
      effective: None,
      expires: None,
      headline: Some("震度速報取消"),
      description: Some("震度速報を取り消します"),
      areas: [],
      alerts: [],
      cleared_areas: [],
      earthquake: None,
    )
  let vxse51_cancel_res =
    models_jma.JmaFetchResult(
      item_url: "https://example.com/xml/vxse51_cancel.xml",
      feed_url: "https://example.com/feed/eqvol.xml",
      fetched_at: "2026-09-21T12:10:05Z",
      http_status: 200,
      error: None,
      raw_xml: Some("<xml>vxse51 cancel</xml>"),
      message: Some(vxse51_cancel_msg),
    )
  let assert Ok(cancel_write) =
    jma_message_writer.write_batch([vxse51_cancel_res], now, conn)
  cancel_write.written |> should.equal(1)
  cancel_write.dropped |> should.equal(0)
  cancel_write.resync_earthquakes |> should.equal(False)

  // Verify: Both VXSE51 telegrams archived in sea.jma_message
  let assert Ok(msg_check) =
    pog.query(
      "SELECT count(*) FROM sea.jma_message WHERE control_title = '震度速報'",
    )
    |> pog.returning(decode.at([0], decode.int))
    |> pog.execute(conn)
  msg_check.rows |> should.equal([2])

  // Earthquake in sea.earthquake is STILL ACTIVE and untouched
  let assert Ok(check_eq) =
    pog.query(
      "SELECT status FROM sea.earthquake WHERE source_id = 'eq-shared-vxse51-01'",
    )
    |> pog.returning(decode.at([0], decode.optional(decode.string)))
    |> pog.execute(conn)
  check_eq.rows |> should.equal([None])

  // Quake watermark was NOT cancelled or altered
  let assert Ok(watermark_check) =
    pog.query(
      "SELECT is_cancelled FROM sea.jma_series WHERE series_key = 'quake:eq-shared-vxse51-01'",
    )
    |> pog.returning(decode.at([0], decode.bool))
    |> pog.execute(conn)
  watermark_check.rows |> should.equal([False])
}

// Explicit test: accepted archival-only stale telegram ACKs written = 1, dropped = 0 with durable archive
pub fn jma_stale_bulletin_ack_written_with_durable_archive_test() {
  use conn <- test_db.with_test_db
  let now = timestamp.system_time()

  // 1. Initial live alert at 09:00
  let alert1 =
    models_jma.JmaAlertItem(
      lifecycle_key: "1310100:大雨警報",
      area_name: "千代田区",
      geocode: "1310100",
      event: "大雨警報",
      category: Some("Met"),
      status: "発表",
      severity: "Severe",
      urgency: "Expected",
      certainty: "Observed",
    )
  let msg1 =
    models_jma.JmaMessageContent(
      identifier: "20260921090000_VPWW53_ack_01",
      control_title: "気象警報・注意報",
      status: "通常",
      info_type: "発表",
      event_id: None,
      series_key: Some("気象警報・注意報:東京管区気象台:ack_series"),
      sent: "2026-09-21T09:00:00+09:00",
      effective: Some("2026-09-21T09:00:00+09:00"),
      expires: None,
      headline: Some("通常発表"),
      description: Some("通常発表"),
      areas: [models_jma.JmaArea(area_name: "千代田区", geocode: "1310100")],
      alerts: [alert1],
      cleared_areas: [],
      earthquake: None,
    )
  let res1 =
    models_jma.JmaFetchResult(
      item_url: "https://example.com/xml/ack_live.xml",
      feed_url: "https://example.com/feed/extra.xml",
      fetched_at: "2026-09-21T09:00:05Z",
      http_status: 200,
      error: None,
      raw_xml: Some("<xml>live</xml>"),
      message: Some(msg1),
    )
  let assert Ok(w1) = jma_message_writer.write_batch([res1], now, conn)
  w1.written |> should.equal(1)
  w1.dropped |> should.equal(0)
  list.length(w1.alert_diff.new) |> should.equal(1)

  // 2. Stale bulletin from 08:30 (< 09:00) arrives
  let stale_alert =
    models_jma.JmaAlertItem(
      lifecycle_key: "1310100:大雨注意報",
      area_name: "千代田区",
      geocode: "1310100",
      event: "大雨注意報",
      category: Some("Met"),
      status: "発表",
      severity: "Moderate",
      urgency: "Expected",
      certainty: "Observed",
    )
  let stale_msg =
    models_jma.JmaMessageContent(
      identifier: "20260921083000_VPWW53_stale_ack",
      control_title: "気象警報・注意報",
      status: "通常",
      info_type: "発表",
      event_id: None,
      series_key: Some("気象警報・注意報:東京管区気象台:ack_series"),
      sent: "2026-09-21T08:30:00+09:00",
      effective: Some("2026-09-21T08:30:00+09:00"),
      expires: None,
      headline: Some("過去発表"),
      description: Some("過去発表"),
      areas: [models_jma.JmaArea(area_name: "千代田区", geocode: "1310100")],
      alerts: [stale_alert],
      cleared_areas: [],
      earthquake: None,
    )
  let stale_res =
    models_jma.JmaFetchResult(
      item_url: "https://example.com/xml/ack_stale.xml",
      feed_url: "https://example.com/feed/extra.xml",
      fetched_at: "2026-09-21T09:05:05Z",
      http_status: 200,
      error: None,
      raw_xml: Some("<xml>stale ack</xml>"),
      message: Some(stale_msg),
    )
  let assert Ok(stale_w) =
    jma_message_writer.write_batch([stale_res], now, conn)
  // Contract: Stale telegram is accepted and durably archived -> ACKs written = 1, dropped = 0!
  stale_w.written |> should.equal(1)
  stale_w.dropped |> should.equal(0)
  stale_w.deduped |> should.equal(0)
  // Zero live effects: no new, updated, or ended alerts
  stale_w.alert_diff.new |> should.equal([])
  stale_w.alert_diff.updated |> should.equal([])
  stale_w.alert_diff.ended |> should.equal([])

  // Durable archive check in sea.jma_message: exactly 1 row
  let assert Ok(archive_check) =
    pog.query(
      "SELECT count(*) FROM sea.jma_message WHERE identifier = '20260921083000_VPWW53_stale_ack'",
    )
    |> pog.returning(decode.at([0], decode.int))
    |> pog.execute(conn)
  archive_check.rows |> should.equal([1])

  // Live alert in DB remains unchanged (still 大雨警報, NOT downgraded to stale 大雨注意報)
  let assert Ok(alert_check) =
    pog.query(
      "SELECT event FROM sea.alert WHERE source_id = '気象警報・注意報:東京管区気象台:ack_series:大雨警報'",
    )
    |> pog.returning(decode.at([0], decode.string))
    |> pog.execute(conn)
  alert_check.rows |> should.equal(["大雨警報"])

  // 3. Duplicate replay of exact same stale bulletin: deduped = 1, written = 0, dropped = 0
  let assert Ok(dup_w) = jma_message_writer.write_batch([stale_res], now, conn)
  dup_w.written |> should.equal(0)
  dup_w.deduped |> should.equal(1)
  dup_w.dropped |> should.equal(0)
}

pub fn jma_vpww53_vpww54_duplication_collapse_test() {
  use conn <- test_db.with_test_db
  let now = timestamp.system_time()

  let alert_vpww53 =
    models_jma.JmaAlertItem(
      lifecycle_key: "120000:大雨警報",
      area_name: "千葉県",
      geocode: "120000",
      event: "大雨警報",
      category: Some("Met"),
      status: "発表",
      severity: "Severe",
      urgency: "Expected",
      certainty: "Observed",
    )

  let msg_vpww53 =
    models_jma.JmaMessageContent(
      identifier: "20260920162940_VPWW53",
      control_title: "気象特別警報・警報・注意報",
      status: "通常",
      info_type: "発表",
      event_id: None,
      series_key: Some("気象特別警報・警報・注意報:銚子地方気象台:通常"),
      sent: "2026-09-20T16:29:40+09:00",
      effective: Some("2026-09-20T16:29:40+09:00"),
      expires: None,
      headline: Some("大雨警報"),
      description: Some("大雨"),
      areas: [models_jma.JmaArea(area_name: "千葉県", geocode: "120000")],
      alerts: [alert_vpww53],
      cleared_areas: [],
      earthquake: None,
    )

  let alert_vpww54 =
    models_jma.JmaAlertItem(
      lifecycle_key: "120000:大雨警報",
      area_name: "千葉県",
      geocode: "120000",
      event: "大雨警報",
      category: Some("Met"),
      status: "発表",
      severity: "Severe",
      urgency: "Expected",
      certainty: "Observed",
    )

  let msg_vpww54 =
    models_jma.JmaMessageContent(
      identifier: "20260920162940_VPWW54",
      control_title: "気象警報・注意報（Ｈ２７）",
      status: "通常",
      info_type: "発表",
      event_id: None,
      series_key: Some("気象警報・注意報（Ｈ２７）:銚子地方気象台:通常"),
      sent: "2026-09-20T16:29:40+09:00",
      effective: Some("2026-09-20T16:29:40+09:00"),
      expires: None,
      headline: Some("大雨警報"),
      description: Some("大雨"),
      areas: [models_jma.JmaArea(area_name: "千葉県", geocode: "120000")],
      alerts: [alert_vpww54],
      cleared_areas: [],
      earthquake: None,
    )

  let res_vpww53 =
    models_jma.JmaFetchResult(
      item_url: "https://example.com/xml/vpww53.xml",
      feed_url: "https://example.com/feed/extra.xml",
      fetched_at: "2026-09-21T02:00:05Z",
      http_status: 200,
      error: None,
      raw_xml: Some("<xml/>"),
      message: Some(msg_vpww53),
    )

  let res_vpww54 =
    models_jma.JmaFetchResult(
      item_url: "https://example.com/xml/vpww54.xml",
      feed_url: "https://example.com/feed/extra.xml",
      fetched_at: "2026-09-21T02:00:06Z",
      http_status: 200,
      error: None,
      raw_xml: Some("<xml/>"),
      message: Some(msg_vpww54),
    )

  let assert Ok(_w) =
    jma_message_writer.write_batch([res_vpww53, res_vpww54], now, conn)

  let assert Ok(alert_check) =
    pog.query("SELECT count(*) FROM sea.alert")
    |> pog.returning(decode.at([0], decode.int))
    |> pog.execute(conn)
  alert_check.rows |> should.equal([1])
}

pub fn jma_multi_area_merge_test() {
  use conn <- test_db.with_test_db
  let now = timestamp.system_time()

  let alert_a =
    models_jma.JmaAlertItem(
      lifecycle_key: "120010:大雨警報",
      area_name: "千葉市",
      geocode: "120010",
      event: "大雨警報",
      category: Some("Met"),
      status: "発表",
      severity: "Severe",
      urgency: "Expected",
      certainty: "Observed",
    )

  let alert_b =
    models_jma.JmaAlertItem(
      lifecycle_key: "120020:大雨警報",
      area_name: "船橋市",
      geocode: "120020",
      event: "大雨警報",
      category: Some("Met"),
      status: "発表",
      severity: "Severe",
      urgency: "Expected",
      certainty: "Observed",
    )

  let alert_c =
    models_jma.JmaAlertItem(
      lifecycle_key: "120030:洪水警報",
      area_name: "市川市",
      geocode: "120030",
      event: "洪水警報",
      category: Some("Met"),
      status: "発表",
      severity: "Severe",
      urgency: "Expected",
      certainty: "Observed",
    )

  let msg =
    models_jma.JmaMessageContent(
      identifier: "20260920163000_VPWW53",
      control_title: "気象特別警報・警報・注意報",
      status: "通常",
      info_type: "発表",
      event_id: None,
      series_key: Some("気象特別警報・警報・注意報:銚子地方気象台:通常"),
      sent: "2026-09-20T16:30:00+09:00",
      effective: Some("2026-09-20T16:30:00+09:00"),
      expires: None,
      headline: Some("警報"),
      description: Some("警報"),
      areas: [
        models_jma.JmaArea(area_name: "千葉市", geocode: "120010"),
        models_jma.JmaArea(area_name: "船橋市", geocode: "120020"),
        models_jma.JmaArea(area_name: "市川市", geocode: "120030"),
      ],
      alerts: [alert_a, alert_b, alert_c],
      cleared_areas: [],
      earthquake: None,
    )

  let res =
    models_jma.JmaFetchResult(
      item_url: "https://example.com/xml/multi.xml",
      feed_url: "https://example.com/feed/extra.xml",
      fetched_at: "2026-09-21T02:00:05Z",
      http_status: 200,
      error: None,
      raw_xml: Some("<xml/>"),
      message: Some(msg),
    )

  let assert Ok(_w) = jma_message_writer.write_batch([res], now, conn)

  let assert Ok(alert_check) =
    pog.query(
      "SELECT event, area_desc, jsonb_array_length(geocodes) FROM sea.alert ORDER BY event",
    )
    |> pog.returning({
      use e <- decode.field(0, decode.string)
      use a <- decode.field(1, decode.string)
      use c <- decode.field(2, decode.int)
      decode.success(#(e, a, c))
    })
    |> pog.execute(conn)

  alert_check.rows
  |> should.equal([#("大雨警報", "千葉市, 船橋市", 2), #("洪水警報", "市川市", 1)])
}

pub fn jma_vpww53_full_cancellation_test() {
  use conn <- test_db.with_test_db
  let now = timestamp.system_time()

  // 1. Issue an alert via VPWW53
  let alert_issue =
    models_jma.JmaAlertItem(
      lifecycle_key: "120000:大雨警報",
      area_name: "千葉県",
      geocode: "120000",
      event: "大雨警報",
      category: Some("Met"),
      status: "発表",
      severity: "Severe",
      urgency: "Expected",
      certainty: "Observed",
    )
  let msg_issue =
    models_jma.JmaMessageContent(
      identifier: "20260921040000_VPWW53_issue",
      control_title: "気象特別警報・警報・注意報",
      status: "通常",
      info_type: "発表",
      event_id: None,
      series_key: Some("気象特別警報・警報・注意報:銚子地方気象台:通常"),
      sent: "2026-09-21T04:00:00+09:00",
      effective: Some("2026-09-21T04:00:00+09:00"),
      expires: None,
      headline: Some("大雨警報"),
      description: Some("大雨"),
      areas: [models_jma.JmaArea(area_name: "千葉県", geocode: "120000")],
      alerts: [alert_issue],
      cleared_areas: [],
      earthquake: None,
    )
  let res_issue =
    models_jma.JmaFetchResult(
      item_url: "https://example.com/xml/vpww53_issue.xml",
      feed_url: "https://example.com/feed/extra.xml",
      fetched_at: "2026-09-21T04:00:05Z",
      http_status: 200,
      error: None,
      raw_xml: Some("<xml/>"),
      message: Some(msg_issue),
    )
  let assert Ok(_w1) = jma_message_writer.write_batch([res_issue], now, conn)

  // 2. Issue cancellation via VPWW53
  let alert_cancel =
    models_jma.JmaAlertItem(
      lifecycle_key: "120000:大雨警報",
      area_name: "千葉県",
      geocode: "120000",
      event: "大雨警報",
      category: Some("Met"),
      status: "解除",
      severity: "Unknown",
      urgency: "Past",
      certainty: "Observed",
    )
  let msg_cancel =
    models_jma.JmaMessageContent(
      identifier: "20260921050000_VPWW53_cancel",
      control_title: "気象特別警報・警報・注意報",
      status: "通常",
      info_type: "発表",
      event_id: None,
      series_key: Some("気象特別警報・警報・注意報:銚子地方気象台:通常"),
      sent: "2026-09-21T05:00:00+09:00",
      effective: Some("2026-09-21T05:00:00+09:00"),
      expires: None,
      headline: Some("大雨警報解除"),
      description: Some("大雨警報解除"),
      areas: [models_jma.JmaArea(area_name: "千葉県", geocode: "120000")],
      alerts: [alert_cancel],
      cleared_areas: [],
      earthquake: None,
    )
  let res_cancel =
    models_jma.JmaFetchResult(
      item_url: "https://example.com/xml/vpww53_cancel.xml",
      feed_url: "https://example.com/feed/extra.xml",
      fetched_at: "2026-09-21T05:00:05Z",
      http_status: 200,
      error: None,
      raw_xml: Some("<xml/>"),
      message: Some(msg_cancel),
    )
  let assert Ok(w2) = jma_message_writer.write_batch([res_cancel], now, conn)

  // The alert should be completely ended
  list.length(w2.alert_diff.ended) |> should.equal(1)

  let assert Ok(alert_check) =
    pog.query(
      "SELECT end_reason FROM sea.alert WHERE source_id = '気象特別警報・警報・注意報:銚子地方気象台:通常:大雨警報'",
    )
    |> pog.returning(decode.at([0], decode.optional(decode.string)))
    |> pog.execute(conn)
  alert_check.rows |> should.equal([Some("cancelled")])
}

pub fn jma_alert_geometry_single_area_test() {
  use conn <- test_db.with_test_db
  let now = timestamp.system_time()

  let assert Ok(_) =
    pog.query(
      "INSERT INTO sea.jma_area (code, name, geom)
       VALUES ('140010', '横浜市', ST_Multi(ST_GeomFromText('POLYGON((139.6 35.4, 139.7 35.4, 139.7 35.5, 139.6 35.5, 139.6 35.4))', 4326)))
       ON CONFLICT (code) DO UPDATE SET name = EXCLUDED.name, geom = EXCLUDED.geom",
    )
    |> pog.returning(decode.success(Nil))
    |> pog.execute(conn)

  let alert_item =
    models_jma.JmaAlertItem(
      lifecycle_key: "140010:大雨警報",
      area_name: "横浜市",
      geocode: "140010",
      event: "大雨警報",
      category: Some("Met"),
      status: "発表",
      severity: "Severe",
      urgency: "Expected",
      certainty: "Observed",
    )

  let msg =
    models_jma.JmaMessageContent(
      identifier: "20260921060000_VPWW53_single",
      control_title: "気象警報・注意報",
      status: "通常",
      info_type: "発表",
      event_id: None,
      series_key: Some("気象警報・注意報:横浜地方気象台:140010"),
      sent: "2026-09-21T06:00:00+09:00",
      effective: Some("2026-09-21T06:00:00+09:00"),
      expires: None,
      headline: Some("大雨警報"),
      description: Some("横浜市に大雨警報"),
      areas: [models_jma.JmaArea(area_name: "横浜市", geocode: "140010")],
      alerts: [alert_item],
      cleared_areas: [],
      earthquake: None,
    )

  let res =
    models_jma.JmaFetchResult(
      item_url: "https://example.com/xml/alert_geom_single.xml",
      feed_url: "https://example.com/feed/extra.xml",
      fetched_at: "2026-09-21T06:00:05Z",
      http_status: 200,
      error: None,
      raw_xml: Some("<xml/>"),
      message: Some(msg),
    )

  let assert Ok(batch_res) = jma_message_writer.write_batch([res], now, conn)
  batch_res.written |> should.equal(1)
  let assert [written_alert] = batch_res.alert_diff.new

  written_alert.geom |> should.not_equal(None)

  let assert Ok(check_geom) =
    pog.query(
      "SELECT ST_GeometryType(a.geom), ST_Equals(a.geom, ja.geom)
       FROM sea.alert a
       JOIN sea.jma_area ja ON ja.code = '140010'
       WHERE a.source = 'jma' AND a.source_id = '気象警報・注意報:横浜地方気象台:140010:大雨警報'",
    )
    |> pog.returning({
      use geom_type <- decode.field(0, decode.optional(decode.string))
      use is_equal <- decode.field(1, decode.bool)
      decode.success(#(geom_type, is_equal))
    })
    |> pog.execute(conn)

  check_geom.rows |> should.equal([#(Some("ST_MultiPolygon"), True)])
}

pub fn jma_alert_geometry_multi_area_union_test() {
  use conn <- test_db.with_test_db
  let now = timestamp.system_time()

  let assert Ok(_) =
    pog.query(
      "INSERT INTO sea.jma_area (code, name, geom)
       VALUES
         ('140010', '横浜市', ST_Multi(ST_GeomFromText('POLYGON((139.6 35.4, 139.7 35.4, 139.7 35.5, 139.6 35.5, 139.6 35.4))', 4326))),
         ('140020', '川崎市', ST_Multi(ST_GeomFromText('POLYGON((139.7 35.5, 139.8 35.5, 139.8 35.6, 139.7 35.6, 139.7 35.5))', 4326))),
         ('140030', '相模原市', ST_Multi(ST_GeomFromText('POLYGON((139.3 35.5, 139.4 35.5, 139.4 35.6, 139.3 35.6, 139.3 35.5))', 4326)))
       ON CONFLICT (code) DO UPDATE SET name = EXCLUDED.name, geom = EXCLUDED.geom",
    )
    |> pog.returning(decode.success(Nil))
    |> pog.execute(conn)

  let alert_rain_yokohama =
    models_jma.JmaAlertItem(
      lifecycle_key: "140010:大雨警報",
      area_name: "横浜市",
      geocode: "140010",
      event: "大雨警報",
      category: Some("Met"),
      status: "発表",
      severity: "Severe",
      urgency: "Expected",
      certainty: "Observed",
    )
  let alert_rain_kawasaki =
    models_jma.JmaAlertItem(
      lifecycle_key: "140020:大雨警報",
      area_name: "川崎市",
      geocode: "140020",
      event: "大雨警報",
      category: Some("Met"),
      status: "発表",
      severity: "Severe",
      urgency: "Expected",
      certainty: "Observed",
    )
  let alert_flood_sagamihara =
    models_jma.JmaAlertItem(
      lifecycle_key: "140030:洪水警報",
      area_name: "相模原市",
      geocode: "140030",
      event: "洪水警報",
      category: Some("Met"),
      status: "発表",
      severity: "Severe",
      urgency: "Expected",
      certainty: "Observed",
    )

  let msg1 =
    models_jma.JmaMessageContent(
      identifier: "20260921070000_VPWW53_multi1",
      control_title: "気象警報・注意報",
      status: "通常",
      info_type: "発表",
      event_id: None,
      series_key: Some("気象警報・注意報:横浜地方気象台:神奈川県"),
      sent: "2026-09-21T07:00:00+09:00",
      effective: Some("2026-09-21T07:00:00+09:00"),
      expires: None,
      headline: Some("大雨・洪水警報"),
      description: Some("警報発表"),
      areas: [
        models_jma.JmaArea(area_name: "横浜市", geocode: "140010"),
        models_jma.JmaArea(area_name: "川崎市", geocode: "140020"),
        models_jma.JmaArea(area_name: "相模原市", geocode: "140030"),
      ],
      alerts: [alert_rain_yokohama, alert_rain_kawasaki, alert_flood_sagamihara],
      cleared_areas: [],
      earthquake: None,
    )

  let res1 =
    models_jma.JmaFetchResult(
      item_url: "https://example.com/xml/alert_geom_multi1.xml",
      feed_url: "https://example.com/feed/extra.xml",
      fetched_at: "2026-09-21T07:00:05Z",
      http_status: 200,
      error: None,
      raw_xml: Some("<xml/>"),
      message: Some(msg1),
    )

  let assert Ok(batch1) = jma_message_writer.write_batch([res1], now, conn)
  list.length(batch1.alert_diff.new) |> should.equal(2)

  let assert Ok(check_rain) =
    pog.query(
      "SELECT ST_GeometryType(a.geom),
              ST_Equals(a.geom, (SELECT ST_Multi(ST_Union(geom)) FROM sea.jma_area WHERE code IN ('140010', '140020')))
       FROM sea.alert a
       WHERE a.source_id = '気象警報・注意報:横浜地方気象台:神奈川県:大雨警報'",
    )
    |> pog.returning({
      use geom_type <- decode.field(0, decode.optional(decode.string))
      use is_equal <- decode.field(1, decode.bool)
      decode.success(#(geom_type, is_equal))
    })
    |> pog.execute(conn)

  check_rain.rows |> should.equal([#(Some("ST_MultiPolygon"), True)])

  let assert Ok(check_flood) =
    pog.query(
      "SELECT ST_GeometryType(a.geom),
              ST_Equals(a.geom, (SELECT geom FROM sea.jma_area WHERE code = '140030'))
       FROM sea.alert a
       WHERE a.source_id = '気象警報・注意報:横浜地方気象台:神奈川県:洪水警報'",
    )
    |> pog.returning({
      use geom_type <- decode.field(0, decode.optional(decode.string))
      use is_equal <- decode.field(1, decode.bool)
      decode.success(#(geom_type, is_equal))
    })
    |> pog.execute(conn)

  check_flood.rows |> should.equal([#(Some("ST_MultiPolygon"), True)])

  let alert_rain_sagamihara =
    models_jma.JmaAlertItem(
      lifecycle_key: "140030:大雨警報",
      area_name: "相模原市",
      geocode: "140030",
      event: "大雨警報",
      category: Some("Met"),
      status: "発表",
      severity: "Severe",
      urgency: "Expected",
      certainty: "Observed",
    )

  let msg2 =
    models_jma.JmaMessageContent(
      identifier: "20260921073000_VPWW53_multi2",
      control_title: "気象警報・注意報",
      status: "通常",
      info_type: "発表",
      event_id: None,
      series_key: Some("気象警報・注意報:横浜地方気象台:神奈川県"),
      sent: "2026-09-21T07:30:00+09:00",
      effective: Some("2026-09-21T07:30:00+09:00"),
      expires: None,
      headline: Some("大雨警報拡大"),
      description: Some("相模原市にも大雨警報"),
      areas: [
        models_jma.JmaArea(area_name: "横浜市", geocode: "140010"),
        models_jma.JmaArea(area_name: "川崎市", geocode: "140020"),
        models_jma.JmaArea(area_name: "相模原市", geocode: "140030"),
      ],
      alerts: [alert_rain_yokohama, alert_rain_kawasaki, alert_rain_sagamihara],
      cleared_areas: [],
      earthquake: None,
    )

  let res2 =
    models_jma.JmaFetchResult(
      item_url: "https://example.com/xml/alert_geom_multi2.xml",
      feed_url: "https://example.com/feed/extra.xml",
      fetched_at: "2026-09-21T07:30:05Z",
      http_status: 200,
      error: None,
      raw_xml: Some("<xml/>"),
      message: Some(msg2),
    )

  let assert Ok(batch2) = jma_message_writer.write_batch([res2], now, conn)
  list.length(batch2.alert_diff.updated) |> should.equal(1)

  let assert Ok(check_updated_rain) =
    pog.query(
      "SELECT ST_GeometryType(a.geom),
              ST_Equals(a.geom, (SELECT ST_Multi(ST_Union(geom)) FROM sea.jma_area WHERE code IN ('140010', '140020', '140030')))
       FROM sea.alert a
       WHERE a.source_id = '気象警報・注意報:横浜地方気象台:神奈川県:大雨警報'",
    )
    |> pog.returning({
      use geom_type <- decode.field(0, decode.optional(decode.string))
      use is_equal <- decode.field(1, decode.bool)
      decode.success(#(geom_type, is_equal))
    })
    |> pog.execute(conn)

  check_updated_rain.rows |> should.equal([#(Some("ST_MultiPolygon"), True)])
}

pub fn jma_alert_geometry_unknown_geocode_test() {
  use conn <- test_db.with_test_db
  let now = timestamp.system_time()

  let alert_unknown =
    models_jma.JmaAlertItem(
      lifecycle_key: "9999999:大雨警報",
      area_name: "架空自治体",
      geocode: "9999999",
      event: "大雨警報",
      category: Some("Met"),
      status: "発表",
      severity: "Severe",
      urgency: "Expected",
      certainty: "Observed",
    )

  let msg =
    models_jma.JmaMessageContent(
      identifier: "20260921080000_VPWW53_unknown",
      control_title: "気象警報・注意報",
      status: "通常",
      info_type: "発表",
      event_id: None,
      series_key: Some("気象警報・注意報:気象庁:9999999"),
      sent: "2026-09-21T08:00:00+09:00",
      effective: Some("2026-09-21T08:00:00+09:00"),
      expires: None,
      headline: Some("大雨警報"),
      description: Some("架空自治体に大雨警報"),
      areas: [models_jma.JmaArea(area_name: "架空自治体", geocode: "9999999")],
      alerts: [alert_unknown],
      cleared_areas: [],
      earthquake: None,
    )

  let res =
    models_jma.JmaFetchResult(
      item_url: "https://example.com/xml/alert_geom_unknown.xml",
      feed_url: "https://example.com/feed/extra.xml",
      fetched_at: "2026-09-21T08:00:05Z",
      http_status: 200,
      error: None,
      raw_xml: Some("<xml/>"),
      message: Some(msg),
    )

  let assert Ok(batch_res) = jma_message_writer.write_batch([res], now, conn)
  batch_res.written |> should.equal(1)
  let assert [written_alert] = batch_res.alert_diff.new

  written_alert.geom |> should.equal(None)

  let assert Ok(check_null) =
    pog.query(
      "SELECT geom IS NULL FROM sea.alert WHERE source_id = '気象警報・注意報:気象庁:9999999:大雨警報'",
    )
    |> pog.returning(decode.at([0], decode.bool))
    |> pog.execute(conn)

  check_null.rows |> should.equal([True])
}
