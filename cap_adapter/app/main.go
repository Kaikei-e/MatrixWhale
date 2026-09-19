package main

import (
	"context"
	"log/slog"
	"os"
	"os/signal"
	"syscall"

	"cap_adapter/controller"
	"cap_adapter/initialize"
	"matrixwhale/adapters/common/metrics"
)

func main() {
	initialize.InitLogger()
	metrics.Serve()
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	controller.Run(ctx)
	slog.Info("CAP adapter stopped")
}
