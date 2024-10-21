package adapter

import (
	"bytes"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"strconv"
	"strings"
)

const MatrixWhaleURL = "http://matrix_whale:6000/api/v1"

func MatrixWhaleAdapter(geoData string) error {
	// unescape the geoData string
	unescapedData := strings.ReplaceAll(geoData, "\n", " ")

	// err := os.WriteFile("unescapedData.json", []byte(unescapedData), 0644)
	// if err != nil {
	// 	slog.Error("Error writing unescaped data to file: " + err.Error())
	// 	return err
	// }

	targetAPIEndpoint, err := url.JoinPath(MatrixWhaleURL, "noaa_data", "send")
	if err != nil {
		slog.Error("Error joining URL path. " + err.Error())
		return err
	}

	req, err := http.NewRequest("POST", targetAPIEndpoint, bytes.NewBuffer([]byte(unescapedData)))
	if err != nil {
		slog.Error("Error creating request is " + err.Error())
		return err
	}

	slog.Info("Sending data to Matrix Whale. Data size, unit is byte: " + strconv.Itoa(len([]byte(unescapedData))))

	req.Header.Set("Content-Type", "application/json")

	client := &http.Client{}
	resp, err := client.Do(req)
	if err != nil {
		slog.Error("Error sending request to Matrix Whale" + err.Error())
		return err
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		slog.Error("Error reading response body: " + err.Error())
		return err
	}

	slog.Info("Matrix Whale response status is " + resp.Status)
	slog.Info("Matrix Whale response is " + string(body))

	return nil
}
