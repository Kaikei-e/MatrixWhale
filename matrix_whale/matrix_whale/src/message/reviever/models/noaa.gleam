import decode.{type Decoder}
import gleam/dict.{type Dict}
import gleam/dynamic.{type DecodeError, type Dynamic}
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

pub fn decode_alerts(data: Dynamic) -> Result(Alerts, List(DecodeError)) {
  let decoder =
    decode.into({
      use context <- decode.parameter
      use type_ <- decode.parameter
      use features <- decode.parameter
      use title <- decode.parameter
      use updated <- decode.parameter
      use pagination <- decode.parameter
      Alerts(context, type_, features, title, updated, pagination)
    })
    |> decode.field("@context", decode.string)
    |> decode.field("type", decode.string)
    |> decode.field("features", decode.list(decode_feature_element))
    |> decode.field("title", decode.string)
    |> decode.field("updated", decode.string)
    |> decode.field("pagination", decode_pagination)

  case
    decoder
    |> decode.from(data)
  {
    Ok(alerts) -> Ok(alerts)
    Error(err) -> Error(err)
  }
}

// fn decode_context_class(data: Dynamic) -> Decoder(List(ContextElement)) {
//   let decoder =
//     decode.into({
//       use version <- decode.parameter
//       use wx <- decode.parameter
//       use vocab <- decode.parameter
//       ContextClass(version, wx, vocab)
//     })
//     |> decode.field("version", decode.string)
//     |> decode.field("wx", decode.string)
//     |> decode.field("vocab", decode.string)

//   case decoder |> decode.from(data) {
//     Ok(context_class) -> {
//       let context_class_element =
//         ContextClassElement(ContextClass(
//           context_class.version,
//           context_class.wx,
//           context_class.vocab,
//         ))

//       let context_element =
//         ContextElement.ContextClassElement(context_class_element)

//       let decoder2 =
//         decode.into({
//           use context_element <- decode.parameter
//           ContextClassElement
//         })
//         |> decode.field("context_class", decode_context_class)

//     }
//     Error(err) -> Error(err)
//   }
// }

fn decode_feature_element(data: Dynamic) {
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
    |> decode.field("geometry", decode.optional(decode_geometry))
    |> decode.field("properties", decode_properties)
    |> decode.from(data)

  decoder
}

fn decode_geometry(data: Dynamic) {
  let decoder =
    decode.into({
      use type_ <- decode.parameter
      use coordinates <- decode.parameter
      Geometry(type_, coordinates)
    })
    |> decode.field("type", decode_polygon)
    |> decode.field(
      "coordinates",
      decode.list(decode.list(decode.list(decode.float))),
    )
    |> decode.from(data)

  decoder
}

fn decode_polygon(data: Dynamic) {
  let decoder =
    decode.into({
      use type_ <- decode.parameter
      Polygon(type_)
    })
    |> decode.field("type", decode.string)
    |> decode.from(data)

  case decoder {
    Ok(polygon) -> {
      decoder(Polygon(polygon.type_))
    }
    Error(err) -> Error(err)
  }
}

fn decode_pagination(data: Dynamic) {
  let decoder =
    decode.into({
      use next <- decode.parameter
      Pagination(next)
    })
    |> decode.field("next", decode.string)
    |> decode.from(data)

  decoder
}
// fn decode_polygon(data: Dynamic) {
//   let decoder =
//     decode.into({
//       use type_ <- decode.parameter
//       use coordinates <- decode.parameter
//       Geometry(type_, coordinates)
//     })
//     |> decode.field("type", decode_geometry_type)
//     |> decode.field(
//       "coordinates",
//       decode.list(decode.list(decode.list(decode.float))),
//     )

//   decoder |> decode.from(data)
// }

// fn decode_geometry_type(data: Dynamic) {
//   let decoder =
//     decode.into({
//       use type_ <- decode.parameter
//       Polygon(type_)
//     })
//     |> decode.field("type", decode.string)

//   decoder |> decode.from(data)
// }
