package main

import (
	"context"
	"log/slog"
	"os"
	"os/signal"
	"syscall"

	"usgs_adapter/controller"
	"usgs_adapter/initialize"
)

func main() {
	initialize.InitLogger()
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	controller.ManageRESTRequest(ctx)
	slog.Info("USGS adapter stopped")
}
