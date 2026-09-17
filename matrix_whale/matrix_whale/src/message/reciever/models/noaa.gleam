import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/string
import wisp

pub type Alerts {
  Alerts(
    context: String,
    type_: String,
    features: List(Dynamic),
    title: String,
    updated: String,
    pagination: String,
  )
}

pub type Features {
  Features(elements: List(FeatureElement))
}

pub type ContextClass {
  ContextClass(version: String, wx: String, vocab: String)
}

pub type ContextElement {
  ContextClassElement(context_class: ContextClass)
  URL(url: String)
}

pub type FeatureElement {
  FeatureElement(
    id: String,
    type_: String,
    geometry: Option(Geometry),
    properties: Properties,
  )
}

pub type FeatureType {
  FeatureType(String)
}

pub type Feature {
  Feature
}

/// Coordinates are normalised into a list of polygons, each a list of
/// rings, each a list of `#(longitude, latitude)` positions. A `Polygon`
/// feature is represented as a single-element list; a `MultiPolygon`
/// feature keeps each of its polygons as a separate element.
pub type Geometry {
  Geometry(type_: String, polygons: List(List(List(#(Float, Float)))))
}

pub type Properties {
  Properties(
    id: Option(String),
    type_: Option(String),
    properties_id: Option(String),
    area_desc: String,
    geocode: Geocode,
    affected_zones: List(String),
    references: List(Reference),
    sent: Option(String),
    effective: String,
    onset: Option(String),
    expires: String,
    ends: Option(String),
    status: Status,
    message_type: Option(MessageType),
    category: Category,
    severity: Severity,
    certainty: Certainty,
    urgency: Urgency,
    event: String,
    sender: Sender,
    sender_name: Option(String),
    headline: Option(String),
    description: Option(String),
    instruction: Option(String),
    response: Response,
    parameters: Dict(String, List(String)),
    replaced_by: Option(String),
    replaced_at: Option(String),
  )
}

pub type Geocode {
  Geocode(same: List(String), ugc: List(String))
}

pub type Reference {
  Reference(id: String, identifier: String, sender: Sender, sent: String)
}

pub type Pagination {
  Pagination(next: String)
}

pub type Category {
  Met
  UnknownCategory
}

pub type Certainty {
  Unknown
  Likely
  Observed
  Possible
}

pub type MessageType {
  Alert
  Cancel
  Update
  UnknownMessageType
}

pub type Sender {
  Sender(String)
}

pub type Response {
  AllClear
  Avoid
  Execute
  Monitor
  None
  Prepare
  Shelter
}

pub type Severity {
  Extreme
  Severe
  Moderate
  Minor
  UnknownSeverity
}

pub type Status {
  Actual
  Test
  UnknownStatus
}

pub type Urgency {
  Expected
  Future
  Immediate
  Past
  UnknownUrgency
}

pub type CustomTypesList {
  GeocodeType(Geocode)
  ReferenceType(Reference)
  StatusType(Status)
  MessageType(MessageType)
  CategoryType(Category)
  SeverityType(Severity)
  CertaintyType(Certainty)
  UrgencyType(Urgency)
  SenderType(Sender)
  ResponseType(Response)
}

/// Metadata the adapter attaches to a poll before posting the features it
/// fetched. Absent for the legacy adapter, which posts the raw NWS
/// `FeatureCollection` with no wrapping object.
pub type PollMeta {
  PollMeta(fetched_at: String, http_status: Int, feature_count: Int)
}

/// Decodes the `/api/v1/noaa_data/send` request body. Accepts both the
/// `{"poll_meta": ..., "features": [...]}` envelope and a bare NWS
/// `FeatureCollection`, since `poll_meta` is an optional field either way.
/// Returns the decoded poll metadata, the features that decoded
/// successfully, how many features were received, and how many were
/// dropped because they failed to decode.
pub fn decode_body(
  data: Dynamic,
) -> #(Option(PollMeta), List(FeatureElement), Int, Int) {
  let decoder = {
    use poll_meta <- decode.optional_field(
      "poll_meta",
      option.None,
      decode_poll_meta(),
    )
    use features <- decode.field("features", decode.list(decode.dynamic))
    decode.success(#(poll_meta, features))
  }

  case decode.run(data, decoder) {
    Ok(#(poll_meta, raw_features)) -> {
      let received = list.length(raw_features)
      let decoded =
        raw_features
        |> list.filter_map(fn(feature) {
          case decode_feature(feature) {
            Ok(feature) -> Ok(feature)
            Error(errors) -> {
              wisp.log_warning(
                "Dropped feature: failed to decode - " <> string.inspect(errors),
              )
              Error(Nil)
            }
          }
        })
      let dropped = received - list.length(decoded)
      #(poll_meta, decoded, received, dropped)
    }
    Error(errors) -> {
      wisp.log_error("Error decoding request body: " <> string.inspect(errors))
      #(option.None, [], 0, 0)
    }
  }
}

fn decode_poll_meta() -> decode.Decoder(Option(PollMeta)) {
  decode.optional({
    use fetched_at <- decode.field("fetched_at", decode.string)
    use http_status <- decode.field("http_status", decode.int)
    use feature_count <- decode.field("feature_count", decode.int)
    decode.success(PollMeta(fetched_at, http_status, feature_count))
  })
}

pub fn prepare_feature_for_decoding(
  feature: Dynamic,
) -> Result(String, List(decode.DecodeError)) {
  decode.run(feature, decode.string)
}

pub fn decode_feature(data: Dynamic) -> Result(FeatureElement, List(String)) {
  let decoder = {
    use id <- decode.field("id", decode.string)
    use type_ <- decode.field("type", decode.string)
    use geometry <- decode.field("geometry", decode.optional(decode_geometry()))
    use properties <- decode.field("properties", decode_properties())
    decode.success(FeatureElement(id, type_, geometry, properties))
  }

  decode.run(data, decoder)
  |> result.map_error(list.map(_, string.inspect))
}

fn decode_properties() -> decode.Decoder(Properties) {
  {
    use id <- decode.optional_field(
      "@id",
      option.None,
      decode.optional(decode.string),
    )
    use type_ <- decode.optional_field(
      "type",
      option.None,
      decode.optional(decode.string),
    )
    use properties_id <- decode.optional_field(
      "id",
      option.None,
      decode.optional(decode.string),
    )
    use area_desc <- decode.field("areaDesc", decode.string)
    use geocode <- decode.optional_field(
      "geocode",
      Geocode([], []),
      decode.optional(decode_geocode())
        |> decode.map(fn(maybe_geocode) {
          case maybe_geocode {
            option.Some(geocode) -> geocode
            option.None -> Geocode([], [])
          }
        }),
    )
    use affected_zones <- decode.optional_field(
      "affectedZones",
      [],
      decode.optional(decode.list(decode.string))
        |> decode.map(fn(maybe_zones) {
          case maybe_zones {
            option.Some(zones) -> zones
            _ -> []
          }
        }),
    )
    use references <- decode.optional_field(
      "references",
      [],
      decode.optional(decode.list(decode_reference()))
        |> decode.map(fn(x) { x |> option.unwrap([]) }),
    )
    use sent <- decode.optional_field(
      "sent",
      option.None,
      decode.optional(decode.string),
    )
    use effective <- decode.field("effective", decode.string)
    use onset <- decode.optional_field(
      "onset",
      option.None,
      decode.optional(decode.string),
    )
    use expires <- decode.field("expires", decode.string)
    use ends <- decode.optional_field(
      "ends",
      option.None,
      decode.optional(decode.string),
    )
    use status <- decode.field("status", decode_status())
    use message_type <- decode.optional_field(
      "messageType",
      option.None,
      decode.optional(decode_message_type()),
    )
    use category <- decode.field("category", decode_category())
    use severity <- decode.field("severity", decode_severity())
    use certainty <- decode.field("certainty", decode_certainty())
    use urgency <- decode.field("urgency", decode_urgency())
    use event <- decode.field("event", decode.string)
    use sender <- decode.optional_field(
      "sender",
      Sender("NOAA"),
      decode.optional(decode_sender())
        |> decode.map(fn(maybe_sender) {
          case maybe_sender {
            option.Some(sender) -> sender
            option.None -> Sender("NOAA")
          }
        }),
    )
    use sender_name <- decode.optional_field(
      "senderName",
      option.None,
      decode.optional(decode.string),
    )
    use headline <- decode.optional_field(
      "headline",
      option.None,
      decode.optional(decode.string),
    )
    use description <- decode.optional_field(
      "description",
      option.None,
      decode.optional(decode.string),
    )
    use instruction <- decode.optional_field(
      "instruction",
      option.None,
      decode.optional(decode.string),
    )
    use response <- decode.field("response", decode_response())
    use parameters <- decode.field(
      "parameters",
      decode.dict(decode.string, decode.list(decode.string)),
    )
    use replaced_by <- decode.optional_field(
      "replacedBy",
      option.None,
      decode.optional(decode.string),
    )
    use replaced_at <- decode.optional_field(
      "replacedAt",
      option.None,
      decode.optional(decode.string),
    )
    decode.success(Properties(
      id,
      type_,
      properties_id,
      area_desc,
      geocode,
      affected_zones,
      references,
      sent,
      effective,
      onset,
      expires,
      ends,
      status,
      message_type,
      category,
      severity,
      certainty,
      urgency,
      event,
      sender,
      sender_name,
      headline,
      description,
      instruction,
      response,
      parameters,
      replaced_by,
      replaced_at,
    ))
  }
}

fn decode_status() -> decode.Decoder(Status) {
  decode.map(decode.string, fn(string) {
    case string {
      "Actual" -> Actual
      "Test" -> Test
      _ -> UnknownStatus
    }
  })
}

fn decode_geocode() -> decode.Decoder(Geocode) {
  {
    use same <- decode.optional_field(
      "SAME",
      [],
      decode.optional(decode.list(decode.string))
        |> decode.map(fn(maybe_same) {
          case maybe_same {
            option.Some(same) -> same
            option.None -> []
          }
        }),
    )
    use ugc <- decode.optional_field(
      "UGC",
      [],
      decode.optional(decode.list(decode.string))
        |> decode.map(fn(maybe_ugc) {
          case maybe_ugc {
            option.Some(ugc) -> ugc
            option.None -> []
          }
        }),
    )
    decode.success(Geocode(same, ugc))
  }
}

fn decode_message_type() -> decode.Decoder(MessageType) {
  decode.map(decode.string, fn(string) {
    case string {
      "Alert" -> Alert
      "Cancel" -> Cancel
      "Update" -> Update
      _ -> UnknownMessageType
    }
  })
}

fn decode_category() -> decode.Decoder(Category) {
  decode.map(decode.string, fn(string) {
    case string {
      "Met" -> Met
      _ -> UnknownCategory
    }
  })
}

fn decode_severity() -> decode.Decoder(Severity) {
  decode.map(decode.string, fn(string) {
    case string {
      "Extreme" -> Extreme
      "Severe" -> Severe
      "Moderate" -> Moderate
      "Minor" -> Minor
      _ -> UnknownSeverity
    }
  })
}

fn decode_certainty() -> decode.Decoder(Certainty) {
  decode.map(decode.string, fn(string) {
    case string {
      "Unknown" -> Unknown
      "Likely" -> Likely
      "Observed" -> Observed
      "Possible" -> Possible
      _ -> Unknown
    }
  })
}

fn decode_urgency() -> decode.Decoder(Urgency) {
  decode.map(decode.string, fn(string) {
    case string {
      "Expected" -> Expected
      "Future" -> Future
      "Immediate" -> Immediate
      "Past" -> Past
      _ -> UnknownUrgency
    }
  })
}

fn decode_sender() -> decode.Decoder(Sender) {
  decode.string
  |> decode.map(fn(s) { Sender(s) })
}

fn decode_response() -> decode.Decoder(Response) {
  decode.map(decode.string, fn(string) {
    case string {
      "AllClear" -> AllClear
      "Avoid" -> Avoid
      "Execute" -> Execute
      "Monitor" -> Monitor
      "None" -> None
      "Prepare" -> Prepare
      "Shelter" -> Shelter
      _ -> None
    }
  })
}

/// Decodes a GeoJSON geometry object (the value of a `"geometry"` field, or
/// the whole payload when reading a stored geometry back out of Postgres).
/// `Polygon` coordinates are 3-level (rings of positions) and are wrapped in
/// a single-element list; `MultiPolygon` coordinates are already 4-level.
pub fn decode_geometry() -> decode.Decoder(Geometry) {
  use type_ <- decode.field("type", decode.string)
  use polygons <- decode.field("coordinates", decode_polygons(type_))
  decode.success(Geometry(type_, polygons))
}

fn decode_polygons(
  type_: String,
) -> decode.Decoder(List(List(List(#(Float, Float))))) {
  case type_ {
    "MultiPolygon" -> decode.list(decode.list(decode.list(decode_position())))
    _ ->
      decode.list(decode.list(decode_position()))
      |> decode.map(fn(rings) { [rings] })
  }
}

fn decode_position() -> decode.Decoder(#(Float, Float)) {
  decode.list(decode_number())
  |> decode.then(fn(values) {
    case values {
      [longitude, latitude, ..] -> decode.success(#(longitude, latitude))
      _ -> decode.failure(#(0.0, 0.0), "Position")
    }
  })
}

fn decode_number() -> decode.Decoder(Float) {
  decode.one_of(decode.float, or: [decode.int |> decode.map(int.to_float)])
}

/// Encodes a `Geometry` back into spec-correct GeoJSON: 3-level coordinates
/// for `Polygon`, 4-level for `MultiPolygon`.
pub fn geometry_to_json(geometry: Geometry) -> json.Json {
  let coordinates = case geometry.type_, geometry.polygons {
    "MultiPolygon", polygons -> json.array(polygons, polygon_to_json)
    _, [rings, ..] -> polygon_to_json(rings)
    _, [] -> json.preprocessed_array([])
  }

  json.object([
    #("type", json.string(geometry.type_)),
    #("coordinates", coordinates),
  ])
}

fn polygon_to_json(rings: List(List(#(Float, Float)))) -> json.Json {
  json.array(rings, ring_to_json)
}

fn ring_to_json(ring: List(#(Float, Float))) -> json.Json {
  json.array(ring, position_to_json)
}

fn position_to_json(position: #(Float, Float)) -> json.Json {
  json.preprocessed_array([json.float(position.0), json.float(position.1)])
}

fn decode_reference() -> decode.Decoder(Reference) {
  {
    use id <- decode.optional_field(
      "@id",
      "",
      decode.optional(decode.string)
        |> decode.map(fn(maybe_id) {
          case maybe_id {
            option.Some(id) -> id
            option.None -> ""
          }
        }),
    )
    use identifier <- decode.optional_field(
      "identifier",
      "",
      decode.optional(decode.string)
        |> decode.map(fn(maybe_identifier) {
          case maybe_identifier {
            option.Some(identifier) -> identifier
            option.None -> ""
          }
        }),
    )
    use sender <- decode.optional_field(
      "sender",
      Sender("UNKNOWN"),
      decode.optional(decode_sender())
        |> decode.map(fn(maybe_sender) {
          case maybe_sender {
            option.Some(sender) -> sender
            option.None -> Sender("UNKNOWN")
          }
        }),
    )
    use sent <- decode.optional_field(
      "sent",
      "",
      decode.optional(decode.string)
        |> decode.map(fn(maybe_sent) {
          case maybe_sent {
            option.Some(sent) -> sent
            option.None -> ""
          }
        }),
    )
    decode.success(Reference(id, identifier, sender, sent))
  }
}

pub fn severity_to_string(severity: Severity) -> String {
  case severity {
    Extreme -> "Extreme"
    Severe -> "Severe"
    Moderate -> "Moderate"
    Minor -> "Minor"
    UnknownSeverity -> "Unknown"
  }
}

pub fn urgency_to_string(urgency: Urgency) -> String {
  case urgency {
    Immediate -> "Immediate"
    Expected -> "Expected"
    Future -> "Future"
    Past -> "Past"
    UnknownUrgency -> "Unknown"
  }
}

pub fn certainty_to_string(certainty: Certainty) -> String {
  case certainty {
    Observed -> "Observed"
    Likely -> "Likely"
    Possible -> "Possible"
    Unknown -> "Unknown"
  }
}

pub fn message_type_to_string(message_type: MessageType) -> String {
  case message_type {
    Alert -> "Alert"
    Update -> "Update"
    Cancel -> "Cancel"
    UnknownMessageType -> "Unknown"
  }
}

pub fn status_to_string(status: Status) -> String {
  case status {
    Actual -> "Actual"
    Test -> "Test"
    UnknownStatus -> "Unknown"
  }
}
