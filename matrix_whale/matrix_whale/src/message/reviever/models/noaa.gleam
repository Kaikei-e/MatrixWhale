import decode.{type Decoder}
import gleam/dict.{type Dict}
import gleam/dynamic.{
  type DecodeError, type Dynamic, field, float, list, optional, string,
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
    type_: Type,
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
}

pub type Sender {
  WNwsWebmasterNoaaGov
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
  UnknownServerity
}

pub type Status {
  Actual
  Test
}

pub type Type {
  WxAlert
}

pub type Urgency {
  Expected
  Future
  Immediate
  Past
  UnknownUrgency
}

pub fn decode_alert_element_list(
  data: String,
) -> Result(List(FeatureElement), json.DecodeError) {
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
    |> decode.field("geocode", decode.subfield("same", decode.list(decode.string)))
    |> decode.field("affected_zones", decode.list(decode.string))
    |> decode.field("references", decode.list(decode_reference))
    |> decode.field("sent", decode.string)
    |> decode.field("effective", decode.string)
    |> decode.field("onset", decode.optional(decode.string))
    |> decode.field("expires", decode.string)
    |> decode.field("ends", decode.optional(decode.string))
    |> decode.field("status", decode.status)
    |> decode.field("message_type", decode.message_type)
    |> decode.field("category", decode.category)
    |> decode.field("severity", decode.severity)
    |> decode.field("certainty", decode.certainty)
    |> decode.field("urgency", decode.urgency)
    |> decode.field("event", decode.string)
    |> decode.field("sender", decode.sender)
    |> decode.field("sender_name", decode.string)
    |> decode.field("headline", decode.optional(decode.string))
    |> decode.field("description", decode.optional(decode.string))
    |> decode.field("instruction", decode.optional(decode.string))
    |> decode.field("response", decode.response)
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

fn decode_geocode(data: String) {
  let decoder =
    dynamic.decode2(
      Geocode,
      field("same", of: list(string)),
      field("ugc", of: list(string)),
    )

  case json.decode(from: data, using: decoder) {
    Ok(geocode) -> Ok(geocode)
    Error(error) -> Error(error)
  }
}
