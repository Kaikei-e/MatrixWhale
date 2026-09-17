package poll

import (
	"math/rand"
	"net/http"
	"testing"
	"time"
)

func TestComputeNextPollDelay(t *testing.T) {
	const floor = 30 * time.Second

	tests := []struct {
		name   string
		header http.Header
		want   time.Duration
		delta  time.Duration
	}{
		{
			name:   "no headers returns floor",
			header: http.Header{},
			want:   floor,
		},
		{
			name:   "expires 45s ahead is honored",
			header: http.Header{"Expires": []string{time.Now().UTC().Add(45 * time.Second).Format(http.TimeFormat)}},
			want:   45 * time.Second,
			delta:  2 * time.Second,
		},
		{
			name:   "expires in the past falls back to floor",
			header: http.Header{"Expires": []string{time.Now().UTC().Add(-45 * time.Second).Format(http.TimeFormat)}},
			want:   floor,
		},
		{
			name:   "cache-control max-age is honored",
			header: http.Header{"Cache-Control": []string{"public, max-age=60"}},
			want:   60 * time.Second,
		},
		{
			name:   "cache-control max-age smaller than floor falls back to floor",
			header: http.Header{"Cache-Control": []string{"public, max-age=5"}},
			want:   floor,
		},
		{
			name: "malformed expires falls back to valid max-age",
			header: http.Header{
				"Expires":       []string{"not-a-date"},
				"Cache-Control": []string{"max-age=90"},
			},
			want: 90 * time.Second,
		},
		{
			name: "malformed expires and cache-control fall back to floor",
			header: http.Header{
				"Expires":       []string{"not-a-date"},
				"Cache-Control": []string{"max-age=not-a-number"},
			},
			want: floor,
		},
		{
			name: "expires and cache-control are combined conservatively",
			header: http.Header{
				"Expires":       []string{time.Now().UTC().Add(120 * time.Second).Format(http.TimeFormat)},
				"Cache-Control": []string{"public, max-age=300"},
			},
			want:  300 * time.Second,
			delta: 2 * time.Second,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := ComputeNextPollDelay(tt.header, floor)

			delta := tt.delta
			if delta == 0 {
				delta = 500 * time.Millisecond
			}

			diff := got - tt.want
			if diff < 0 {
				diff = -diff
			}
			if diff > delta {
				t.Errorf("ComputeNextPollDelay() = %v, want %v (+/- %v)", got, tt.want, delta)
			}
		})
	}
}

func TestParseRetryAfter(t *testing.T) {
	tests := []struct {
		name   string
		header http.Header
		want   time.Duration
		wantOk bool
	}{
		{
			name:   "no header",
			header: http.Header{},
			wantOk: false,
		},
		{
			name:   "seconds form",
			header: http.Header{"Retry-After": []string{"120"}},
			want:   120 * time.Second,
			wantOk: true,
		},
		{
			name:   "http-date form",
			header: http.Header{"Retry-After": []string{time.Now().UTC().Add(90 * time.Second).Format(http.TimeFormat)}},
			want:   90 * time.Second,
			wantOk: true,
		},
		{
			name:   "http-date in the past clamps to zero",
			header: http.Header{"Retry-After": []string{time.Now().UTC().Add(-90 * time.Second).Format(http.TimeFormat)}},
			want:   0,
			wantOk: true,
		},
		{
			name:   "malformed value",
			header: http.Header{"Retry-After": []string{"not-a-value"}},
			wantOk: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, ok := ParseRetryAfter(tt.header)
			if ok != tt.wantOk {
				t.Fatalf("ParseRetryAfter() ok = %v, want %v", ok, tt.wantOk)
			}
			if !ok {
				return
			}
			delta := got - tt.want
			if delta < 0 {
				delta = -delta
			}
			if delta > 2*time.Second {
				t.Errorf("ParseRetryAfter() = %v, want %v (+/- 2s)", got, tt.want)
			}
		})
	}
}

func TestComputeBackoff(t *testing.T) {
	const floor = 30 * time.Second
	const ceiling = 10 * time.Minute

	tests := []struct {
		name      string
		header    http.Header
		prevDelay time.Duration
		want      time.Duration
	}{
		{
			name:      "first failure starts at floor",
			header:    http.Header{},
			prevDelay: 0,
			want:      floor,
		},
		{
			name:      "grows by doubling",
			header:    http.Header{},
			prevDelay: floor,
			want:      60 * time.Second,
		},
		{
			name:      "keeps doubling",
			header:    http.Header{},
			prevDelay: 4 * time.Minute,
			want:      8 * time.Minute,
		},
		{
			name:      "capped at ceiling",
			header:    http.Header{},
			prevDelay: 8 * time.Minute,
			want:      ceiling,
		},
		{
			name:      "retry-after seconds overrides doubling",
			header:    http.Header{"Retry-After": []string{"45"}},
			prevDelay: 4 * time.Minute,
			want:      45 * time.Second,
		},
		{
			name:      "retry-after below floor is clamped up",
			header:    http.Header{"Retry-After": []string{"1"}},
			prevDelay: 0,
			want:      floor,
		},
		{
			name:      "retry-after above ceiling is honored, not clamped down",
			header:    http.Header{"Retry-After": []string{"3600"}},
			prevDelay: 0,
			want:      time.Hour,
		},
		{
			name:      "expired retry-after http-date falls back to floor",
			header:    http.Header{"Retry-After": []string{time.Now().UTC().Add(-90 * time.Second).Format(http.TimeFormat)}},
			prevDelay: 0,
			want:      floor,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := ComputeBackoff(tt.header, tt.prevDelay, floor, ceiling)
			if got != tt.want {
				t.Errorf("ComputeBackoff() = %v, want %v", got, tt.want)
			}
		})
	}
}

func TestJitter(t *testing.T) {
	r := rand.New(rand.NewSource(1))
	const base = 30 * time.Second
	const maxJitter = 5 * time.Second

	for range 100 {
		got := Jitter(base, maxJitter, r)
		if got < base || got >= base+maxJitter {
			t.Fatalf("Jitter() = %v, want in [%v, %v)", got, base, base+maxJitter)
		}
	}

	if got := Jitter(base, 0, r); got != base {
		t.Errorf("Jitter() with zero maxJitter = %v, want %v", got, base)
	}
}
