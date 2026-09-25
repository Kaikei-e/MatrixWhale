package tc

import (
	"os"
	"path/filepath"
	"testing"

	"wis2_adapter/bufr"
)

func TestExtractStormsRealBUFR(t *testing.T) {
	bufrPath := filepath.Join("..", "bufr", "testdata", "1.bufr")
	data, err := os.ReadFile(bufrPath)
	if err != nil {
		t.Fatalf("failed to read %s: %v", bufrPath, err)
	}

	msgs, errs := bufr.Decode(data)
	if len(msgs) != 16 {
		t.Fatalf("expected 16 messages, got %d", len(msgs))
	}
	for i, err := range errs {
		if err != nil {
			t.Fatalf("decode error in message %d: %v", i, err)
		}
	}

	tracks := ExtractStorms(msgs)
	if len(tracks) == 0 {
		t.Fatalf("expected extracted tracks, got 0")
	}

	// 1. Verify FAY / 06L (Message index 0)
	var fayTrack *StormTrack
	for i := range tracks {
		if tracks[i].StormID == "06L" {
			fayTrack = &tracks[i]
			break
		}
	}

	if fayTrack == nil {
		t.Fatalf("expected to find storm 06L (FAY)")
	}
	if fayTrack.StormName == nil || *fayTrack.StormName != "FAY" {
		t.Errorf("expected storm_name FAY, got %v", fayTrack.StormName)
	}
	if fayTrack.AnalysisTime != "2026-09-25T06:00:00Z" {
		t.Errorf("expected analysis_time 2026-09-25T06:00:00Z, got %s", fayTrack.AnalysisTime)
	}
	if fayTrack.OriginatingCentre != 98 {
		t.Errorf("expected originating_centre 98, got %d", fayTrack.OriginatingCentre)
	}
	if fayTrack.EnsembleMember == nil || *fayTrack.EnsembleMember != 51 {
		t.Errorf("expected ensemble_member 51, got %v", fayTrack.EnsembleMember)
	}

	// Check step 0 of FAY
	if len(fayTrack.Points) == 0 {
		t.Fatalf("expected points for FAY, got 0")
	}
	p0 := fayTrack.Points[0]
	if p0.LeadHours != 0 {
		t.Errorf("expected lead_hours 0 for first point, got %d", p0.LeadHours)
	}
	if p0.Time != "2026-09-25T06:00:00Z" {
		t.Errorf("expected time 2026-09-25T06:00:00Z for first point, got %s", p0.Time)
	}
	if p0.Lat != 29.8 || p0.Lon != -42.6 {
		t.Errorf("expected centre lat/lon (29.8, -42.6), got (%f, %f)", p0.Lat, p0.Lon)
	}
	if p0.MSLPPa == nil || *p0.MSLPPa != 101100.0 {
		t.Errorf("expected mslp_pa 101100.0, got %v", p0.MSLPPa)
	}
	if p0.MaxWindMS == nil || *p0.MaxWindMS != 14.4 {
		t.Errorf("expected max_wind_ms 14.4, got %v", p0.MaxWindMS)
	}
	if p0.MaxWindLat == nil || *p0.MaxWindLat != 30.2 {
		t.Errorf("expected max_wind_lat 30.2, got %v", p0.MaxWindLat)
	}
	if p0.MaxWindLon == nil || *p0.MaxWindLon != -41.7 {
		t.Errorf("expected max_wind_lon -41.7, got %v", p0.MaxWindLon)
	}

	// Wind radii at step 0
	if len(p0.WindRadii) != 3 {
		t.Fatalf("expected 3 wind radii thresholds at step 0, got %d", len(p0.WindRadii))
	}
	if p0.WindRadii[0].ThresholdMS != 18.0 {
		t.Errorf("expected threshold 18.0, got %f", p0.WindRadii[0].ThresholdMS)
	}
	for q := 0; q < 4; q++ {
		if p0.WindRadii[0].RadiiM[q] == nil || *p0.WindRadii[0].RadiiM[q] != 0.0 {
			t.Errorf("expected radius 0.0 at quadrant %d, got %v", q, p0.WindRadii[0].RadiiM[q])
		}
	}

	// 2. Verify numbered storm (e.g. 70W)
	var numberedTrack *StormTrack
	for i := range tracks {
		if tracks[i].StormID == "70W" {
			numberedTrack = &tracks[i]
			break
		}
	}

	if numberedTrack == nil {
		t.Logf("Track IDs found: ")
		for _, tr := range tracks {
			name := "nil"
			if tr.StormName != nil {
				name = *tr.StormName
			}
			t.Logf(" - storm_id=%s, storm_name=%s, points=%d", tr.StormID, name, len(tr.Points))
		}
		t.Fatalf("expected to find numbered storm 70W")
	}

	if numberedTrack.StormName != nil && *numberedTrack.StormName != numberedTrack.StormID {
		t.Errorf("expected numbered storm 70W to have storm_name null or equal to storm_id, got %v", *numberedTrack.StormName)
	}

	// 3. Verify all 16 messages
	for i, msg := range msgs {
		track, ok := ExtractStorm(msg, i)
		if !ok {
			t.Logf("Message %d: no valid storm track extracted", i)
			continue
		}

		if track.MessageIndex != i {
			t.Errorf("msg %d: expected message_index %d, got %d", i, i, track.MessageIndex)
		}
		if track.StormID == "" {
			t.Errorf("msg %d: empty storm_id", i)
		}
		if len(track.Points) == 0 {
			t.Errorf("msg %d: expected points > 0", i)
		}

		// Verify every point has valid lat/lon and RFC3339 time
		for ptIdx, pt := range track.Points {
			if pt.Time == "" {
				t.Errorf("msg %d pt %d: empty time", i, ptIdx)
			}
			if len(pt.WindRadii) > 0 {
				for rIdx, r := range pt.WindRadii {
					if r.ThresholdMS <= 0 {
						t.Errorf("msg %d pt %d radii %d: invalid threshold %f", i, ptIdx, rIdx, r.ThresholdMS)
					}
				}
			}
		}

		// Count steps with valid centres in msg to ensure points count matches
		validCentres := countValidCentreSteps(msg)
		if len(track.Points) != validCentres {
			t.Errorf("msg %d (storm %s): expected %d points with valid centres, got %d",
				i, track.StormID, validCentres, len(track.Points))
		}
	}
}

// countValidCentreSteps inspects the message raw values and counts how many steps had valid centre lat/lon
func countValidCentreSteps(msg bufr.Message) int {
	if len(msg.Subsets) == 0 {
		return 0
	}
	values := msg.Subsets[0]

	steps := 0
	stepStarted := false
	currSig := 0
	var cLat, cLon *float64

	flush := func() {
		if stepStarted && cLat != nil && cLon != nil {
			steps++
		}
		cLat = nil
		cLon = nil
	}

	for _, v := range values {
		switch v.Descriptor.Code() {
		case 4024:
			flush()
			stepStarted = true
			currSig = 0
		case 8005:
			if !stepStarted {
				stepStarted = true
			}
			if v.Float != nil {
				currSig = int(*v.Float)
			}
		case 5002:
			if currSig == 1 {
				cLat = v.Float
			}
		case 6002:
			if currSig == 1 {
				cLon = v.Float
			}
		}
	}
	flush()
	return steps
}
