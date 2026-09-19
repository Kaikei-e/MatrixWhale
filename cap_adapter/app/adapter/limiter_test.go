package adapter

import (
	"context"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestLimiterSpacingSameHost(t *testing.T) {
	minInterval := 50 * time.Millisecond
	limiter := NewHostLimiter(minInterval, 4)
	ctx := context.Background()
	host := "host-a.example.com"

	// First request: no prior request, proceeds immediately.
	start1 := time.Now()
	if err := limiter.Wait(ctx, host); err != nil {
		t.Fatalf("first wait failed: %v", err)
	}
	time.Sleep(10 * time.Millisecond)
	limiter.Done(host)
	end1 := time.Now()

	// Second request: must wait at least minInterval after end1.
	if err := limiter.Wait(ctx, host); err != nil {
		t.Fatalf("second wait failed: %v", err)
	}
	start2 := time.Now()
	limiter.Done(host)

	elapsed := start2.Sub(end1)
	if elapsed < minInterval-5*time.Millisecond {
		t.Fatalf("expected delay >= %v, got %v (start1: %v, end1: %v, start2: %v)", minInterval, elapsed, start1, end1, start2)
	}
}

func TestLimiterCrossHostParallelism(t *testing.T) {
	minInterval := 200 * time.Millisecond
	limiter := NewHostLimiter(minInterval, 5)
	ctx := context.Background()

	var wg sync.WaitGroup
	var concurrentInFlight int32
	var maxObserved int32

	numHosts := 3
	for i := 0; i < numHosts; i++ {
		wg.Add(1)
		host := "host-" + string(rune('a'+i)) + ".example.com"
		go func(h string) {
			defer wg.Done()
			if err := limiter.Wait(ctx, h); err != nil {
				t.Errorf("wait failed for %s: %v", h, err)
				return
			}
			cur := atomic.AddInt32(&concurrentInFlight, 1)
			for {
				old := atomic.LoadInt32(&maxObserved)
				if cur <= old || atomic.CompareAndSwapInt32(&maxObserved, old, cur) {
					break
				}
			}
			time.Sleep(30 * time.Millisecond)
			atomic.AddInt32(&concurrentInFlight, -1)
			limiter.Done(h)
		}(host)
	}

	wg.Wait()
	if maxObserved < 2 {
		t.Fatalf("expected concurrent in-flight hosts >= 2, got %d", maxObserved)
	}
}

func TestLimiterMaxParallelHostsCap(t *testing.T) {
	maxParallel := 2
	limiter := NewHostLimiter(10*time.Millisecond, maxParallel)
	ctx := context.Background()

	var concurrentInFlight int32
	var maxObserved int32
	var wg sync.WaitGroup

	numHosts := 5
	for i := 0; i < numHosts; i++ {
		wg.Add(1)
		host := "host-" + string(rune('a'+i)) + ".example.com"
		go func(h string) {
			defer wg.Done()
			if err := limiter.Wait(ctx, h); err != nil {
				t.Errorf("wait failed for %s: %v", h, err)
				return
			}
			cur := atomic.AddInt32(&concurrentInFlight, 1)
			for {
				old := atomic.LoadInt32(&maxObserved)
				if cur <= old || atomic.CompareAndSwapInt32(&maxObserved, old, cur) {
					break
				}
			}
			time.Sleep(40 * time.Millisecond)
			atomic.AddInt32(&concurrentInFlight, -1)
			limiter.Done(h)
		}(host)
	}

	wg.Wait()
	if maxObserved > int32(maxParallel) {
		t.Fatalf("expected max parallel hosts <= %d, got %d", maxParallel, maxObserved)
	}
}

func TestLimiterContextCancellation(t *testing.T) {
	limiter := NewHostLimiter(500*time.Millisecond, 1)
	ctx, cancel := context.WithCancel(context.Background())
	host := "host-c.example.com"

	// First request succeeds and completes.
	if err := limiter.Wait(ctx, host); err != nil {
		t.Fatalf("wait 1 failed: %v", err)
	}
	limiter.Done(host)

	// Cancel context during the spacing delay.
	cancel()
	err := limiter.Wait(ctx, host)
	if err != context.Canceled {
		t.Fatalf("expected context.Canceled, got %v", err)
	}
}
