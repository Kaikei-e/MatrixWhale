package model

// import "time"

// type Alert struct {
// 	Context    []ContextElement `json:"@context"`
// 	Type       string           `json:"type"`
// 	Features   []FeatureElement `json:"features"`
// 	Title      string           `json:"title"`
// 	Updated    time.Time        `json:"updated"`
// 	Pagination Pagination       `json:"pagination"`
// }

// type ContextClass struct {
// 	Version string `json:"@version"`
// 	Wx      string `json:"wx"`
// 	Vocab   string `json:"@vocab"`
// }

// type FeatureElement struct {
// 	ID         string      `json:"id"`
// 	Type       FeatureType `json:"type"`
// 	Geometry   *Geometry   `json:"geometry"`
// 	Properties Properties  `json:"properties"`
// }

// type Geometry struct {
// 	Type        GeometryType  `json:"type"`
// 	Coordinates [][][]float64 `json:"coordinates"`
// }

// type Properties struct {
// 	ID            string      `json:"@id"`
// 	Type          Type        `json:"@type"`
// 	PropertiesID  string      `json:"id"`
// 	AreaDesc      string      `json:"areaDesc"`
// 	Geocode       Geocode     `json:"geocode"`
// 	AffectedZones []string    `json:"affectedZones"`
// 	References    []Reference `json:"references"`
// 	Sent          time.Time   `json:"sent"`
// 	Effective     time.Time   `json:"effective"`
// 	Onset         *time.Time  `json:"onset"`
// 	Expires       time.Time   `json:"expires"`
// 	Ends          *time.Time  `json:"ends"`
// 	Status        Status      `json:"status"`
// 	MessageType   MessageType `json:"messageType"`
// 	Category      Category    `json:"category"`
// 	Severity      Severity    `json:"severity"`
// 	Certainty     Certainty   `json:"certainty"`
// 	Urgency       Urgency     `json:"urgency"`
// 	Event         Event       `json:"event"`
// 	Sender        Sender      `json:"sender"`
// 	SenderName    string      `json:"senderName"`
// 	Headline      *string     `json:"headline"`
// 	Description   *string     `json:"description"`
// 	Instruction   *string     `json:"instruction"`
// 	Response      Response    `json:"response"`
// 	Parameters    Parameters  `json:"parameters"`
// 	ReplacedBy    *string     `json:"replacedBy,omitempty"`
// 	ReplacedAt    *time.Time  `json:"replacedAt,omitempty"`
// }

// type Geocode struct {
// 	Same []string `json:"SAME"`
// 	Ugc  []string `json:"UGC"`
// }

// type Parameters struct {
// 	AWIPSidentifier   []string       `json:"AWIPSidentifier"`
// 	WMOidentifier     []string       `json:"WMOidentifier"`
// 	Blockchannel      []Blockchannel `json:"BLOCKCHANNEL"`
// 	NWSheadline       []string       `json:"NWSheadline,omitempty"`
// 	Vtec              []string       `json:"VTEC,omitempty"`
// 	EventEndingTime   []time.Time    `json:"eventEndingTime,omitempty"`
// 	ExpiredReferences []string       `json:"expiredReferences,omitempty"`
// 	EASOrg            []EASOrg       `json:"EAS-ORG,omitempty"`
// }

// type Reference struct {
// 	ID         string    `json:"@id"`
// 	Identifier string    `json:"identifier"`
// 	Sender     Sender    `json:"sender"`
// 	Sent       time.Time `json:"sent"`
// }

// type Pagination struct {
// 	Next string `json:"next"`
// }

// type GeometryType string

// const (
// 	Polygon GeometryType = "Polygon"
// )

// type Category string

// const (
// 	Met Category = "Met"
// )

// type Certainty string

// const (
// 	CertaintyUnknown Certainty = "Unknown"
// 	Likely           Certainty = "Likely"
// 	Observed         Certainty = "Observed"
// 	Possible         Certainty = "Possible"
// )

// type Event string

// const (
// 	AirQualityAlert         Event = "Air Quality Alert"
// 	CoastalFloodAdvisory    Event = "Coastal Flood Advisory"
// 	CoastalFloodStatement   Event = "Coastal Flood Statement"
// 	CoastalFloodWarning     Event = "Coastal Flood Warning"
// 	DenseFogAdvisory        Event = "Dense Fog Advisory"
// 	FireWeatherWatch        Event = "Fire Weather Watch"
// 	FloodAdvisory           Event = "Flood Advisory"
// 	FloodWarning            Event = "Flood Warning"
// 	GaleWarning             Event = "Gale Warning"
// 	HeatAdvisory            Event = "Heat Advisory"
// 	HighSurfAdvisory        Event = "High Surf Advisory"
// 	HighWindWarning         Event = "High Wind Warning"
// 	MarineWeatherStatement  Event = "Marine Weather Statement"
// 	RIPCurrentStatement     Event = "Rip Current Statement"
// 	RedFlagWarning          Event = "Red Flag Warning"
// 	SmallCraftAdvisory      Event = "Small Craft Advisory"
// 	SpecialWeatherStatement Event = "Special Weather Statement"
// 	StormWarning            Event = "Storm Warning"
// 	TestMessage             Event = "Test Message"
// 	WindAdvisory            Event = "Wind Advisory"
// 	WinterWeatherAdvisory   Event = "Winter Weather Advisory"
// )

// type MessageType string

// const (
// 	Cancel           MessageType = "Cancel"
// 	MessageTypeAlert MessageType = "Alert"
// 	Update           MessageType = "Update"
// )

// type Blockchannel string

// const (
// 	Cmas Blockchannel = "CMAS"
// 	EAS  Blockchannel = "EAS"
// 	Nwem Blockchannel = "NWEM"
// )

// type EASOrg string

// const (
// 	Wxr EASOrg = "WXR"
// )

// type Sender string

// const (
// 	WNwsWebmasterNoaaGov Sender = "w-nws.webmaster@noaa.gov"
// )

// type Response string

// const (
// 	AllClear Response = "AllClear"
// 	Avoid    Response = "Avoid"
// 	Execute  Response = "Execute"
// 	Monitor  Response = "Monitor"
// 	None     Response = "None"
// 	Prepare  Response = "Prepare"
// )

// type Severity string

// const (
// 	Minor           Severity = "Minor"
// 	Moderate        Severity = "Moderate"
// 	Severe          Severity = "Severe"
// 	SeverityUnknown Severity = "Unknown"
// )

// type Status string

// const (
// 	Actual Status = "Actual"
// 	Test   Status = "Test"
// )

// type Type string

// const (
// 	WxAlert Type = "wx:Alert"
// )

// type Urgency string

// const (
// 	Expected       Urgency = "Expected"
// 	Future         Urgency = "Future"
// 	Immediate      Urgency = "Immediate"
// 	Past           Urgency = "Past"
// 	UrgencyUnknown Urgency = "Unknown"
// )

// type FeatureType string

// const (
// 	Feature FeatureType = "Feature"
// )

// type ContextElement struct {
// 	ContextClass *ContextClass
// 	String       *string
// }
