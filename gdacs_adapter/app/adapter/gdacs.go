package adapter

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"

	"matrixwhale/adapters/common/useragent"
)

const (
	DefaultAPIURL = "https://www.gdacs.org/gdacsapi/api"

	// latest filters on datemodified.
	eventListLatestEndpoint = "events/geteventlist/latest"
	eventListSearchEndpoint = "events/geteventlist/search"
	geometryEndpoint        = "polygons/getgeometry"

	// TS is queried alone via search because combining it into the eventlist collapses the results.
	EventTypesPrimary = "EQ;TC;FL;VO;WF;DR"
	EventTypesTsunami = "TS"

	alertLevels = "green;orange;red"
	callerName  = "matrixwhale"

	pageSize     = 100
	maxBodyBytes = 16 << 20

	dateModifiedLayout = "2006-01-02T15:04:05"
	dateLayout         = "2006-01-02"
)

type EventListQuery struct {
	EventList string
	endpoint  string
	dateQuery func(since, until time.Time) string
}

var PrimaryEventListQuery = EventListQuery{
	EventList: EventTypesPrimary,
	endpoint:  eventListLatestEndpoint,
	dateQuery: func(since, _ time.Time) string {
		return "datemodified=" + since.UTC().Format(dateModifiedLayout)
	},
}

var TsunamiEventListQuery = EventListQuery{
	EventList: EventTypesTsunami,
	endpoint:  eventListSearchEndpoint,
	dateQuery: func(since, until time.Time) string {
		return "fromDate=" + since.UTC().Format(dateLayout) + "&toDate=" + until.UTC().Format(dateLayout)
	},
}

type EventPage struct {
	Features   []json.RawMessage
	Done       bool
	HTTPStatus int
	Header     http.Header
	URL        string
	Bytes      int
}

type featureCollection struct {
	Type     string            `json:"type"`
	Features []json.RawMessage `json:"features"`
}

func FetchEventPage(ctx context.Context, client *http.Client, baseURL string, query EventListQuery, since, until time.Time, pageNumber int) (EventPage, error) {
	target := buildEventListURL(baseURL, query, since, until, pageNumber)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, target, nil)
	if err != nil {
		return EventPage{}, fmt.Errorf("build GDACS event list request: %w", err)
	}
	req.Header.Set("User-Agent", userAgent())
	req.Header.Set("Accept", "application/json")

	res, err := client.Do(req)
	if err != nil {
		return EventPage{}, err
	}
	defer res.Body.Close()

	page := EventPage{HTTPStatus: res.StatusCode, Header: res.Header.Clone(), URL: target}
	if res.StatusCode == http.StatusNoContent {
		page.Done = true
		return page, nil
	}

	body, readErr := readLimited(res.Body, maxBodyBytes)
	page.Bytes = len(body)
	if readErr != nil {
		return page, readErr
	}
	if res.StatusCode < http.StatusOK || res.StatusCode >= http.StatusMultipleChoices {
		return page, fmt.Errorf("GDACS event list request failed with status %d", res.StatusCode)
	}

	var collection featureCollection
	if err := json.Unmarshal(body, &collection); err != nil {
		return page, fmt.Errorf("invalid GDACS event list response: %w", err)
	}
	if collection.Type != "FeatureCollection" {
		return page, fmt.Errorf("GDACS event list top-level type is %q", collection.Type)
	}
	if collection.Features == nil {
		return page, fmt.Errorf("GDACS event list features is missing or null")
	}

	page.Features = collection.Features
	page.Done = len(collection.Features) < pageSize
	return page, nil
}

func FetchGeometry(ctx context.Context, client *http.Client, baseURL, eventtype string, eventid, episodeid int64) (json.RawMessage, int, error) {
	target := buildGeometryURL(baseURL, eventtype, eventid, episodeid)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, target, nil)
	if err != nil {
		return nil, 0, fmt.Errorf("build GDACS geometry request: %w", err)
	}
	req.Header.Set("User-Agent", userAgent())
	req.Header.Set("Accept", "application/json")

	res, err := client.Do(req)
	if err != nil {
		return nil, 0, err
	}
	defer res.Body.Close()

	if res.StatusCode == http.StatusNoContent {
		return nil, res.StatusCode, nil
	}

	body, readErr := readLimited(res.Body, maxBodyBytes)
	if readErr != nil {
		return nil, res.StatusCode, readErr
	}
	if res.StatusCode < http.StatusOK || res.StatusCode >= http.StatusMultipleChoices {
		return nil, res.StatusCode, fmt.Errorf("GDACS geometry request failed with status %d", res.StatusCode)
	}

	var collection struct {
		Type string `json:"type"`
	}
	if err := json.Unmarshal(body, &collection); err != nil {
		return nil, res.StatusCode, fmt.Errorf("invalid GDACS geometry response: %w", err)
	}
	if collection.Type != "FeatureCollection" {
		return nil, res.StatusCode, fmt.Errorf("GDACS geometry top-level type is %q", collection.Type)
	}

	return json.RawMessage(body), res.StatusCode, nil
}

// built by hand: Go's net/url no longer treats ';' as a query separator, so url.Values can't produce this string.
func buildEventListURL(baseURL string, query EventListQuery, since, until time.Time, pageNumber int) string {
	q := fmt.Sprintf(
		"eventlist=%s&alertlevel=%s&%s&pageSize=%d&pageNumber=%d&caller=%s",
		query.EventList, alertLevels, query.dateQuery(since, until),
		pageSize, pageNumber, callerName,
	)
	return strings.TrimRight(baseURL, "/") + "/" + query.endpoint + "?" + q
}

func buildGeometryURL(baseURL, eventtype string, eventid, episodeid int64) string {
	query := fmt.Sprintf(
		"eventtype=%s&eventid=%s&episodeid=%s",
		eventtype, strconv.FormatInt(eventid, 10), strconv.FormatInt(episodeid, 10),
	)
	return strings.TrimRight(baseURL, "/") + "/" + geometryEndpoint + "?" + query
}

func readLimited(r io.Reader, limit int64) ([]byte, error) {
	body, err := io.ReadAll(io.LimitReader(r, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(body)) > limit {
		return nil, fmt.Errorf("response body exceeds %d bytes", limit)
	}
	return body, nil
}

func userAgent() string {
	return useragent.Build("gdacs_adapter", "GDACS_CONTACT_EMAIL", "", nil)
}
