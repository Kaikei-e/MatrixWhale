package adapter

import (
	"math/rand"
	"net/http"
	"strconv"
	"strings"
	"time"
)

func ComputeNextPollDelay(h http.Header, minDelay time.Duration) time.Duration {
	delay := minDelay
	if expires := h.Get("Expires"); expires != "" {
		if t, err := http.ParseTime(expires); err == nil {
			if d := time.Until(t); d > delay {
				delay = d
			}
		}
	}
	if maxAge, ok := parseMaxAge(h.Get("Cache-Control")); ok {
		if d := time.Duration(maxAge) * time.Second; d > delay {
			delay = d
		}
	}
	return delay
}

func parseMaxAge(cacheControl string) (int, bool) {
	for directive := range strings.SplitSeq(cacheControl, ",") {
		directive = strings.TrimSpace(directive)
		value, found := strings.CutPrefix(directive, "max-age=")
		if !found {
			continue
		}
		n, err := strconv.Atoi(value)
		if err != nil || n < 0 {
			return 0, false
		}
		return n, true
	}
	return 0, false
}

func ParseRetryAfter(h http.Header) (time.Duration, bool) {
	v := h.Get("Retry-After")
	if v == "" {
		return 0, false
	}
	if seconds, err := strconv.Atoi(v); err == nil {
		if seconds < 0 {
			seconds = 0
		}
		return time.Duration(seconds) * time.Second, true
	}
	if t, err := http.ParseTime(v); err == nil {
		if d := time.Until(t); d > 0 {
			return d, true
		}
		return 0, true
	}
	return 0, false
}

func ComputeBackoff(h http.Header, previous, floor, ceiling time.Duration) time.Duration {
	if delay, ok := ParseRetryAfter(h); ok {
		// Retry-After is an explicit server instruction. Never retry sooner
		// merely because the local exponential-backoff ceiling is smaller.
		if delay < floor {
			return floor
		}
		return delay
	}
	if previous < floor {
		return floor
	}
	return clamp(previous*2, floor, ceiling)
}

func clamp(value, floor, ceiling time.Duration) time.Duration {
	if value < floor {
		return floor
	}
	if value > ceiling {
		return ceiling
	}
	return value
}

func Jitter(delay, maximum time.Duration, rng *rand.Rand) time.Duration {
	if maximum <= 0 {
		return delay
	}
	return delay + time.Duration(rng.Int63n(int64(maximum)))
}
