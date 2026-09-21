package main

import (
	"context"
	"log/slog"
	"os"
	"os/signal"
	"syscall"

	"jma_adapter/client"
	"jma_adapter/config"
	"jma_adapter/controller"
	"jma_adapter/initialize"
	"jma_adapter/state"
	"matrixwhale/adapters/common/core"
	"matrixwhale/adapters/common/metrics"
)

func main() {
	initialize.InitLogger()
	metrics.Serve()

	cfg, err := config.Load()
	if err != nil {
		slog.Error("Failed to load configuration", "err", err)
		os.Exit(1)
	}

	// Acquire single-instance process lock on state directory
	lock, err := state.AcquireLock(cfg.StateDir)
	if err != nil {
		slog.Error("Failed to acquire JMA process lock", "err", err)
		os.Exit(1)
	}
	defer lock.Close()

	// Initialize disk state store
	store, err := state.NewStore(cfg.StateDir, cfg.DailyByteLimit)
	if err != nil {
		slog.Error("Failed to initialize state store", "err", err)
		os.Exit(1)
	}
	defer store.Close()

	urlValidator := client.NewURLValidator("www.data.jma.go.jp", false)
	jmaClient := client.NewJMAClient(
		store,
		urlValidator,
		cfg.UserAgent,
		cfg.RequestInterval,
		cfg.MaxItemBytes,
		cfg.PollInterval,
		nil,
	)

	coreHTTPClient := core.NewClientFromEnv()
	coreClient := client.NewCoreClient(coreHTTPClient, nil)

	ctrl := controller.NewController(cfg, store, jmaClient, coreClient, urlValidator)

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	ctrl.Run(ctx)
	slog.Info("JMA adapter stopped cleanly")
}
