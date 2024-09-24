import gleam/dict.{type Dict}
import gleam/option.{type Option}

pub type ContextClass {
  ContextClass(version: String, wx: String, vocab: String)
}

// Enums and their encode/decode functions
pub type GeometryType {
  Polygon
}

pub fn encode_geometry_type(value: GeometryType) -> String {
  case value {
    Polygon -> "Polygon"
  }
}

pub fn decode_geometry_type(value: String) -> Result(GeometryType, String) {
  case value {
    "Polygon" -> Ok(Polygon)
    _ -> Error("Unexpected value when decoding GeometryType: " <> value)
  }
}

pub type Category {
  Met
}

pub fn encode_category(value: Category) -> String {
  case value {
    Met -> "Met"
  }
}

pub fn decode_category(value: String) -> Result(Category, String) {
  case value {
    "Met" -> Ok(Met)
    _ -> Error("Unexpected value when decoding Category: " <> value)
  }
}

pub type Certainty {
  Likely
  Observed
  Possible
  UnknownCertainty
}

pub fn encode_certainty(value: Certainty) -> String {
  case value {
    Likely -> "Likely"
    Observed -> "Observed"
    Possible -> "Possible"
    UnknownCertainty -> "Unknown"
  }
}

pub fn decode_certainty(value: String) -> Result(Certainty, String) {
  case value {
    "Likely" -> Ok(Likely)
    "Observed" -> Ok(Observed)
    "Possible" -> Ok(Possible)
    "Unknown" -> Ok(UnknownCertainty)
    _ -> Error("Unexpected value when decoding Certainty: " <> value)
  }
}

pub type MessageType {
  Alert
  Cancel
  Update
}

pub fn encode_message_type(value: MessageType) -> String {
  case value {
    Alert -> "Alert"
    Cancel -> "Cancel"
    Update -> "Update"
  }
}

pub fn decode_message_type(value: String) -> Result(MessageType, String) {
  case value {
    "Alert" -> Ok(Alert)
    "Cancel" -> Ok(Cancel)
    "Update" -> Ok(Update)
    _ -> Error("Unexpected value when decoding MessageType: " <> value)
  }
}

pub type ResponseType {
  AllClear
  Avoid
  Execute
  Monitor
  NoneResponse
  Prepare
  Shelter
}

pub fn encode_response(value: ResponseType) -> String {
  case value {
    AllClear -> "AllClear"
    Avoid -> "Avoid"
    Execute -> "Execute"
    Monitor -> "Monitor"
    NoneResponse -> "None"
    Prepare -> "Prepare"
    Shelter -> "Shelter"
  }
}

pub fn decode_response(value: String) -> Result(ResponseType, String) {
  case value {
    "AllClear" -> Ok(AllClear)
    "Avoid" -> Ok(Avoid)
    "Execute" -> Ok(Execute)
    "Monitor" -> Ok(Monitor)
    "None" -> Ok(NoneResponse)
    "Prepare" -> Ok(Prepare)
    "Shelter" -> Ok(Shelter)
    _ -> Error("Unexpected value when decoding ResponseType: " <> value)
  }
}

pub type Severity {
  Minor
  Moderate
  Severe
  UnknownSeverity
}

pub fn encode_severity(value: Severity) -> String {
  case value {
    Minor -> "Minor"
    Moderate -> "Moderate"
    Severe -> "Severe"
    UnknownSeverity -> "Unknown"
  }
}

pub fn decode_severity(value: String) -> Result(Severity, String) {
  case value {
    "Minor" -> Ok(Minor)
    "Moderate" -> Ok(Moderate)
    "Severe" -> Ok(Severe)
    "Unknown" -> Ok(UnknownSeverity)
    _ -> Error("Unexpected value when decoding Severity: " <> value)
  }
}

pub type Status {
  Actual
  Test
}

pub fn encode_status(value: Status) -> String {
  case value {
    Actual -> "Actual"
    Test -> "Test"
  }
}

pub fn decode_status(value: String) -> Result(Status, String) {
  case value {
    "Actual" -> Ok(Actual)
    "Test" -> Ok(Test)
    _ -> Error("Unexpected value when decoding Status: " <> value)
  }
}

pub type TypeValue {
  WxAlert
}

pub fn encode_type_value(value: TypeValue) -> String {
  case value {
    WxAlert -> "wx:Alert"
  }
}

pub fn decode_type_value(value: String) -> Result(TypeValue, String) {
  case value {
    "wx:Alert" -> Ok(WxAlert)
    _ -> Error("Unexpected value when decoding TypeValue: " <> value)
  }
}

pub type Urgency {
  Expected
  Future
  Immediate
  Past
  UnknownUrgency
}

pub fn encode_urgency(value: Urgency) -> String {
  case value {
    Expected -> "Expected"
    Future -> "Future"
    Immediate -> "Immediate"
    Past -> "Past"
    UnknownUrgency -> "Unknown"
  }
}

pub fn decode_urgency(value: String) -> Result(Urgency, String) {
  case value {
    "Expected" -> Ok(Expected)
    "Future" -> Ok(Future)
    "Immediate" -> Ok(Immediate)
    "Past" -> Ok(Past)
    "Unknown" -> Ok(UnknownUrgency)
    _ -> Error("Unexpected value when decoding Urgency: " <> value)
  }
}

pub type FeatureTypeValue {
  FeatureType
}

pub fn encode_feature_type(value: FeatureTypeValue) -> String {
  case value {
    FeatureType -> "Feature"
  }
}

pub fn decode_feature_type(value: String) -> Result(FeatureTypeValue, String) {
  case value {
    "Feature" -> Ok(FeatureType)
    _ -> Error("Unexpected value when decoding FeatureTypeValue: " <> value)
  }
}

// Data Structures

pub type Geocode {
  Geocode(same: List(String), ugc: List(String))
}

pub type Sender {
  Sender(String)
}

pub fn encode_sender(value: Sender) -> String {
  case value {
    Sender(email) -> email
  }
}

pub fn decode_sender(value: String) -> Result(Sender, String) {
  case value {
    "w-nws.webmaster@noaa.gov" -> {
      Ok(Sender(value))
    }
    _ -> Error("Unexpected value when decoding Sender: " <> value)
  }
}

pub type Reference {
  Reference(id: String, identifier: String, sender: Sender, sent: String)
}

pub type Geometry {
  Geometry(type_: GeometryType, coordinates: List(List(List(Float))))
}

pub type Properties {
  Properties(
    id: String,
    type_: TypeValue,
    properties_id: String,
    area_desc: String,
    geocode: Geocode,
    affected_zones: List(String),
    references: List(Reference),
    sent: String,
    effective: String,
    onset: String,
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
    response: ResponseType,
    parameters: Dict(String, List(String)),
    replaced_by: Option(String),
    replaced_at: Option(String),
  )
}

pub type Feature {
  Feature(
    id: String,
    type_: FeatureTypeValue,
    geometry: Option(Geometry),
    properties: Properties,
  )
}

pub type Pagination {
  Pagination(next: String)
}

pub type ContextClassOrString {
  ContextClassVariant(ContextClass)
  ContextString(String)
}

pub type Alerts {
  Alerts(
    context: List(ContextClassOrString),
    type_: String,
    features: List(Feature),
    title: String,
    updated: String,
    pagination: Pagination,
  )
}
