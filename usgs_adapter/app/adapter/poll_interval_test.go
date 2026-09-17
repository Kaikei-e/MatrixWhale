package adapter

import (
	"math/rand"
	"net/http"
	"testing"
	"time"
)

func TestPollScheduling(t *testing.T) {
	min := 60 * time.Second
	if got := ComputeNextPollDelay(http.Header{"Cache-Control": []string{"public, max-age=60"}}, min); got != min {
		t.Fatalf("cache delay = %v, want %v", got, min)
	}
	if got := ComputeNextPollDelay(http.Header{
		"Expires":       []string{time.Now().Add(120 * time.Second).UTC().Format(http.TimeFormat)},
		"Cache-Control": []string{"public, max-age=300"},
	}, min); got < 299*time.Second {
		t.Fatalf("cache hints were not combined conservatively: %v", got)
	}
	if got := ComputeBackoff(http.Header{"Retry-After": []string{"3600"}}, 0, min, 10*time.Minute); got != time.Hour {
		t.Fatalf("Retry-After was clamped: %v", got)
	}
	if got := ComputeBackoff(http.Header{}, min, min, 10*time.Minute); got != 2*min {
		t.Fatalf("exponential delay = %v", got)
	}
	rng := rand.New(rand.NewSource(1))
	for range 20 {
		got := Jitter(min, 5*time.Second, rng)
		if got < min || got >= min+5*time.Second {
			t.Fatalf("jitter = %v", got)
		}
	}
}
