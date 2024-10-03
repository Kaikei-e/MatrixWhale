package adapter

import (
	"bytes"
	"compress/gzip"
	"log/slog"
	"net/http"
	"net/url"
)

const MatrixWhaleURL = "http://matrix_whale:6000/api/v1"

func MatrixWhaleAdapter(geoData string) error {
	targetAPIEndpoint, err := url.JoinPath(MatrixWhaleURL, "noaa_data", "send")
	if err != nil {
		slog.Error("Error joining URL path", "error", err)
		panic(err)
	}

	sendData := []byte(geoData)

	var buf bytes.Buffer
	gzipWriter := gzip.NewWriter(&buf)

	slog.Info("Sending data to Matrix Whale", "data size, unit is byte", len(sendData))

	_, err = gzipWriter.Write(sendData)
	if err != nil {
		slog.Error("Error writing data to gzip", "error", err)
		return err
	}

	if err := gzipWriter.Close(); err != nil {
		slog.Error("Error closing gzip writer", "error", err)
		return err
	}

	req, err := http.NewRequest("POST", targetAPIEndpoint, &buf)
	if err != nil {
		slog.Error("Error creating request", "error", err)
		return err
	}

	req.Header.Set("Content-Encoding", "gzip")

	client := &http.Client{}
	resp, err := client.Do(req)
	if err != nil {
		slog.Error("Error sending data to Matrix Whale", "error", err)
		return err
	}

	defer resp.Body.Close()

	slog.Info("Matrix Whale response", "status", resp.Status)
	if resp.StatusCode != http.StatusOK {
		slog.Error("Matrix Whale response status is not OK", "status", resp.Status)
		return err
	}

	return nil
}
