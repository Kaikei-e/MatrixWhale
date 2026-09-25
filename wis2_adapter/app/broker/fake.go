package broker

import (
	"context"
	"sync"
)

type FakeBroker struct {
	mu          sync.RWMutex
	brokerURL   string
	connected   bool
	lastError   string
	handler     MessageHandler
	runningChan chan struct{}
	stopChan    chan struct{}
}

func NewFakeBroker(url string) *FakeBroker {
	return &FakeBroker{
		brokerURL:   url,
		connected:   true,
		runningChan: make(chan struct{}),
		stopChan:    make(chan struct{}),
	}
}

func (f *FakeBroker) CurrentBroker() string {
	f.mu.RLock()
	defer f.mu.RUnlock()
	return f.brokerURL
}

func (f *FakeBroker) SetCurrentBroker(url string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.brokerURL = url
}

func (f *FakeBroker) IsConnected() bool {
	f.mu.RLock()
	defer f.mu.RUnlock()
	return f.connected
}

func (f *FakeBroker) SetConnected(connected bool, errStr string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.connected = connected
	f.lastError = errStr
}

func (f *FakeBroker) LastError() string {
	f.mu.RLock()
	defer f.mu.RUnlock()
	return f.lastError
}

func (f *FakeBroker) Publish(topic string, payload []byte) {
	f.mu.RLock()
	h := f.handler
	f.mu.RUnlock()
	if h != nil {
		h(topic, payload)
	}
}

func (f *FakeBroker) Run(ctx context.Context, handler MessageHandler) error {
	f.mu.Lock()
	f.handler = handler
	close(f.runningChan)
	f.mu.Unlock()

	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-f.stopChan:
		return nil
	}
}

func (f *FakeBroker) WaitRunning(ctx context.Context) error {
	select {
	case <-f.runningChan:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func (f *FakeBroker) Close() error {
	f.mu.Lock()
	defer f.mu.Unlock()
	select {
	case <-f.stopChan:
	default:
		close(f.stopChan)
	}
	return nil
}
