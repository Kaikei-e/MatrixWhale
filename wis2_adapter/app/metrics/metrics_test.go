package metrics

import "testing"

func TestMetricsRecord(t *testing.T) {
	RecordMessage("warnings")
	RecordDuplicate("warnings")
	RecordDownload("payload", "success")
	RecordDownload("payload", "failed")
	RecordDownload("payload", "integrity_failed")
	RecordDownload("geometry", "success")
	RecordDownload("geometry", "failed")
	RecordDrop("inbound")
	RecordDrop("observations")
	SetBrokerConnected(true)
	SetBrokerInfo("mqtts://broker:8883", "matrixwhale-1234")
	SetBrokerConnected(false)
}
