import domain/source
import erlang_tools/raw_json
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/calendar
import gleam/time/timestamp.{type Timestamp}
import message/reciever/models/cap as models_cap

pub type AreaPrecision {
  Exact
  Bbox
}

pub type Wis2CapFeature {
  Wis2CapFeature(
    notification_id: String,
    data_id: String,
    topic: String,
    centre_id: String,
    channel: String,
    pubtime: String,
    datetime: Option(String),
    license_url: Option(String),
    fetched_via: String,
    download_url: Option(String),
    raw_xml: String,
    cap: Option(models_cap.CapMessage),
    area_key: Option(String),
    area_geometry: Option(String),
    area_precision: Option(AreaPrecision),
  )
}

pub type Wis2PollMeta {
  Wis2PollMeta(feed_url: Option(String), error: Option(String))
}

pub type Wis2HealthFeature {
  Wis2HealthFeature(
    centre_id: String,
    kind: String,
    window_start: String,
    window_end: String,
    received: Int,
    duplicates: Int,
    download_failed: Int,
    decode_failed: Int,
    integrity_failed: Int,
    last_received_at: Option(String),
  )
}

pub type ChannelStatus {
  StatusOk
  StatusStale
  StatusFailing
}

pub type BrokerState {
  BrokerState(
    url: String,
    connected: Bool,
    last_report_at: Option(Timestamp),
    error: Option(String),
  )
}

pub type ChannelHealth {
  ChannelHealth(
    centre_id: String,
    kind: String,
    received_24h: Int,
    duplicates_24h: Int,
    download_failed_24h: Int,
    decode_failed_24h: Int,
    integrity_failed_24h: Int,
    last_received_at: Option(Timestamp),
    status: ChannelStatus,
  )
}

pub fn area_precision_to_string(precision: AreaPrecision) -> String {
  case precision {
    Exact -> "exact"
    Bbox -> "bbox"
  }
}

pub fn area_precision_from_string(s: String) -> Result(AreaPrecision, Nil) {
  case string.trim(s) {
    "exact" -> Ok(Exact)
    "bbox" -> Ok(Bbox)
    _ -> Error(Nil)
  }
}

pub fn should_replace_area(
  incoming: AreaPrecision,
  stored: Option(AreaPrecision),
) -> Bool {
  case incoming, stored {
    _, None -> True
    Exact, _ -> True
    Bbox, Some(Bbox) -> True
    Bbox, Some(Exact) -> False
  }
}

pub fn is_new_area(
  incoming: AreaPrecision,
  stored: Option(AreaPrecision),
) -> Bool {
  case incoming, stored {
    _, None -> True
    Exact, Some(Bbox) -> True
    _, _ -> False
  }
}

pub fn source_id(centre_id: String) -> String {
  "wis2-" <> string.trim(centre_id)
}

pub fn make_source(
  centre_id: String,
  license_url: Option(String),
) -> source.Source {
  let trimmed = string.trim(centre_id)
  let license = case license_url {
    Some(l) -> {
      let t = string.trim(l)
      case t {
        "" -> "Unknown"
        _ -> t
      }
    }
    None -> "Unknown"
  }
  source.Source(
    id: source_id(trimmed),
    name: "WMO WIS2 / " <> trimmed,
    homepage: None,
    license: license,
    attribution_text: "WMO WIS2 / " <> trimmed,
    redistributable: False,
    priority: 70,
  )
}

pub fn truncate_to_hour(ts: Timestamp) -> Timestamp {
  let #(sec, _) = timestamp.to_unix_seconds_and_nanoseconds(ts)
  let hour_sec = { sec / 3600 } * 3600
  timestamp.from_unix_seconds_and_nanoseconds(hour_sec, 0)
}

pub fn channel_status_to_string(status: ChannelStatus) -> String {
  case status {
    StatusOk -> "ok"
    StatusStale -> "stale"
    StatusFailing -> "failing"
  }
}

pub fn compute_status(
  kind: String,
  received_24h: Int,
  download_failed_24h: Int,
  decode_failed_24h: Int,
  integrity_failed_24h: Int,
  last_received_at: Option(Timestamp),
  now: Timestamp,
) -> ChannelStatus {
  let total_failed =
    download_failed_24h + decode_failed_24h + integrity_failed_24h
  let is_failing = received_24h > 0 && total_failed * 2 > received_24h
  case is_failing {
    True -> StatusFailing
    False -> {
      let threshold_hours = case string.lowercase(string.trim(kind)) {
        "trajectory" -> 24
        _ -> 6
      }
      let is_stale = case last_received_at {
        None -> True
        Some(last_ts) -> {
          let #(now_sec, _) = timestamp.to_unix_seconds_and_nanoseconds(now)
          let #(last_sec, _) =
            timestamp.to_unix_seconds_and_nanoseconds(last_ts)
          now_sec - last_sec > threshold_hours * 3600
        }
      }
      case is_stale {
        True -> StatusStale
        False -> StatusOk
      }
    }
  }
}

pub fn decode_cap_body(
  data: Dynamic,
) -> Result(#(Option(Wis2PollMeta), List(Wis2CapFeature), Int, Int), String) {
  let decoder = {
    use poll_meta <- decode.optional_field(
      "poll_meta",
      None,
      decode.optional(poll_meta_decoder()),
    )
    use raw <- decode.field("features", decode.list(decode.dynamic))
    decode.success(#(poll_meta, raw))
  }
  case decode.run(data, decoder) {
    Ok(#(poll_meta, raw)) -> {
      let items =
        raw
        |> list.filter_map(fn(x) {
          case decode.run(x, cap_feature_decoder()) {
            Ok(item) -> Ok(item)
            Error(_) -> Error(Nil)
          }
        })
      let received = list.length(raw)
      let dropped = received - list.length(items)
      Ok(#(poll_meta, items, received, dropped))
    }
    Error(errors) -> Error(string.inspect(errors))
  }
}

pub fn decode_health_body(
  data: Dynamic,
) -> Result(#(Option(Wis2PollMeta), List(Wis2HealthFeature), Int, Int), String) {
  let decoder = {
    use poll_meta <- decode.optional_field(
      "poll_meta",
      None,
      decode.optional(poll_meta_decoder()),
    )
    use raw <- decode.field("features", decode.list(decode.dynamic))
    decode.success(#(poll_meta, raw))
  }
  case decode.run(data, decoder) {
    Ok(#(poll_meta, raw)) -> {
      let items =
        raw
        |> list.filter_map(fn(x) {
          case decode.run(x, health_feature_decoder()) {
            Ok(item) -> Ok(item)
            Error(_) -> Error(Nil)
          }
        })
      let received = list.length(raw)
      let dropped = received - list.length(items)
      Ok(#(poll_meta, items, received, dropped))
    }
    Error(errors) -> Error(string.inspect(errors))
  }
}

fn poll_meta_decoder() -> decode.Decoder(Wis2PollMeta) {
  use feed_url <- decode.optional_field(
    "feed_url",
    None,
    decode.optional(decode.string),
  )
  use error <- decode.optional_field(
    "error",
    None,
    decode.optional(decode.string),
  )
  decode.success(Wis2PollMeta(
    feed_url: option.map(feed_url, string.trim),
    error: option.map(error, string.trim),
  ))
}

fn area_geometry_decoder() -> decode.Decoder(Option(String)) {
  let string_or_json_object =
    decode.one_of(decode.string, [
      decode.dynamic
      |> decode.map(fn(dyn) { raw_json.encode(dyn) |> result.unwrap("") }),
    ])
  decode.optional(string_or_json_object)
  |> decode.map(fn(opt) {
    case opt {
      Some(s) ->
        case string.trim(s) {
          "" -> None
          trimmed -> Some(trimmed)
        }
      None -> None
    }
  })
}

pub fn area_precision_decoder() -> decode.Decoder(Option(AreaPrecision)) {
  use opt_str <- decode.then(decode.optional(decode.string))
  case opt_str {
    None -> decode.success(None)
    Some(s) ->
      case string.trim(s) {
        "exact" -> decode.success(Some(Exact))
        "bbox" -> decode.success(Some(Bbox))
        _ -> decode.failure(None, "AreaPrecision (exact | bbox)")
      }
  }
}

fn cap_feature_decoder() -> decode.Decoder(Wis2CapFeature) {
  use notification_id <- decode.field("notification_id", decode.string)
  use data_id <- decode.field("data_id", decode.string)
  use topic <- decode.field("topic", decode.string)
  use centre_id <- decode.field("centre_id", decode.string)
  use channel <- decode.field("channel", decode.string)
  use pubtime <- decode.field("pubtime", decode.string)
  use datetime <- decode.optional_field(
    "datetime",
    None,
    decode.optional(decode.string),
  )
  use license_url <- decode.optional_field(
    "license_url",
    None,
    decode.optional(decode.string),
  )
  use fetched_via <- decode.field("fetched_via", decode.string)
  use download_url <- decode.optional_field(
    "download_url",
    None,
    decode.optional(decode.string),
  )
  use raw_xml <- decode.optional_field("raw_xml", "", decode.string)
  use cap_dyn <- decode.optional_field(
    "cap",
    None,
    decode.optional(decode.dynamic),
  )
  use area_key <- decode.optional_field(
    "area_key",
    None,
    decode.optional(decode.string),
  )
  use area_geometry <- decode.optional_field(
    "area_geometry",
    None,
    area_geometry_decoder(),
  )
  use area_precision_opt <- decode.optional_field(
    "area_precision",
    None,
    area_precision_decoder(),
  )

  let cap = case cap_dyn {
    Some(dyn) ->
      case models_cap.decode_cap(dyn) {
        Ok(msg) -> Some(msg)
        Error(_) -> None
      }
    None -> None
  }

  let area_precision = case area_precision_opt {
    Some(p) -> Some(p)
    None ->
      case area_geometry {
        Some(_) -> Some(Exact)
        None -> None
      }
  }

  decode.success(Wis2CapFeature(
    notification_id: string.trim(notification_id),
    data_id: string.trim(data_id),
    topic: string.trim(topic),
    centre_id: string.trim(centre_id),
    channel: string.trim(channel),
    pubtime: string.trim(pubtime),
    datetime: option.map(datetime, string.trim),
    license_url: option.map(license_url, string.trim),
    fetched_via: string.trim(fetched_via),
    download_url: option.map(download_url, string.trim),
    raw_xml:,
    cap:,
    area_key: option.map(area_key, string.trim),
    area_geometry:,
    area_precision:,
  ))
}

fn health_feature_decoder() -> decode.Decoder(Wis2HealthFeature) {
  use centre_id <- decode.field("centre_id", decode.string)
  use kind <- decode.field("kind", decode.string)
  use window_start <- decode.field("window_start", decode.string)
  use window_end <- decode.field("window_end", decode.string)
  use received <- decode.field("received", decode.int)
  use duplicates <- decode.field("duplicates", decode.int)
  use download_failed <- decode.field("download_failed", decode.int)
  use decode_failed <- decode.field("decode_failed", decode.int)
  use integrity_failed <- decode.field("integrity_failed", decode.int)
  use last_received_at <- decode.optional_field(
    "last_received_at",
    None,
    decode.optional(decode.string),
  )
  decode.success(Wis2HealthFeature(
    centre_id: string.trim(centre_id),
    kind: string.trim(kind),
    window_start: string.trim(window_start),
    window_end: string.trim(window_end),
    received:,
    duplicates:,
    download_failed:,
    decode_failed:,
    integrity_failed:,
    last_received_at: option.map(last_received_at, string.trim),
  ))
}

pub fn broker_to_json(b: BrokerState) -> json.Json {
  json.object([
    #("url", json.string(b.url)),
    #("connected", json.bool(b.connected)),
    #(
      "last_report_at",
      json.nullable(b.last_report_at, fn(t) {
        json.string(timestamp.to_rfc3339(t, calendar.utc_offset))
      }),
    ),
    #("error", json.nullable(b.error, json.string)),
  ])
}

pub fn channel_health_to_json(ch: ChannelHealth) -> json.Json {
  json.object([
    #("centre_id", json.string(ch.centre_id)),
    #("kind", json.string(ch.kind)),
    #("received_24h", json.int(ch.received_24h)),
    #("duplicates_24h", json.int(ch.duplicates_24h)),
    #("download_failed_24h", json.int(ch.download_failed_24h)),
    #("decode_failed_24h", json.int(ch.decode_failed_24h)),
    #("integrity_failed_24h", json.int(ch.integrity_failed_24h)),
    #(
      "last_received_at",
      json.nullable(ch.last_received_at, fn(t) {
        json.string(timestamp.to_rfc3339(t, calendar.utc_offset))
      }),
    ),
    #("status", json.string(channel_status_to_string(ch.status))),
  ])
}

pub fn health_report_to_json(
  broker: BrokerState,
  channels: List(ChannelHealth),
) -> json.Json {
  json.object([
    #("broker", broker_to_json(broker)),
    #("channels", json.array(channels, channel_health_to_json)),
  ])
}
