package broker

import (
	"context"
	"strings"
	"testing"
	"time"
)

func TestRandomClientID(t *testing.T) {
	id1 := RandomClientID()
	id2 := RandomClientID()

	if !strings.HasPrefix(id1, "matrixwhale-") {
		t.Errorf("expected matrixwhale- prefix, got: %s", id1)
	}
	if id1 == id2 {
		t.Errorf("expected random client IDs to differ: %s == %s", id1, id2)
	}
}

func TestRotatorOrderAndBackoff(t *testing.T) {
	brokers := []string{
		"mqtts://b1:8883",
		"mqtts://b2:8883",
		"mqtts://b3:8883",
	}

	floor := 100 * time.Millisecond
	ceiling := 1 * time.Second
	maxJitter := 50 * time.Millisecond

	r := NewRotator(brokers, floor, ceiling, maxJitter)

	if r.Current() != "mqtts://b1:8883" {
		t.Errorf("expected b1 as initial broker, got: %s", r.Current())
	}

	// Rotate 1 -> b2
	next, delay := r.Rotate()
	if next != "mqtts://b2:8883" || r.Current() != "mqtts://b2:8883" {
		t.Errorf("expected b2 after first rotate, got: %s", next)
	}
	if delay < floor || delay > floor+maxJitter {
		t.Errorf("unexpected delay for first rotate: %v", delay)
	}

	// Rotate 2 -> b3
	next, delay = r.Rotate()
	if next != "mqtts://b3:8883" {
		t.Errorf("expected b3 after second rotate, got: %s", next)
	}
	// Backoff doubles: 200ms
	if delay < 200*time.Millisecond || delay > 200*time.Millisecond+maxJitter {
		t.Errorf("unexpected delay for second rotate: %v", delay)
	}

	// Rotate 3 -> wraps back to b1
	next, _ = r.Rotate()
	if next != "mqtts://b1:8883" {
		t.Errorf("expected b1 after wrap around, got: %s", next)
	}

	// Rotate multiple times to test ceiling clamp
	for i := 0; i < 10; i++ {
		_, delay = r.Rotate()
		if delay > ceiling+maxJitter {
			t.Errorf("delay exceeded ceiling: %v > %v", delay, ceiling+maxJitter)
		}
	}

	// Test reset backoff
	r.ResetBackoff()
	_, delay = r.Rotate()
	if delay < floor || delay > floor+maxJitter {
		t.Errorf("expected delay to reset to floor, got: %v", delay)
	}
}

func TestFakeBroker(t *testing.T) {
	fb := NewFakeBroker("mqtts://test-broker:8883")
	if fb.CurrentBroker() != "mqtts://test-broker:8883" {
		t.Errorf("unexpected current broker: %s", fb.CurrentBroker())
	}
	if !fb.IsConnected() {
		t.Errorf("expected connected")
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	received := make(chan string, 1)
	go func() {
		_ = fb.Run(ctx, func(topic string, payload []byte) {
			received <- topic + ":" + string(payload)
		})
	}()

	if err := fb.WaitRunning(ctx); err != nil {
		t.Fatalf("wait running failed: %v", err)
	}

	fb.Publish("test/topic", []byte("test-payload"))

	select {
	case msg := <-received:
		if msg != "test/topic:test-payload" {
			t.Errorf("unexpected message: %s", msg)
		}
	case <-time.After(1 * time.Second):
		t.Fatal("timed out waiting for fake broker message")
	}

	fb.SetConnected(false, "conn-err")
	if fb.IsConnected() {
		t.Errorf("expected disconnected")
	}
	if fb.LastError() != "conn-err" {
		t.Errorf("unexpected last error: %s", fb.LastError())
	}
}
