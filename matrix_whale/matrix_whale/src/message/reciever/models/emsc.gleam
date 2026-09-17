import erlang_tools/raw_json
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/time/timestamp
import message/reciever/models/earthquake_feature.{
  type IncomingEarthquake, type PollMeta, IncomingEarthquake, PollMeta,
}

pub fn decode_body(
  data: Dynamic,
) -> Result(#(Option(PollMeta), List(IncomingEarthquake), Int, Int), String) {
  let decoder = {
    use poll_meta <- decode.optional_field(
      "poll_meta",
      None,
      decode.optional(meta()),
    )
    use raw <- decode.field("features", decode.list(decode.dynamic))
    decode.success(#(poll_meta, raw))
  }
  case decode.run(data, decoder) {
    Ok(#(poll_meta, raw)) -> {
      let rows =
        raw
        |> list.filter_map(fn(x) {
          case decode_feature(x) {
            Ok(x) -> Ok(x)
            Error(_) -> Error(Nil)
          }
        })
      Ok(#(
        poll_meta,
        rows,
        list.length(raw),
        list.length(raw) - list.length(rows),
      ))
    }
    Error(errors) -> Error(string.inspect(errors))
  }
}

fn meta() -> decode.Decoder(PollMeta) {
  use fetched_at <- decode.field("fetched_at", decode.string)
  use http_status <- decode.field("http_status", decode.int)
  use feature_count <- decode.field("feature_count", decode.int)
  use bytes <- decode.optional_field("bytes", 0, decode.int)
  use backfill <- decode.optional_field("backfill", False, decode.bool)
  decode.success(PollMeta(
    fetched_at:,
    http_status:,
    feature_count:,
    bytes:,
    backfill:,
  ))
}

/// Decodes one `{"action": "create"|"update"|"delete", "data": <GeoJSON
/// Feature>}` envelope entry into the shared `IncomingEarthquake` shape.
pub fn decode_feature(
  data: Dynamic,
) -> Result(IncomingEarthquake, List(String)) {
  let decoder = {
    use action <- decode.field("action", decode.string)
    use feature_type <- decode.subfield(["data", "type"], decode.string)
    use p <- decode.subfield(["data", "properties"], props())
    use payload <- decode.field("data", decode.dynamic)
    let raw = raw_json.encode(payload)
    let unid = p.0
    let time = rfc3339_to_ms(p.3)
    let updated = rfc3339_to_ms(p.2)
    let feature =
      IncomingEarthquake(
        source_id: unid,
        ids: [unid],
        sources: option.map(p.9, fn(a) { [a] }) |> option.unwrap([]),
        net: p.9,
        code: p.1,
        mag: p.10,
        mag_type: p.11,
        time:,
        updated:,
        place: p.4,
        title: Some(title_for(p.10, p.4)),
        status: Some(status_for(action)),
        type_: Some(event_type_for(p.8)),
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
        url: Some(
          "https://www.seismicportal.eu/eventdetails.html?unid=" <> unid,
        ),
        detail: None,
        lon: p.6,
        lat: p.5,
        depth: p.7,
        raw: result.unwrap(raw, ""),
      )
    case
      feature_type == "Feature"
      && unid != ""
      && feature.lon >=. -180.0
      && feature.lon <=. 180.0
      && feature.lat >=. -90.0
      && feature.lat <=. 90.0
      && time > 0
      && updated > 0
      && result.is_ok(raw)
    {
      True -> decode.success(feature)
      False -> decode.failure(feature, "valid EMSC feature")
    }
  }
  decode.run(data, decoder) |> result.map_error(list.map(_, string.inspect))
}

type Props =
  #(
    String,
    Option(String),
    String,
    String,
    Option(String),
    Float,
    Float,
    Option(Float),
    Option(String),
    Option(String),
    Option(Float),
    Option(String),
  )

fn props() -> decode.Decoder(Props) {
  use unid <- decode.optional_field("unid", "", decode.string)
  use source_id <- decode.optional_field(
    "source_id",
    None,
    decode.optional(decode.string),
  )
  use lastupdate <- decode.optional_field("lastupdate", "", decode.string)
  use time <- decode.optional_field("time", "", decode.string)
  use flynn_region <- decode.optional_field(
    "flynn_region",
    None,
    decode.optional(decode.string),
  )
  use lat <- decode.optional_field("lat", 0.0, num())
  use lon <- decode.optional_field("lon", 0.0, num())
  use depth <- decode.optional_field("depth", None, decode.optional(num()))
  use evtype <- decode.optional_field(
    "evtype",
    None,
    decode.optional(decode.string),
  )
  use auth <- decode.optional_field(
    "auth",
    None,
    decode.optional(decode.string),
  )
  use mag <- decode.optional_field("mag", None, decode.optional(num()))
  use magtype <- decode.optional_field(
    "magtype",
    None,
    decode.optional(decode.string),
  )
  decode.success(#(
    unid,
    source_id,
    lastupdate,
    time,
    flynn_region,
    lat,
    lon,
    depth,
    evtype,
    auth,
    mag,
    magtype,
  ))
}

fn num() -> decode.Decoder(Float) {
  decode.one_of(decode.float, or: [decode.int |> decode.map(int.to_float)])
}

/// Sub-millisecond precision is truncated by an integer-ms conversion, and an
/// unparseable timestamp becomes 0 so the feature fails the caller's validity
/// check rather than being kept with a made-up time.
fn rfc3339_to_ms(input: String) -> Int {
  case timestamp.parse_rfc3339(input) {
    Ok(ts) -> {
      let #(seconds, nanoseconds) =
        timestamp.to_unix_seconds_and_nanoseconds(ts)
      seconds * 1000 + nanoseconds / 1_000_000
    }
    Error(_) -> 0
  }
}

fn status_for(action: String) -> String {
  case action {
    "delete" -> "deleted"
    _ -> "automatic"
  }
}

/// ISC 2-letter event type codes, per the EMSC/ISC catalogue vocabulary.
fn event_type_for(evtype: Option(String)) -> String {
  case option.map(evtype, string.lowercase) {
    Some("ke") | Some("se") | Some("fe") | Some("de") -> "earthquake"
    Some("kr") | Some("sr") -> "rock burst"
    Some("ki") | Some("si") -> "induced or triggered event"
    Some("km") | Some("sm") -> "mining explosion"
    Some("kh") | Some("sh") | Some("kx") | Some("sx") -> "explosion"
    Some("kn") | Some("sn") -> "nuclear explosion"
    Some("ls") -> "landslide"
    _ -> "other event"
  }
}

fn title_for(mag: Option(Float), place: Option(String)) -> String {
  "M " <> mag_text(mag) <> " - " <> option.unwrap(place, "unknown")
}

fn mag_text(mag: Option(Float)) -> String {
  case mag {
    Some(value) -> float.to_string(float.to_precision(value, 1))
    None -> "?"
  }
}
