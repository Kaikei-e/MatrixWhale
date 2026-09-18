package adapter

import (
	"context"
	"sync"
	"time"
)

// Limiter measures its minimum gap from the end of the previous request, not its start.
type Limiter struct {
	minInterval time.Duration
	mu          sync.Mutex
	lastEnd     time.Time
	hasRun      bool
	now         func() time.Time
	sleep       func(context.Context, time.Duration) error
}

func NewLimiter(minInterval time.Duration) *Limiter {
	return newLimiterWithClock(minInterval, time.Now, sleepCtx)
}

func newLimiterWithClock(minInterval time.Duration, now func() time.Time, sleep func(context.Context, time.Duration) error) *Limiter {
	return &Limiter{minInterval: minInterval, now: now, sleep: sleep}
}

func (l *Limiter) Wait(ctx context.Context) error {
	l.mu.Lock()
	var wait time.Duration
	if l.hasRun {
		wait = l.minInterval - l.now().Sub(l.lastEnd)
	}
	l.mu.Unlock()

	if wait <= 0 {
		return ctx.Err()
	}
	return l.sleep(ctx, wait)
}

func (l *Limiter) Done() {
	l.mu.Lock()
	l.lastEnd = l.now()
	l.hasRun = true
	l.mu.Unlock()
}

func sleepCtx(ctx context.Context, d time.Duration) error {
	timer := time.NewTimer(d)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}
