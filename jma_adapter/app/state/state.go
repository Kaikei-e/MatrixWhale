package state

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"math"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"
)

var (
	ErrDailyByteLimitExceeded = errors.New("daily byte limit exceeded")
	ErrAlreadyRunning         = errors.New("another instance of JMA adapter is already running (process lock held)")
	ErrCorruptedState         = errors.New("corrupted state file: failing closed")
	ErrNegativeAmount         = errors.New("negative byte count is invalid")
	ErrIntegerOverflow        = errors.New("integer overflow in byte computation")
	ErrStatePersistenceFailed = errors.New("state persistence failed")
)

// ProcessLock holds the file descriptor for the single-instance lock file.
type ProcessLock struct {
	file *os.File
}

func (l *ProcessLock) Close() error {
	if l == nil || l.file == nil {
		return nil
	}
	_ = syscall.Flock(int(l.file.Fd()), syscall.LOCK_UN)
	return l.file.Close()
}

// AcquireLock acquires an exclusive non-blocking file lock on jma.lock in stateDir.
func AcquireLock(stateDir string) (*ProcessLock, error) {
	if err := os.MkdirAll(stateDir, 0755); err != nil {
		return nil, fmt.Errorf("create state directory: %w", err)
	}
	lockPath := filepath.Join(stateDir, "jma.lock")
	f, err := os.OpenFile(lockPath, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, fmt.Errorf("open lock file %s: %w", lockPath, err)
	}

	err = syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
	if err != nil {
		f.Close()
		if errors.Is(err, syscall.EWOULDBLOCK) || errors.Is(err, syscall.EAGAIN) {
			return nil, ErrAlreadyRunning
		}
		return nil, fmt.Errorf("flock on %s: %w", lockPath, err)
	}

	return &ProcessLock{file: f}, nil
}

// ByteBudget tracks consumed bandwidth across 24h UTC days.
type ByteBudget struct {
	Date      string `json:"date"` // YYYY-MM-DD (UTC)
	BytesUsed int64  `json:"bytes_used"`
}

// FeedSchedule tracks caching headers and per-feed attempt/backoff scheduling.
type FeedSchedule struct {
	LastAttemptAt     time.Time `json:"last_attempt_at"`
	NextAllowedAt     time.Time `json:"next_allowed_at"`
	LastModified      string    `json:"last_modified"`
	ETag              string    `json:"etag"`
	LastPolledAt      time.Time `json:"last_polled_at"`
	ConsecutiveErrors int       `json:"consecutive_errors,omitempty"`
}

// FeedState holds validators and scheduling for all feeds and global backoff.
type FeedState struct {
	Feeds              map[string]FeedSchedule `json:"feeds"`
	LastLongPollTime   time.Time               `json:"last_long_poll_time"`
	GlobalBackoffUntil time.Time               `json:"global_backoff_until,omitempty"`
}

// SpoolItem represents an unacknowledged telegram spooled on disk.
type SpoolItem struct {
	ID               string          `json:"id"`
	ItemURL          string          `json:"item_url"`
	FeedURL          string          `json:"feed_url"`
	FetchedAt        string          `json:"fetched_at"`
	HTTPStatus       int             `json:"http_status"`
	RawXML           *string         `json:"raw_xml,omitempty"`
	Error            *string         `json:"error,omitempty"`
	Message          json.RawMessage `json:"message,omitempty"`
	DeliveryAttempts int             `json:"delivery_attempts,omitempty"`
	LastAttemptAt    *time.Time      `json:"last_attempt_at,omitempty"`
}

// Store manages all persistent state files in JMA_STATE_DIR.
type Store struct {
	dir         string
	dailyLimit  int64
	mu          sync.Mutex
	budget      ByteBudget
	feedState   FeedState
	fetchedURLs map[string]bool
	historyFile *os.File
}

// NewStore initializes disk state, failing closed on corrupted data.
func NewStore(dir string, dailyLimit int64) (*Store, error) {
	if dailyLimit <= 0 {
		return nil, fmt.Errorf("%w: daily limit must be positive", ErrNegativeAmount)
	}

	if err := os.MkdirAll(dir, 0755); err != nil {
		return nil, fmt.Errorf("mkdir state dir: %w", err)
	}
	spoolDir := filepath.Join(dir, "spool")
	if err := os.MkdirAll(spoolDir, 0755); err != nil {
		return nil, fmt.Errorf("mkdir spool dir: %w", err)
	}

	s := &Store{
		dir:         dir,
		dailyLimit:  dailyLimit,
		fetchedURLs: make(map[string]bool),
		feedState: FeedState{
			Feeds: make(map[string]FeedSchedule),
		},
	}

	// Load byte budget - fails closed on corruption!
	if err := s.loadByteBudget(); err != nil {
		return nil, err
	}

	// Load feed state - fails closed on corruption!
	if err := s.loadFeedState(); err != nil {
		return nil, err
	}

	// Load fetched URLs history - fails closed on corruption!
	if err := s.loadHistory(); err != nil {
		return nil, err
	}

	return s, nil
}

// Close closes any open file handles.
func (s *Store) Close() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.historyFile != nil {
		return s.historyFile.Close()
	}
	return nil
}

// --- Byte Budget ---

func (s *Store) loadByteBudget() error {
	path := filepath.Join(s.dir, "byte_budget.json")
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		s.budget = ByteBudget{
			Date:      time.Now().UTC().Format("2006-01-02"),
			BytesUsed: 0,
		}
		return s.persistByteBudgetLocked()
	}
	if err != nil {
		return fmt.Errorf("%w: read byte_budget.json: %v", ErrCorruptedState, err)
	}

	var bb ByteBudget
	if err := json.Unmarshal(data, &bb); err != nil {
		return fmt.Errorf("%w: parse byte_budget.json: %v", ErrCorruptedState, err)
	}

	if bb.BytesUsed < 0 {
		return fmt.Errorf("%w: negative bytes_used in byte_budget.json: %d", ErrCorruptedState, bb.BytesUsed)
	}

	// Reset if date has changed (new UTC calendar day)
	today := time.Now().UTC().Format("2006-01-02")
	if bb.Date != today {
		bb.Date = today
		bb.BytesUsed = 0
	}
	s.budget = bb
	return nil
}

func (s *Store) persistByteBudgetLocked() error {
	data, err := json.MarshalIndent(s.budget, "", "  ")
	if err != nil {
		return err
	}
	path := filepath.Join(s.dir, "byte_budget.json")
	return atomicWriteFile(path, data, 0644)
}

// Reserve checks if estimatedBytes can be spent within the daily limit and reserves it.
func (s *Store) Reserve(estimatedBytes int64) error {
	if estimatedBytes < 0 {
		return ErrNegativeAmount
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	today := time.Now().UTC().Format("2006-01-02")
	if s.budget.Date != today {
		s.budget.Date = today
		s.budget.BytesUsed = 0
	}

	if estimatedBytes > math.MaxInt64-s.budget.BytesUsed {
		return ErrIntegerOverflow
	}

	if s.budget.BytesUsed+estimatedBytes > s.dailyLimit {
		return fmt.Errorf("%w: current %d, reserving %d, limit %d",
			ErrDailyByteLimitExceeded, s.budget.BytesUsed, estimatedBytes, s.dailyLimit)
	}

	oldUsed := s.budget.BytesUsed
	s.budget.BytesUsed += estimatedBytes
	if err := s.persistByteBudgetLocked(); err != nil {
		s.budget.BytesUsed = oldUsed
		return fmt.Errorf("%w: %v", ErrStatePersistenceFailed, err)
	}
	return nil
}

// Commit adjusts the reserved estimate with actual consumed bytes and persists to disk.
func (s *Store) Commit(reserved, actual int64) error {
	if reserved < 0 || actual < 0 {
		return ErrNegativeAmount
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	today := time.Now().UTC().Format("2006-01-02")
	oldUsed := s.budget.BytesUsed
	oldDate := s.budget.Date

	if s.budget.Date != today {
		s.budget.Date = today
		s.budget.BytesUsed = actual
	} else {
		newUsed := s.budget.BytesUsed - reserved
		if actual > math.MaxInt64-newUsed {
			return ErrIntegerOverflow
		}
		newUsed += actual
		if newUsed < 0 {
			newUsed = 0
		}
		s.budget.BytesUsed = newUsed
	}

	if err := s.persistByteBudgetLocked(); err != nil {
		s.budget.BytesUsed = oldUsed
		s.budget.Date = oldDate
		return fmt.Errorf("%w: %v", ErrStatePersistenceFailed, err)
	}
	return nil
}

// GetBytesUsed returns current day's byte usage.
func (s *Store) GetBytesUsed() int64 {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.budget.BytesUsed
}

// --- History & Terminal Invalid URLs ---

func (s *Store) loadHistory() error {
	path := filepath.Join(s.dir, "fetched_history.txt")
	data, err := os.ReadFile(path)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("%w: read fetched_history.txt: %v", ErrCorruptedState, err)
	}
	if len(data) > 0 {
		lines := strings.Split(string(data), "\n")
		for _, line := range lines {
			line = strings.TrimSpace(line)
			if line != "" {
				s.fetchedURLs[line] = true
			}
		}
	}

	// Open for appending
	f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0644)
	if err != nil {
		return fmt.Errorf("open fetched_history.txt for append: %w", err)
	}
	s.historyFile = f
	return nil
}

// IsFetched checks if the URL has already been processed or marked terminal invalid.
func (s *Store) IsFetched(itemURL string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.fetchedURLs[itemURL]
}

// MarkFetched permanently registers a URL as fetched only AFTER durable sync succeeds.
func (s *Store) MarkFetched(itemURL string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.fetchedURLs[itemURL] {
		return nil
	}

	if s.historyFile == nil {
		return errors.New("history file is not open")
	}

	if _, err := s.historyFile.WriteString(itemURL + "\n"); err != nil {
		return fmt.Errorf("%w: append to history file: %v", ErrStatePersistenceFailed, err)
	}

	if err := s.historyFile.Sync(); err != nil {
		return fmt.Errorf("%w: sync history file: %v", ErrStatePersistenceFailed, err)
	}

	// Durable success confirmed: now update in-memory map
	s.fetchedURLs[itemURL] = true
	return nil
}

// --- Feed State (Scheduling & Validators) ---

func (s *Store) loadFeedState() error {
	path := filepath.Join(s.dir, "feed_state.json")
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("%w: read feed_state.json: %v", ErrCorruptedState, err)
	}
	var fs FeedState
	if err := json.Unmarshal(data, &fs); err != nil {
		return fmt.Errorf("%w: parse feed_state.json: %v", ErrCorruptedState, err)
	}
	if fs.Feeds == nil {
		fs.Feeds = make(map[string]FeedSchedule)
	}
	s.feedState = fs
	return nil
}

func (s *Store) persistFeedStateLocked() error {
	data, err := json.MarshalIndent(s.feedState, "", "  ")
	if err != nil {
		return err
	}
	path := filepath.Join(s.dir, "feed_state.json")
	return atomicWriteFile(path, data, 0644)
}

// GetFeedSchedule returns the persisted schedule and caching headers for a feed URL.
func (s *Store) GetFeedSchedule(feedURL string) FeedSchedule {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.feedState.Feeds[feedURL]
}

// RecordFeedAttempt records the attempt time and earliest next allowed poll time (honoring Retry-After / backoff).
func (s *Store) RecordFeedAttempt(feedURL string, attemptAt, nextAllowedAt time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	sch := s.feedState.Feeds[feedURL]
	sch.LastAttemptAt = attemptAt
	sch.NextAllowedAt = nextAllowedAt
	s.feedState.Feeds[feedURL] = sch
	if err := s.persistFeedStateLocked(); err != nil {
		return fmt.Errorf("%w: %v", ErrStatePersistenceFailed, err)
	}
	return nil
}

// RecordFeedSuccess records success, clearing consecutive errors and scheduling next poll.
func (s *Store) RecordFeedSuccess(feedURL string, nextAllowedAt time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	sch := s.feedState.Feeds[feedURL]
	sch.NextAllowedAt = nextAllowedAt
	sch.ConsecutiveErrors = 0
	s.feedState.Feeds[feedURL] = sch
	if err := s.persistFeedStateLocked(); err != nil {
		return fmt.Errorf("%w: %v", ErrStatePersistenceFailed, err)
	}
	return nil
}

// RecordFeedFailure records failure, tracking consecutive errors and scheduling backoff.
func (s *Store) RecordFeedFailure(feedURL string, attemptAt, nextAllowedAt time.Time, consecutiveErrors int) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	sch := s.feedState.Feeds[feedURL]
	sch.LastAttemptAt = attemptAt
	sch.NextAllowedAt = nextAllowedAt
	sch.ConsecutiveErrors = consecutiveErrors
	s.feedState.Feeds[feedURL] = sch
	if err := s.persistFeedStateLocked(); err != nil {
		return fmt.Errorf("%w: %v", ErrStatePersistenceFailed, err)
	}
	return nil
}

// SaveFeedValidator saves validators only after downstream index has accepted items.
func (s *Store) SaveFeedValidator(feedURL, lastModified, etag string, polledAt time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	sch := s.feedState.Feeds[feedURL]
	sch.LastModified = lastModified
	sch.ETag = etag
	sch.LastPolledAt = polledAt
	s.feedState.Feeds[feedURL] = sch
	if err := s.persistFeedStateLocked(); err != nil {
		return fmt.Errorf("%w: %v", ErrStatePersistenceFailed, err)
	}
	return nil
}

// GetGlobalBackoffUntil returns the timestamp until which all upstream calls are backed off.
func (s *Store) GetGlobalBackoffUntil() time.Time {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.feedState.GlobalBackoffUntil
}

// SetGlobalBackoff records a global backoff deadline across all upstream operations.
func (s *Store) SetGlobalBackoff(until time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.feedState.GlobalBackoffUntil = until
	if err := s.persistFeedStateLocked(); err != nil {
		return fmt.Errorf("%w: %v", ErrStatePersistenceFailed, err)
	}
	return nil
}

// GetLastLongPollTime returns the last time long-term feed was executed.
func (s *Store) GetLastLongPollTime() time.Time {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.feedState.LastLongPollTime
}

// SetLastLongPollTime records the time a long-term feed cycle completed.
func (s *Store) SetLastLongPollTime(t time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.feedState.LastLongPollTime = t
	if err := s.persistFeedStateLocked(); err != nil {
		return fmt.Errorf("%w: %v", ErrStatePersistenceFailed, err)
	}
	return nil
}

// --- Durable Spool ---

// SpoolItemKey generates a safe filesystem filename from item URL.
func SpoolItemKey(itemURL string) string {
	sum := sha256.Sum256([]byte(itemURL))
	return hex.EncodeToString(sum[:16])
}

// HasSpool checks whether an unacknowledged spool file exists for the item URL.
func (s *Store) HasSpool(itemURL string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	spoolFile := filepath.Join(s.dir, "spool", SpoolItemKey(itemURL)+".json")
	_, err := os.Stat(spoolFile)
	return err == nil
}

// SaveSpool persists an uncommitted item into the spool directory before core delivery.
func (s *Store) SaveSpool(item SpoolItem) error {
	data, err := json.MarshalIndent(item, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal spool item: %w", err)
	}
	spoolFile := filepath.Join(s.dir, "spool", SpoolItemKey(item.ItemURL)+".json")
	if err := atomicWriteFile(spoolFile, data, 0644); err != nil {
		return fmt.Errorf("%w: %v", ErrStatePersistenceFailed, err)
	}
	return nil
}

// DeleteSpool removes a successfully delivered item from the spool.
func (s *Store) DeleteSpool(itemURL string) error {
	spoolFile := filepath.Join(s.dir, "spool", SpoolItemKey(itemURL)+".json")
	err := os.Remove(spoolFile)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("%w: delete %s: %v", ErrStatePersistenceFailed, spoolFile, err)
	}
	return nil
}

// QuarantineSpool moves a repeatedly failing or malformed spool item out of active spool.
func (s *Store) QuarantineSpool(itemURL, reason string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	spoolFile := filepath.Join(s.dir, "spool", SpoolItemKey(itemURL)+".json")
	quarantineDir := filepath.Join(s.dir, "spool", "quarantine")
	if err := os.MkdirAll(quarantineDir, 0755); err != nil {
		return fmt.Errorf("mkdir quarantine dir: %w", err)
	}
	dstFile := filepath.Join(quarantineDir, SpoolItemKey(itemURL)+".json")
	slog.Warn("Quarantining spool item", "url", itemURL, "reason", reason, "dst", dstFile)
	if err := os.Rename(spoolFile, dstFile); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("%w: quarantine %s: %v", ErrStatePersistenceFailed, spoolFile, err)
	}
	return nil
}

// ListSpool returns all uncommitted items awaiting delivery.
func (s *Store) ListSpool() ([]SpoolItem, error) {
	spoolDir := filepath.Join(s.dir, "spool")
	entries, err := os.ReadDir(spoolDir)
	if err != nil {
		return nil, fmt.Errorf("%w: read spool dir: %v", ErrStatePersistenceFailed, err)
	}

	var items []SpoolItem
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".json") {
			continue
		}
		path := filepath.Join(spoolDir, e.Name())
		data, err := os.ReadFile(path)
		if err != nil {
			slog.Warn("Failed to read spool file, quarantining", "path", path, "err", err)
			quarantineDir := filepath.Join(spoolDir, "quarantine")
			_ = os.MkdirAll(quarantineDir, 0755)
			_ = os.Rename(path, filepath.Join(quarantineDir, e.Name()))
			continue
		}
		var item SpoolItem
		if err := json.Unmarshal(data, &item); err != nil {
			slog.Warn("Corrupted spool JSON, quarantining to unblock valid spool queue", "path", path, "err", err)
			quarantineDir := filepath.Join(spoolDir, "quarantine")
			_ = os.MkdirAll(quarantineDir, 0755)
			_ = os.Rename(path, filepath.Join(quarantineDir, e.Name()))
			continue
		}
		items = append(items, item)
	}
	return items, nil
}

// atomicWriteFile writes data to a temporary file, fsyncs the file, closes it,
// renames it over destination, and fsyncs the parent directory.
func atomicWriteFile(filename string, data []byte, perm os.FileMode) error {
	dir := filepath.Dir(filename)
	tmpFile, err := os.CreateTemp(dir, "tmp-*")
	if err != nil {
		return fmt.Errorf("create temp file in %s: %w", dir, err)
	}
	tmpName := tmpFile.Name()
	defer func() {
		_ = tmpFile.Close()
		_ = os.Remove(tmpName)
	}()

	if _, err := tmpFile.Write(data); err != nil {
		return fmt.Errorf("write temp file: %w", err)
	}
	if err := tmpFile.Chmod(perm); err != nil {
		return fmt.Errorf("chmod temp file: %w", err)
	}

	// 1. fsync file before closing
	if err := tmpFile.Sync(); err != nil {
		return fmt.Errorf("sync temp file: %w", err)
	}

	if err := tmpFile.Close(); err != nil {
		return fmt.Errorf("close temp file: %w", err)
	}

	// 2. Atomic rename
	if err := os.Rename(tmpName, filename); err != nil {
		return fmt.Errorf("rename %s to %s: %w", tmpName, filename, err)
	}

	// 3. fsync parent directory to guarantee metadata persistence
	dirFile, err := os.Open(dir)
	if err == nil {
		_ = dirFile.Sync()
		_ = dirFile.Close()
	}

	return nil
}
