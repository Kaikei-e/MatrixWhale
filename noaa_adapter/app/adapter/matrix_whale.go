package adapter

import (
	"bytes"
	"fmt"
	"log/slog"
	"net/http"
	"net/url"
	"strings"
)

const MatrixWhaleURL = "http://matrix_whale:6000/api/v1"

func MatrixWhaleAdapter(geoData string) error {
	// unescape the geoData string
	unescapedData := strings.ReplaceAll(geoData, "\\", "")
	unescapedData = strings.ReplaceAll(unescapedData, `\\`, ``)

	fmt.Println(unescapedData[0:100])

	targetAPIEndpoint, err := url.JoinPath(MatrixWhaleURL, "noaa_data", "send")
	if err != nil {
		slog.Error("Error joining URL path", "error", err)
		return err
	}

	req, err := http.NewRequest("POST", targetAPIEndpoint, bytes.NewBuffer([]byte(unescapedData)))
	if err != nil {
		slog.Error("Error creating request", "error", err)
		return err
	}

	slog.Info("Sending data to Matrix Whale", "data size, unit is byte", len([]byte(unescapedData)))

	req.Header.Set("Content-Type", "application/json")

	client := &http.Client{}
	resp, err := client.Do(req)
	if err != nil {
		slog.Error("Error sending request", "error", err)
		return err
	}
	defer resp.Body.Close()

	slog.Info("Matrix Whale response", "status", resp.Status)

	return nil
}
