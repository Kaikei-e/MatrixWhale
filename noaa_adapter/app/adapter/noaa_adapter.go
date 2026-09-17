package adapter

import (
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"os"
	"sync"
	"time"
)

const NoaaURL = "https://api.weather.gov"

type PollResult struct {
	Body       []byte
	FetchedAt  time.Time
	HTTPStatus int
	Header     http.Header
}

var warnMissingContactOnce sync.Once

// NoaaAlertsAdapter fetches /alerts/active. prevETag/prevLastModified, when
// non-empty, are sent as conditional-request headers (If-None-Match /
// If-Modified-Since) so an unchanged feed costs a 304 with no body instead
// of a full re-fetch. The returned PollResult always carries the response
// Header and HTTPStatus, even on a non-2xx/304 result, so the caller can
// read rate-limit hints (e.g. Retry-After) regardless of error.
func NoaaAlertsAdapter(prevETag, prevLastModified string) (PollResult, error) {
	targetURL, err := url.JoinPath(NoaaURL, "alerts", "active")
	if err != nil {
		return PollResult{}, err
	}

	req, err := http.NewRequest("GET", targetURL, nil)
	if err != nil {
		return PollResult{}, err
	}

	req.Header.Set("User-Agent", userAgent())
	req.Header.Set("Accept", "application/geo+json")
	if prevETag != "" {
		req.Header.Set("If-None-Match", prevETag)
	}
	if prevLastModified != "" {
		req.Header.Set("If-Modified-Since", prevLastModified)
	}

	cl := http.Client{Timeout: 60 * time.Second}
	res, err := cl.Do(req)
	if err != nil {
		return PollResult{}, err
	}
	defer res.Body.Close()

	slog.Info("noaa's response", "status", res.Status)

	resBytes, err := io.ReadAll(res.Body)
	if err != nil {
		return PollResult{HTTPStatus: res.StatusCode, Header: res.Header}, err
	}

	result := PollResult{
		FetchedAt:  time.Now().UTC(),
		HTTPStatus: res.StatusCode,
		Header:     res.Header,
	}

	switch {
	case res.StatusCode == http.StatusNotModified:
		return result, nil
	case res.StatusCode >= 200 && res.StatusCode < 300:
		result.Body = resBytes
		return result, nil
	default:
		return result, fmt.Errorf("noaa alerts request failed with status %d", res.StatusCode)
	}
}

func userAgent() string {
	contact := os.Getenv("NOAA_CONTACT_EMAIL")
	if contact == "" {
		warnMissingContactOnce.Do(func() {
			slog.Warn("NOAA_CONTACT_EMAIL is not set; falling back to placeholder contact in User-Agent")
		})
		contact = "contact-email-not-configured"
	}
	return fmt.Sprintf("MatrixWhale/1.0 (%s)", contact)
}
