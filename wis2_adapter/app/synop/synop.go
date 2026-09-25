package synop

import (
	"fmt"
	"math"
	"strings"
	"time"

	"wis2_adapter/bufr"
)

type PrecipItem struct {
	PeriodH float64 `json:"period_h"`
	MM      float64 `json:"mm"`
}

type ObservationFeature struct {
	DataID        string       `json:"data_id"`
	CentreID      string       `json:"centre_id"`
	PubTime       string       `json:"pubtime"`
	StationID     string       `json:"station_id"`
	StationName   *string      `json:"station_name"`
	Lat           float64      `json:"lat"`
	Lon           float64      `json:"lon"`
	ElevationM    *float64     `json:"elevation_m"`
	ObservedAt    string       `json:"observed_at"`
	WindSpeedMS   *float64     `json:"wind_speed_ms"`
	GustMS        *float64     `json:"gust_ms"`
	GustPeriodMin *int         `json:"gust_period_min"`
	Precip        []PrecipItem `json:"precip"`
	MSLPPa        *float64     `json:"mslp_pa"`
}

// ExtractObservations extracts valid observation features from a BUFR message.
// Each subset in the message corresponds to one station observation.
// Subsets without valid lat/lon/time/station_id are rejected.
// Returns the extracted features and the slice of rejection reasons for rejected subsets.
func ExtractObservations(msg bufr.Message, dataID, centreID, pubTime string) (features []ObservationFeature, rejections []string) {
	for _, subset := range msg.Subsets {
		feat, reason, ok := ExtractObservationWithReason(subset, dataID, centreID, pubTime)
		if !ok {
			rejections = append(rejections, reason)
			continue
		}
		features = append(features, *feat)
	}
	return features, rejections
}

// ExtractObservation extracts a single observation feature from a slice of BUFR values (one subset).
// Returns (feat, true) if valid, or (nil, false) if rejected due to missing lat/lon/time/station_id.
func ExtractObservation(values []bufr.Value, dataID, centreID, pubTime string) (*ObservationFeature, bool) {
	feat, _, ok := ExtractObservationWithReason(values, dataID, centreID, pubTime)
	return feat, ok
}

// ExtractObservationWithReason extracts a single observation feature and returns the rejection reason if invalid.
// Rejection reasons are: "missing_station_id", "missing_coordinates", "missing_time".
func ExtractObservationWithReason(values []bufr.Value, dataID, centreID, pubTime string) (*ObservationFeature, string, bool) {
	var (
		wigosSeries  *int
		wigosIssuer  *int
		wigosIssueNo *int
		wigosLocal   *string
		block        *int
		station      *int
		stationName  *string

		lat       *float64
		lon       *float64
		elevation *float64

		year   *int
		month  *int
		day    *int
		hour   *int
		minute *int
		second *int

		recentPeriodMin *int
		recentPeriodH   *float64

		mslpPa      *float64
		windSpeedMS *float64

		gustMS        *float64
		gustPeriodMin *int

		precip            []PrecipItem
		seenPrecipPeriods = make(map[float64]bool)
	)

	for _, v := range values {
		code := v.Descriptor.Code()

		switch code {
		// WIGOS identifier components: 0 01 125..128
		case 1125:
			if v.Float != nil {
				val := int(math.Round(*v.Float))
				wigosSeries = &val
			}
		case 1126:
			if v.Float != nil {
				val := int(math.Round(*v.Float))
				wigosIssuer = &val
			}
		case 1127:
			if v.Float != nil {
				val := int(math.Round(*v.Float))
				wigosIssueNo = &val
			}
		case 1128:
			var s string
			if v.String != nil {
				s = strings.TrimSpace(*v.String)
			} else if v.Float != nil {
				s = fmt.Sprintf("%d", int(math.Round(*v.Float)))
			}
			if s != "" {
				wigosLocal = &s
			}

		// Traditional block and station numbers: 0 01 001, 0 01 002
		case 1001:
			if v.Float != nil {
				val := int(math.Round(*v.Float))
				block = &val
			}
		case 1002:
			if v.Float != nil {
				val := int(math.Round(*v.Float))
				station = &val
			}

		// Station name: 0 01 015 or 0 01 019
		case 1015, 1019:
			if stationName == nil && v.String != nil {
				trimmed := strings.TrimSpace(*v.String)
				if trimmed != "" {
					stationName = &trimmed
				}
			}

		// Position: latitude 0 05 001 / 0 05 002, longitude 0 06 001 / 0 06 002
		case 5001:
			if lat == nil && v.Float != nil {
				lat = v.Float
			}
		case 5002:
			if lat == nil && v.Float != nil {
				lat = v.Float
			}
		case 6001:
			if lon == nil && v.Float != nil {
				lon = v.Float
			}
		case 6002:
			if lon == nil && v.Float != nil {
				lon = v.Float
			}

		// Elevation: 0 07 030 / 0 07 001
		case 7030:
			if elevation == nil && v.Float != nil {
				elevation = v.Float
			}
		case 7001:
			if elevation == nil && v.Float != nil {
				elevation = v.Float
			}

		// Time: 0 04 001..006
		case 4001:
			if v.Float != nil {
				val := int(math.Round(*v.Float))
				year = &val
			}
		case 4002:
			if v.Float != nil {
				val := int(math.Round(*v.Float))
				month = &val
			}
		case 4003:
			if v.Float != nil {
				val := int(math.Round(*v.Float))
				day = &val
			}
		case 4004:
			if v.Float != nil {
				val := int(math.Round(*v.Float))
				hour = &val
			}
		case 4005:
			if v.Float != nil {
				val := int(math.Round(*v.Float))
				minute = &val
			}
		case 4006:
			if v.Float != nil {
				val := int(math.Round(*v.Float))
				second = &val
			}

		// Time periods: 0 04 024 (hours), 0 04 025 (minutes)
		// Track the most recent time-period descriptor to attach periods.
		// Values missing -> null (resets recent period).
		case 4024:
			if v.Float != nil {
				h := math.Abs(*v.Float)
				recentPeriodH = &h
				m := int(math.Round(h * 60))
				recentPeriodMin = &m
			} else {
				recentPeriodH = nil
				recentPeriodMin = nil
			}
		case 4025:
			if v.Float != nil {
				mFlt := math.Abs(*v.Float)
				m := int(math.Round(mFlt))
				recentPeriodMin = &m
				h := mFlt / 60.0
				recentPeriodH = &h
			} else {
				recentPeriodH = nil
				recentPeriodMin = nil
			}

		// MSLP: 0 10 051
		case 10051:
			if mslpPa == nil && v.Float != nil {
				mslpPa = v.Float
			}

		// Mean wind: 0 11 002 (or 0 11 012)
		case 11002, 11012:
			if windSpeedMS == nil && v.Float != nil {
				windSpeedMS = v.Float
			}

		// Gust speed: 0 11 041
		case 11041:
			if v.Float != nil {
				spd := *v.Float
				if gustMS == nil || spd > *gustMS {
					gustMS = &spd
					gustPeriodMin = recentPeriodMin
				}
			}

		// Precipitation 24h: 0 13 023 -> period 24
		case 13023:
			if v.Float != nil {
				if !seenPrecipPeriods[24.0] {
					seenPrecipPeriods[24.0] = true
					precip = append(precip, PrecipItem{PeriodH: 24.0, MM: *v.Float})
				}
			}

		// Precipitation with period: 0 13 011 preceded by time period
		case 13011:
			if v.Float != nil && recentPeriodH != nil && *recentPeriodH > 0 {
				pH := math.Round(*recentPeriodH*1000) / 1000
				if !seenPrecipPeriods[pH] {
					seenPrecipPeriods[pH] = true
					precip = append(precip, PrecipItem{PeriodH: pH, MM: *v.Float})
				}
			}
		}
	}

	// 1. Station ID: WIGOS id takes precedence; else block+station
	var stationID string
	if wigosSeries != nil && wigosIssuer != nil && wigosIssueNo != nil && wigosLocal != nil && *wigosLocal != "" {
		stationID = fmt.Sprintf("%d-%d-%d-%s", *wigosSeries, *wigosIssuer, *wigosIssueNo, *wigosLocal)
	} else if block != nil && station != nil {
		stationID = fmt.Sprintf("0-20000-0-%02d%03d", *block, *station)
	}
	if stationID == "" {
		return nil, "missing_station_id", false
	}

	// 2. Position: lat & lon are required
	if lat == nil || lon == nil {
		return nil, "missing_coordinates", false
	}

	// 3. Time: year, month, day, hour, minute are required
	if year == nil || month == nil || day == nil || hour == nil || minute == nil {
		return nil, "missing_time", false
	}
	sec := 0
	if second != nil {
		sec = *second
	}
	if *month < 1 || *month > 12 || *day < 1 || *day > 31 || *hour < 0 || *hour > 23 || *minute < 0 || *minute > 59 || sec < 0 || sec > 59 {
		return nil, "missing_time", false
	}

	observedAt := time.Date(*year, time.Month(*month), *day, *hour, *minute, sec, 0, time.UTC).Format(time.RFC3339)

	if precip == nil {
		precip = []PrecipItem{}
	}

	return &ObservationFeature{
		DataID:        dataID,
		CentreID:      centreID,
		PubTime:       pubTime,
		StationID:     stationID,
		StationName:   stationName,
		Lat:           *lat,
		Lon:           *lon,
		ElevationM:    elevation,
		ObservedAt:    observedAt,
		WindSpeedMS:   windSpeedMS,
		GustMS:        gustMS,
		GustPeriodMin: gustPeriodMin,
		Precip:        precip,
		MSLPPa:        mslpPa,
	}, "", true
}
