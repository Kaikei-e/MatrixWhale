import decode.{type Decoder}
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic, list, string}
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

pub type Geometry {
  Geometry(type_: String, coordinates: List(List(List(Coordinate))))
}

pub type Polygon {
  Polygon(type_: String)
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
  Minor
  Moderate
  Severe
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

pub type Coordinate {
  FloatType(Float)
  IntType(Int)
  StringType(String)
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

pub fn extract_and_decode_features(data: Dynamic) -> List(FeatureElement) {
  let decoded_result =
    dynamic.field("features", dynamic.list(dynamic.dynamic))(data)

  wisp.log_info("Extracted features: ")

  case decoded_result {
    Ok(features) -> {
      wisp.log_info(
        "Decoded features count: " <> string.inspect(list.length(features)),
      )
      features
      |> list.filter_map(fn(feature) {
        case decode_feature(feature) {
          Ok(feature) -> Ok(feature)
          Error(error) -> {
            wisp.log_error("Error decoding feature: " <> string.inspect(error))
            Error(error)
          }
        }
      })
    }
    Error(err) -> {
      wisp.log_error("Error decoding features JSON: " <> string.inspect(err))
      []
    }
  }
}

pub fn prepare_feature_for_decoding(
  feature: Dynamic,
) -> Result(String, List(dynamic.DecodeError)) {
  case dynamic.string(feature) {
    Ok(json_string) -> Ok(json_string)
    Error(_) as error -> {
      error
    }
  }
}

pub fn decode_feature(data: Dynamic) -> Result(FeatureElement, List(String)) {
  let decoder =
    decode.into({
      use id <- decode.parameter
      use type_ <- decode.parameter
      use geometry <- decode.parameter
      use properties <- decode.parameter
      FeatureElement(id, type_, geometry, properties)
    })
    |> decode.field("id", decode.string)
    |> decode.field("type", decode.string)
    |> decode.field("geometry", decode_geometry())
    |> decode.field("properties", decode_properties(data))

  decoder
  |> decode.from(data)
  |> result.map_error(fn(error) {
    wisp.log_error("Error decoding feature: " <> string.inspect(error))
    list.new()
    |> list.append(list.map([error], string.inspect))
  })
}

fn decode_properties(data: Dynamic) {
  decode.into({
    use id <- decode.parameter
    use type_ <- decode.parameter
    use properties_id <- decode.parameter
    use area_desc <- decode.parameter
    use geocode <- decode.parameter
    use affected_zones <- decode.parameter
    use references <- decode.parameter
    use sent <- decode.parameter
    use effective <- decode.parameter
    use onset <- decode.parameter
    use expires <- decode.parameter
    use ends <- decode.parameter
    use status <- decode.parameter
    use message_type <- decode.parameter
    use category <- decode.parameter
    use severity <- decode.parameter
    use certainty <- decode.parameter
    use urgency <- decode.parameter
    use event <- decode.parameter
    use sender <- decode.parameter
    use sender_name <- decode.parameter
    use headline <- decode.parameter
    use description <- decode.parameter
    use instruction <- decode.parameter
    use response <- decode.parameter
    use parameters <- decode.parameter
    use replaced_by <- decode.parameter
    use replaced_at <- decode.parameter
    Properties(
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
    )
  })
  |> decode.field("id", decode.optional(decode.string))
  |> decode.field("type", decode.optional(decode.string))
  |> decode.field("properties_id", decode.optional(decode.string))
  |> decode.field("areaDesc", decode.string)
  |> decode.field(
    "geocode",
    decode.optional(decode_geocode())
      |> decode.map(fn(maybe_geocode) {
        case maybe_geocode {
          option.Some(geocode) -> geocode
          option.None -> Geocode([], [])
        }
      }),
  )
  |> decode.field(
    "affectedZones",
    decode.optional(decode.list(decode.string))
      |> decode.map(fn(maybe_zones) {
        case maybe_zones {
          option.Some(zones) -> zones
          _ -> []
        }
      }),
  )
  |> decode.field(
    "references",
    decode.optional(decode.list(decode_reference()))
      |> decode.map(fn(x) { x |> option.unwrap([]) }),
  )
  |> decode.field("sent", decode.optional(decode.string))
  |> decode.field("effective", decode.string)
  |> decode.field("onset", decode.optional(decode.string))
  |> decode.field("expires", decode.string)
  |> decode.field("ends", decode.optional(decode.string))
  |> decode.field("status", decode_status())
  |> decode.field("messageType", decode.optional(decode_message_type()))
  |> decode.field("category", decode_category())
  |> decode.field("severity", decode_severity())
  |> decode.field("certainty", decode_certainty())
  |> decode.field("urgency", decode_urgency())
  |> decode.field("event", decode.string)
  |> decode.field(
    "sender",
    decode.optional(decode_sender())
      |> decode.map(fn(maybe_sender) {
        case maybe_sender {
          option.Some(sender) -> sender
          option.None -> Sender("NOAA")
        }
      }),
  )
  |> decode.field("senderName", decode.optional(decode.string))
  |> decode.field("headline", decode.optional(decode.string))
  |> decode.field("description", decode.optional(decode.string))
  |> decode.field("instruction", decode.optional(decode.string))
  |> decode.field("response", decode_response())
  |> decode.field(
    "parameters",
    decode.dict(decode.string, decode.list(decode.string)),
  )
  |> decode.field("replacedBy", decode.optional(decode.string))
  |> decode.field("replacedAt", decode.optional(decode.string))
}

fn decode_status() -> Decoder(Status) {
  decode.map(decode.string, fn(string) {
    case string {
      "Actual" -> Actual
      "Test" -> Test
      _ -> UnknownStatus
    }
  })
}

fn decode_geocode() -> Decoder(Geocode) {
  decode.into({
    use same <- decode.parameter
    use ugc <- decode.parameter
    Geocode(same, ugc)
  })
  |> decode.field(
    "same",
    decode.optional(decode.list(decode.string))
      |> decode.map(fn(maybe_same) {
        case maybe_same {
          option.Some(same) -> same
          option.None -> []
        }
      }),
  )
  |> decode.field(
    "ugc",
    decode.optional(decode.list(decode.string))
      |> decode.map(fn(maybe_ugc) {
        case maybe_ugc {
          option.Some(ugc) -> ugc
          option.None -> []
        }
      }),
  )
}

fn decode_message_type() -> Decoder(MessageType) {
  decode.map(decode.string, fn(string) {
    case string {
      "Alert" -> Alert
      "Cancel" -> Cancel
      "Update" -> Update
      _ -> UnknownMessageType
    }
  })
}

fn decode_category() -> Decoder(Category) {
  decode.map(decode.string, fn(string) {
    case string {
      "Met" -> Met
      _ -> UnknownCategory
    }
  })
}

fn decode_severity() -> Decoder(Severity) {
  decode.map(decode.string, fn(string) {
    case string {
      "Minor" -> Minor
      "Moderate" -> Moderate
      "Severe" -> Severe
      _ -> UnknownSeverity
    }
  })
}

fn decode_certainty() -> Decoder(Certainty) {
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

fn decode_urgency() -> Decoder(Urgency) {
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

fn decode_sender() -> Decoder(Sender) {
  decode.string
  |> decode.map(fn(s) { Sender(s) })
}

fn decode_response() -> Decoder(Response) {
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

fn decode_geometry() -> Decoder(Option(Geometry)) {
  decode.optional(
    decode.into({
      use type_ <- decode.parameter
      use coordinates <- decode.parameter
      Geometry(type_, coordinates)
    })
    |> decode.field("type", decode.string)
    |> decode.field(
      "coordinates",
      decode.list(decode.list(decode.list(decode_coordinates()))),
    ),
  )
}

fn decode_coordinates() -> Decoder(Coordinate) {
  decode.float
  |> decode.map(FloatType)
}

fn decode_reference() -> Decoder(Reference) {
  decode.into({
    use id <- decode.parameter
    use identifier <- decode.parameter
    use sender <- decode.parameter
    use sent <- decode.parameter
    Reference(id, identifier, sender, sent)
  })
  |> decode.field(
    "id",
    decode.optional(decode.string)
      |> decode.map(fn(maybe_id) {
        case maybe_id {
          option.Some(id) -> id
          option.None -> ""
        }
      }),
  )
  |> decode.field(
    "identifier",
    decode.optional(decode.string)
      |> decode.map(fn(maybe_identifier) {
        case maybe_identifier {
          option.Some(identifier) -> identifier
          option.None -> ""
        }
      }),
  )
  |> decode.field(
    "sender",
    decode.optional(decode_sender())
      |> decode.map(fn(maybe_sender) {
        case maybe_sender {
          option.Some(sender) -> sender
          option.None -> Sender("UNKNOWN")
        }
      }),
  )
  |> decode.field(
    "sent",
    decode.optional(decode.string)
      |> decode.map(fn(maybe_sent) {
        case maybe_sent {
          option.Some(sent) -> sent
          option.None -> ""
        }
      }),
  )
}
