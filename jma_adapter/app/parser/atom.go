package parser

import (
	"bytes"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"strings"

	"jma_adapter/client"
)

const atomNamespace = "http://www.w3.org/2005/Atom"

type atomLink struct {
	Rel  string `xml:"rel,attr"`
	Type string `xml:"type,attr"`
	Href string `xml:"href,attr"`
}

type atomEntry struct {
	ID        string     `xml:"id"`
	Title     string     `xml:"title"`
	Updated   string     `xml:"updated"`
	Published string     `xml:"published"`
	Links     []atomLink `xml:"link"`
}

type atomFeed struct {
	XMLName xml.Name    `xml:"http://www.w3.org/2005/Atom feed"`
	Title   string      `xml:"title"`
	Updated string      `xml:"updated"`
	Entries []atomEntry `xml:"entry"`
}

// ParseAtomFeed parses an Atom 1.0 feed, enforces strict namespace, DTD rejection,
// validates item URLs, deduplicates items within feed, and returns JmaIndexItem slice.
func ParseAtomFeed(feedURL string, feedBytes []byte, validator *client.URLValidator) ([]client.JmaIndexItem, error) {
	// 1. Security token pre-scan: reject DTD / entity declarations
	preScanDec := xml.NewDecoder(bytes.NewReader(feedBytes))
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

	// 2. Decode feed with strict namespace matching
	var feed atomFeed
	decoder := xml.NewDecoder(bytes.NewReader(feedBytes))
	decoder.Entity = xml.HTMLEntity
	if err := decoder.Decode(&feed); err != nil {
		if strings.Contains(err.Error(), "in name space") {
			return nil, fmt.Errorf("%w: %v", ErrUnsupportedNamespace, err)
		}
		return nil, fmt.Errorf("decode Atom XML: %w", err)
	}

	if feed.XMLName.Local != "feed" {
		return nil, fmt.Errorf("root element is not feed: %s", feed.XMLName.Local)
	}
	if feed.XMLName.Space != atomNamespace {
		return nil, fmt.Errorf("%w: feed namespace %q must be %s", ErrUnsupportedNamespace, feed.XMLName.Space, atomNamespace)
	}

	// 3. Reject trailing extra root elements
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

	items := make([]client.JmaIndexItem, 0, len(feed.Entries))
	seenURLs := make(map[string]bool)

	for _, entry := range feed.Entries {
		var itemURL string
		// Prefer application/xml link
		for _, link := range entry.Links {
			if link.Type == "application/xml" && link.Href != "" {
				itemURL = link.Href
				break
			}
		}
		// Fallback to any href ending in .xml
		if itemURL == "" {
			for _, link := range entry.Links {
				if strings.HasSuffix(link.Href, ".xml") {
					itemURL = link.Href
					break
				}
			}
		}
		// Fallback to id if it is a valid URL
		if itemURL == "" && strings.HasPrefix(entry.ID, "http") && strings.HasSuffix(entry.ID, ".xml") {
			itemURL = entry.ID
		}

		itemURL = strings.TrimSpace(itemURL)
		if itemURL == "" || (!strings.HasPrefix(itemURL, "http://") && !strings.HasPrefix(itemURL, "https://")) {
			continue
		}

		// Deduplicate canonical item URLs within feed
		if seenURLs[itemURL] {
			continue
		}

		// Validate URL against data URL allowlist
		if validator != nil {
			if _, err := validator.ValidateDataURL(itemURL); err != nil {
				// Reject unallowed URLs from malicious or unexpected feeds
				continue
			}
		}

		seenURLs[itemURL] = true

		guid := entry.ID
		title := entry.Title
		pubTime := entry.Updated
		if pubTime == "" {
			pubTime = entry.Published
		}

		item := client.JmaIndexItem{
			ItemURL: itemURL,
			FeedURL: feedURL,
		}
		if guid != "" {
			item.GUID = &guid
		}
		if title != "" {
			item.Title = &title
		}
		if pubTime != "" {
			// Validate timestamp conservatively
			if err := parseAndValidateTimestamp(pubTime); err == nil {
				item.Published = &pubTime
			}
		}

		items = append(items, item)
	}

	return items, nil
}
