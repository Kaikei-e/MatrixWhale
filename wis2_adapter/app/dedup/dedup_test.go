package dedup

import (
	"sync"
	"testing"
	"time"
)

func TestDedupNotificationIDAndDataID(t *testing.T) {
	currTime := time.Date(2026, 9, 25, 12, 0, 0, 0, time.UTC)
	var mu sync.Mutex
	nowFunc := func() time.Time {
		mu.Lock()
		defer mu.Unlock()
		return currTime
	}

	cache := NewWithTTL(1*time.Hour, 24*time.Hour, nowFunc)

	// 1. Initial insert
	if cache.CheckOrAdd("notif-1", "data-1") {
		t.Errorf("expected first insert to be non-duplicate")
	}

	// 2. Same notification ID
	if !cache.CheckOrAdd("notif-1", "data-2") {
		t.Errorf("expected duplicate for same notification ID")
	}

	// 3. Same data ID
	if !cache.CheckOrAdd("notif-2", "data-1") {
		t.Errorf("expected duplicate for same data ID")
	}

	// 4. Advance time by 2 hours (notification TTL 1h expired, but dataID 24h still active)
	mu.Lock()
	currTime = currTime.Add(2 * time.Hour)
	mu.Unlock()

	// "notif-1" has expired, but if paired with new data ID "data-3", notif-1 should not match
	if cache.CheckOrAdd("notif-1", "data-3") {
		t.Errorf("expected notif-1 to have expired after 2h")
	}

	// "data-1" has not expired after 2h (24h TTL)
	if !cache.CheckOrAdd("notif-99", "data-1") {
		t.Errorf("expected data-1 to still be duplicate after 2h")
	}

	// 5. Advance time by 25 hours total
	mu.Lock()
	currTime = currTime.Add(23 * time.Hour)
	mu.Unlock()

	// "data-1" has expired now
	if cache.CheckOrAdd("notif-100", "data-1") {
		t.Errorf("expected data-1 to have expired after 25h")
	}
}

func TestDedupConcurrency(t *testing.T) {
	cache := New()
	var wg sync.WaitGroup
	for i := 0; i < 50; i++ {
		wg.Add(1)
		go func(id int) {
			defer wg.Done()
			cache.CheckOrAdd("notif", "data")
		}(i)
	}
	wg.Wait()
}
