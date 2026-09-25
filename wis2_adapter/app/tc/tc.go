package tc

import (
	"math"
	"strings"
	"time"

	"wis2_adapter/bufr"
)

type WindRadii struct {
	ThresholdMS float64     `json:"threshold_ms"`
	RadiiM      [4]*float64 `json:"radii_m"`
}

type ForecastPoint struct {
	LeadHours  int         `json:"lead_hours"`
	Time       string      `json:"time"`
	Lat        float64     `json:"lat"`
	Lon        float64     `json:"lon"`
	MSLPPa     *float64    `json:"mslp_pa"`
	MaxWindMS  *float64    `json:"max_wind_ms"`
	MaxWindLat *float64    `json:"max_wind_lat"`
	MaxWindLon *float64    `json:"max_wind_lon"`
	WindRadii  []WindRadii `json:"wind_radii"`
}

type StormTrack struct {
	MessageIndex      int             `json:"message_index"`
	OriginatingCentre int             `json:"originating_centre"`
	StormID           string          `json:"storm_id"`
	StormName         *string         `json:"storm_name"`
	EnsembleMember    *int            `json:"ensemble_member"`
	AnalysisTime      string          `json:"analysis_time"`
	Points            []ForecastPoint `json:"points"`
}

// ExtractStorms processes a list of decoded BUFR messages and returns valid storm tracks.
// Storms with no valid forecast points are omitted.
func ExtractStorms(messages []bufr.Message) []StormTrack {
	var tracks []StormTrack
	for i, msg := range messages {
		if track, ok := ExtractStorm(msg, i); ok {
			tracks = append(tracks, *track)
		}
	}
	return tracks
}

// ExtractStorm extracts a single storm track from a BUFR message (template 3 16 082).
// Returns (track, true) if the message contains a valid storm track with at least one point,
// or (nil, false) otherwise.
func ExtractStorm(msg bufr.Message, messageIndex int) (*StormTrack, bool) {
	if len(msg.Subsets) == 0 || len(msg.Subsets[0]) == 0 {
		return nil, false
	}
	values := msg.Subsets[0]

	var (
		stormID        string
		stormName      *string
		ensembleMember *int

		year, month, day, hour, minute, second int
		hasYear, hasMonth, hasDay              bool

		points []ForecastPoint

		// State markers & current point tracking
		stepStarted      bool
		leadHours        int
		currSignificance int // 0 08 005 (1=centre, 5=pressure, 3=max wind)

		centreLat *float64
		centreLon *float64
		mslpPa    *float64

		maxWindLat *float64
		maxWindLon *float64
		maxWindMS  *float64

		windRadii               []WindRadii
		currThreshold           *float64
		currRadii               [4]*float64
		bearingsSinceLastRadius []float64
		fallbackQuadrantIdx     int
	)

	flushWindRadiiThreshold := func() {
		if currThreshold != nil {
			windRadii = append(windRadii, WindRadii{
				ThresholdMS: *currThreshold,
				RadiiM:      currRadii,
			})
			currThreshold = nil
			currRadii = [4]*float64{nil, nil, nil, nil}
			bearingsSinceLastRadius = nil
			fallbackQuadrantIdx = 0
		}
	}

	flushPoint := func() {
		if !stepStarted {
			return
		}
		flushWindRadiiThreshold()

		// Omit points where centre lat or lon is missing
		if centreLat != nil && centreLon != nil && hasYear && hasMonth && hasDay {
			analysisTime := time.Date(year, time.Month(month), day, hour, minute, second, 0, time.UTC)
			ptTime := analysisTime.Add(time.Duration(leadHours) * time.Hour).UTC().Format(time.RFC3339)

			radiiList := windRadii
			if radiiList == nil {
				radiiList = []WindRadii{}
			}

			points = append(points, ForecastPoint{
				LeadHours:  leadHours,
				Time:       ptTime,
				Lat:        *centreLat,
				Lon:        *centreLon,
				MSLPPa:     mslpPa,
				MaxWindMS:  maxWindMS,
				MaxWindLat: maxWindLat,
				MaxWindLon: maxWindLon,
				WindRadii:  radiiList,
			})
		}

		// Reset point fields
		centreLat = nil
		centreLon = nil
		mslpPa = nil
		maxWindLat = nil
		maxWindLon = nil
		maxWindMS = nil
		windRadii = nil
		currThreshold = nil
		currRadii = [4]*float64{nil, nil, nil, nil}
		bearingsSinceLastRadius = nil
		fallbackQuadrantIdx = 0
	}

	for _, v := range values {
		code := v.Descriptor.Code()

		switch code {
		case 1025: // 0 01 025: stormIdentifier
			if v.String != nil {
				stormID = strings.TrimSpace(*v.String)
			}
		case 1027: // 0 01 027: longStormName
			if v.String != nil {
				s := strings.TrimSpace(*v.String)
				if s != "" {
					stormName = &s
				}
			}
		case 1091: // 0 01 091: ensembleMemberNumber
			if v.Float != nil {
				em := int(math.Round(*v.Float))
				ensembleMember = &em
			}
		case 4001: // 0 04 001: year
			if v.Float != nil {
				year = int(math.Round(*v.Float))
				hasYear = true
			}
		case 4002: // 0 04 002: month
			if v.Float != nil {
				month = int(math.Round(*v.Float))
				hasMonth = true
			}
		case 4003: // 0 04 003: day
			if v.Float != nil {
				day = int(math.Round(*v.Float))
				hasDay = true
			}
		case 4004: // 0 04 004: hour
			if v.Float != nil {
				hour = int(math.Round(*v.Float))
			}
		case 4005: // 0 04 005: minute
			if v.Float != nil {
				minute = int(math.Round(*v.Float))
			}
		case 4006: // 0 04 006: second
			if v.Float != nil {
				second = int(math.Round(*v.Float))
			}

		case 4024: // 0 04 024: timePeriod (hours) -> marks transition to a new forecast step
			flushPoint()
			stepStarted = true
			if v.Float != nil {
				leadHours = int(math.Round(*v.Float))
			}
			currSignificance = 0

		case 8005: // 0 08 005: meteorologicalAttributeSignificance
			if !stepStarted {
				// Step 0 begins with the first 0 08 005 before any 0 04 024
				stepStarted = true
				leadHours = 0
			}
			if v.Float != nil {
				currSignificance = int(math.Round(*v.Float))
			}

		case 5002: // 0 05 002: latitude
			switch currSignificance {
			case 1:
				centreLat = v.Float
			case 3:
				maxWindLat = v.Float
			}

		case 6002: // 0 06 002: longitude
			switch currSignificance {
			case 1:
				centreLon = v.Float
			case 3:
				maxWindLon = v.Float
			}

		case 10051: // 0 10 051: pressureReducedToMeanSeaLevel (MSLP Pa)
			// At step 0, central pressure is under significance 5; in forecast steps, under significance 1
			if currSignificance == 1 || currSignificance == 5 {
				mslpPa = v.Float
			}

		case 11012: // 0 11 012: windSpeedAt10M
			if currSignificance == 3 {
				maxWindMS = v.Float
			}

		case 19003: // 0 19 003: windSpeedThreshold
			flushWindRadiiThreshold()
			if v.Float != nil {
				currThreshold = v.Float
			}

		case 5021: // 0 05 021: bearingOrAzimuth
			if v.Float != nil {
				bearingsSinceLastRadius = append(bearingsSinceLastRadius, *v.Float)
			}

		case 19004: // 0 19 004: effectiveRadiusWithRespectToWindSpeedsAboveThreshold
			q := mapQuadrant(bearingsSinceLastRadius)
			if q < 0 || q > 3 {
				q = fallbackQuadrantIdx % 4
			}
			fallbackQuadrantIdx = (q + 1) % 4
			currRadii[q] = v.Float
			bearingsSinceLastRadius = nil
		}
	}

	// Flush the final point
	flushPoint()

	if stormID == "" || len(points) == 0 || !hasYear || !hasMonth || !hasDay {
		return nil, false
	}

	analysisTime := time.Date(year, time.Month(month), day, hour, minute, second, 0, time.UTC)
	centre := msg.Centre
	if centre == 0 {
		centre = 98 // Default ECMWF
	}

	track := &StormTrack{
		MessageIndex:      messageIndex,
		OriginatingCentre: centre,
		StormID:           stormID,
		StormName:         stormName,
		EnsembleMember:    ensembleMember,
		AnalysisTime:      analysisTime.Format(time.RFC3339),
		Points:            points,
	}

	return track, true
}

// mapQuadrant maps bearing(s) to a quadrant index:
// 0: NE (0..90 deg, midpoint 45)
// 1: SE (90..180 deg, midpoint 135)
// 2: SW (180..270 deg, midpoint 225)
// 3: NW (270..360 deg, midpoint 315)
func mapQuadrant(bearings []float64) int {
	if len(bearings) >= 2 {
		b1 := normalizeDeg(bearings[len(bearings)-2])
		b2 := normalizeDeg(bearings[len(bearings)-1])
		// Handle 270 -> 0 wrap-around
		if b1 > b2 && (b2 == 0 || b2 < 90) {
			b2 += 360
		}
		mid := (b1 + b2) / 2.0
		return azimuthToQuadrant(normalizeDeg(mid))
	}
	if len(bearings) == 1 {
		b := normalizeDeg(bearings[0])
		// Exact quadrant starting points
		if b == 0 {
			return 0 // NE [0..90]
		}
		if b == 90 {
			return 1 // SE [90..180]
		}
		if b == 180 {
			return 2 // SW [180..270]
		}
		if b == 270 {
			return 3 // NW [270..360]
		}
		return azimuthToQuadrant(b)
	}
	return -1
}

func normalizeDeg(deg float64) float64 {
	for deg >= 360 {
		deg -= 360
	}
	for deg < 0 {
		deg += 360
	}
	return deg
}

func azimuthToQuadrant(deg float64) int {
	if deg >= 0 && deg < 90 {
		return 0
	}
	if deg >= 90 && deg < 180 {
		return 1
	}
	if deg >= 180 && deg < 270 {
		return 2
	}
	if deg >= 270 && deg < 360 {
		return 3
	}
	return -1
}
