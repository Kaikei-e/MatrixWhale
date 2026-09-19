package adapter

import (
	"bytes"
	"encoding/xml"
	"fmt"
	"io"
	"net/url"
	"strings"

	"golang.org/x/net/html/charset"
)

const (
	FormatRSS   = "rss"
	FormatAtom  = "atom"
	FormatOther = "other"
)

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

type FeedIndexFeature struct {
	GUID      *string `json:"guid"`
	Title     *string `json:"title"`
	CAPURL    *string `json:"cap_url"`
	Published *string `json:"published"`
}

type FeedParseResult struct {
	Format   string
	Features []FeedIndexFeature
	Error    string
}

type atomLink struct {
	Href string `xml:"href,attr"`
	Rel  string `xml:"rel,attr"`
	Type string `xml:"type,attr"`
}

type atomEntry struct {
	ID        string
	Title     string
	Updated   string
	Published string
	Links     []atomLink
}

func (ae *atomEntry) UnmarshalXML(d *xml.Decoder, start xml.StartElement) error {
	depth := 1
	for depth > 0 {
		tok, err := d.Token()
		if err != nil {
			if err == io.EOF {
				break
			}
			return err
		}
		switch t := tok.(type) {
		case xml.StartElement:
			depth++
			if t.Name.Space == "" || t.Name.Space == start.Name.Space {
				switch t.Name.Local {
				case "id":
					var v string
					if err := d.DecodeElement(&v, &t); err != nil {
						return err
					}
					depth--
					ae.ID = strings.TrimSpace(v)
					continue
				case "title":
					var v string
					if err := d.DecodeElement(&v, &t); err != nil {
						return err
					}
					depth--
					if ae.Title == "" {
						ae.Title = strings.TrimSpace(v)
					}
					continue
				case "updated":
					var v string
					if err := d.DecodeElement(&v, &t); err != nil {
						return err
					}
					depth--
					ae.Updated = strings.TrimSpace(v)
					continue
				case "published":
					var v string
					if err := d.DecodeElement(&v, &t); err != nil {
						return err
					}
					depth--
					ae.Published = strings.TrimSpace(v)
					continue
				case "link":
					var l atomLink
					for _, a := range t.Attr {
						switch a.Name.Local {
						case "href":
							l.Href = strings.TrimSpace(a.Value)
						case "rel":
							l.Rel = strings.TrimSpace(a.Value)
						case "type":
							l.Type = strings.TrimSpace(a.Value)
						}
					}
					ae.Links = append(ae.Links, l)
					if err := d.Skip(); err != nil {
						return err
					}
					depth--
					continue
				}
			}
			// Skip elements in other namespaces (such as media:title).
			if err := d.Skip(); err != nil {
				return err
			}
			depth--
		case xml.EndElement:
			depth--
		}
	}
	return nil
}

type atomFeed struct {
	XMLName xml.Name    `xml:"feed"`
	Entries []atomEntry `xml:"entry"`
}

type rssEnclosure struct {
	URL string `xml:"url,attr"`
}

// rssItem uses a custom UnmarshalXML so that <link> and <title> are only
// populated from elements in the empty (no) namespace.  Namespaced elements
// such as <atom:link> and <media:title> are ignored, preventing them from
// overwriting the RSS-native values.
type rssItem struct {
	Title     string
	Link      string
	GUID      string        `xml:"guid"`
	PubDate   string        `xml:"pubDate"`
	Enclosure *rssEnclosure `xml:"enclosure"`
}

func (ri *rssItem) UnmarshalXML(d *xml.Decoder, start xml.StartElement) error {
	depth := 1
	for depth > 0 {
		tok, err := d.Token()
		if err != nil {
			if err == io.EOF {
				break
			}
			return err
		}
		switch t := tok.(type) {
		case xml.StartElement:
			depth++
			// Accept child when its namespace equals the item element's own namespace or is empty.
			if t.Name.Space == "" || t.Name.Space == start.Name.Space {
				switch t.Name.Local {
				case "link":
					var v string
					if err := d.DecodeElement(&v, &t); err != nil {
						return err
					}
					depth--
					if ri.Link == "" {
						ri.Link = strings.TrimSpace(v)
					}
					continue
				case "title":
					var v string
					if err := d.DecodeElement(&v, &t); err != nil {
						return err
					}
					depth--
					if ri.Title == "" {
						ri.Title = strings.TrimSpace(v)
					}
					continue
				case "guid":
					var v string
					if err := d.DecodeElement(&v, &t); err != nil {
						return err
					}
					depth--
					ri.GUID = strings.TrimSpace(v)
					continue
				case "pubDate":
					var v string
					if err := d.DecodeElement(&v, &t); err != nil {
						return err
					}
					depth--
					ri.PubDate = strings.TrimSpace(v)
					continue
				case "enclosure":
					var enc rssEnclosure
					for _, a := range t.Attr {
						if a.Name.Local == "url" {
							enc.URL = strings.TrimSpace(a.Value)
						}
					}
					ri.Enclosure = &enc
					if err := d.Skip(); err != nil {
						return err
					}
					depth--
					continue
				}
			}
			// For any other element (including namespaced ones) just skip.
			if err := d.Skip(); err != nil {
				return err
			}
			depth--
		case xml.EndElement:
			depth--
		}
	}
	return nil
}

type rssChannel struct {
	Items []rssItem `xml:"item"`
}

type rssFeed struct {
	XMLName xml.Name   `xml:"rss"`
	Channel rssChannel `xml:"channel"`
}

type rdfFeed struct {
	XMLName xml.Name  `xml:"RDF"`
	Items   []rssItem `xml:"item"`
}

// ParseFeed detects RSS or Atom and extracts index features per §5.3.
func ParseFeed(feedURL string, data []byte) FeedParseResult {
	data = bytes.TrimPrefix(data, []byte("\xef\xbb\xbf"))

	trimmed := bytes.TrimSpace(data)
	if len(trimmed) == 0 || trimmed[0] == '{' || trimmed[0] == '[' {
		return FeedParseResult{Format: FormatOther, Error: "not an XML feed"}
	}

	decoder := newFeedDecoder(data, true)
	var rootStart *xml.StartElement
	for {
		tok, err := decoder.Token()
		if err != nil {
			if err != io.EOF {
				// Retry with non-strict decoder if strict token reading failed
				decoder = newFeedDecoder(data, false)
				for {
					tok, err = decoder.Token()
					if err != nil {
						break
					}
					if se, ok := tok.(xml.StartElement); ok {
						rootStart = &se
						break
					}
				}
			}
			if rootStart == nil {
				if err == io.EOF {
					return FeedParseResult{
						Format: FormatOther,
						Error:  "not an XML feed",
					}
				}
				return FeedParseResult{
					Format: FormatOther,
					Error:  fmt.Sprintf("xml parse error: %v", err),
				}
			}
			break
		}
		if se, ok := tok.(xml.StartElement); ok {
			rootStart = &se
			break
		}
	}

	rootLocal := strings.ToLower(rootStart.Name.Local)
	switch rootLocal {
	case "rss":
		return parseRSS(feedURL, data)
	case "rdf":
		return parseRDF(feedURL, data)
	case "feed":
		return parseAtom(feedURL, data)
	default:
		return FeedParseResult{
			Format: FormatOther,
			Error:  fmt.Sprintf("not an XML feed: root <%s>", rootStart.Name.Local),
		}
	}
}

func newFeedDecoder(data []byte, strict bool) *xml.Decoder {
	d := xml.NewDecoder(bytes.NewReader(data))
	d.CharsetReader = charset.NewReaderLabel
	if !strict {
		d.Strict = false
		d.AutoClose = customHTMLAutoClose
		d.Entity = xml.HTMLEntity
	}
	return d
}

func parseRSS(feedURL string, data []byte) FeedParseResult {
	var feed rssFeed
	if err := newFeedDecoder(data, true).Decode(&feed); err != nil {
		var fallbackFeed rssFeed
		if fallbackErr := newFeedDecoder(data, false).Decode(&fallbackFeed); fallbackErr == nil {
			return FeedParseResult{
				Format:   FormatRSS,
				Features: extractRSSFeatures(feedURL, fallbackFeed.Channel.Items),
			}
		}
		return FeedParseResult{
			Format: FormatRSS,
			Error:  fmt.Sprintf("failed to parse RSS feed: %v", err),
		}
	}
	return FeedParseResult{
		Format:   FormatRSS,
		Features: extractRSSFeatures(feedURL, feed.Channel.Items),
	}
}

func parseRDF(feedURL string, data []byte) FeedParseResult {
	var feed rdfFeed
	if err := newFeedDecoder(data, true).Decode(&feed); err != nil {
		var fallbackFeed rdfFeed
		if fallbackErr := newFeedDecoder(data, false).Decode(&fallbackFeed); fallbackErr == nil {
			return FeedParseResult{
				Format:   FormatRSS,
				Features: extractRSSFeatures(feedURL, fallbackFeed.Items),
			}
		}
		return FeedParseResult{
			Format: FormatRSS,
			Error:  fmt.Sprintf("failed to parse RDF feed: %v", err),
		}
	}
	return FeedParseResult{
		Format:   FormatRSS,
		Features: extractRSSFeatures(feedURL, feed.Items),
	}
}

func extractRSSFeatures(feedURL string, items []rssItem) []FeedIndexFeature {
	features := make([]FeedIndexFeature, 0, len(items))
	for _, item := range items {
		// cap_url extraction rules for RSS:
		// 1. <link> text
		// 2. else <guid> if it looks like an http(s) URL
		// 3. else <enclosure url>
		candidate := strings.TrimSpace(item.Link)
		if candidate == "" {
			guidCandidate := strings.TrimSpace(item.GUID)
			lowerGuid := strings.ToLower(guidCandidate)
			if strings.HasPrefix(lowerGuid, "http://") || strings.HasPrefix(lowerGuid, "https://") {
				candidate = guidCandidate
			}
		}
		if candidate == "" && item.Enclosure != nil {
			candidate = strings.TrimSpace(item.Enclosure.URL)
		}

		capURL := resolveCandidateURL(feedURL, candidate)

		features = append(features, FeedIndexFeature{
			GUID:      cleanNonEmpty(item.GUID),
			Title:     cleanNonEmpty(item.Title),
			CAPURL:    capURL,
			Published: cleanNonEmpty(item.PubDate),
		})
	}
	return features
}

func parseAtom(feedURL string, data []byte) FeedParseResult {
	var feed atomFeed
	if err := newFeedDecoder(data, true).Decode(&feed); err != nil {
		var fallbackFeed atomFeed
		if fallbackErr := newFeedDecoder(data, false).Decode(&fallbackFeed); fallbackErr == nil {
			return extractAtomFeatures(feedURL, fallbackFeed.Entries)
		}
		return FeedParseResult{
			Format: FormatAtom,
			Error:  fmt.Sprintf("failed to parse Atom feed: %v", err),
		}
	}
	return extractAtomFeatures(feedURL, feed.Entries)
}

func extractAtomFeatures(feedURL string, entries []atomEntry) FeedParseResult {
	features := make([]FeedIndexFeature, 0, len(entries))
	for _, entry := range entries {
		// cap_url extraction rules for Atom:
		// 1. <link> whose type contains "cap"
		// 2. else first <link rel="alternate">
		// 3. else first <link> href
		var candidate string
		for _, link := range entry.Links {
			if strings.Contains(strings.ToLower(link.Type), "cap") && strings.TrimSpace(link.Href) != "" {
				candidate = link.Href
				break
			}
		}
		if candidate == "" {
			for _, link := range entry.Links {
				if strings.EqualFold(strings.TrimSpace(link.Rel), "alternate") && strings.TrimSpace(link.Href) != "" {
					candidate = link.Href
					break
				}
			}
		}
		if candidate == "" {
			for _, link := range entry.Links {
				if strings.TrimSpace(link.Href) != "" {
					candidate = link.Href
					break
				}
			}
		}

		capURL := resolveCandidateURL(feedURL, candidate)

		published := entry.Published
		if strings.TrimSpace(published) == "" {
			published = entry.Updated
		}

		features = append(features, FeedIndexFeature{
			GUID:      cleanNonEmpty(entry.ID),
			Title:     cleanNonEmpty(entry.Title),
			CAPURL:    capURL,
			Published: cleanNonEmpty(published),
		})
	}

	return FeedParseResult{
		Format:   FormatAtom,
		Features: features,
	}
}

func resolveCandidateURL(feedURL, candidate string) *string {
	candidate = strings.TrimSpace(candidate)
	if candidate == "" {
		return nil
	}
	ref, err := url.Parse(candidate)
	if err != nil {
		return &candidate
	}
	if ref.IsAbs() {
		res := ref.String()
		return &res
	}
	base, err := url.Parse(feedURL)
	if err != nil {
		return &candidate
	}
	resolved := base.ResolveReference(ref).String()
	return &resolved
}

func cleanNonEmpty(s string) *string {
	trimmed := strings.TrimSpace(s)
	if trimmed == "" {
		return nil
	}
	return &trimmed
}
