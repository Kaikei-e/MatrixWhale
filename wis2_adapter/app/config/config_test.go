package config

import (
	"os"
	"testing"
	"time"
)

func TestLoadConfigDefaults(t *testing.T) {
	cfg := LoadConfig()
	if len(cfg.Brokers) != 4 {
		t.Errorf("expected 4 default brokers, got %d", len(cfg.Brokers))
	}
	if cfg.Username != "everyone" || cfg.Password != "everyone" {
		t.Errorf("unexpected user/pass: %s / %s", cfg.Username, cfg.Password)
	}
	if len(cfg.Topics) != 3 || cfg.Topics[0] != "cache/a/wis2/+/data/core/weather/advisories-warnings/#" || cfg.Topics[1] != "cache/a/wis2/+/data/core/weather/prediction/forecast/+/deterministic/trajectory/#" || cfg.Topics[2] != "cache/a/wis2/+/data/core/weather/surface-based-observations/synop/#" {
		t.Errorf("expected 3 default topics, got %v", cfg.Topics)
	}
	if cfg.MaxDownloadBytes != 5*1024*1024 {
		t.Errorf("unexpected max download bytes: %d", cfg.MaxDownloadBytes)
	}
	if cfg.DownloadConcurrency != 8 {
		t.Errorf("unexpected concurrency: %d", cfg.DownloadConcurrency)
	}
	if cfg.HealthInterval != 60*time.Second {
		t.Errorf("unexpected health interval: %v", cfg.HealthInterval)
	}
}

func TestLoadConfigCustomEnv(t *testing.T) {
	_ = os.Setenv("WIS2_BROKERS", "mqtts://b1:8883, mqtts://b2:8883")
	_ = os.Setenv("WIS2_USERNAME", "customuser")
	_ = os.Setenv("WIS2_PASSWORD", "custompass")
	_ = os.Setenv("WIS2_TOPICS", "cache/a/wis2/+/data/core/weather/surface-based-observations/synop")
	_ = os.Setenv("WIS2_CONTACT_EMAIL", "test@example.com")
	_ = os.Setenv("WIS2_MAX_DOWNLOAD_BYTES", "1048576")
	_ = os.Setenv("WIS2_DOWNLOAD_CONCURRENCY", "4")
	_ = os.Setenv("WIS2_HEALTH_INTERVAL", "30s")
	defer func() {
		_ = os.Unsetenv("WIS2_BROKERS")
		_ = os.Unsetenv("WIS2_USERNAME")
		_ = os.Unsetenv("WIS2_PASSWORD")
		_ = os.Unsetenv("WIS2_TOPICS")
		_ = os.Unsetenv("WIS2_CONTACT_EMAIL")
		_ = os.Unsetenv("WIS2_MAX_DOWNLOAD_BYTES")
		_ = os.Unsetenv("WIS2_DOWNLOAD_CONCURRENCY")
		_ = os.Unsetenv("WIS2_HEALTH_INTERVAL")
	}()

	cfg := LoadConfig()
	if len(cfg.Brokers) != 2 || cfg.Brokers[0] != "mqtts://b1:8883" || cfg.Brokers[1] != "mqtts://b2:8883" {
		t.Errorf("unexpected brokers: %v", cfg.Brokers)
	}
	if cfg.Username != "customuser" || cfg.Password != "custompass" {
		t.Errorf("unexpected user/pass: %s / %s", cfg.Username, cfg.Password)
	}
	if len(cfg.Topics) != 1 || cfg.Topics[0] != "cache/a/wis2/+/data/core/weather/surface-based-observations/synop" {
		t.Errorf("unexpected topics: %v", cfg.Topics)
	}
	if cfg.ContactEmail != "test@example.com" {
		t.Errorf("unexpected contact email: %s", cfg.ContactEmail)
	}
	if cfg.MaxDownloadBytes != 1048576 {
		t.Errorf("unexpected max download bytes: %d", cfg.MaxDownloadBytes)
	}
	if cfg.DownloadConcurrency != 4 {
		t.Errorf("unexpected concurrency: %d", cfg.DownloadConcurrency)
	}
	if cfg.HealthInterval != 30*time.Second {
		t.Errorf("unexpected health interval: %v", cfg.HealthInterval)
	}
}
