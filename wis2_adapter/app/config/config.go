package config

import (
	"log/slog"
	"os"
	"strconv"
	"strings"
	"time"
)

const (
	DefaultBrokers             = "mqtts://globalbroker.meteo.fr:8883,mqtts://gb.wis.cma.cn:8883,mqtts://wis2globalbroker.nws.noaa.gov:8883,mqtts://globalbroker.inmet.gov.br:8883"
	DefaultUsername            = "everyone"
	DefaultPassword            = "everyone"
	DefaultTopics              = "cache/a/wis2/+/data/core/weather/advisories-warnings/#,cache/a/wis2/+/data/core/weather/prediction/forecast/+/deterministic/trajectory/#,cache/a/wis2/+/data/core/weather/surface-based-observations/synop/#"
	DefaultMaxDownloadBytes    = 5 * 1024 * 1024
	DefaultDownloadConcurrency = 8
	DefaultHealthInterval      = 60 * time.Second
)

type Config struct {
	Brokers             []string
	Username            string
	Password            string
	Topics              []string
	ContactEmail        string
	MaxDownloadBytes    int64
	DownloadConcurrency int
	HealthInterval      time.Duration
}

func LoadConfig() Config {
	cfg := Config{
		Username:            DefaultUsername,
		Password:            DefaultPassword,
		MaxDownloadBytes:    DefaultMaxDownloadBytes,
		DownloadConcurrency: DefaultDownloadConcurrency,
		HealthInterval:      DefaultHealthInterval,
	}

	brokersStr := DefaultBrokers
	if v := strings.TrimSpace(os.Getenv("WIS2_BROKERS")); v != "" {
		brokersStr = v
	}
	cfg.Brokers = splitCommaList(brokersStr)
	if len(cfg.Brokers) == 0 {
		cfg.Brokers = splitCommaList(DefaultBrokers)
	}

	if v := strings.TrimSpace(os.Getenv("WIS2_USERNAME")); v != "" {
		cfg.Username = v
	}
	if v := strings.TrimSpace(os.Getenv("WIS2_PASSWORD")); v != "" {
		cfg.Password = v
	}

	topicsStr := DefaultTopics
	if v := strings.TrimSpace(os.Getenv("WIS2_TOPICS")); v != "" {
		topicsStr = v
	}
	cfg.Topics = splitCommaList(topicsStr)
	if len(cfg.Topics) == 0 {
		cfg.Topics = splitCommaList(DefaultTopics)
	}

	cfg.ContactEmail = strings.TrimSpace(os.Getenv("WIS2_CONTACT_EMAIL"))

	if v := strings.TrimSpace(os.Getenv("WIS2_MAX_DOWNLOAD_BYTES")); v != "" {
		if n, err := strconv.ParseInt(v, 10, 64); err == nil && n > 0 {
			cfg.MaxDownloadBytes = n
		} else {
			slog.Warn("WIS2_MAX_DOWNLOAD_BYTES is invalid; using default", "value", v, "default", DefaultMaxDownloadBytes)
		}
	}

	if v := strings.TrimSpace(os.Getenv("WIS2_DOWNLOAD_CONCURRENCY")); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			cfg.DownloadConcurrency = n
		} else {
			slog.Warn("WIS2_DOWNLOAD_CONCURRENCY is invalid; using default", "value", v, "default", DefaultDownloadConcurrency)
		}
	}

	if v := strings.TrimSpace(os.Getenv("WIS2_HEALTH_INTERVAL")); v != "" {
		if d, err := time.ParseDuration(v); err == nil && d > 0 {
			cfg.HealthInterval = d
		} else {
			slog.Warn("WIS2_HEALTH_INTERVAL is invalid; using default", "value", v, "default", DefaultHealthInterval)
		}
	}

	return cfg
}

func splitCommaList(s string) []string {
	parts := strings.Split(s, ",")
	res := make([]string, 0, len(parts))
	for _, p := range parts {
		trimmed := strings.TrimSpace(p)
		if trimmed != "" {
			res = append(res, trimmed)
		}
	}
	return res
}
