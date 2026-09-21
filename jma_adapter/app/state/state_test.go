package state

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestProcessLock(t *testing.T) {
	tmpDir, err := os.MkdirTemp("", "jma-lock-test-*")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(tmpDir)

	lock1, err := AcquireLock(tmpDir)
	if err != nil {
		t.Fatalf("first acquire failed: %v", err)
	}
	defer lock1.Close()

	// Second acquire on the same directory should fail with ErrAlreadyRunning
	_, err = AcquireLock(tmpDir)
	if err != ErrAlreadyRunning {
		t.Fatalf("expected ErrAlreadyRunning, got %v", err)
	}

	// Release lock1
	if err := lock1.Close(); err != nil {
		t.Fatalf("release lock1 failed: %v", err)
	}

	// Third acquire should now succeed
	lock2, err := AcquireLock(tmpDir)
	if err != nil {
		t.Fatalf("re-acquire after release failed: %v", err)
	}
	_ = lock2.Close()
}

func TestByteBudget(t *testing.T) {
	tmpDir, err := os.MkdirTemp("", "jma-budget-test-*")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(tmpDir)

	limit := int64(1000)
	store, err := NewStore(tmpDir, limit)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()

	// Negative amount should fail
	if err := store.Reserve(-10); !errors.Is(err, ErrNegativeAmount) {
		t.Fatalf("expected ErrNegativeAmount for -10, got %v", err)
	}

	// Reserve 600
	if err := store.Reserve(600); err != nil {
		t.Fatalf("reserve 600 failed: %v", err)
	}
	if store.GetBytesUsed() != 600 {
		t.Fatalf("expected 600 used, got %d", store.GetBytesUsed())
	}

	// Commit actual 500 (refund 100)
	if err := store.Commit(600, 500); err != nil {
		t.Fatalf("commit failed: %v", err)
	}
	if store.GetBytesUsed() != 500 {
		t.Fatalf("expected 500 used after commit, got %d", store.GetBytesUsed())
	}

	// Attempting to reserve 600 should exceed limit 1000 (500 + 600 = 1100 > 1000)
	if err := store.Reserve(600); !errors.Is(err, ErrDailyByteLimitExceeded) {
		t.Fatalf("expected ErrDailyByteLimitExceeded, got %v", err)
	}

	// Restart store from disk and check persistence
	store.Close()
	store2, err := NewStore(tmpDir, limit)
	if err != nil {
		t.Fatal(err)
	}
	defer store2.Close()

	if store2.GetBytesUsed() != 500 {
		t.Fatalf("expected persisted 500 bytes used after restart, got %d", store2.GetBytesUsed())
	}
}

func TestCorruptedStateFailsClosed(t *testing.T) {
	tmpDir, err := os.MkdirTemp("", "jma-corrupt-test-*")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(tmpDir)

	// Write invalid json to byte_budget.json
	budgetPath := filepath.Join(tmpDir, "byte_budget.json")
	if err := os.WriteFile(budgetPath, []byte("NOT_VALID_JSON{{{"), 0644); err != nil {
		t.Fatal(err)
	}

	// NewStore MUST fail closed on corrupted budget!
	_, err = NewStore(tmpDir, 1000)
	if err == nil || !errors.Is(err, ErrCorruptedState) {
		t.Fatalf("expected ErrCorruptedState for corrupted budget, got %v", err)
	}
}

func TestFetchedHistory(t *testing.T) {
	tmpDir, err := os.MkdirTemp("", "jma-history-test-*")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(tmpDir)

	store, err := NewStore(tmpDir, 10000)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()

	url1 := "https://www.data.jma.go.jp/developer/xml/data/20260921012500_0_VXSE53_010000.xml"
	url2 := "https://www.data.jma.go.jp/developer/xml/data/20260921020000_0_VPWW53_130000.xml"

	if store.IsFetched(url1) {
		t.Fatalf("expected not fetched")
	}

	if err := store.MarkFetched(url1); err != nil {
		t.Fatalf("mark fetched failed: %v", err)
	}
	if !store.IsFetched(url1) {
		t.Fatalf("expected fetched after mark")
	}
	if store.IsFetched(url2) {
		t.Fatalf("expected url2 not fetched")
	}

	// Restart store
	store.Close()
	store2, err := NewStore(tmpDir, 10000)
	if err != nil {
		t.Fatal(err)
	}
	defer store2.Close()

	if !store2.IsFetched(url1) {
		t.Fatalf("expected url1 fetched after restart")
	}
	if store2.IsFetched(url2) {
		t.Fatalf("expected url2 not fetched after restart")
	}
}

func TestFeedScheduleAndValidators(t *testing.T) {
	tmpDir, err := os.MkdirTemp("", "jma-sched-test-*")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(tmpDir)

	store, err := NewStore(tmpDir, 10000)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()

	feedURL := "https://www.data.jma.go.jp/developer/xml/feed/eqvol.xml"
	attemptTime := time.Now().Truncate(time.Second)
	nextAllowed := attemptTime.Add(5 * time.Minute)

	// Record attempt and backoff schedule
	if err := store.RecordFeedAttempt(feedURL, attemptTime, nextAllowed); err != nil {
		t.Fatal(err)
	}

	// Save validator
	if err := store.SaveFeedValidator(feedURL, "Mon, 21 Sep 2026 01:00:00 GMT", `"etag-123"`, attemptTime); err != nil {
		t.Fatal(err)
	}

	// Restart store
	store.Close()
	store2, err := NewStore(tmpDir, 10000)
	if err != nil {
		t.Fatal(err)
	}
	defer store2.Close()

	sch := store2.GetFeedSchedule(feedURL)
	if !sch.LastAttemptAt.Equal(attemptTime) || !sch.NextAllowedAt.Equal(nextAllowed) {
		t.Fatalf("schedule mismatch after restart: got attempt=%v, next=%v", sch.LastAttemptAt, sch.NextAllowedAt)
	}
	if sch.LastModified != "Mon, 21 Sep 2026 01:00:00 GMT" || sch.ETag != `"etag-123"` {
		t.Fatalf("validator mismatch: got %s, %s", sch.LastModified, sch.ETag)
	}
}

func TestDurableSpool(t *testing.T) {
	tmpDir, err := os.MkdirTemp("", "jma-spool-test-*")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(tmpDir)

	store, err := NewStore(tmpDir, 10000)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()

	rawXML := "<Report>...</Report>"
	item := SpoolItem{
		ID:         "test_item_1",
		ItemURL:    "https://www.data.jma.go.jp/developer/xml/data/20260921012500_0_VXSE53_010000.xml",
		FeedURL:    "https://www.data.jma.go.jp/developer/xml/feed/eqvol.xml",
		FetchedAt:  "2026-09-21T01:25:00Z",
		HTTPStatus: 200,
		RawXML:     &rawXML,
		Message:    json.RawMessage(`{"identifier":"20260921012500_0_VXSE53_010000"}`),
	}

	if err := store.SaveSpool(item); err != nil {
		t.Fatalf("save spool failed: %v", err)
	}

	items, err := store.ListSpool()
	if err != nil {
		t.Fatalf("list spool failed: %v", err)
	}
	if len(items) != 1 {
		t.Fatalf("expected 1 item, got %d", len(items))
	}

	// Delete spool
	if err := store.DeleteSpool(item.ItemURL); err != nil {
		t.Fatalf("delete spool failed: %v", err)
	}

	items2, err := store.ListSpool()
	if err != nil {
		t.Fatalf("list spool after delete failed: %v", err)
	}
	if len(items2) != 0 {
		t.Fatalf("expected 0 items after delete, got %d", len(items2))
	}
}
