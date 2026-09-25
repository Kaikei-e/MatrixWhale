package broker

import (
	"context"
	"crypto/rand"
	"crypto/tls"
	"encoding/hex"
	"fmt"
	"log/slog"
	"net/url"
	"sync"
	"time"

	"github.com/eclipse/paho.golang/autopaho"
	"github.com/eclipse/paho.golang/paho"

	"wis2_adapter/config"
	wis2metrics "wis2_adapter/metrics"
)

type MessageHandler func(topic string, payload []byte)

type Broker interface {
	Run(ctx context.Context, handler MessageHandler) error
	CurrentBroker() string
	IsConnected() bool
	LastError() string
	Close() error
}

func RandomClientID() string {
	b := make([]byte, 4)
	if _, err := rand.Read(b); err != nil {
		return fmt.Sprintf("matrixwhale-%x", time.Now().UnixNano())
	}
	return fmt.Sprintf("matrixwhale-%s", hex.EncodeToString(b))
}

type MQTTBroker struct {
	cfg       config.Config
	rotator   *Rotator
	clientID  string
	mu        sync.RWMutex
	connected bool
	lastError string
	connMgr   *autopaho.ConnectionManager
	closed    bool
}

func NewMQTTBroker(cfg config.Config) *MQTTBroker {
	return &MQTTBroker{
		cfg:      cfg,
		rotator:  NewRotator(cfg.Brokers, 1*time.Second, 30*time.Second, 500*time.Millisecond),
		clientID: RandomClientID(),
	}
}

func (b *MQTTBroker) CurrentBroker() string {
	return b.rotator.Current()
}

func (b *MQTTBroker) IsConnected() bool {
	b.mu.RLock()
	defer b.mu.RUnlock()
	return b.connected
}

func (b *MQTTBroker) LastError() string {
	b.mu.RLock()
	defer b.mu.RUnlock()
	return b.lastError
}

func (b *MQTTBroker) setConnected(connected bool, errStr string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.connected = connected
	b.lastError = errStr
}

func (b *MQTTBroker) Close() error {
	b.mu.Lock()
	b.closed = true
	cm := b.connMgr
	b.mu.Unlock()

	if cm != nil {
		return cm.Disconnect(context.Background())
	}
	return nil
}

func (b *MQTTBroker) Run(ctx context.Context, handler MessageHandler) error {
	for {
		if ctx.Err() != nil {
			return ctx.Err()
		}

		b.mu.RLock()
		closed := b.closed
		b.mu.RUnlock()
		if closed {
			return nil
		}

		currentURL := b.rotator.Current()
		slog.Info("Connecting to WIS2 broker", "broker", currentURL, "client_id", b.clientID)

		cm, err := b.connectOne(ctx, currentURL, handler)
		if err != nil {
			b.setConnected(false, err.Error())
			wis2metrics.SetBrokerConnected(false)
			nextBroker, delay := b.rotator.Rotate()
			slog.Warn("Failed to connect to broker, rotating",
				"failed_broker", currentURL,
				"error", err,
				"next_broker", nextBroker,
				"backoff", delay)

			timer := time.NewTimer(delay)
			select {
			case <-ctx.Done():
				timer.Stop()
				return ctx.Err()
			case <-timer.C:
			}
			continue
		}

		b.mu.Lock()
		b.connMgr = cm
		b.mu.Unlock()

		b.setConnected(true, "")
		b.rotator.ResetBackoff()
		wis2metrics.SetBrokerConnected(true)
		wis2metrics.SetBrokerInfo(currentURL, b.clientID)

		select {
		case <-ctx.Done():
			_ = cm.Disconnect(context.Background())
			return ctx.Err()
		case <-cm.Done():
			b.setConnected(false, "connection closed")
			wis2metrics.SetBrokerConnected(false)
			nextBroker, delay := b.rotator.Rotate()
			slog.Warn("Broker connection lost, rotating",
				"lost_broker", currentURL,
				"next_broker", nextBroker,
				"backoff", delay)

			timer := time.NewTimer(delay)
			select {
			case <-ctx.Done():
				timer.Stop()
				return ctx.Err()
			case <-timer.C:
			}
		}
	}
}

func (b *MQTTBroker) connectOne(ctx context.Context, brokerStr string, handler MessageHandler) (*autopaho.ConnectionManager, error) {
	u, err := url.Parse(brokerStr)
	if err != nil {
		return nil, fmt.Errorf("parse broker url: %w", err)
	}

	pahoCfg := paho.ClientConfig{
		ClientID: b.clientID,
		OnPublishReceived: []func(paho.PublishReceived) (bool, error){
			func(pr paho.PublishReceived) (bool, error) {
				handler(pr.Packet.Topic, pr.Packet.Payload)
				return true, nil
			},
		},
		OnClientError: func(err error) {
			slog.Warn("Broker client error", "error", err)
		},
	}

	autoCfg := autopaho.ClientConfig{
		ServerUrls:                    []*url.URL{u},
		TlsCfg:                        &tls.Config{InsecureSkipVerify: false},
		KeepAlive:                     60,
		CleanStartOnInitialConnection: true,
		SessionExpiryInterval:         0,
		ConnectUsername:               b.cfg.Username,
		ConnectPassword:               []byte(b.cfg.Password),
		ConnectTimeout:                10 * time.Second,
		ClientConfig:                  pahoCfg,
		OnConnectionUp: func(cm *autopaho.ConnectionManager, connAck *paho.Connack) {
			slog.Info("Connected to broker, subscribing to topics", "broker", brokerStr)
			var subs []paho.SubscribeOptions
			for _, topic := range b.cfg.Topics {
				subs = append(subs, paho.SubscribeOptions{
					Topic: topic,
					QoS:   1,
				})
			}
			subCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			if _, subErr := cm.Subscribe(subCtx, &paho.Subscribe{Subscriptions: subs}); subErr != nil {
				slog.Error("Failed to subscribe to topics", "error", subErr)
			}
		},
		OnConnectionDown: func() bool {
			// Trigger rotation on connection loss
			return false
		},
		OnConnectError: func(err error) {
			slog.Warn("Broker connect error", "broker", brokerStr, "error", err)
		},
	}

	cm, err := autopaho.NewConnection(ctx, autoCfg)
	if err != nil {
		return nil, fmt.Errorf("new connection: %w", err)
	}

	awaitCtx, cancelAwait := context.WithTimeout(ctx, 10*time.Second)
	defer cancelAwait()

	if err := cm.AwaitConnection(awaitCtx); err != nil {
		_ = cm.Disconnect(context.Background())
		return nil, fmt.Errorf("await connection: %w", err)
	}

	return cm, nil
}
