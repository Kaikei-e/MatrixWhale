package adapter

import (
	"math/rand"
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
	for directive := range strings.SplitSeq(cacheControl, ",") {
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

// ParseRetryAfter parses a Retry-After header (RFC 9110 §10.2.3), which a
// server sends as either a delay in seconds or an HTTP-date.
func ParseRetryAfter(h http.Header) (time.Duration, bool) {
	v := h.Get("Retry-After")
	if v == "" {
		return 0, false
	}

	if secs, err := strconv.Atoi(v); err == nil {
		if secs < 0 {
			secs = 0
		}
		return time.Duration(secs) * time.Second, true
	}

	if t, err := http.ParseTime(v); err == nil {
		if d := time.Until(t); d > 0 {
			return d, true
		}
		return 0, true
	}

	return 0, false
}

// ComputeBackoff decides how long to wait before retrying a poll that
// failed (a network error, or a non-2xx/304 status such as 429 or 503). It
// honours a server-supplied Retry-After header when present, clamped to
// [floor, ceiling]; otherwise it doubles prevDelay, starting at floor.
// Callers should reset prevDelay to 0 after a successful poll.
func ComputeBackoff(h http.Header, prevDelay, floor, ceiling time.Duration) time.Duration {
	if d, ok := ParseRetryAfter(h); ok {
		return clamp(d, floor, ceiling)
	}
	if prevDelay < floor {
		return floor
	}
	return clamp(prevDelay*2, floor, ceiling)
}

func clamp(d, floor, ceiling time.Duration) time.Duration {
	if d < floor {
		return floor
	}
	if d > ceiling {
		return ceiling
	}
	return d
}

// Jitter adds a pseudo-random delay in [0, maxJitter) to d, using r as the
// random source, so that adapter restarts don't all poll in lockstep.
func Jitter(d, maxJitter time.Duration, r *rand.Rand) time.Duration {
	if maxJitter <= 0 {
		return d
	}
	return d + time.Duration(r.Int63n(int64(maxJitter)))
}
