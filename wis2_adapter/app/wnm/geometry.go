package wnm

import (
	"encoding/json"
	"strings"
)

type MultiPolygonGeometry struct {
	Type        string          `json:"type"`
	Coordinates [][][][]float64 `json:"coordinates"`
}

type rawGeoJSON struct {
	Type        string          `json:"type"`
	Coordinates json.RawMessage `json:"coordinates,omitempty"`
	Geometry    json.RawMessage `json:"geometry,omitempty"`
	Features    []rawGeoJSON    `json:"features,omitempty"`
}

func FlattenToMultiPolygon(data []byte) (*MultiPolygonGeometry, error) {
	var root rawGeoJSON
	if err := json.Unmarshal(data, &root); err != nil {
		return nil, err
	}

	var allPolygons [][][][]float64

	switch strings.ToLower(root.Type) {
	case "featurecollection":
		for _, feat := range root.Features {
			extractGeometry(feat.Geometry, &allPolygons)
		}
	case "feature":
		extractGeometry(root.Geometry, &allPolygons)
	case "polygon":
		var poly [][][]float64
		if err := json.Unmarshal(root.Coordinates, &poly); err == nil && len(poly) > 0 {
			allPolygons = append(allPolygons, poly)
		}
	case "multipolygon":
		var mpoly [][][][]float64
		if err := json.Unmarshal(root.Coordinates, &mpoly); err == nil && len(mpoly) > 0 {
			allPolygons = append(allPolygons, mpoly...)
		}
	}

	if len(allPolygons) == 0 {
		return nil, nil
	}

	return &MultiPolygonGeometry{
		Type:        "MultiPolygon",
		Coordinates: allPolygons,
	}, nil
}

func extractGeometry(raw json.RawMessage, allPolygons *[][][][]float64) {
	if len(raw) == 0 {
		return
	}
	var geom rawGeoJSON
	if err := json.Unmarshal(raw, &geom); err != nil {
		return
	}

	switch strings.ToLower(geom.Type) {
	case "polygon":
		var poly [][][]float64
		if err := json.Unmarshal(geom.Coordinates, &poly); err == nil && len(poly) > 0 {
			*allPolygons = append(*allPolygons, poly)
		}
	case "multipolygon":
		var mpoly [][][][]float64
		if err := json.Unmarshal(geom.Coordinates, &mpoly); err == nil && len(mpoly) > 0 {
			*allPolygons = append(*allPolygons, mpoly...)
		}
	}
}
