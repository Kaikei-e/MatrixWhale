package bufr

import (
	"encoding/json"
	"math"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type GoldenElement struct {
	Code int    `json:"code"`
	Name string `json:"name"`
	Unit string `json:"unit"`
	Val  any    `json:"val"`
}

type GoldenMessage struct {
	Edition            int               `json:"edition"`
	MasterTable        int               `json:"master_table"`
	MasterTableVersion int               `json:"master_table_version"`
	LocalTableVersion  int               `json:"local_table_version"`
	Centre             int               `json:"centre"`
	SubCentre          int               `json:"subcentre"`
	DataCategory       int               `json:"data_category"`
	DataSubcategory    int               `json:"data_subcategory"`
	Compressed         bool              `json:"compressed"`
	NumSubsets         int               `json:"num_subsets"`
	Subsets            [][]GoldenElement `json:"subsets"`
}

func compareMessageWithGolden(t *testing.T, msg Message, golden GoldenMessage, msgLabel string) int {
	t.Helper()
	if msg.Edition != golden.Edition {
		t.Fatalf("%s: edition mismatch: got %d, want %d", msgLabel, msg.Edition, golden.Edition)
	}
	if msg.MasterTable != golden.MasterTable {
		t.Errorf("%s: master table mismatch: got %d, want %d", msgLabel, msg.MasterTable, golden.MasterTable)
	}
	if msg.MasterTableVersion != golden.MasterTableVersion {
		t.Errorf("%s: master table version mismatch: got %d, want %d", msgLabel, msg.MasterTableVersion, golden.MasterTableVersion)
	}
	if msg.LocalTableVersion != golden.LocalTableVersion {
		t.Errorf("%s: local table version mismatch: got %d, want %d", msgLabel, msg.LocalTableVersion, golden.LocalTableVersion)
	}
	if msg.Centre != golden.Centre {
		t.Errorf("%s: centre mismatch: got %d, want %d", msgLabel, msg.Centre, golden.Centre)
	}
	if msg.SubCentre != golden.SubCentre {
		t.Errorf("%s: subcentre mismatch: got %d, want %d", msgLabel, msg.SubCentre, golden.SubCentre)
	}
	if msg.DataCategory != golden.DataCategory {
		t.Errorf("%s: data category mismatch: got %d, want %d", msgLabel, msg.DataCategory, golden.DataCategory)
	}
	if msg.DataSubcategory != golden.DataSubcategory {
		t.Errorf("%s: data subcategory mismatch: got %d, want %d", msgLabel, msg.DataSubcategory, golden.DataSubcategory)
	}
	if msg.Compressed != golden.Compressed {
		t.Errorf("%s: compressed mismatch: got %v, want %v", msgLabel, msg.Compressed, golden.Compressed)
	}
	if len(msg.Subsets) != len(golden.Subsets) {
		t.Fatalf("%s: subsets count mismatch: got %d, want %d", msgLabel, len(msg.Subsets), len(golden.Subsets))
	}

	valuesCompared := 0
	for s := range msg.Subsets {
		subsetGot := msg.Subsets[s]
		subsetWant := golden.Subsets[s]
		if len(subsetGot) != len(subsetWant) {
			t.Fatalf("%s subset %d: elements count mismatch: got %d, want %d", msgLabel, s, len(subsetGot), len(subsetWant))
		}

		for i := range subsetGot {
			got := subsetGot[i]
			want := subsetWant[i]
			valuesCompared++

			if got.Descriptor.Code() != want.Code {
				t.Fatalf("%s subset %d elem %d: code mismatch: got %d, want %d (%s)", msgLabel, s, i, got.Descriptor.Code(), want.Code, want.Name)
			}

			if want.Val == nil {
				if got.Float != nil {
					t.Errorf("%s subset %d elem %d (%s, %d): expected missing, got float %f", msgLabel, s, i, got.Name, got.Descriptor.Code(), *got.Float)
				}
				if got.String != nil {
					t.Errorf("%s subset %d elem %d (%s, %d): expected missing, got string %q", msgLabel, s, i, got.Name, got.Descriptor.Code(), *got.String)
				}
			} else if wantFloat, ok := want.Val.(float64); ok {
				if got.Float == nil {
					t.Errorf("%s subset %d elem %d (%s, %d): expected float %f, got nil (missing)", msgLabel, s, i, got.Name, got.Descriptor.Code(), wantFloat)
				} else {
					diff := math.Abs(*got.Float - wantFloat)
					tol := 1e-3
					if math.Abs(wantFloat) > 1e4 {
						tol = 1.0
					}
					if diff > tol {
						t.Errorf("%s subset %d elem %d (%s, %d): float mismatch: got %f, want %f (diff %f)", msgLabel, s, i, got.Name, got.Descriptor.Code(), *got.Float, wantFloat, diff)
					}
				}
			} else if wantStr, ok := want.Val.(string); ok {
				if got.String == nil {
					t.Errorf("%s subset %d elem %d (%s, %d): expected string %q, got nil (missing)", msgLabel, s, i, got.Name, got.Descriptor.Code(), wantStr)
				} else {
					gotTrimmed := strings.TrimSpace(*got.String)
					if gotTrimmed != wantStr {
						t.Errorf("%s subset %d elem %d (%s, %d): string mismatch: got %q, want %q", msgLabel, s, i, got.Name, got.Descriptor.Code(), gotTrimmed, wantStr)
					}
				}
			}
		}
	}
	return valuesCompared
}

func TestTC1Messages(t *testing.T) {
	bufrBytes, err := os.ReadFile(filepath.Join("testdata", "1.bufr"))
	if err != nil {
		t.Fatalf("failed reading 1.bufr: %v", err)
	}

	goldenJSON, err := os.ReadFile(filepath.Join("testdata", "1_golden.json"))
	if err != nil {
		t.Fatalf("failed reading 1_golden.json: %v", err)
	}

	var goldenMsgs []GoldenMessage
	if err := json.Unmarshal(goldenJSON, &goldenMsgs); err != nil {
		t.Fatalf("failed parsing 1_golden.json: %v", err)
	}

	msgs, errs := Decode(bufrBytes)
	if len(msgs) != 16 {
		t.Fatalf("expected 16 messages, got %d", len(msgs))
	}
	for i, err := range errs {
		if err != nil {
			t.Fatalf("message %d decode error: %v", i+1, err)
		}
	}

	totalVals := 0
	for i := range msgs {
		count := compareMessageWithGolden(t, msgs[i], goldenMsgs[i], filepath.Join("1.bufr", string(rune('0'+i+1))))
		totalVals += count
	}
	t.Logf("TC 1.bufr (16 messages): verified %d values against ecCodes golden", totalVals)
}

func TestSynopGoldenMessages(t *testing.T) {
	synopNames := []string{
		"synop_cn_cma",
		"synop_jp_jma",
		"synop_fr_meteofrance",
		"synop_kz_kazhydromet_compressed",
		"synop_by_belgidromet_compressed",
		"synop_br_inmet",
		"synop_uk_metoffice",
		"synop_ru_roshydromet",
		"synop_sg_mss",
	}

	totalVals := 0
	for _, name := range synopNames {
		t.Run(name, func(t *testing.T) {
			bufrPath := filepath.Join("testdata", name+".bufr")
			goldenPath := filepath.Join("testdata", name+"_golden.json")

			bufrBytes, err := os.ReadFile(bufrPath)
			if err != nil {
				t.Fatalf("failed reading %s: %v", bufrPath, err)
			}
			goldenBytes, err := os.ReadFile(goldenPath)
			if err != nil {
				t.Fatalf("failed reading %s: %v", goldenPath, err)
			}

			var golden GoldenMessage
			if err := json.Unmarshal(goldenBytes, &golden); err != nil {
				t.Fatalf("failed parsing %s: %v", goldenPath, err)
			}

			msgs, errs := Decode(bufrBytes)
			if len(msgs) != 1 {
				t.Fatalf("expected 1 message, got %d", len(msgs))
			}
			if errs[0] != nil {
				t.Fatalf("message decode error: %v", errs[0])
			}

			count := compareMessageWithGolden(t, msgs[0], golden, name)
			totalVals += count
			t.Logf("%s: verified %d values (compressed=%v) against ecCodes golden", name, count, msgs[0].Compressed)
		})
	}
	t.Logf("All SYNOP golden tests passed! Total synop values verified: %d", totalVals)
}

func TestMultiMessageWithGarbage(t *testing.T) {
	cmaBytes, err := os.ReadFile(filepath.Join("testdata", "synop_cn_cma.bufr"))
	if err != nil {
		t.Fatalf("failed reading CMA: %v", err)
	}
	jmaBytes, err := os.ReadFile(filepath.Join("testdata", "synop_jp_jma.bufr"))
	if err != nil {
		t.Fatalf("failed reading JMA: %v", err)
	}

	var combined []byte
	combined = append(combined, []byte("GARBAGE_HEADER_12345")...)
	combined = append(combined, cmaBytes...)
	combined = append(combined, []byte("MIDDLE_GARBAGE_BYTES_67890")...)
	combined = append(combined, jmaBytes...)
	combined = append(combined, []byte("TRAILING_GARBAGE_TEXT")...)

	msgs, errs := Decode(combined)
	if len(msgs) != 2 {
		t.Fatalf("expected 2 messages, got %d", len(msgs))
	}
	if errs[0] != nil || errs[1] != nil {
		t.Fatalf("unexpected decode error with garbage: %v, %v", errs[0], errs[1])
	}
	if msgs[0].Centre != 38 || msgs[1].Centre != 34 {
		t.Errorf("unexpected centres: %d, %d", msgs[0].Centre, msgs[1].Centre)
	}
}

func TestTruncatedMessage(t *testing.T) {
	cmaBytes, err := os.ReadFile(filepath.Join("testdata", "synop_cn_cma.bufr"))
	if err != nil {
		t.Fatalf("failed reading CMA: %v", err)
	}

	truncated := cmaBytes[:len(cmaBytes)-20]
	msgs, errs := Decode(truncated)
	if len(errs) == 0 {
		t.Fatalf("expected error on truncated input")
	}
	if _, ok := errs[0].(ErrTruncated); !ok {
		t.Errorf("expected ErrTruncated, got %T: %v", errs[0], errs[0])
	}
	_ = msgs
}

func TestEdition3Message(t *testing.T) {
	// Synthesize valid Edition 3 BUFR message
	// Total length: 8 (sec0) + 18 (sec1) + 9 (sec3) + 6 (sec4) + 4 (sec5) = 45 bytes
	totLen := 45
	b := make([]byte, totLen)
	copy(b[0:4], "BUFR")
	b[4] = byte(totLen >> 16)
	b[5] = byte(totLen >> 8)
	b[6] = byte(totLen)
	b[7] = 3 // Edition 3

	// Section 1: len 18
	b[8] = 0
	b[9] = 0
	b[10] = 18
	b[11] = 0  // Master table 0
	b[12] = 20 // SubCentre 20
	b[13] = 98 // Centre 98
	b[14] = 0  // Update seq
	b[15] = 0  // flags: no sec 2
	b[16] = 7  // data category 7
	b[17] = 32 // data subcategory 32
	b[18] = 35 // master table version 35
	b[19] = 0  // local table version 0

	// Section 3: len 9
	pos := 8 + 18
	b[pos] = 0
	b[pos+1] = 0
	b[pos+2] = 9
	b[pos+3] = 0
	b[pos+4] = 0
	b[pos+5] = 1 // 1 subset
	b[pos+6] = 0 // uncompressed
	// 1 descriptor: 0 01 001 (001001) -> (0<<14)|(1<<8)|1 = 0x0101
	b[pos+7] = 0x01
	b[pos+8] = 0x01

	// Section 4: len 6
	pos += 9
	b[pos] = 0
	b[pos+1] = 0
	b[pos+2] = 6
	b[pos+3] = 0
	// Data: block number 50 (7 bits: 0110010)
	b[pos+4] = 0x64
	b[pos+5] = 0x00

	// Section 5: "7777"
	copy(b[totLen-4:totLen], "7777")

	msgs, errs := Decode(b)
	if len(msgs) != 1 || errs[0] != nil {
		t.Fatalf("failed decoding Edition 3 message: %v", errs)
	}
	m := msgs[0]
	if m.Edition != 3 {
		t.Errorf("expected Edition 3, got %d", m.Edition)
	}
	if m.Centre != 98 || m.SubCentre != 20 {
		t.Errorf("expected Centre 98, SubCentre 20, got %d, %d", m.Centre, m.SubCentre)
	}
	if m.DataCategory != 7 || m.DataSubcategory != 32 {
		t.Errorf("expected Category 7, Subcategory 32, got %d, %d", m.DataCategory, m.DataSubcategory)
	}
	if len(m.Subsets) != 1 || len(m.Subsets[0]) != 1 {
		t.Fatalf("expected 1 subset with 1 value, got %+v", m.Subsets)
	}
	v := m.Subsets[0][0]
	if v.Float == nil || *v.Float != 50.0 {
		t.Errorf("expected value 50.0, got %+v", v.Float)
	}
}
