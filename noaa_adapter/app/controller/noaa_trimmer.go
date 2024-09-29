package controller

import (
	"encoding/json"
	"log/slog"
	"noaa_adapter/model"
)

func TrimNoaaData(data string) (string, error) {
	var noaaData model.Alerts

	err := json.Unmarshal([]byte(data), &noaaData)
	if err != nil {
		slog.Error("Error unmarshalling data", "error", err)
		return "", err
	}

	var trimmedNoaaData model.Features

	trimmedNoaaData.Element = noaaData.Features

	jsonData, err := json.Marshal(trimmedNoaaData)
	if err != nil {
		slog.Error("Error marshalling data", "error", err)
		return "", err
	}

	return string(jsonData), nil
}
