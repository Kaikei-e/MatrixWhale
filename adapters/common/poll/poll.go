// Package poll computes when an adapter should next contact a source feed,
// combining HTTP caching hints, Retry-After backoff and jitter. It is shared
// by every polling adapter regardless of the feed it polls.
package poll

import (
	"math/rand"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// ComputeNextPollDelay derives how long to wait before the next poll from
// cache freshness hints (Expires, Cache-Control max-age) on the previous
// response, never going below floor.
func ComputeNextPollDelay(h http.Header, floor time.Duration) time.Duration {
	delay := floor
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

// ParseRetryAfter parses a Retry-After header (RFC 9110 S10.2.3), which a
// server sends as either a delay in seconds or an HTTP-date.
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

// ComputeBackoff decides how long to wait before retrying a poll that
// failed (a network error, or a non-2xx/304 status such as 429 or 503).
// A server-supplied Retry-After header is an explicit instruction: it is
// honored even if it exceeds ceiling, and is only ever raised up to floor,
// never lowered. Otherwise the delay doubles from previous, starting at
// floor and clamped to ceiling. Callers should reset previous to 0 after a
// successful poll.
func ComputeBackoff(h http.Header, previous, floor, ceiling time.Duration) time.Duration {
	if delay, ok := ParseRetryAfter(h); ok {
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

// Jitter adds a pseudo-random delay in [0, maximum) to delay, using rng as
// the random source, so that adapter restarts don't all poll in lockstep.
func Jitter(delay, maximum time.Duration, rng *rand.Rand) time.Duration {
	if maximum <= 0 {
		return delay
	}
	return delay + time.Duration(rng.Int63n(int64(maximum)))
}
