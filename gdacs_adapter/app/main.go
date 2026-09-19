package main

import (
	"context"
	"log/slog"
	"os"
	"os/signal"
	"syscall"

	"gdacs_adapter/controller"
	"gdacs_adapter/initialize"
	"matrixwhale/adapters/common/metrics"
)

func main() {
	initialize.InitLogger()
	metrics.Serve()
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	controller.Run(ctx)
	slog.Info("GDACS adapter stopped")
}
