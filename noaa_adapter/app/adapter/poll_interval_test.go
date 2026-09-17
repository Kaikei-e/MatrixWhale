package adapter

import (
	"net/http"
	"testing"
	"time"
)

func TestComputeNextPollDelay(t *testing.T) {
	const minDelay = 30 * time.Second

	tests := []struct {
		name   string
		header http.Header
		want   time.Duration
		delta  time.Duration
	}{
		{
			name:   "no headers returns min delay",
			header: http.Header{},
			want:   minDelay,
		},
		{
			name:   "expires 45s ahead is honored",
			header: http.Header{"Expires": []string{time.Now().UTC().Add(45 * time.Second).Format(http.TimeFormat)}},
			want:   45 * time.Second,
			delta:  2 * time.Second,
		},
		{
			name:   "expires in the past falls back to min delay",
			header: http.Header{"Expires": []string{time.Now().UTC().Add(-45 * time.Second).Format(http.TimeFormat)}},
			want:   minDelay,
		},
		{
			name:   "cache-control max-age is honored",
			header: http.Header{"Cache-Control": []string{"public, max-age=60"}},
			want:   60 * time.Second,
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
			name: "malformed expires and cache-control fall back to min delay",
			header: http.Header{
				"Expires":       []string{"not-a-date"},
				"Cache-Control": []string{"max-age=not-a-number"},
			},
			want: minDelay,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := ComputeNextPollDelay(tt.header, minDelay)

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
