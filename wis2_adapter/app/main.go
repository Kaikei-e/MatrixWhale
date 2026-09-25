package main

import (
	"context"
	"log/slog"
	"os"
	"os/signal"
	"syscall"

	"matrixwhale/adapters/common/metrics"

	"wis2_adapter/controller"
	"wis2_adapter/initialize"
)

func main() {
	initialize.InitLogger()
	metrics.Serve()
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	controller.Run(ctx)
	slog.Info("WIS2 adapter stopped")
}
