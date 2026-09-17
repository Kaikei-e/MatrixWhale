package initialize

import (
	"log/slog"

	"matrixwhale/adapters/common/core"
	"matrixwhale/adapters/common/logging"
)

func InitLogger() {
	handler := logging.NewCoreHandler(core.NewClientFromEnv(), "noaa_adapter")
	slog.SetDefault(slog.New(handler))
	slog.Info("The NOAA Adapter Logger initialized")
}
