package adapter

import (
	"bytes"
	"encoding/xml"
	"strings"
)

type RAAFeed struct {
	URL      string  `json:"url"`
	Language *string `json:"language"`
}

func (f *RAAFeed) UnmarshalXML(d *xml.Decoder, start xml.StartElement) error {
	for _, attr := range start.Attr {
		if attr.Name.Local == "lang" {
			val := strings.TrimSpace(attr.Value)
			if val != "" {
				f.Language = &val
			}
		}
	}
	var content string
	if err := d.DecodeElement(&content, &start); err != nil {
		return err
	}
	f.URL = strings.TrimSpace(content)
	return nil
}

type RAARegistryFeature struct {
	GUID        *string   `json:"guid"`
	Title       *string   `json:"title"`
	CountryISO3 *string   `json:"country_iso3"`
	Link        *string   `json:"link"`
	Description *string   `json:"description"`
	PubDate     *string   `json:"pub_date"`
	Abbrev      *string   `json:"abbrev"`
	Feeds       []RAAFeed `json:"feeds"`
}

type rawRAAItem struct {
	Title       *string   `xml:"title"`
	CountryCode *string   `xml:"countrycode"`
	Link        *string   `xml:"link"`
	Description *string   `xml:"description"`
	PubDate     *string   `xml:"pubDate"`
	GUID        *string   `xml:"guid"`
	Abbrev      *string   `xml:"authorityAbbrev"`
	Feeds       []RAAFeed `xml:"capAlertFeed"`
}

type rawRAAChannel struct {
	Items []rawRAAItem `xml:"item"`
}

type rawRAARSS struct {
	XMLName xml.Name      `xml:"rss"`
	Channel rawRAAChannel `xml:"channel"`
}

// ParseRAA parses the WMO RAA RSS 2.0 document into registry features per contract §5.1.
func ParseRAA(data []byte) ([]RAARegistryFeature, error) {
	data = bytes.TrimPrefix(data, []byte("\xef\xbb\xbf"))
	var rss rawRAARSS
	if err := xml.Unmarshal(data, &rss); err != nil {
		return nil, err
	}

	features := make([]RAARegistryFeature, 0, len(rss.Channel.Items))
	for _, item := range rss.Channel.Items {
		feeds := make([]RAAFeed, 0, len(item.Feeds))
		for _, feed := range item.Feeds {
			u := strings.TrimSpace(feed.URL)
			if u == "" {
				continue
			}
			f := RAAFeed{
				URL:      u,
				Language: cleanStringPtr(feed.Language),
			}
			feeds = append(feeds, f)
		}

		feat := RAARegistryFeature{
			GUID:        cleanStringPtr(item.GUID),
			Title:       cleanStringPtr(item.Title),
			CountryISO3: cleanStringPtr(item.CountryCode),
			Link:        cleanStringPtr(item.Link),
			Description: cleanStringPtr(item.Description),
			PubDate:     cleanStringPtr(item.PubDate),
			Abbrev:      cleanStringPtr(item.Abbrev),
			Feeds:       feeds,
		}
		features = append(features, feat)
	}

	return features, nil
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
