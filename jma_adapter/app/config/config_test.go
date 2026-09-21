package config

import (
	"os"
	"testing"
)

func TestConfigDefaultsAndClamping(t *testing.T) {
	os.Unsetenv("JMA_FEEDS")
	os.Unsetenv("JMA_LONG_FEEDS")
	os.Unsetenv("JMA_POLL_INTERVAL")
	os.Unsetenv("JMA_LONG_POLL_INTERVAL")
	os.Unsetenv("JMA_REQUEST_INTERVAL")
	os.Unsetenv("JMA_STATE_DIR")
	os.Unsetenv("JMA_DAILY_BYTE_LIMIT")
	os.Unsetenv("JMA_MAX_ITEM_BYTES")
	os.Unsetenv("JMA_CONTACT_EMAIL")

	cfg, err := Load()
	if err != nil {
		t.Fatalf("unexpected error loading config: %v", err)
	}
	if len(cfg.Feeds) != 2 || len(cfg.LongFeeds) != 2 {
		t.Fatalf("expected 2 default feeds, got %d, %d", len(cfg.Feeds), len(cfg.LongFeeds))
	}
	if cfg.PollInterval != DefaultPollInterval {
		t.Fatalf("expected poll interval %v, got %v", DefaultPollInterval, cfg.PollInterval)
	}
	if cfg.DailyByteLimit != DefaultDailyByteLimit {
		t.Fatalf("expected daily byte limit %d, got %d", DefaultDailyByteLimit, cfg.DailyByteLimit)
	}

	// Test clamping below minimums and above max budget
	os.Setenv("JMA_POLL_INTERVAL", "10s")
	os.Setenv("JMA_LONG_POLL_INTERVAL", "10m")
	os.Setenv("JMA_REQUEST_INTERVAL", "100ms")
	os.Setenv("JMA_DAILY_BYTE_LIMIT", "10000000000") // 10GB -> should clamp to 5GB max
	os.Setenv("JMA_CONTACT_EMAIL", "ops@example.com")

	cfg2, err := Load()
	if err != nil {
		t.Fatalf("unexpected error loading clamped config: %v", err)
	}
	if cfg2.PollInterval != MinPollInterval {
		t.Fatalf("expected clamped poll interval %v, got %v", MinPollInterval, cfg2.PollInterval)
	}
	if cfg2.DailyByteLimit != MaxAllowedByteLimit {
		t.Fatalf("expected clamped byte limit %d, got %d", MaxAllowedByteLimit, cfg2.DailyByteLimit)
	}
	if cfg2.UserAgent != "matrixwhale-jma-adapter (ops@example.com)" {
		t.Fatalf("expected user agent with email, got %s", cfg2.UserAgent)
	}

	// Test negative budget fails
	os.Setenv("JMA_DAILY_BYTE_LIMIT", "-500")
	if _, err := Load(); err == nil {
		t.Fatalf("expected error on negative byte limit, got nil")
	}
}
