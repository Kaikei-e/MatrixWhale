package config

import (
	"errors"
	"fmt"
	"log/slog"
	"math"
	"os"
	"strconv"
	"strings"
	"time"

	"matrixwhale/adapters/common/useragent"
)

const (
	OfficialFeedHost        = "https://www.data.jma.go.jp"
	DefaultFeeds            = "https://www.data.jma.go.jp/developer/xml/feed/eqvol.xml,https://www.data.jma.go.jp/developer/xml/feed/extra.xml"
	DefaultLongFeeds        = "https://www.data.jma.go.jp/developer/xml/feed/eqvol_l.xml,https://www.data.jma.go.jp/developer/xml/feed/extra_l.xml"
	DefaultPollInterval     = 1 * time.Minute
	MinPollInterval         = 1 * time.Minute
	DefaultLongPollInterval = 1 * time.Hour
	MinLongPollInterval     = 1 * time.Hour
	DefaultRequestInterval  = 1 * time.Second
	MinRequestInterval      = 1 * time.Second
	DefaultStateDir         = "/var/lib/jma"
	DefaultDailyByteLimit   = 1073741824 // 1 GiB
	MaxAllowedByteLimit     = 1073741824 // 1 GiB (strictly capped to 1GiB; 2 calendar days cannot exceed 10GB origin ban)
	MinAllowedByteLimit     = 1048576    // 1 MiB
	DefaultMaxItemBytes     = 8388608    // 8 MiB
	MaxAllowedItemBytes     = 33554432   // 32 MiB
	MinAllowedItemBytes     = 1024       // 1 KiB
	ProductName             = "matrixwhale-jma-adapter"
)

// Config holds runtime configuration for the JMA adapter.
type Config struct {
	Feeds            []string
	LongFeeds        []string
	PollInterval     time.Duration
	LongPollInterval time.Duration
	RequestInterval  time.Duration
	StateDir         string
	DailyByteLimit   int64
	MaxItemBytes     int64
	UserAgent        string
}

// Load reads and validates configuration from environment variables.
func Load() (*Config, error) {
	feeds := parseCommaSeparatedURLs("JMA_FEEDS", DefaultFeeds)
	if len(feeds) == 0 {
		return nil, errors.New("JMA_FEEDS contains no valid URLs")
	}

	longFeeds := parseCommaSeparatedURLs("JMA_LONG_FEEDS", DefaultLongFeeds)
	if len(longFeeds) == 0 {
		return nil, errors.New("JMA_LONG_FEEDS contains no valid URLs")
	}

	pollInterval := parseDurationEnv("JMA_POLL_INTERVAL", DefaultPollInterval, MinPollInterval)
	longPollInterval := parseDurationEnv("JMA_LONG_POLL_INTERVAL", DefaultLongPollInterval, MinLongPollInterval)
	requestInterval := parseDurationEnv("JMA_REQUEST_INTERVAL", DefaultRequestInterval, MinRequestInterval)

	stateDir := os.Getenv("JMA_STATE_DIR")
	if stateDir == "" {
		stateDir = DefaultStateDir
	}

	dailyByteLimit, err := parseInt64RangeEnv("JMA_DAILY_BYTE_LIMIT", DefaultDailyByteLimit, MinAllowedByteLimit, MaxAllowedByteLimit)
	if err != nil {
		return nil, fmt.Errorf("JMA_DAILY_BYTE_LIMIT: %w", err)
	}

	maxItemBytes, err := parseInt64RangeEnv("JMA_MAX_ITEM_BYTES", DefaultMaxItemBytes, MinAllowedItemBytes, MaxAllowedItemBytes)
	if err != nil {
		return nil, fmt.Errorf("JMA_MAX_ITEM_BYTES: %w", err)
	}

	// Use shared useragent package; fallback is empty string so unconfigured email emits bare product name.
	ua := useragent.Build(ProductName, "JMA_CONTACT_EMAIL", "", nil)

	cfg := &Config{
		Feeds:            feeds,
		LongFeeds:        longFeeds,
		PollInterval:     pollInterval,
		LongPollInterval: longPollInterval,
		RequestInterval:  requestInterval,
		StateDir:         stateDir,
		DailyByteLimit:   dailyByteLimit,
		MaxItemBytes:     maxItemBytes,
		UserAgent:        ua,
	}

	slog.Info("Loaded JMA adapter configuration",
		"feeds", strings.Join(cfg.Feeds, ","),
		"long_feeds", strings.Join(cfg.LongFeeds, ","),
		"poll_interval", cfg.PollInterval.String(),
		"long_poll_interval", cfg.LongPollInterval.String(),
		"request_interval", cfg.RequestInterval.String(),
		"state_dir", cfg.StateDir,
		"daily_byte_limit", cfg.DailyByteLimit,
		"max_item_bytes", cfg.MaxItemBytes,
		"user_agent", cfg.UserAgent,
	)

	return cfg, nil
}

func parseCommaSeparatedURLs(envKey, defVal string) []string {
	val := os.Getenv(envKey)
	if val == "" {
		val = defVal
	}
	parts := strings.Split(val, ",")
	var result []string
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p != "" {
			result = append(result, p)
		}
	}
	return result
}

func parseDurationEnv(key string, def, min time.Duration) time.Duration {
	val := os.Getenv(key)
	if val == "" {
		return def
	}
	d, err := time.ParseDuration(val)
	if err != nil {
		slog.Warn("Invalid duration for environment variable, using default", "key", key, "value", val, "default", def.String())
		return def
	}
	if d < min {
		slog.Warn("Configured interval is below minimum threshold, clamping to minimum", "key", key, "configured", d.String(), "minimum", min.String())
		return min
	}
	return d
}

func parseInt64RangeEnv(key string, def, minVal, maxVal int64) (int64, error) {
	val := os.Getenv(key)
	if val == "" {
		return def, nil
	}
	n, err := strconv.ParseInt(val, 10, 64)
	if err != nil {
		return 0, fmt.Errorf("invalid integer '%s': %w", val, err)
	}
	if n < 0 || n > math.MaxInt64-1024 {
		return 0, fmt.Errorf("value %d out of safe bounds", n)
	}
	if n < minVal {
		slog.Warn("Value below minimum threshold, clamping", "key", key, "configured", n, "minimum", minVal)
		return minVal, nil
	}
	if n > maxVal {
		slog.Warn("Value above maximum safety limit, clamping", "key", key, "configured", n, "maximum", maxVal)
		return maxVal, nil
	}
	return n, nil
}
