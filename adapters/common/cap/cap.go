package cap

import (
	"bytes"
	"encoding/xml"
	"fmt"
	"io"
	"regexp"
	"strconv"
	"strings"

	"golang.org/x/net/html/charset"
)

const maxNonAlertRawSize = 1 << 20

var customHTMLAutoClose = []string{
	"basefont",
	"br",
	"col",
	"frame",
	"hr",
	"img",
	"input",
	"isindex",
}

type CAPKeyValuePair struct {
	ValueName string `json:"valueName"`
	Value     string `json:"value"`
}

type CAPResource struct {
	ResourceDesc string  `json:"resourceDesc"`
	MimeType     *string `json:"mimeType"`
	Size         *int64  `json:"size"`
	URI          *string `json:"uri"`
	Digest       *string `json:"digest"`
}

type CAPArea struct {
	AreaDesc string            `json:"areaDesc"`
	Polygon  []string          `json:"polygon"`
	Circle   []string          `json:"circle"`
	Geocode  []CAPKeyValuePair `json:"geocode"`
	Altitude *string           `json:"altitude"`
	Ceiling  *string           `json:"ceiling"`
}

type CAPInfo struct {
	Language     *string           `json:"language"`
	Category     []string          `json:"category"`
	Event        string            `json:"event"`
	ResponseType []string          `json:"responseType"`
	Urgency      string            `json:"urgency"`
	Severity     string            `json:"severity"`
	Certainty    string            `json:"certainty"`
	Audience     *string           `json:"audience"`
	EventCode    []CAPKeyValuePair `json:"eventCode"`
	Effective    *string           `json:"effective"`
	Onset        *string           `json:"onset"`
	Expires      *string           `json:"expires"`
	SenderName   *string           `json:"senderName"`
	Headline     *string           `json:"headline"`
	Description  *string           `json:"description"`
	Instruction  *string           `json:"instruction"`
	Web          *string           `json:"web"`
	Contact      *string           `json:"contact"`
	Parameter    []CAPKeyValuePair `json:"parameter"`
	Resource     []CAPResource     `json:"resource"`
	Area         []CAPArea         `json:"area"`
}

type CAPAlert struct {
	CAPVersion  string    `json:"cap_version"`
	Identifier  string    `json:"identifier"`
	Sender      string    `json:"sender"`
	Sent        string    `json:"sent"`
	Status      string    `json:"status"`
	MsgType     string    `json:"msgType"`
	Source      *string   `json:"source"`
	Scope       string    `json:"scope"`
	Restriction *string   `json:"restriction"`
	Addresses   *string   `json:"addresses"`
	Code        []string  `json:"code"`
	Note        *string   `json:"note"`
	References  *string   `json:"references"`
	Incidents   *string   `json:"incidents"`
	Info        []CAPInfo `json:"info"`
}

type rawKeyValuePairXML struct {
	ValueName string `xml:"valueName"`
	Value     string `xml:"value"`
}

type rawResourceXML struct {
	ResourceDesc string  `xml:"resourceDesc"`
	MimeType     *string `xml:"mimeType"`
	Size         *string `xml:"size"`
	URI          *string `xml:"uri"`
	Digest       *string `xml:"digest"`
}

type rawAreaXML struct {
	AreaDesc string               `xml:"areaDesc"`
	Polygon  []string             `xml:"polygon"`
	Circle   []string             `xml:"circle"`
	Geocode  []rawKeyValuePairXML `xml:"geocode"`
	Altitude *string              `xml:"altitude"`
	Ceiling  *string              `xml:"ceiling"`
}

type rawInfoXML struct {
	Language     *string              `xml:"language"`
	Category     []string             `xml:"category"`
	Event        string               `xml:"event"`
	ResponseType []string             `xml:"responseType"`
	Urgency      string               `xml:"urgency"`
	Severity     string               `xml:"severity"`
	Certainty    string               `xml:"certainty"`
	Audience     *string              `xml:"audience"`
	EventCode    []rawKeyValuePairXML `xml:"eventCode"`
	Effective    *string              `xml:"effective"`
	Onset        *string              `xml:"onset"`
	Expires      *string              `xml:"expires"`
	SenderName   *string              `xml:"senderName"`
	Headline     *string              `xml:"headline"`
	Description  *string              `xml:"description"`
	Instruction  *string              `xml:"instruction"`
	Web          *string              `xml:"web"`
	Contact      *string              `xml:"contact"`
	Parameter    []rawKeyValuePairXML `xml:"parameter"`
	Resource     []rawResourceXML     `xml:"resource"`
	Area         []rawAreaXML         `xml:"area"`
}

type rawAlertXML struct {
	XMLName     xml.Name
	Identifier  string       `xml:"identifier"`
	Sender      string       `xml:"sender"`
	Sent        string       `xml:"sent"`
	Status      string       `xml:"status"`
	MsgType     string       `xml:"msgType"`
	Source      *string      `xml:"source"`
	Scope       string       `xml:"scope"`
	Restriction *string      `xml:"restriction"`
	Addresses   *string      `xml:"addresses"`
	Code        []string     `xml:"code"`
	Note        *string      `xml:"note"`
	References  *string      `xml:"references"`
	Incidents   *string      `xml:"incidents"`
	Info        []rawInfoXML `xml:"info"`
}

type CAPResult struct {
	Cap    *CAPAlert
	Error  *string
	RawXML *string
}

var xmlDeclRE = regexp.MustCompile(`(?is)^\s*<\?xml\b[^>]*\?>`)
var xmlEncodingRE = regexp.MustCompile(`(?i)(encoding\s*=\s*["'])([^"']+)(["'])`)

func toUTF8(src []byte) ([]byte, error) {
	declLoc := xmlDeclRE.FindIndex(src)
	if declLoc == nil {
		return src, nil
	}
	decl := src[declLoc[0]:declLoc[1]]
	match := xmlEncodingRE.FindSubmatch(decl)
	if match == nil {
		return src, nil
	}
	label := strings.TrimSpace(string(match[2]))
	if strings.EqualFold(label, "utf-8") || strings.EqualFold(label, "utf8") || label == "" {
		return src, nil
	}
	r, err := charset.NewReaderLabel(label, bytes.NewReader(src))
	if err != nil {
		return nil, err
	}
	out, err := io.ReadAll(r)
	if err != nil {
		return nil, err
	}
	outDeclLoc := xmlDeclRE.FindIndex(out)
	if outDeclLoc != nil {
		outDecl := out[outDeclLoc[0]:outDeclLoc[1]]
		rewrittenDecl := xmlEncodingRE.ReplaceAll(outDecl, []byte(`${1}UTF-8${3}`))
		var buf bytes.Buffer
		buf.Write(rewrittenDecl)
		buf.Write(out[outDeclLoc[1]:])
		out = buf.Bytes()
	}
	return out, nil
}

func ParseCAP(data []byte) CAPResult {
	cleanData := bytes.TrimPrefix(data, []byte("\xef\xbb\xbf"))

	utf8Data, err := toUTF8(cleanData)
	if err != nil {
		utf8Data = cleanData
	}

	res := parseCAPInternal(utf8Data, true)
	if res.Error == nil {
		return res
	}

	fallbackRes := parseCAPInternal(utf8Data, false)
	if fallbackRes.Error == nil {
		return fallbackRes
	}

	return res
}

func parseCAPInternal(utf8Data []byte, strict bool) CAPResult {
	decoder := xml.NewDecoder(bytes.NewReader(utf8Data))
	decoder.CharsetReader = charset.NewReaderLabel
	if !strict {
		decoder.Strict = false
		decoder.AutoClose = customHTMLAutoClose
		decoder.Entity = xml.HTMLEntity
	}

	var rootStart *xml.StartElement
	for {
		tok, err := decoder.Token()
		if err != nil {
			errStr := fmt.Sprintf("xml parse error: %v", err)
			rawStr := string(truncateRaw(utf8Data, maxNonAlertRawSize))
			return CAPResult{
				Cap:    nil,
				Error:  &errStr,
				RawXML: &rawStr,
			}
		}
		if se, ok := tok.(xml.StartElement); ok {
			rootStart = &se
			break
		}
	}

	rootName := strings.ToLower(rootStart.Name.Local)
	if rootName != "alert" {
		errStr := fmt.Sprintf("not a CAP alert: root <%s>", rootStart.Name.Local)
		rawStr := string(truncateRaw(utf8Data, maxNonAlertRawSize))
		return CAPResult{
			Cap:    nil,
			Error:  &errStr,
			RawXML: &rawStr,
		}
	}

	capVersion := detectCAPVersion(*rootStart)

	var raw rawAlertXML
	if err := decoder.DecodeElement(&raw, rootStart); err != nil {
		errStr := fmt.Sprintf("decode CAP alert failed: %v", err)
		rawStr := string(truncateRaw(utf8Data, maxNonAlertRawSize))
		return CAPResult{
			Cap:    nil,
			Error:  &errStr,
			RawXML: &rawStr,
		}
	}

	alert := buildCAPAlert(capVersion, raw)
	rawStr := string(utf8Data)
	return CAPResult{
		Cap:    &alert,
		Error:  nil,
		RawXML: &rawStr,
	}
}

func detectCAPVersion(start xml.StartElement) string {
	ns := start.Name.Space
	if ns == "" {
		for _, attr := range start.Attr {
			if attr.Name.Local == "xmlns" || attr.Name.Space == "xmlns" {
				ns = attr.Value
				break
			}
		}
	}
	if strings.Contains(ns, "1.2") {
		return "1.2"
	}
	if strings.Contains(ns, "1.1") {
		return "1.1"
	}
	if strings.Contains(ns, "1.0") {
		return "1.0"
	}
	return ""
}

func buildCAPAlert(capVersion string, raw rawAlertXML) CAPAlert {
	alert := CAPAlert{
		CAPVersion:  capVersion,
		Identifier:  strings.TrimSpace(raw.Identifier),
		Sender:      strings.TrimSpace(raw.Sender),
		Sent:        strings.TrimSpace(raw.Sent),
		Status:      strings.TrimSpace(raw.Status),
		MsgType:     strings.TrimSpace(raw.MsgType),
		Source:      cleanStringPtr(raw.Source),
		Scope:       strings.TrimSpace(raw.Scope),
		Restriction: cleanStringPtr(raw.Restriction),
		Addresses:   cleanStringPtr(raw.Addresses),
		Code:        cleanStringSlice(raw.Code),
		Note:        cleanStringPtr(raw.Note),
		References:  cleanStringPtr(raw.References),
		Incidents:   cleanStringPtr(raw.Incidents),
		Info:        make([]CAPInfo, 0, len(raw.Info)),
	}

	for _, rawInfo := range raw.Info {
		info := CAPInfo{
			Language:     cleanStringPtr(rawInfo.Language),
			Category:     cleanStringSlice(rawInfo.Category),
			Event:        strings.TrimSpace(rawInfo.Event),
			ResponseType: cleanStringSlice(rawInfo.ResponseType),
			Urgency:      strings.TrimSpace(rawInfo.Urgency),
			Severity:     strings.TrimSpace(rawInfo.Severity),
			Certainty:    strings.TrimSpace(rawInfo.Certainty),
			Audience:     cleanStringPtr(rawInfo.Audience),
			EventCode:    buildKeyValuePairs(rawInfo.EventCode),
			Effective:    cleanStringPtr(rawInfo.Effective),
			Onset:        cleanStringPtr(rawInfo.Onset),
			Expires:      cleanStringPtr(rawInfo.Expires),
			SenderName:   cleanStringPtr(rawInfo.SenderName),
			Headline:     cleanStringPtr(rawInfo.Headline),
			Description:  cleanStringPtr(rawInfo.Description),
			Instruction:  cleanStringPtr(rawInfo.Instruction),
			Web:          cleanStringPtr(rawInfo.Web),
			Contact:      cleanStringPtr(rawInfo.Contact),
			Parameter:    buildKeyValuePairs(rawInfo.Parameter),
			Resource:     make([]CAPResource, 0, len(rawInfo.Resource)),
			Area:         make([]CAPArea, 0, len(rawInfo.Area)),
		}

		for _, rawRes := range rawInfo.Resource {
			res := CAPResource{
				ResourceDesc: strings.TrimSpace(rawRes.ResourceDesc),
				MimeType:     cleanStringPtr(rawRes.MimeType),
				Size:         parseSizePtr(rawRes.Size),
				URI:          cleanStringPtr(rawRes.URI),
				Digest:       cleanStringPtr(rawRes.Digest),
			}
			info.Resource = append(info.Resource, res)
		}

		for _, rawArea := range rawInfo.Area {
			area := CAPArea{
				AreaDesc: strings.TrimSpace(rawArea.AreaDesc),
				Polygon:  cleanStringSlice(rawArea.Polygon),
				Circle:   cleanStringSlice(rawArea.Circle),
				Geocode:  buildKeyValuePairs(rawArea.Geocode),
				Altitude: cleanStringPtr(rawArea.Altitude),
				Ceiling:  cleanStringPtr(rawArea.Ceiling),
			}
			info.Area = append(info.Area, area)
		}

		alert.Info = append(alert.Info, info)
	}

	return alert
}

func cleanStringPtr(s *string) *string {
	if s == nil {
		return nil
	}
	trimmed := strings.TrimSpace(*s)
	if trimmed == "" {
		return nil
	}
	return &trimmed
}

func cleanStringSlice(s []string) []string {
	if len(s) == 0 {
		return []string{}
	}
	res := make([]string, 0, len(s))
	for _, item := range s {
		trimmed := strings.TrimSpace(item)
		if trimmed != "" {
			res = append(res, trimmed)
		}
	}
	return res
}

func buildKeyValuePairs(pairs []rawKeyValuePairXML) []CAPKeyValuePair {
	if len(pairs) == 0 {
		return []CAPKeyValuePair{}
	}
	res := make([]CAPKeyValuePair, 0, len(pairs))
	for _, p := range pairs {
		res = append(res, CAPKeyValuePair{
			ValueName: strings.TrimSpace(p.ValueName),
			Value:     strings.TrimSpace(p.Value),
		})
	}
	return res
}

func parseSizePtr(s *string) *int64 {
	if s == nil {
		return nil
	}
	trimmed := strings.TrimSpace(*s)
	if trimmed == "" {
		return nil
	}
	val, err := strconv.ParseInt(trimmed, 10, 64)
	if err != nil {
		return nil
	}
	return &val
}

func truncateRaw(data []byte, limit int) []byte {
	if len(data) > limit {
		return data[:limit]
	}
	return data
}
