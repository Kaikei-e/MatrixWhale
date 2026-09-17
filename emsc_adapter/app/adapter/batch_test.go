package adapter_test

import (
	"context"
	"testing"
	"time"

	"emsc_adapter/adapter"
)

func TestBatcherFlushesAtSize(t *testing.T) {
	in := make(chan adapter.LiveMessage)
	out := make(chan []adapter.LiveMessage)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	go adapter.Batcher{Size: 3, MaxWait: time.Minute}.Run(ctx, in, out)

	for i := 0; i < 3; i++ {
		in <- adapter.LiveMessage{LastUpdate: string(rune('a' + i))}
	}

	select {
	case batch := <-out:
		if len(batch) != 3 {
			t.Fatalf("batch size = %d, want 3", len(batch))
		}
	case <-time.After(time.Second):
		t.Fatal("batch was not flushed at size")
	}
}

func TestBatcherFlushesAtMaxWait(t *testing.T) {
	in := make(chan adapter.LiveMessage)
	out := make(chan []adapter.LiveMessage)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	go adapter.Batcher{Size: 100, MaxWait: 20 * time.Millisecond}.Run(ctx, in, out)

	in <- adapter.LiveMessage{LastUpdate: "only"}

	select {
	case batch := <-out:
		if len(batch) != 1 {
			t.Fatalf("batch size = %d, want 1", len(batch))
		}
	case <-time.After(time.Second):
		t.Fatal("batch was not flushed at max wait")
	}
}

func TestBatcherFlushesRemainingWhenInputCloses(t *testing.T) {
	in := make(chan adapter.LiveMessage)
	out := make(chan []adapter.LiveMessage)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	done := make(chan struct{})
	go func() {
		adapter.Batcher{Size: 100, MaxWait: time.Minute}.Run(ctx, in, out)
		close(done)
	}()

	in <- adapter.LiveMessage{LastUpdate: "a"}
	in <- adapter.LiveMessage{LastUpdate: "b"}
	close(in)

	select {
	case batch := <-out:
		if len(batch) != 2 {
			t.Fatalf("flushed batch size = %d, want 2", len(batch))
		}
	case <-time.After(time.Second):
		t.Fatal("remaining messages were not flushed on close")
	}

	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("Run did not return after input closed")
	}
	if _, ok := <-out; ok {
		t.Fatal("out was not closed")
	}
}

func TestBatcherStopsOnContextCancel(t *testing.T) {
	in := make(chan adapter.LiveMessage)
	out := make(chan []adapter.LiveMessage)
	ctx, cancel := context.WithCancel(context.Background())

	done := make(chan struct{})
	go func() {
		adapter.Batcher{Size: 100, MaxWait: time.Minute}.Run(ctx, in, out)
		close(done)
	}()

	cancel()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("Run did not stop on context cancellation")
	}
}
