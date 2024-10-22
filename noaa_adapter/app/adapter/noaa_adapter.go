package adapter

import (
	"io"
	"log/slog"
	"net/http"
	"net/url"
)

const NoaaURL = "https://api.weather.gov"

func NoaaAlertsAdapter() ([]byte, error) {
	targetURL, err := url.JoinPath(NoaaURL, "alerts")
	if err != nil {
		panic(err)
	}

	req, err := http.NewRequest("GET", targetURL, nil)
	if err != nil {
		panic(err)
	}

	req.Header.Set("User-Agent", "Matrix Whale, A Data Processing Project")
	req.Header.Set("Accept", "application/geo+json")
	cl := http.Client{}
	res, err := cl.Do(req)
	if err != nil {
		panic(err)
	}

	slog.Info("noaa's response", "status", res.Status)

	resBytes, errRead := io.ReadAll(res.Body)
	if errRead != nil {
		return nil, errRead
	}
	defer res.Body.Close()

	return resBytes, nil
}
