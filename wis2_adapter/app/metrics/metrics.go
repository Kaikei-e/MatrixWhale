package metrics

import (
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
)

var (
	MessagesTotal = promauto.NewCounterVec(
		prometheus.CounterOpts{
			Name: "matrixwhale_wis2_messages_total",
			Help: "Total WIS2 messages received by kind.",
		},
		[]string{"kind"},
	)

	DuplicatesTotal = promauto.NewCounterVec(
		prometheus.CounterOpts{
			Name: "matrixwhale_wis2_duplicates_total",
			Help: "Total duplicate WIS2 messages dropped by kind.",
		},
		[]string{"kind"},
	)

	DownloadsTotal = promauto.NewCounterVec(
		prometheus.CounterOpts{
			Name: "matrixwhale_wis2_downloads_total",
			Help: "Total downloads by target and result.",
		},
		[]string{"target", "result"},
	)

	BrokerConnected = promauto.NewGauge(
		prometheus.GaugeOpts{
			Name: "matrixwhale_wis2_broker_connected",
			Help: "WIS2 MQTT broker connection status (1 if connected, 0 otherwise).",
		},
	)

	BrokerInfo = promauto.NewGaugeVec(
		prometheus.GaugeOpts{
			Name: "matrixwhale_wis2_broker_info",
			Help: "Information about the currently connected WIS2 broker.",
		},
		[]string{"broker", "client_id"},
	)
)

func RecordMessage(kind string) {
	MessagesTotal.WithLabelValues(kind).Inc()
}

func RecordDuplicate(kind string) {
	DuplicatesTotal.WithLabelValues(kind).Inc()
}

func RecordDownload(target, result string) {
	DownloadsTotal.WithLabelValues(target, result).Inc()
}

func SetBrokerConnected(connected bool) {
	if connected {
		BrokerConnected.Set(1)
	} else {
		BrokerConnected.Set(0)
	}
}

func SetBrokerInfo(broker, clientID string) {
	BrokerInfo.Reset()
	BrokerInfo.WithLabelValues(broker, clientID).Set(1)
}
