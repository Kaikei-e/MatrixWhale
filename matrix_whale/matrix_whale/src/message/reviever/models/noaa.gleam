import decode.{type Decoder}
import gleam/dict.{type Dict}
import gleam/dynamic.{
  type DecodeError, type Dynamic, decode2, field, float, list, optional, string,
}
import gleam/json
import gleam/option.{type Option}

pub type Alerts {
  Alerts(
    context: String,
    type_: String,
    features: List(FeatureElement),
    title: String,
    updated: String,
    pagination: Pagination,
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
  String(string: String)
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
  Geometry(type_: Polygon, coordinates: List(List(List(Float))))
}

pub type Polygon {
  Polygon(type_: String)
}

pub type Properties {
  Properties(
    id: String,
    type_: String,
    properties_id: String,
    area_desc: String,
    geocode: Geocode,
    affected_zones: List(String),
    references: List(Reference),
    sent: String,
    effective: String,
    onset: Option(String),
    expires: String,
    ends: Option(String),
    status: Status,
    message_type: MessageType,
    category: Category,
    severity: Severity,
    certainty: Certainty,
    urgency: Urgency,
    event: String,
    sender: Sender,
    sender_name: String,
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

pub fn decode_alert_element_list(
  data: String,
) -> Result(Features, json.DecodeError) {
  let decoder =
    dynamic.decode1(
      Features,
      field(
        "alert_elements",
        of: list(dynamic.decode4(
          FeatureElement,
          field("id", of: string),
          field("type", of: string),
          field(
            "geometry",
            optional(dynamic.decode2(
              Geometry,
              field("type", of: dynamic.decode1(Polygon, field("type", string))),
              field("coordinates", of: list(list(list(float)))),
            )),
          ),
          field("properties", of: decode_properties),
        )),
      ),
    )

  json.decode(from: data, using: decoder)
}

fn decode_properties(data: Dynamic) {
  let decoder =
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
    |> decode.field("id", decode.string)
    |> decode.field("type", decode.string)
    |> decode.field("properties_id", decode.string)
    |> decode.field("area_desc", decode.string)
    |> decode.field(
      "geocode",
      deocde_geocode_wrapper(
        data,
        decode2(
          Geocode,
          field("same", of: list(string)),
          field("ugc", of: list(string)),
        ),
      ),
    )
    |> decode.field("affected_zones", decode.list(decode.string))
    |> decode.field(
      "references",
      decode.list(decode_reference_wrapper(
        data,
        dynamic.decode4(
          Reference,
          field("id", string),
          field("identifier", string),
          field("sender", dynamic.decode1(Sender, field("sender", string))),
          field("sent", string),
        ),
      )),
    )
    |> decode.field("sent", decode.string)
    |> decode.field("effective", decode.string)
    |> decode.field("onset", decode.optional(decode.string))
    |> decode.field("expires", decode.string)
    |> decode.field("ends", decode.optional(decode.string))
    |> decode.field("status", decode_status())
    |> decode.field("message_type", decode_message_type())
    |> decode.field("category", decode_category())
    |> decode.field("severity", decode_severity())
    |> decode.field("certainty", decode_certainty())
    |> decode.field("urgency", decode_urgency())
    |> decode.field("event", decode.string)
    |> decode.field("sender", decode_sender())
    |> decode.field("sender_name", decode.string)
    |> decode.field("headline", decode.optional(decode.string))
    |> decode.field("description", decode.optional(decode.string))
    |> decode.field("instruction", decode.optional(decode.string))
    |> decode.field("response", decode_response())
    |> decode.field(
      "parameters",
      decode.dict(decode.string, decode.list(decode.string)),
    )
    |> decode.field("replaced_by", decode.optional(decode.string))
    |> decode.field("replaced_at", decode.optional(decode.string))

  case decoder |> decode.from(data) {
    Ok(properties) -> Ok(properties)
    Error(error) -> Error(error)
  }
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
  decode.map(decode.string, fn(string) { Sender(string) })
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

fn deocde_geocode_wrapper(
  data: Dynamic,
  decoded_fn: fn(Dynamic) -> Result(Geocode, List(DecodeError)),
) -> Decoder(Geocode) {
  let result = decoded_fn(data)

  case result {
    Ok(_) ->
      decode.into({
        use same <- decode.parameter
        use ugc <- decode.parameter
        Geocode(same, ugc)
      })
      |> decode.field("same", decode.list(decode.string))
      |> decode.field("ugc", decode.list(decode.string))
    _ -> decode.fail("Invalid type variant")
  }
}

fn decode_reference_wrapper(
  data: Dynamic,
  decoded_fn: fn(Dynamic) -> Result(Reference, List(DecodeError)),
) -> Decoder(Reference) {
  let result = decoded_fn(data)

  case result {
    Ok(_) ->
      decode.into({
        use id <- decode.parameter
        use identifier <- decode.parameter
        use sender <- decode.parameter
        use sent <- decode.parameter
        Reference(id, identifier, sender, sent)
      })
      |> decode.field("id", decode.string)
      |> decode.field("identifier", decode.string)
      |> decode.field("sender", decode_sender())
      |> decode.field("sent", decode.string)
    _ -> decode.fail("Invalid type variant")
  }
}
