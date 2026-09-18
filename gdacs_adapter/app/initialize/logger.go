package initialize

import (
	"log/slog"

	"matrixwhale/adapters/common/core"
	"matrixwhale/adapters/common/logging"
)

func InitLogger() {
	handler := logging.NewCoreHandler(core.NewClientFromEnv(), "gdacs_adapter")
	slog.SetDefault(slog.New(handler).With("source", "gdacs"))
	slog.Info("The GDACS Adapter Logger initialized")
}
