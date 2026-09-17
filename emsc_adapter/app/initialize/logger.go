package initialize

import (
	"log/slog"

	"matrixwhale/adapters/common/core"
	"matrixwhale/adapters/common/logging"
)

func InitLogger() {
	handler := logging.NewCoreHandler(core.NewClientFromEnv(), "emsc_adapter")
	slog.SetDefault(slog.New(handler).With("source", "emsc"))
	slog.Info("The EMSC Adapter Logger initialized")
}
