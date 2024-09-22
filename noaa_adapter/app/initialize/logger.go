package initialize

import (
	"log/slog"
	"os"
)

func InitLogger() {
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, nil)).With("service", "noaa_adapter"))
	slog.Info("The Logger initialized")
}
