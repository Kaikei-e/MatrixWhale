package adapter

import (
	"net/http"
	"strconv"
	"strings"
	"time"
)

// ComputeNextPollDelay derives how long to wait before the next NOAA poll
// from cache freshness hints on the previous response, never going below minDelay.
func ComputeNextPollDelay(h http.Header, minDelay time.Duration) time.Duration {
	if expires := h.Get("Expires"); expires != "" {
		if t, err := http.ParseTime(expires); err == nil {
			if d := time.Until(t); d > minDelay {
				return d
			}
		}
	}

	if maxAge, ok := parseMaxAge(h.Get("Cache-Control")); ok {
		if d := time.Duration(maxAge) * time.Second; d > minDelay {
			return d
		}
	}

	return minDelay
}

func parseMaxAge(cacheControl string) (int, bool) {
	for _, directive := range strings.Split(cacheControl, ",") {
		directive = strings.TrimSpace(directive)
		value, found := strings.CutPrefix(directive, "max-age=")
		if !found {
			continue
		}
		n, err := strconv.Atoi(value)
		if err != nil {
			return 0, false
		}
		return n, true
	}
	return 0, false
}
