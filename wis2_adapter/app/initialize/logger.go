package initialize

import (
	"log/slog"

	"matrixwhale/adapters/common/core"
	"matrixwhale/adapters/common/logging"
)

func InitLogger() {
	handler := logging.NewCoreHandler(core.NewClientFromEnv(), "wis2_adapter")
	slog.SetDefault(slog.New(handler).With("source", "wis2"))
	slog.Info("The WIS2 Adapter Logger initialized")
}
