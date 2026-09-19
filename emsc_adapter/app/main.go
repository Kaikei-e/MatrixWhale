package main

import (
	"context"
	"log/slog"
	"os"
	"os/signal"
	"syscall"

	"emsc_adapter/controller"
	"emsc_adapter/initialize"
	"matrixwhale/adapters/common/metrics"
)

func main() {
	initialize.InitLogger()
	metrics.Serve()
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	controller.Run(ctx)
	slog.Info("EMSC adapter stopped")
}
