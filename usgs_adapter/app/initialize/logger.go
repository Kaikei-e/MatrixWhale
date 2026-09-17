package initialize

import (
	"log/slog"

	"matrixwhale/adapters/common/core"
	"matrixwhale/adapters/common/logging"
)

func InitLogger() {
	handler := logging.NewCoreHandler(core.NewClientFromEnv(), "usgs_adapter")
	slog.SetDefault(slog.New(handler).With("source", "usgs"))
	slog.Info("The USGS Adapter Logger initialized")
}
