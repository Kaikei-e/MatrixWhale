package main

import (
	"context"
	"log/slog"
	"os"
	"os/signal"
	"syscall"

	"cap_adapter/controller"
	"cap_adapter/initialize"
)

func main() {
	initialize.InitLogger()
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	controller.Run(ctx)
	slog.Info("CAP adapter stopped")
}
