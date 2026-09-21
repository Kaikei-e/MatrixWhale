import gleam/dynamic/decode
import gleam/json
import gleam/option.{None, Some}
import gleeunit/should
import message/reciever/models/jma as models_jma

pub fn decode_index_body_valid_test() {
  let json_str =
    "{\"poll_meta\": {\"fetched_at\": \"2026-09-21T01:30:00Z\", \"http_status\": 200, \"feature_count\": 2, \"bytes\": 4096, \"feed_url\": \"https://www.data.jma.go.jp/developer/xml/feed/eqvol.xml\"},
      \"features\": [
        {\"item_url\": \"https://www.data.jma.go.jp/developer/xml/data/20260921012500_0_VXSE53_010000.xml\",
         \"feed_url\": \"https://www.data.jma.go.jp/developer/xml/feed/eqvol.xml\",
         \"guid\": \"urn:uuid:20260921012500_0_VXSE53_010000\",
         \"title\": \"震源・震度に関する情報\",
         \"published\": \"2026-09-21T01:25:00+09:00\"},
        {\"item_url\": \"https://www.data.jma.go.jp/developer/xml/data/20260921012000_0_VXSE51_010000.xml\",
         \"feed_url\": \"https://www.data.jma.go.jp/developer/xml/feed/eqvol.xml\",
         \"guid\": \"urn:uuid:20260921012000_0_VXSE51_010000\",
         \"title\": \"震度速報\",
         \"published\": \"2026-09-21T01:20:00+09:00\"}
      ]}"

  let assert Ok(dyn) = json.parse(json_str, decode.dynamic)
  let assert Ok(#(meta, items, received, dropped)) =
    models_jma.decode_index_body(dyn)

  received |> should.equal(2)
  dropped |> should.equal(0)
  let assert [first, second] = items
  first.item_url
  |> should.equal(
    "https://www.data.jma.go.jp/developer/xml/data/20260921012500_0_VXSE53_010000.xml",
  )
  first.title |> should.equal(Some("震源・震度に関する情報"))
  second.title |> should.equal(Some("震度速報"))

  let assert Some(m) = meta
  m.http_status |> should.equal(200)
  m.feed_url
  |> should.equal(Some(
    "https://www.data.jma.go.jp/developer/xml/feed/eqvol.xml",
  ))
}

pub fn decode_index_body_with_dropped_item_test() {
  let json_str =
    "{\"features\": [
        {\"item_url\": \"https://www.data.jma.go.jp/valid.xml\", \"feed_url\": \"https://feed.xml\"},
        {\"item_url\": \"ftp://invalid.xml\", \"feed_url\": \"https://feed.xml\"},
        {\"item_url\": \"\", \"feed_url\": \"https://feed.xml\"}
      ]}"

  let assert Ok(dyn) = json.parse(json_str, decode.dynamic)
  let assert Ok(#(meta, items, received, dropped)) =
    models_jma.decode_index_body(dyn)

  meta |> should.equal(None)
  received |> should.equal(3)
  dropped |> should.equal(2)
  let assert [valid] = items
  valid.item_url |> should.equal("https://www.data.jma.go.jp/valid.xml")
}

pub fn decode_messages_body_live_earthquake_test() {
  let json_str =
    "{\"features\": [
        {
          \"item_url\": \"https://www.data.jma.go.jp/developer/xml/data/20260921012500_0_VXSE53_010000.xml\",
          \"feed_url\": \"https://www.data.jma.go.jp/developer/xml/feed/eqvol.xml\",
          \"fetched_at\": \"2026-09-21T01:25:05Z\",
          \"http_status\": 200,
          \"raw_xml\": \"<jma_xml>sample</jma_xml>\",
          \"message\": {
            \"identifier\": \"20260921012500_0_VXSE53_010000\",
            \"control_title\": \"震源・震度に関する情報\",
            \"status\": \"通常\",
            \"info_type\": \"発表\",
            \"event_id\": \"20260921012000\",
            \"sent\": \"2026-09-21T01:25:00+09:00\",
            \"headline\": \"２１日０１時２０分ころ、地震がありました。\",
            \"description\": \"震源地は東京湾、深さ約10km、M4.2。\",
            \"earthquake\": {
              \"origin_time\": \"2026-09-21T01:20:00+09:00\",
              \"latitude\": 35.68,
              \"longitude\": 139.76,
              \"depth_km\": 10.0,
              \"magnitude\": 4.2,
              \"magnitude_type\": \"Mj\",
              \"place\": \"東京湾\",
              \"max_intensity\": \"3\"
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
  res.http_status |> should.equal(200)
  res.raw_xml |> should.equal(Some("<jma_xml>sample</jma_xml>"))
  let assert Some(msg) = res.message
  msg.status |> should.equal("通常")
  msg.info_type |> should.equal("発表")
  msg.event_id |> should.equal(Some("20260921012000"))

  let assert Some(eq) = msg.earthquake
  eq.latitude |> should.equal(Some(35.68))
  eq.longitude |> should.equal(Some(139.76))
  eq.depth_km |> should.equal(Some(10.0))
  eq.magnitude |> should.equal(Some(4.2))
  eq.place |> should.equal(Some("東京湾"))
}

pub fn decode_messages_body_live_alert_test() {
  let json_str =
    "{\"features\": [
        {
          \"item_url\": \"https://www.data.jma.go.jp/developer/xml/data/20260921020000_0_VPWW53_130000.xml\",
          \"feed_url\": \"https://www.data.jma.go.jp/developer/xml/feed/regular.xml\",
          \"fetched_at\": \"2026-09-21T02:00:05Z\",
          \"http_status\": 200,
          \"message\": {
            \"identifier\": \"20260921020000_0_VPWW53_130000\",
            \"control_title\": \"気象警報・注意報\",
            \"status\": \"通常\",
            \"info_type\": \"発表\",
            \"sent\": \"2026-09-21T02:00:00+09:00\",
            \"headline\": \"大雨警報が発表されました。\",
            \"alerts\": [
              {
                \"lifecycle_key\": \"130000:大雨警報\",
                \"area_name\": \"東京地方\",
                \"geocode\": \"130000\",
                \"event\": \"大雨警報\",
                \"category\": \"Met\",
                \"status\": \"発表\",
                \"severity\": \"Severe\",
                \"urgency\": \"Expected\",
                \"certainty\": \"Observed\"
              }
            ]
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
  msg.identifier |> should.equal("20260921020000_0_VPWW53_130000")
  let assert [alert] = msg.alerts
  alert.lifecycle_key |> should.equal("130000:大雨警報")
  alert.area_name |> should.equal("東京地方")
  alert.event |> should.equal("大雨警報")
  alert.status |> should.equal("発表")
}

pub fn decode_messages_body_drill_or_test_test() {
  let json_str =
    "{\"features\": [
        {
          \"item_url\": \"https://www.data.jma.go.jp/test.xml\",
          \"feed_url\": \"https://feed.xml\",
          \"fetched_at\": \"2026-09-21T02:00:00Z\",
          \"http_status\": 200,
          \"message\": {
            \"identifier\": \"test_001\",
            \"control_title\": \"緊急地震速報（警報）\",
            \"status\": \"訓練\",
            \"info_type\": \"発表\",
            \"sent\": \"2026-09-21T02:00:00Z\"
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
  msg.status |> should.equal("訓練")
}

pub fn decode_messages_body_cancellation_test() {
  let json_str =
    "{\"features\": [
        {
          \"item_url\": \"https://www.data.jma.go.jp/cancel.xml\",
          \"feed_url\": \"https://feed.xml\",
          \"fetched_at\": \"2026-09-21T02:00:00Z\",
          \"http_status\": 200,
          \"message\": {
            \"identifier\": \"cancel_001\",
            \"control_title\": \"気象警報・注意報\",
            \"status\": \"通常\",
            \"info_type\": \"取消\",
            \"sent\": \"2026-09-21T02:00:00Z\",
            \"alerts\": [
              {
                \"lifecycle_key\": \"130000:大雨警報\",
                \"area_name\": \"東京地方\",
                \"geocode\": \"130000\",
                \"event\": \"大雨警報\",
                \"status\": \"解除\",
                \"severity\": \"Minor\",
                \"urgency\": \"Past\",
                \"certainty\": \"Observed\"
              }
            ]
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
  msg.info_type |> should.equal("取消")
  let assert [alert] = msg.alerts
  alert.status |> should.equal("解除")
}

pub fn decode_messages_body_bad_payload_test() {
  let json_str = "{\"bad_root\": 123}"
  let assert Ok(dyn) = json.parse(json_str, decode.dynamic)
  models_jma.decode_messages_body(dyn)
  |> should.be_error
}
