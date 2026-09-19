package initialize

import (
	"log/slog"

	"matrixwhale/adapters/common/core"
	"matrixwhale/adapters/common/logging"
)

func InitLogger() {
	handler := logging.NewCoreHandler(core.NewClientFromEnv(), "cap_adapter")
	slog.SetDefault(slog.New(handler).With("source", "cap"))
	slog.Info("The CAP Adapter Logger initialized")
}
