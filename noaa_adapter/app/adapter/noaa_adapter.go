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

func NoaaAlertsAdapter() (PollResult, error) {
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

	cl := http.Client{Timeout: 60 * time.Second}
	res, err := cl.Do(req)
	if err != nil {
		return PollResult{}, err
	}
	defer res.Body.Close()

	slog.Info("noaa's response", "status", res.Status)

	resBytes, err := io.ReadAll(res.Body)
	if err != nil {
		return PollResult{}, err
	}

	if res.StatusCode < 200 || res.StatusCode >= 300 {
		return PollResult{}, fmt.Errorf("noaa alerts request failed with status %d", res.StatusCode)
	}

	return PollResult{
		Body:       resBytes,
		FetchedAt:  time.Now().UTC(),
		HTTPStatus: res.StatusCode,
		Header:     res.Header,
	}, nil
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
