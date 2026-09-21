package parser

import (
	"bytes"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"math"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"jma_adapter/client"
)

var (
	ErrInvalidRootElement   = errors.New("invalid XML root element: must be Report")
	ErrUnsupportedNamespace = errors.New("unsupported XML namespace")
	ErrDisallowedDTD        = errors.New("DTD/entity declarations are prohibited in JMAXML")
	ErrTrailingRootElement  = errors.New("unexpected trailing root element")
	ErrMissingStatus        = errors.New("missing mandatory Control.Status")
	ErrInvalidDateTime      = errors.New("invalid ISO8601/RFC3339 timestamp")
	ErrUnsupportedDatum     = errors.New("unsupported geodetic datum: explicit 日本測地系 or unknown datum rejected")
	ErrInvalidCoordinates   = errors.New("invalid ISO 6709 coordinate string")
)

const (
	jmaXmlReportNamespace = "http://xml.kishou.go.jp/jmaxml1/"
	jmaXmlHeadNamespace   = "http://xml.kishou.go.jp/jmaxml1/informationBasis1/"
	jmaXmlMeteNamespace   = "http://xml.kishou.go.jp/jmaxml1/body/meteorology1/"
	jmaXmlSeisNamespace   = "http://xml.kishou.go.jp/jmaxml1/body/seismology1/"
	jmaXmlVolcNamespace   = "http://xml.kishou.go.jp/jmaxml1/body/volcanology1/"
)

// Raw XML data models for unmarshaling JMAXML telegrams

type rawReport struct {
	XMLName xml.Name   `xml:"http://xml.kishou.go.jp/jmaxml1/ Report"`
	Control rawControl `xml:"http://xml.kishou.go.jp/jmaxml1/ Control"`
	Head    rawHead    `xml:"http://xml.kishou.go.jp/jmaxml1/informationBasis1/ Head"`
	Body    rawBody    `xml:"Body"`
}

type rawControl struct {
	Title            string `xml:"Title"`
	DateTime         string `xml:"DateTime"`
	Status           string `xml:"Status"`
	EditorialOffice  string `xml:"EditorialOffice"`
	PublishingOffice string `xml:"PublishingOffice"`
}

type rawHead struct {
	Title          string      `xml:"Title"`
	ReportDateTime string      `xml:"ReportDateTime"`
	TargetDateTime string      `xml:"TargetDateTime"`
	ValidDateTime  string      `xml:"ValidDateTime"`
	EventID        string      `xml:"EventID"`
	InfoType       string      `xml:"InfoType"`
	Serial         string      `xml:"Serial"`
	InfoKind       string      `xml:"InfoKind"`
	Headline       rawHeadline `xml:"Headline"`
}

type rawHeadline struct {
	Text        string        `xml:"Text"`
	Information []rawHeadInfo `xml:"Information"`
}

type rawHeadInfo struct {
	Type  string        `xml:"type,attr"`
	Items []rawHeadItem `xml:"Item"`
}

type rawHeadItem struct {
	Kind  rawHeadKind  `xml:"Kind"`
	Areas rawHeadAreas `xml:"Areas"`
}

type rawHeadKind struct {
	Name string `xml:"Name"`
	Code string `xml:"Code"`
}

type rawHeadAreas struct {
	CodeType string        `xml:"codeType,attr"`
	Areas    []rawHeadArea `xml:"Area"`
}

type rawHeadArea struct {
	Name string `xml:"Name"`
	Code string `xml:"Code"`
}

type rawBody struct {
	XMLName xml.Name

	// Seismology
	Earthquake *rawEarthquake `xml:"Earthquake"`
	Intensity  *rawIntensity  `xml:"Intensity"`

	// Meteorology
	Warnings []rawWarning `xml:"Warning"`

	// Volcanology
	VolcanoInfo *rawVolcanoInfo `xml:"VolcanoInfo"`
}

type rawEarthquake struct {
	OriginTime  string         `xml:"OriginTime"`
	ArrivalTime string         `xml:"ArrivalTime"`
	Hypocenter  *rawHypocenter `xml:"Hypocenter"`
	Magnitude   *rawMagnitude  `xml:"Magnitude"`
}

type rawHypocenter struct {
	Area rawHypoArea `xml:"Area"`
}

type rawHypoArea struct {
	Name       string        `xml:"Name"`
	Code       string        `xml:"Code"`
	Coordinate rawCoordinate `xml:"Coordinate"`
}

type rawCoordinate struct {
	Datum       string `xml:"datum,attr"`
	Type        string `xml:"type,attr"`
	Description string `xml:"description,attr"`
	Value       string `xml:",chardata"`
}

type rawMagnitude struct {
	Type        string `xml:"type,attr"`
	Description string `xml:"description,attr"`
	Value       string `xml:",chardata"`
}

type rawIntensity struct {
	Observation *rawIntensityObs `xml:"Observation"`
}

type rawIntensityObs struct {
	MaxInt string `xml:"MaxInt"`
}

type rawWarning struct {
	Type  string           `xml:"type,attr"`
	Items []rawWarningItem `xml:"Item"`
}

type rawWarningItem struct {
	Area  rawWarningArea   `xml:"Area"`
	Kinds []rawWarningKind `xml:"Kind"`
}

type rawWarningArea struct {
	Name string `xml:"Name"`
	Code string `xml:"Code"`
}

type rawWarningKind struct {
	Name     string `xml:"Name"`
	Code     string `xml:"Code"`
	Status   string `xml:"Status"`
	Property string `xml:"Property"`
}

type rawVolcanoInfo struct {
	Type  string           `xml:"type,attr"`
	Items []rawVolcanoItem `xml:"Item"`
}

type rawVolcanoItem struct {
	EventTime rawEventTime    `xml:"EventTime"`
	Kind      rawHeadKind     `xml:"Kind"`
	Areas     rawVolcanoAreas `xml:"Areas"`
}

type rawEventTime struct {
	EventDateTime string `xml:"EventDateTime"`
}

type rawVolcanoAreas struct {
	Areas []rawVolcanoArea `xml:"Area"`
}

type rawVolcanoArea struct {
	Name       string        `xml:"Name"`
	Code       string        `xml:"Code"`
	Coordinate rawCoordinate `xml:"Coordinate"`
}

// ISO 6709 coordinate regex matching ±DD.DDDD±DDD.DDDD±altitude/ or ±DDMM±DDDMM/
var iso6709Pattern = regexp.MustCompile(`^([+-]\d+(?:\.\d+)?)([+-]\d+(?:\.\d+)?)(?:([+-]\d+(?:\.\d+)?))?/$`)

// ParseISO6709 parses a JMA ISO 6709 coordinate string into latitude, longitude, and depth (in km).
// Hypocenter depth is represented in JMAXML as negative altitude in meters (e.g. -10000/ -> 10.0km).
// Positive altitude is rejected as invalid for an underground hypocenter without fabricating 0 depth.
func ParseISO6709(coordStr string) (lat, lon, depthKM float64, hasDepth bool, err error) {
	coordStr = strings.TrimSpace(coordStr)
	match := iso6709Pattern.FindStringSubmatch(coordStr)
	if match == nil {
		return 0, 0, 0, false, fmt.Errorf("%w: %s", ErrInvalidCoordinates, coordStr)
	}

	latStr := match[1]
	lonStr := match[2]
	altStr := match[3]

	lat, err = parseCoordinatePart(latStr, false)
	if err != nil {
		return 0, 0, 0, false, fmt.Errorf("%w: %v", ErrInvalidCoordinates, err)
	}
	if lat < -90.0 || lat > 90.0 || math.IsNaN(lat) || math.IsInf(lat, 0) {
		return 0, 0, 0, false, fmt.Errorf("%w: latitude %f out of range", ErrInvalidCoordinates, lat)
	}

	lon, err = parseCoordinatePart(lonStr, true)
	if err != nil {
		return 0, 0, 0, false, fmt.Errorf("%w: %v", ErrInvalidCoordinates, err)
	}
	if lon < -180.0 || lon > 180.0 || math.IsNaN(lon) || math.IsInf(lon, 0) {
		return 0, 0, 0, false, fmt.Errorf("%w: longitude %f out of range", ErrInvalidCoordinates, lon)
	}

	if altStr != "" {
		altMeters, err := strconv.ParseFloat(altStr, 64)
		if err != nil || math.IsNaN(altMeters) || math.IsInf(altMeters, 0) {
			return 0, 0, 0, false, fmt.Errorf("%w: invalid altitude %s", ErrInvalidCoordinates, altStr)
		}
		if altMeters > 0 {
			return 0, 0, 0, false, fmt.Errorf("%w: positive hypocenter altitude %f rejected", ErrInvalidCoordinates, altMeters)
		}
		depthKM = -altMeters / 1000.0
		if math.IsNaN(depthKM) || math.IsInf(depthKM, 0) {
			return 0, 0, 0, false, fmt.Errorf("%w: nonfinite depthKM", ErrInvalidCoordinates)
		}
		hasDepth = true
	}

	return lat, lon, depthKM, hasDepth, nil
}

func parseCoordinatePart(val string, isLon bool) (float64, error) {
	if len(val) < 2 {
		return 0, fmt.Errorf("coordinate part too short: %s", val)
	}
	sign := 1.0
	if val[0] == '-' {
		sign = -1.0
	} else if val[0] != '+' {
		return 0, fmt.Errorf("coordinate part must start with + or -: %s", val)
	}
	num := val[1:]

	degLen := 2
	if isLon {
		degLen = 3
	}

	intPart := num
	if dotIdx := strings.IndexByte(num, '.'); dotIdx >= 0 {
		intPart = num[:dotIdx]
	}

	// Degree-minute format check:
	// Lat: 2 digits deg + 2 digits min (len 4).
	// Lon: 3 digits deg + 2 digits min (len 5).
	if len(intPart) == degLen+2 {
		degStr := num[:degLen]
		minStr := num[degLen:]
		deg, err1 := strconv.ParseFloat(degStr, 64)
		min, err2 := strconv.ParseFloat(minStr, 64)
		if err1 != nil || err2 != nil || math.IsNaN(deg) || math.IsNaN(min) || math.IsInf(deg, 0) || math.IsInf(min, 0) {
			return 0, fmt.Errorf("invalid deg/min: %s", val)
		}
		if min < 0 || min >= 60.0 {
			return 0, fmt.Errorf("minutes %f out of range [0, 60)", min)
		}
		v := sign * (deg + (min / 60.0))
		if math.IsNaN(v) || math.IsInf(v, 0) {
			return 0, fmt.Errorf("nonfinite deg/min: %s", val)
		}
		return v, nil
	}

	v, err := strconv.ParseFloat(val, 64)
	if err != nil || math.IsNaN(v) || math.IsInf(v, 0) {
		return 0, fmt.Errorf("invalid float coordinate: %s", val)
	}
	return v, nil
}

func parseAndValidateTimestamp(ts string) error {
	ts = strings.TrimSpace(ts)
	if ts == "" {
		return errors.New("empty timestamp")
	}
	if _, err := time.Parse(time.RFC3339, ts); err == nil {
		return nil
	}
	if _, err := time.Parse(time.RFC3339Nano, ts); err == nil {
		return nil
	}
	return fmt.Errorf("%w: %s", ErrInvalidDateTime, ts)
}

// ExtractPhenomenon extracts the core physical phenomenon identity from a JMA warning/advisory name.
// E.g. "大雨特別警報" -> "大雨", "大雨警報" -> "大雨", "大雨注意報" -> "大雨".
// For wind warnings ("暴風警報" / "強風注意報"), it normalizes to "風".
// For snow & wind ("暴風雪警報" / "風雪注意報"), it normalizes to "風雪".
func ExtractPhenomenon(name string) string {
	name = strings.TrimSpace(name)
	switch {
	case strings.Contains(name, "暴風雪") || strings.Contains(name, "風雪"):
		return "風雪"
	case strings.Contains(name, "暴風") || strings.Contains(name, "強風"):
		return "風"
	default:
		p := name
		p = strings.ReplaceAll(p, "特別警報", "")
		p = strings.ReplaceAll(p, "警報", "")
		p = strings.ReplaceAll(p, "注意報", "")
		p = strings.TrimSpace(p)
		if p != "" {
			return p
		}
		return name
	}
}

// DeriveIdentifier extracts the bulletin identifier from the item URL filename or fallback.
func DeriveIdentifier(itemURL, eventID, serial string) string {
	base := filepath.Base(itemURL)
	if strings.HasSuffix(base, ".xml") {
		return strings.TrimSuffix(base, ".xml")
	}
	if eventID != "" && serial != "" {
		return eventID + "_" + serial
	}
	if eventID != "" {
		return eventID
	}
	return base
}

// BuildSeriesKey builds a stable series identity key from Title, EditorialOffice, Status, and EventID.
func BuildSeriesKey(title, office, status, eventID string) string {
	title = strings.TrimSpace(title)
	office = strings.TrimSpace(office)
	status = strings.TrimSpace(status)
	eventID = strings.TrimSpace(eventID)

	if eventID != "" {
		return fmt.Sprintf("%s:%s:%s:%s", title, office, status, eventID)
	}
	return fmt.Sprintf("%s:%s:%s", title, office, status)
}

// ParseTelegram parses a JMAXML telegram payload into JmaMessageContent with strict conformance.
func ParseTelegram(itemURL string, xmlBytes []byte) (*client.JmaMessageContent, error) {
	// 1. Security token pre-scan: reject DTD / entity declarations
	preScanDec := xml.NewDecoder(bytes.NewReader(xmlBytes))
	for {
		tok, err := preScanDec.Token()
		if err != nil {
			if errors.Is(err, io.EOF) {
				break
			}
			return nil, fmt.Errorf("XML syntax error: %w", err)
		}
		if dir, ok := tok.(xml.Directive); ok {
			upper := strings.ToUpper(string(dir))
			if strings.Contains(upper, "DOCTYPE") || strings.Contains(upper, "ENTITY") {
				return nil, ErrDisallowedDTD
			}
		}
	}

	// 2. Decode Report with strict root, Control, and Head namespace matching
	var report rawReport
	decoder := xml.NewDecoder(bytes.NewReader(xmlBytes))
	decoder.Entity = xml.HTMLEntity
	if err := decoder.Decode(&report); err != nil {
		if strings.Contains(err.Error(), "in name space") {
			return nil, fmt.Errorf("%w: %v", ErrUnsupportedNamespace, err)
		}
		return nil, fmt.Errorf("%w: %v", ErrInvalidRootElement, err)
	}

	// Verify root element name and namespace
	if report.XMLName.Local != "Report" {
		return nil, fmt.Errorf("%w: got %s", ErrInvalidRootElement, report.XMLName.Local)
	}
	if report.XMLName.Space != jmaXmlReportNamespace {
		return nil, fmt.Errorf("%w: root namespace %q must be %s", ErrUnsupportedNamespace, report.XMLName.Space, jmaXmlReportNamespace)
	}

	// 3. Reject unexpected trailing root elements
	for {
		tok, err := decoder.Token()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return nil, fmt.Errorf("XML syntax error after root: %w", err)
		}
		if _, ok := tok.(xml.StartElement); ok {
			return nil, ErrTrailingRootElement
		}
	}

	// 4. Validate mandatory Control.Status (never default to 通常)
	status := strings.TrimSpace(report.Control.Status)
	if status == "" {
		return nil, ErrMissingStatus
	}

	// 5. Validate timestamps
	if err := parseAndValidateTimestamp(report.Control.DateTime); err != nil {
		return nil, fmt.Errorf("control datetime: %w", err)
	}
	if err := parseAndValidateTimestamp(report.Head.ReportDateTime); err != nil {
		return nil, fmt.Errorf("report datetime: %w", err)
	}

	controlTitle := strings.TrimSpace(report.Control.Title)
	office := strings.TrimSpace(report.Control.EditorialOffice)

	// Validate InfoType: must be known (発表, 訂正, 取消, 遅延)
	infoType := strings.TrimSpace(report.Head.InfoType)
	if infoType == "" {
		infoType = "発表"
	}
	isKnownInfoType := infoType == "発表" || infoType == "訂正" || infoType == "取消" || infoType == "遅延"

	eventID := strings.TrimSpace(report.Head.EventID)
	var eventIDPtr *string
	if eventID != "" {
		eventIDPtr = &eventID
	}

	// Authoritative revision timestamp: Control.DateTime (UTC)
	sent := strings.TrimSpace(report.Control.DateTime)
	effective := strings.TrimSpace(report.Head.ReportDateTime)
	var effectivePtr *string
	if effective != "" {
		effectivePtr = &effective
	}

	// Head.ValidDateTime mapping to Expires
	var expiresPtr *string
	validDT := strings.TrimSpace(report.Head.ValidDateTime)
	if validDT != "" {
		if err := parseAndValidateTimestamp(validDT); err == nil {
			expiresPtr = &validDT
		}
	}

	headlineText := strings.TrimSpace(report.Head.Headline.Text)
	var headlinePtr *string
	if headlineText != "" {
		headlinePtr = &headlineText
	}

	identifier := DeriveIdentifier(itemURL, eventID, report.Head.Serial)
	seriesKey := BuildSeriesKey(controlTitle, office, status, eventID)

	// Collect target areas from Headline and Body
	areasMap := make(map[string]string)
	for _, info := range report.Head.Headline.Information {
		for _, item := range info.Items {
			for _, a := range item.Areas.Areas {
				if a.Code != "" && a.Name != "" {
					areasMap[a.Code] = a.Name
				}
			}
		}
	}
	for _, w := range report.Body.Warnings {
		for _, item := range w.Items {
			if item.Area.Code != "" && item.Area.Name != "" {
				areasMap[item.Area.Code] = item.Area.Name
			}
		}
	}

	areas := make([]client.JmaArea, 0, len(areasMap))
	for code, name := range areasMap {
		areas = append(areas, client.JmaArea{
			AreaName: name,
			Geocode:  code,
		})
	}

	msg := &client.JmaMessageContent{
		Identifier:   identifier,
		ControlTitle: controlTitle,
		Status:       status,
		InfoType:     infoType,
		EventID:      eventIDPtr,
		SeriesKey:    &seriesKey,
		Sent:         sent,
		Effective:    effectivePtr,
		Expires:      expiresPtr,
		Headline:     headlinePtr,
		Description:  headlinePtr,
		Areas:        areas,
		Alerts:       make([]client.JmaAlertItem, 0),
		Earthquake:   nil,
	}

	// Conformance Rule: Only "通常" produces live alerts or live earthquakes.
	// Training / Test items ("訓練", "試験") or non-standard status retain raw envelope metadata but no live models.
	if status != "通常" {
		return msg, nil
	}

	// Unknown InfoType: archive raw envelope, no normalized live event
	if !isKnownInfoType {
		return msg, nil
	}

	// Bodyless cancellation (InfoType == 取消): retain empty alerts and series_key (do not invent cancellation area keys)
	if infoType == "取消" {
		return msg, nil
	}

	// Body schema namespace validation: unknown valid official body schema archives raw envelope without live models
	bodySpace := report.Body.XMLName.Space

	// Parse Weather Warnings (jmx_mete)
	// R06 unfamiliar warning schemas (e.g. 気象警報・注意報（Ｒ０６）...): archive raw envelope with 0 normalized alerts
	isR06 := strings.Contains(controlTitle, "Ｒ０６") || strings.Contains(controlTitle, "R06")
	if bodySpace == jmaXmlMeteNamespace && !isR06 && len(report.Body.Warnings) > 0 {
		// Tier selection:
		// 1. Primary: Municipal tier "気象警報・注意報（市町村等）"
		// 2. Fallback: Municipal aggregated regional tier "気象警報・注意報（市町村等をまとめた地域等）"
		// 3. Fallback: Primary subdivision tier "気象警報・注意報（一次細分区域等）"
		// 4. Fallback: Generic "気象警報・注意報"
		var selectedWarning *rawWarning
		for i := range report.Body.Warnings {
			w := &report.Body.Warnings[i]
			if w.Type == "気象警報・注意報（市町村等）" {
				selectedWarning = w
				break
			}
		}
		if selectedWarning == nil {
			for i := range report.Body.Warnings {
				w := &report.Body.Warnings[i]
				if w.Type == "気象警報・注意報（市町村等をまとめた地域等）" {
					selectedWarning = w
					break
				}
			}
		}
		if selectedWarning == nil {
			for i := range report.Body.Warnings {
				w := &report.Body.Warnings[i]
				if w.Type == "気象警報・注意報（一次細分区域等）" {
					selectedWarning = w
					break
				}
			}
		}
		if selectedWarning == nil {
			for i := range report.Body.Warnings {
				w := &report.Body.Warnings[i]
				if w.Type == "気象警報・注意報" {
					selectedWarning = w
					break
				}
			}
		}

		if selectedWarning != nil {
			activeGeocodes := make(map[string]bool)
			noWarningGeocodes := make(map[string]bool)

			for _, item := range selectedWarning.Items {
				areaName := item.Area.Name
				geocode := item.Area.Code

				for _, kind := range item.Kinds {
					eventName := strings.TrimSpace(kind.Name)
					kindStatus := strings.TrimSpace(kind.Status)
					kindCode := strings.TrimSpace(kind.Code)

					// Identify no-warning placeholder elements ("発表警報・注意報はなし" or Code "00")
					isNoWarningMarker := eventName == "発表警報・注意報はなし" ||
						kindStatus == "発表警報・注意報はなし" ||
						kindCode == "00"

					if isNoWarningMarker {
						if geocode != "" {
							noWarningGeocodes[geocode] = true
						}
						continue
					}

					// Otherwise this is an alert item (active or transition or cancellation)
					if geocode != "" {
						activeGeocodes[geocode] = true
					}

					if kindStatus == "" {
						kindStatus = "発表"
					}

					// Stable lifecycle key: series_key + geocode + phenomenon identity.
					// Ensures transitions (e.g. warning -> advisory or active -> 解除) update the same alert record.
					phenomenon := ExtractPhenomenon(eventName)
					lifecycleKey := fmt.Sprintf("%s:%s:%s", seriesKey, geocode, phenomenon)

					severity := "Moderate"
					if strings.Contains(eventName, "特別警報") {
						severity = "Extreme"
					} else if kindStatus == "警報から注意報" {
						// 警報から注意報 represents an active advisory downgraded from a previous warning
						severity = "Moderate"
					} else if strings.Contains(eventName, "警報") {
						severity = "Severe"
					} else if strings.Contains(eventName, "注意報") {
						severity = "Moderate"
					}

					category := "Met"
					msg.Alerts = append(msg.Alerts, client.JmaAlertItem{
						LifecycleKey: lifecycleKey,
						AreaName:     areaName,
						Geocode:      geocode,
						Event:        eventName,
						Category:     &category,
						Status:       kindStatus,
						Severity:     severity,
						Urgency:      "Expected",
						Certainty:    "Observed",
					})
				}
			}

			// Derive ClearedAreas: unique geocodes explicitly marked as no-warning without conflicting active alerts
			var clearedList []string
			for gc := range noWarningGeocodes {
				if !activeGeocodes[gc] {
					clearedList = append(clearedList, gc)
				}
			}
			if len(clearedList) > 0 {
				sort.Strings(clearedList)
				msg.ClearedAreas = clearedList
			}
		}
	}

	// Parse Observed Earthquake (jmx_seis)
	// Supported observed earthquake bulletins only: VXSE52 ("震源に関する情報") or VXSE53 ("震源・震度に関する情報").
	// Never EEW ("緊急地震速報") or tsunami forecast ("津波").
	isObservedQuake := (controlTitle == "震源・震度に関する情報" || controlTitle == "震源に関する情報") &&
		(report.Head.InfoKind == "地震情報" || report.Head.InfoKind == "震源・震度に関する情報" || report.Head.InfoKind == "震源に関する情報")
	isEEW := strings.Contains(controlTitle, "緊急地震速報") || strings.Contains(report.Head.InfoKind, "緊急地震速報")
	isTsunami := strings.Contains(controlTitle, "津波") || strings.Contains(report.Head.InfoKind, "津波")

	if bodySpace == jmaXmlSeisNamespace && isObservedQuake && !isEEW && !isTsunami && report.Body.Earthquake != nil {
		eq := report.Body.Earthquake
		// No invented origin fallback from ReportDateTime; use OriginTime as provided
		originTime := strings.TrimSpace(eq.OriginTime)

		var (
			latPtr     *client.Float64
			lonPtr     *client.Float64
			depthKMPtr *client.Float64
			magPtr     *client.Float64
			placePtr   *string
			maxIntPtr  *string
		)

		if eq.Hypocenter != nil {
			place := strings.TrimSpace(eq.Hypocenter.Area.Name)
			if place != "" {
				placePtr = &place
			}

			coord := eq.Hypocenter.Area.Coordinate
			datum := strings.TrimSpace(coord.Datum)
			cType := strings.TrimSpace(coord.Type)

			// Datum check: reject explicit unsupported Tokyo Datum (日本測地系) without verified transformation
			if strings.Contains(datum, "日本測地系") || strings.Contains(datum, "Tokyo") ||
				strings.Contains(cType, "日本測地系") || strings.Contains(cType, "Tokyo") {
				return nil, fmt.Errorf("%w: explicit Tokyo datum rejected (datum=%q, type=%q)", ErrUnsupportedDatum, datum, cType)
			}

			// Reject unknown explicit datum
			isSupportedDatum := func(d string) bool {
				if d == "" || d == "世界測地系" || d == "WGS-84" || d == "WGS84" || strings.HasPrefix(d, "ITRF") || strings.HasPrefix(d, "JGD") {
					return true
				}
				return false
			}
			if datum != "" && !isSupportedDatum(datum) {
				return nil, fmt.Errorf("%w: unknown explicit datum %q", ErrUnsupportedDatum, datum)
			}
			if cType != "" && !isSupportedDatum(cType) && cType != "震央位置" && cType != "位置" {
				return nil, fmt.Errorf("%w: unknown explicit coordinate type/datum %q", ErrUnsupportedDatum, cType)
			}

			rawCoordVal := strings.TrimSpace(coord.Value)
			if rawCoordVal != "" && rawCoordVal != "/" {
				lat, lon, depthKM, hasDepth, err := ParseISO6709(rawCoordVal)
				if err == nil {
					l1 := client.Float64(lat)
					l2 := client.Float64(lon)
					latPtr = &l1
					lonPtr = &l2
					if hasDepth {
						d := client.Float64(depthKM)
						depthKMPtr = &d
					}
				}
			}
		}

		if eq.Magnitude != nil {
			rawMag := strings.TrimSpace(eq.Magnitude.Value)
			if rawMag != "" && rawMag != "NaN" {
				if m, err := strconv.ParseFloat(rawMag, 64); err == nil && !math.IsNaN(m) && !math.IsInf(m, 0) {
					magVal := client.Float64(m)
					magPtr = &magVal
				}
			}
		}

		if report.Body.Intensity != nil && report.Body.Intensity.Observation != nil {
			maxInt := strings.TrimSpace(report.Body.Intensity.Observation.MaxInt)
			if maxInt != "" {
				maxIntPtr = &maxInt
			}
		}

		magType := "Mj"
		msg.Earthquake = &client.JmaEarthquake{
			OriginTime:    originTime,
			Latitude:      latPtr,
			Longitude:     lonPtr,
			DepthKM:       depthKMPtr,
			Magnitude:     magPtr,
			MagnitudeType: &magType,
			Place:         placePtr,
			MaxIntensity:  maxIntPtr,
		}
	}

	return msg, nil
}
