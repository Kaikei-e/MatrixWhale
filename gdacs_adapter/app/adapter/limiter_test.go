package adapter

import (
	"context"
	"testing"
	"time"
)

type fakeClock struct {
	t time.Time
}

func (f *fakeClock) now() time.Time { return f.t }

func (f *fakeClock) sleep(_ context.Context, d time.Duration) error {
	f.t = f.t.Add(d)
	return nil
}

func TestLimiterWaitDoesNotSleepBeforeFirstDone(t *testing.T) {
	clock := &fakeClock{t: time.Unix(0, 0)}
	limiter := newLimiterWithClock(10*time.Second, clock.now, clock.sleep)

	if err := limiter.Wait(context.Background()); err != nil {
		t.Fatalf("Wait: %v", err)
	}
	if clock.t != time.Unix(0, 0) {
		t.Fatalf("clock advanced before any request completed: %v", clock.t)
	}
}

func TestLimiterWaitSleepsRemainderOfMinInterval(t *testing.T) {
	clock := &fakeClock{t: time.Unix(0, 0)}
	limiter := newLimiterWithClock(10*time.Second, clock.now, clock.sleep)

	limiter.Done()
	clock.t = clock.t.Add(3 * time.Second)

	if err := limiter.Wait(context.Background()); err != nil {
		t.Fatalf("Wait: %v", err)
	}
	if clock.t != time.Unix(10, 0) {
		t.Fatalf("clock after Wait = %v, want 10s after Done", clock.t)
	}
}

func TestLimiterWaitSkipsSleepWhenIntervalAlreadyElapsed(t *testing.T) {
	clock := &fakeClock{t: time.Unix(0, 0)}
	limiter := newLimiterWithClock(10*time.Second, clock.now, clock.sleep)

	limiter.Done()
	clock.t = clock.t.Add(30 * time.Second)

	if err := limiter.Wait(context.Background()); err != nil {
		t.Fatalf("Wait: %v", err)
	}
	if clock.t != time.Unix(30, 0) {
		t.Fatalf("clock after Wait = %v, want unchanged at 30s", clock.t)
	}
}

func TestLimiterWaitReturnsContextError(t *testing.T) {
	limiter := NewLimiter(time.Minute)
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	limiter.Done()
	if err := limiter.Wait(ctx); err == nil {
		t.Fatal("Wait accepted an already-cancelled context")
	}
}
