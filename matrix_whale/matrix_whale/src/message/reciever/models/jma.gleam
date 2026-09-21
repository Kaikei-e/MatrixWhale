import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{type Option, None}
import gleam/string

pub type JmaPollMeta {
  JmaPollMeta(
    fetched_at: String,
    http_status: Int,
    feature_count: Int,
    bytes: Int,
    feed_url: Option(String),
    backfill: Bool,
    error: Option(String),
    format: Option(String),
  )
}

pub type JmaIndexItem {
  JmaIndexItem(
    item_url: String,
    feed_url: String,
    guid: Option(String),
    title: Option(String),
    published: Option(String),
  )
}

pub type JmaArea {
  JmaArea(area_name: String, geocode: String)
}

pub type JmaAlertItem {
  JmaAlertItem(
    lifecycle_key: String,
    area_name: String,
    geocode: String,
    event: String,
    category: Option(String),
    status: String,
    severity: String,
    urgency: String,
    certainty: String,
  )
}

pub type JmaEarthquake {
  JmaEarthquake(
    origin_time: String,
    latitude: Option(Float),
    longitude: Option(Float),
    depth_km: Option(Float),
    magnitude: Option(Float),
    magnitude_type: Option(String),
    place: Option(String),
    max_intensity: Option(String),
  )
}

pub type JmaMessageContent {
  JmaMessageContent(
    identifier: String,
    control_title: String,
    status: String,
    info_type: String,
    event_id: Option(String),
    series_key: Option(String),
    sent: String,
    effective: Option(String),
    expires: Option(String),
    headline: Option(String),
    description: Option(String),
    areas: List(JmaArea),
    alerts: List(JmaAlertItem),
    cleared_areas: List(String),
    earthquake: Option(JmaEarthquake),
  )
}

pub type JmaFetchResult {
  JmaFetchResult(
    item_url: String,
    feed_url: String,
    fetched_at: String,
    http_status: Int,
    error: Option(String),
    raw_xml: Option(String),
    message: Option(JmaMessageContent),
  )
}

pub fn decode_index_body(
  data: Dynamic,
) -> Result(#(Option(JmaPollMeta), List(JmaIndexItem), Int, Int), String) {
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
          case decode.run(x, index_item_decoder()) {
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

pub fn decode_messages_body(
  data: Dynamic,
) -> Result(#(Option(JmaPollMeta), List(JmaFetchResult), Int, Int), String) {
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
          case decode.run(x, fetch_result_decoder()) {
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

fn poll_meta_decoder() -> decode.Decoder(JmaPollMeta) {
  use fetched_at <- decode.field("fetched_at", decode.string)
  use http_status <- decode.field("http_status", decode.int)
  use feature_count <- decode.field("feature_count", decode.int)
  use bytes <- decode.field("bytes", decode.int)
  use feed_url <- decode.optional_field(
    "feed_url",
    None,
    decode.optional(decode.string),
  )
  use backfill <- decode.optional_field("backfill", False, decode.bool)
  use error <- decode.optional_field(
    "error",
    None,
    decode.optional(decode.string),
  )
  use format <- decode.optional_field(
    "format",
    None,
    decode.optional(decode.string),
  )
  decode.success(JmaPollMeta(
    fetched_at:,
    http_status:,
    feature_count:,
    bytes:,
    feed_url:,
    backfill:,
    error:,
    format:,
  ))
}

fn index_item_decoder() -> decode.Decoder(JmaIndexItem) {
  use item_url <- decode.field("item_url", decode.string)
  use feed_url <- decode.field("feed_url", decode.string)
  use guid <- decode.optional_field(
    "guid",
    None,
    decode.optional(decode.string),
  )
  use title <- decode.optional_field(
    "title",
    None,
    decode.optional(decode.string),
  )
  use published <- decode.optional_field(
    "published",
    None,
    decode.optional(decode.string),
  )
  // Ensure item_url is non-empty and starts with http
  case
    string.starts_with(item_url, "http://")
    || string.starts_with(item_url, "https://")
  {
    True ->
      decode.success(JmaIndexItem(
        item_url:,
        feed_url:,
        guid:,
        title:,
        published:,
      ))
    False ->
      decode.failure(
        JmaIndexItem(item_url:, feed_url:, guid:, title:, published:),
        "item_url must start with http:// or https://",
      )
  }
}

fn area_decoder() -> decode.Decoder(JmaArea) {
  use area_name <- decode.field("area_name", decode.string)
  use geocode <- decode.field("geocode", decode.string)
  decode.success(JmaArea(area_name:, geocode:))
}

fn alert_item_decoder() -> decode.Decoder(JmaAlertItem) {
  use lifecycle_key <- decode.field("lifecycle_key", decode.string)
  use area_name <- decode.field("area_name", decode.string)
  use geocode <- decode.field("geocode", decode.string)
  use event <- decode.field("event", decode.string)
  use category <- decode.optional_field(
    "category",
    None,
    decode.optional(decode.string),
  )
  use status <- decode.optional_field("status", "発表", decode.string)
  use severity <- decode.optional_field("severity", "Moderate", decode.string)
  use urgency <- decode.optional_field("urgency", "Expected", decode.string)
  use certainty <- decode.optional_field("certainty", "Observed", decode.string)
  decode.success(JmaAlertItem(
    lifecycle_key:,
    area_name:,
    geocode:,
    event:,
    category:,
    status:,
    severity:,
    urgency:,
    certainty:,
  ))
}

pub fn number_decoder() -> decode.Decoder(Float) {
  decode.one_of(decode.float, or: [decode.int |> decode.map(int.to_float)])
}

fn earthquake_decoder() -> decode.Decoder(JmaEarthquake) {
  use origin_time <- decode.field("origin_time", decode.string)
  use latitude <- decode.optional_field(
    "latitude",
    None,
    decode.optional(number_decoder()),
  )
  use longitude <- decode.optional_field(
    "longitude",
    None,
    decode.optional(number_decoder()),
  )
  use depth_km <- decode.optional_field(
    "depth_km",
    None,
    decode.optional(number_decoder()),
  )
  use magnitude <- decode.optional_field(
    "magnitude",
    None,
    decode.optional(number_decoder()),
  )
  use magnitude_type <- decode.optional_field(
    "magnitude_type",
    None,
    decode.optional(decode.string),
  )
  use place <- decode.optional_field(
    "place",
    None,
    decode.optional(decode.string),
  )
  use max_intensity <- decode.optional_field(
    "max_intensity",
    None,
    decode.optional(decode.string),
  )
  decode.success(JmaEarthquake(
    origin_time:,
    latitude:,
    longitude:,
    depth_km:,
    magnitude:,
    magnitude_type:,
    place:,
    max_intensity:,
  ))
}

fn message_content_decoder() -> decode.Decoder(JmaMessageContent) {
  use identifier <- decode.field("identifier", decode.string)
  use control_title <- decode.field("control_title", decode.string)
  use status <- decode.field("status", decode.string)
  use info_type <- decode.field("info_type", decode.string)
  use event_id <- decode.optional_field(
    "event_id",
    None,
    decode.optional(decode.string),
  )
  use series_key <- decode.optional_field(
    "series_key",
    None,
    decode.optional(decode.string),
  )
  use sent <- decode.field("sent", decode.string)
  use effective <- decode.optional_field(
    "effective",
    None,
    decode.optional(decode.string),
  )
  use expires <- decode.optional_field(
    "expires",
    None,
    decode.optional(decode.string),
  )
  use headline <- decode.optional_field(
    "headline",
    None,
    decode.optional(decode.string),
  )
  use description <- decode.optional_field(
    "description",
    None,
    decode.optional(decode.string),
  )
  use areas <- decode.optional_field("areas", [], decode.list(area_decoder()))
  use alerts <- decode.optional_field(
    "alerts",
    [],
    decode.list(alert_item_decoder()),
  )
  use cleared_areas <- decode.optional_field(
    "cleared_areas",
    [],
    decode.list(decode.string),
  )
  use earthquake <- decode.optional_field(
    "earthquake",
    None,
    decode.optional(earthquake_decoder()),
  )
  decode.success(JmaMessageContent(
    identifier:,
    control_title:,
    status:,
    info_type:,
    event_id:,
    series_key:,
    sent:,
    effective:,
    expires:,
    headline:,
    description:,
    areas:,
    alerts:,
    cleared_areas:,
    earthquake:,
  ))
}

fn fetch_result_decoder() -> decode.Decoder(JmaFetchResult) {
  use item_url <- decode.field("item_url", decode.string)
  use feed_url <- decode.field("feed_url", decode.string)
  use fetched_at <- decode.field("fetched_at", decode.string)
  use http_status <- decode.field("http_status", decode.int)
  use error <- decode.optional_field(
    "error",
    None,
    decode.optional(decode.string),
  )
  use raw_xml <- decode.optional_field(
    "raw_xml",
    None,
    decode.optional(decode.string),
  )
  use message <- decode.optional_field(
    "message",
    None,
    decode.optional(message_content_decoder()),
  )
  decode.success(JmaFetchResult(
    item_url:,
    feed_url:,
    fetched_at:,
    http_status:,
    error:,
    raw_xml:,
    message:,
  ))
}
