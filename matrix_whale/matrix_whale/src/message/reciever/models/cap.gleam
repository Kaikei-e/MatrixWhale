import erlang_tools/raw_json
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub type CapPollMeta {
  CapPollMeta(
    fetched_at: String,
    http_status: Int,
    feature_count: Int,
    bytes: Int,
    backfill: Bool,
    feed_url: Option(String),
    error: Option(String),
    format: Option(String),
  )
}

pub type RegistryFeed {
  RegistryFeed(url: String, language: Option(String))
}

pub type RegistryItem {
  RegistryItem(
    guid: String,
    title: Option(String),
    country_iso3: Option(String),
    link: Option(String),
    description: Option(String),
    pub_date: Option(String),
    abbrev: Option(String),
    feeds: List(RegistryFeed),
  )
}

pub type IndexItem {
  IndexItem(
    guid: Option(String),
    title: Option(String),
    cap_url: String,
    published: Option(String),
  )
}

pub type ValuePair {
  ValuePair(value_name: String, value: String)
}

pub type CapResource {
  CapResource(
    resource_desc: String,
    mime_type: Option(String),
    size: Option(Int),
    uri: Option(String),
    digest: Option(String),
  )
}

pub type CapArea {
  CapArea(
    area_desc: String,
    polygon: List(String),
    circle: List(String),
    geocode: List(ValuePair),
    altitude: Option(String),
    ceiling: Option(String),
  )
}

pub type CapInfo {
  CapInfo(
    language: Option(String),
    category: List(String),
    event: String,
    response_type: List(String),
    urgency: String,
    severity: String,
    certainty: String,
    audience: Option(String),
    event_code: List(ValuePair),
    effective: Option(String),
    onset: Option(String),
    expires: Option(String),
    sender_name: Option(String),
    headline: Option(String),
    description: Option(String),
    instruction: Option(String),
    web: Option(String),
    contact: Option(String),
    parameter: List(ValuePair),
    resource: List(CapResource),
    area: List(CapArea),
  )
}

pub type CapMessage {
  CapMessage(
    cap_version: Option(String),
    identifier: String,
    sender: String,
    sent: String,
    status: String,
    msg_type: String,
    source: Option(String),
    scope: String,
    restriction: Option(String),
    addresses: Option(String),
    code: List(String),
    note: Option(String),
    references: Option(String),
    incidents: Option(String),
    info: List(CapInfo),
    raw_json: String,
  )
}

pub type CapFetchResult {
  CapFetchResult(
    cap_url: String,
    feed_url: String,
    fetched_at: String,
    http_status: Int,
    error: Option(String),
    cap: Option(CapMessage),
    raw_cap_json: Option(String),
    raw_xml: Option(String),
  )
}

pub fn decode_registry_body(
  data: Dynamic,
) -> Result(#(Option(CapPollMeta), List(RegistryItem), Int, Int), String) {
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
          case decode.run(x, registry_item_decoder()) {
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

pub fn decode_index_body(
  data: Dynamic,
) -> Result(#(Option(CapPollMeta), List(IndexItem), Int, Int), String) {
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

pub fn decode_alerts_body(
  data: Dynamic,
) -> Result(#(Option(CapPollMeta), List(CapFetchResult), Int, Int), String) {
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

pub fn decode_cap(data: Dynamic) -> Result(CapMessage, String) {
  let raw = raw_json.encode(data) |> result.unwrap("")
  decode.run(data, cap_message_decoder(raw))
  |> result.map_error(fn(errors) { string.inspect(errors) })
}

pub fn decode_cap_json(json_str: String) -> Result(CapMessage, String) {
  case json.parse(json_str, decode.dynamic) {
    Ok(dyn) -> decode_cap(dyn)
    Error(err) -> Error(string.inspect(err))
  }
}

fn poll_meta_decoder() -> decode.Decoder(CapPollMeta) {
  use fetched_at <- decode.field("fetched_at", decode.string)
  use http_status <- decode.field("http_status", decode.int)
  use feature_count <- decode.field("feature_count", decode.int)
  use bytes <- decode.optional_field("bytes", 0, decode.int)
  use backfill <- decode.optional_field("backfill", False, decode.bool)
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
  use format <- decode.optional_field(
    "format",
    None,
    decode.optional(decode.string),
  )
  decode.success(CapPollMeta(
    fetched_at:,
    http_status:,
    feature_count:,
    bytes:,
    backfill:,
    feed_url:,
    error:,
    format:,
  ))
}

fn registry_feed_decoder() -> decode.Decoder(RegistryFeed) {
  use url <- decode.field("url", decode.string)
  use language <- decode.optional_field(
    "language",
    None,
    decode.optional(decode.string),
  )
  decode.success(RegistryFeed(url: string.trim(url), language:))
}

fn registry_item_decoder() -> decode.Decoder(RegistryItem) {
  use guid <- decode.field("guid", decode.string)
  use title <- decode.optional_field(
    "title",
    None,
    decode.optional(decode.string),
  )
  use country_iso3 <- decode.optional_field(
    "country_iso3",
    None,
    decode.optional(decode.string),
  )
  use link <- decode.optional_field(
    "link",
    None,
    decode.optional(decode.string),
  )
  use description <- decode.optional_field(
    "description",
    None,
    decode.optional(decode.string),
  )
  use pub_date <- decode.optional_field(
    "pub_date",
    None,
    decode.optional(decode.string),
  )
  use abbrev <- decode.optional_field(
    "abbrev",
    None,
    decode.optional(decode.string),
  )
  use feeds <- decode.optional_field(
    "feeds",
    [],
    decode.list(registry_feed_decoder()),
  )
  let trimmed_guid = string.trim(guid)
  let item =
    RegistryItem(
      guid: trimmed_guid,
      title: option.map(title, string.trim),
      country_iso3: option.map(country_iso3, string.trim),
      link: option.map(link, string.trim),
      description: option.map(description, string.trim),
      pub_date: option.map(pub_date, string.trim),
      abbrev: option.map(abbrev, string.trim),
      feeds:,
    )
  case trimmed_guid != "" {
    True -> decode.success(item)
    False -> decode.failure(item, "valid registry item with non-empty guid")
  }
}

fn index_item_decoder() -> decode.Decoder(IndexItem) {
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
  use cap_url <- decode.optional_field(
    "cap_url",
    None,
    decode.optional(decode.string),
  )
  use published <- decode.optional_field(
    "published",
    None,
    decode.optional(decode.string),
  )
  case cap_url {
    Some(url) -> {
      let trimmed = string.trim(url)
      case
        string.starts_with(trimmed, "http://")
        || string.starts_with(trimmed, "https://")
      {
        True ->
          decode.success(IndexItem(
            guid: option.map(guid, string.trim),
            title: option.map(title, string.trim),
            cap_url: trimmed,
            published: option.map(published, string.trim),
          ))
        False ->
          decode.failure(
            IndexItem(guid, title, "", published),
            "http(s) cap_url",
          )
      }
    }
    None ->
      decode.failure(IndexItem(guid, title, "", published), "present cap_url")
  }
}

fn fetch_result_decoder() -> decode.Decoder(CapFetchResult) {
  use cap_url <- decode.field("cap_url", decode.string)
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
  use cap_dyn <- decode.optional_field(
    "cap",
    None,
    decode.optional(decode.dynamic),
  )
  let #(cap, raw_cap_json) = case cap_dyn {
    Some(dyn) -> {
      let raw_encoded = raw_json.encode(dyn) |> option.from_result
      case decode_cap(dyn) {
        Ok(msg) -> #(Some(msg), raw_encoded)
        Error(_) -> #(None, raw_encoded)
      }
    }
    None -> #(None, None)
  }
  let trimmed_cap_url = string.trim(cap_url)
  let trimmed_feed_url = string.trim(feed_url)
  case trimmed_cap_url != "" && trimmed_feed_url != "" {
    True ->
      decode.success(CapFetchResult(
        cap_url: trimmed_cap_url,
        feed_url: trimmed_feed_url,
        fetched_at: string.trim(fetched_at),
        http_status:,
        error: option.map(error, string.trim),
        cap:,
        raw_cap_json:,
        raw_xml:,
      ))
    False ->
      decode.failure(
        CapFetchResult(
          trimmed_cap_url,
          trimmed_feed_url,
          fetched_at,
          http_status,
          error,
          cap,
          raw_cap_json,
          raw_xml,
        ),
        "valid CapFetchResult",
      )
  }
}

fn value_pair_decoder() -> decode.Decoder(ValuePair) {
  use value_name <- decode.field("valueName", string_or_number_as_string())
  use value <- decode.field("value", string_or_number_as_string())
  decode.success(ValuePair(
    value_name: string.trim(value_name),
    value: string.trim(value),
  ))
}

fn string_or_number_as_string() -> decode.Decoder(String) {
  decode.one_of(decode.string, [
    decode.int |> decode.map(int.to_string),
    decode.float |> decode.map(float.to_string),
  ])
}

fn optional_list(decoder: decode.Decoder(a)) -> decode.Decoder(List(a)) {
  decode.optional(decode.list(decoder))
  |> decode.map(option.unwrap(_, []))
}

fn lenient_size_decoder() -> decode.Decoder(Option(Int)) {
  let inner =
    decode.one_of(decode.int |> decode.map(Some), [
      decode.string
        |> decode.map(fn(s) {
          case int.parse(string.trim(s)) {
            Ok(i) -> Some(i)
            Error(_) -> None
          }
        }),
      decode.dynamic |> decode.map(fn(_) { None }),
    ])
  decode.optional(inner) |> decode.map(option.flatten)
}

fn cap_resource_decoder() -> decode.Decoder(CapResource) {
  use resource_desc <- decode.optional_field("resourceDesc", "", decode.string)
  use mime_type <- decode.optional_field(
    "mimeType",
    None,
    decode.optional(decode.string),
  )
  use size <- decode.optional_field("size", None, lenient_size_decoder())
  use uri <- decode.optional_field("uri", None, decode.optional(decode.string))
  use digest <- decode.optional_field(
    "digest",
    None,
    decode.optional(decode.string),
  )
  decode.success(CapResource(
    resource_desc: string.trim(resource_desc),
    mime_type: option.map(mime_type, string.trim),
    size:,
    uri: option.map(uri, string.trim),
    digest: option.map(digest, string.trim),
  ))
}

fn cap_area_decoder() -> decode.Decoder(CapArea) {
  use area_desc <- decode.optional_field("areaDesc", "", decode.string)
  use polygon <- decode.optional_field(
    "polygon",
    [],
    optional_list(decode.string),
  )
  use circle <- decode.optional_field(
    "circle",
    [],
    optional_list(decode.string),
  )
  use geocode <- decode.optional_field(
    "geocode",
    [],
    optional_list(value_pair_decoder()),
  )
  use altitude <- decode.optional_field(
    "altitude",
    None,
    decode.optional(string_or_number_as_string()),
  )
  use ceiling <- decode.optional_field(
    "ceiling",
    None,
    decode.optional(string_or_number_as_string()),
  )
  decode.success(CapArea(
    area_desc: string.trim(area_desc),
    polygon: list.map(polygon, string.trim),
    circle: list.map(circle, string.trim),
    geocode:,
    altitude: option.map(altitude, string.trim),
    ceiling: option.map(ceiling, string.trim),
  ))
}

fn cap_info_decoder() -> decode.Decoder(CapInfo) {
  use language <- decode.optional_field(
    "language",
    None,
    decode.optional(decode.string),
  )
  use category <- decode.optional_field(
    "category",
    [],
    optional_list(decode.string),
  )
  use event <- decode.optional_field("event", "", decode.string)
  use response_type <- decode.optional_field(
    "responseType",
    [],
    optional_list(decode.string),
  )
  use urgency <- decode.optional_field("urgency", "", decode.string)
  use severity <- decode.optional_field("severity", "", decode.string)
  use certainty <- decode.optional_field("certainty", "", decode.string)
  use audience <- decode.optional_field(
    "audience",
    None,
    decode.optional(decode.string),
  )
  use event_code <- decode.optional_field(
    "eventCode",
    [],
    optional_list(value_pair_decoder()),
  )
  use effective <- decode.optional_field(
    "effective",
    None,
    decode.optional(decode.string),
  )
  use onset <- decode.optional_field(
    "onset",
    None,
    decode.optional(decode.string),
  )
  use expires <- decode.optional_field(
    "expires",
    None,
    decode.optional(decode.string),
  )
  use sender_name <- decode.optional_field(
    "senderName",
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
  use instruction <- decode.optional_field(
    "instruction",
    None,
    decode.optional(decode.string),
  )
  use web <- decode.optional_field("web", None, decode.optional(decode.string))
  use contact <- decode.optional_field(
    "contact",
    None,
    decode.optional(decode.string),
  )
  use parameter <- decode.optional_field(
    "parameter",
    [],
    optional_list(value_pair_decoder()),
  )
  use resource <- decode.optional_field(
    "resource",
    [],
    optional_list(cap_resource_decoder()),
  )
  use area <- decode.optional_field(
    "area",
    [],
    optional_list(cap_area_decoder()),
  )
  decode.success(CapInfo(
    language: option.map(language, string.trim),
    category: list.map(category, string.trim),
    event: string.trim(event),
    response_type: list.map(response_type, string.trim),
    urgency: string.trim(urgency),
    severity: string.trim(severity),
    certainty: string.trim(certainty),
    audience: option.map(audience, string.trim),
    event_code:,
    effective: option.map(effective, string.trim),
    onset: option.map(onset, string.trim),
    expires: option.map(expires, string.trim),
    sender_name: option.map(sender_name, string.trim),
    headline: option.map(headline, string.trim),
    description: option.map(description, string.trim),
    instruction: option.map(instruction, string.trim),
    web: option.map(web, string.trim),
    contact: option.map(contact, string.trim),
    parameter:,
    resource:,
    area:,
  ))
}

fn cap_message_decoder(raw_json_str: String) -> decode.Decoder(CapMessage) {
  use cap_version <- decode.optional_field(
    "cap_version",
    None,
    decode.optional(decode.string),
  )
  use identifier <- decode.field("identifier", decode.string)
  use sender <- decode.field("sender", decode.string)
  use sent <- decode.field("sent", decode.string)
  use status <- decode.field("status", decode.string)
  use msg_type <- decode.field("msgType", decode.string)
  use source <- decode.optional_field(
    "source",
    None,
    decode.optional(decode.string),
  )
  use scope <- decode.field("scope", decode.string)
  use restriction <- decode.optional_field(
    "restriction",
    None,
    decode.optional(decode.string),
  )
  use addresses <- decode.optional_field(
    "addresses",
    None,
    decode.optional(decode.string),
  )
  use code <- decode.optional_field("code", [], optional_list(decode.string))
  use note <- decode.optional_field(
    "note",
    None,
    decode.optional(decode.string),
  )
  use references <- decode.optional_field(
    "references",
    None,
    decode.optional(decode.string),
  )
  use incidents <- decode.optional_field(
    "incidents",
    None,
    decode.optional(decode.string),
  )
  use info <- decode.optional_field(
    "info",
    [],
    optional_list(cap_info_decoder()),
  )
  let trimmed_identifier = string.trim(identifier)
  let trimmed_sender = string.trim(sender)
  let trimmed_sent = string.trim(sent)
  let trimmed_status = string.trim(status)
  let trimmed_msg_type = string.trim(msg_type)
  let trimmed_scope = string.trim(scope)
  let msg =
    CapMessage(
      cap_version: option.map(cap_version, string.trim),
      identifier: trimmed_identifier,
      sender: trimmed_sender,
      sent: trimmed_sent,
      status: trimmed_status,
      msg_type: trimmed_msg_type,
      source: option.map(source, string.trim),
      scope: trimmed_scope,
      restriction: option.map(restriction, string.trim),
      addresses: option.map(addresses, string.trim),
      code: list.map(code, string.trim),
      note: option.map(note, string.trim),
      references: option.map(references, string.trim),
      incidents: option.map(incidents, string.trim),
      info:,
      raw_json: raw_json_str,
    )
  case
    trimmed_identifier != ""
    && trimmed_sender != ""
    && trimmed_sent != ""
    && trimmed_status != ""
    && trimmed_msg_type != ""
    && trimmed_scope != ""
  {
    True -> decode.success(msg)
    False -> decode.failure(msg, "valid CAP message with required elements")
  }
}
