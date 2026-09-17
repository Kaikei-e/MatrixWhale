import erlang_tools/raw_json
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
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

pub fn decode_feature(
  data: Dynamic,
) -> Result(IncomingEarthquake, List(String)) {
  let decoder = {
    use source_id <- decode.field("id", decode.string)
    use feature_type <- decode.field("type", decode.string)
    use p <- decode.field("properties", props())
    use #(lon, lat, depth) <- decode.field("geometry", geo())
    let raw = raw_json.encode(data)
    let feature =
      IncomingEarthquake(
        source_id:,
        ids: p.0,
        sources: p.1,
        net: p.2,
        code: p.3,
        mag: p.4,
        mag_type: p.5,
        time: p.6,
        updated: p.7,
        place: p.8,
        title: p.9,
        status: p.10,
        type_: p.11,
        tsunami: p.12,
        sig: p.13,
        alert: p.14,
        mmi: p.15,
        cdi: p.16,
        felt: p.17,
        nst: p.18,
        dmin: p.19,
        rms: p.20,
        gap: p.21,
        url: p.22,
        detail: p.23,
        lon:,
        lat:,
        depth:,
        raw: result.unwrap(raw, ""),
      )
    case
      feature_type == "Feature"
      && source_id != ""
      && lon >=. -180.0
      && lon <=. 180.0
      && lat >=. -90.0
      && lat <=. 90.0
      && p.6 > 0
      && p.7 > 0
      && result.is_ok(raw)
    {
      True -> decode.success(feature)
      False -> decode.failure(feature, "valid USGS feature")
    }
  }
  decode.run(data, decoder) |> result.map_error(list.map(_, string.inspect))
}

type Props =
  #(
    List(String),
    List(String),
    Option(String),
    Option(String),
    Option(Float),
    Option(String),
    Int,
    Int,
    Option(String),
    Option(String),
    Option(String),
    Option(String),
    Option(Int),
    Option(Int),
    Option(String),
    Option(Float),
    Option(Float),
    Option(Int),
    Option(Int),
    Option(Float),
    Option(Float),
    Option(Float),
    Option(String),
    Option(String),
  )

fn props() -> decode.Decoder(Props) {
  use ids <- decode.optional_field("ids", None, decode.optional(decode.string))
  use sources <- decode.optional_field(
    "sources",
    None,
    decode.optional(decode.string),
  )
  use net <- decode.optional_field("net", None, decode.optional(decode.string))
  use code <- decode.optional_field(
    "code",
    None,
    decode.optional(decode.string),
  )
  use mag <- decode.optional_field("mag", None, decode.optional(num()))
  use mag_type <- decode.optional_field(
    "magType",
    None,
    decode.optional(decode.string),
  )
  use time <- decode.field("time", decode.int)
  use updated <- decode.field("updated", decode.int)
  use place <- decode.optional_field(
    "place",
    None,
    decode.optional(decode.string),
  )
  use title <- decode.optional_field(
    "title",
    None,
    decode.optional(decode.string),
  )
  use status <- decode.optional_field(
    "status",
    None,
    decode.optional(decode.string),
  )
  use type_ <- decode.optional_field(
    "type",
    None,
    decode.optional(decode.string),
  )
  use tsunami <- decode.optional_field(
    "tsunami",
    None,
    decode.optional(decode.int),
  )
  use sig <- decode.optional_field("sig", None, decode.optional(decode.int))
  use alert <- decode.optional_field(
    "alert",
    None,
    decode.optional(decode.string),
  )
  use mmi <- decode.optional_field("mmi", None, decode.optional(num()))
  use cdi <- decode.optional_field("cdi", None, decode.optional(num()))
  use felt <- decode.optional_field("felt", None, decode.optional(decode.int))
  use nst <- decode.optional_field("nst", None, decode.optional(decode.int))
  use dmin <- decode.optional_field("dmin", None, decode.optional(num()))
  use rms <- decode.optional_field("rms", None, decode.optional(num()))
  use gap <- decode.optional_field("gap", None, decode.optional(num()))
  use url <- decode.optional_field("url", None, decode.optional(decode.string))
  use detail <- decode.optional_field(
    "detail",
    None,
    decode.optional(decode.string),
  )
  decode.success(#(
    ids_to_list(ids),
    ids_to_list(sources),
    net,
    code,
    mag,
    mag_type,
    time,
    updated,
    place,
    title,
    status,
    type_,
    tsunami,
    sig,
    alert,
    mmi,
    cdi,
    felt,
    nst,
    dmin,
    rms,
    gap,
    url,
    detail,
  ))
}

fn geo() -> decode.Decoder(#(Float, Float, Option(Float))) {
  use type_ <- decode.field("type", decode.string)
  use xs <- decode.field("coordinates", decode.list(decode.optional(num())))
  case type_, xs {
    "Point", [Some(lon), Some(lat), depth, ..] ->
      decode.success(#(lon, lat, depth))
    "Point", [Some(lon), Some(lat)] -> decode.success(#(lon, lat, None))
    _, _ -> decode.failure(#(0.0, 0.0, None), "USGS Point coordinates")
  }
}

fn num() -> decode.Decoder(Float) {
  decode.one_of(decode.float, or: [decode.int |> decode.map(int.to_float)])
}

fn ids_to_list(x: Option(String)) -> List(String) {
  case x {
    Some(x) ->
      x
      |> string.split(",")
      |> list.map(string.trim)
      |> list.filter(fn(x) { x != "" })
    None -> []
  }
}
