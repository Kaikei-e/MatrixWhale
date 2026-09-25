package tables

import (
	"embed"
	"encoding/csv"
	"io"
	"strconv"
	"strings"
	"sync"
)

//go:embed *.csv
var tableFS embed.FS

type TableBEntry struct {
	Name      string
	Unit      string
	Scale     int
	Reference int64
	Width     int
}

var (
	loadOnce sync.Once
	tableB   map[int]TableBEntry
	tableD   map[int][]int
)

func ensureLoaded() {
	loadOnce.Do(func() {
		tableB = make(map[int]TableBEntry, 2048)
		tableD = make(map[int][]int, 1024)

		entries, err := tableFS.ReadDir(".")
		if err != nil {
			return
		}

		for _, e := range entries {
			name := e.Name()
			if strings.HasPrefix(name, "BUFRCREX_TableB_en_") && strings.HasSuffix(name, ".csv") {
				loadTableB(name)
			} else if strings.HasPrefix(name, "BUFR_TableD_en_") && strings.HasSuffix(name, ".csv") {
				loadTableD(name)
			}
		}
	})
}

func loadTableB(filename string) {
	f, err := tableFS.Open(filename)
	if err != nil {
		return
	}
	defer f.Close()

	r := csv.NewReader(f)
	r.FieldsPerRecord = -1
	header, err := r.Read()
	if err != nil {
		return
	}

	colFXY := -1
	colName := -1
	colUnit := -1
	colScale := -1
	colRef := -1
	colWidth := -1

	for i, h := range header {
		switch strings.TrimSpace(h) {
		case "FXY":
			colFXY = i
		case "ElementName_en":
			colName = i
		case "BUFR_Unit":
			colUnit = i
		case "BUFR_Scale":
			colScale = i
		case "BUFR_ReferenceValue":
			colRef = i
		case "BUFR_DataWidth_Bits":
			colWidth = i
		}
	}

	if colFXY < 0 || colName < 0 || colUnit < 0 || colScale < 0 || colRef < 0 || colWidth < 0 {
		return
	}

	for {
		rec, err := r.Read()
		if err == io.EOF {
			break
		}
		if err != nil {
			continue
		}
		if len(rec) <= colFXY || len(rec) <= colName || len(rec) <= colUnit ||
			len(rec) <= colScale || len(rec) <= colRef || len(rec) <= colWidth {
			continue
		}

		fxyStr := strings.TrimSpace(rec[colFXY])
		if len(fxyStr) != 6 {
			continue
		}
		code, err := strconv.Atoi(fxyStr)
		if err != nil {
			continue
		}

		scale, err := strconv.Atoi(strings.TrimSpace(rec[colScale]))
		if err != nil {
			continue
		}
		refVal, err := strconv.ParseInt(strings.TrimSpace(rec[colRef]), 10, 64)
		if err != nil {
			continue
		}
		width, err := strconv.Atoi(strings.TrimSpace(rec[colWidth]))
		if err != nil {
			continue
		}

		tableB[code] = TableBEntry{
			Name:      strings.TrimSpace(rec[colName]),
			Unit:      strings.TrimSpace(rec[colUnit]),
			Scale:     scale,
			Reference: refVal,
			Width:     width,
		}
	}
}

func loadTableD(filename string) {
	f, err := tableFS.Open(filename)
	if err != nil {
		return
	}
	defer f.Close()

	r := csv.NewReader(f)
	r.FieldsPerRecord = -1
	header, err := r.Read()
	if err != nil {
		return
	}

	colFXY1 := -1
	colFXY2 := -1
	for i, h := range header {
		switch strings.TrimSpace(h) {
		case "FXY1":
			colFXY1 = i
		case "FXY2":
			colFXY2 = i
		}
	}

	if colFXY1 < 0 || colFXY2 < 0 {
		return
	}

	for {
		rec, err := r.Read()
		if err == io.EOF {
			break
		}
		if err != nil {
			continue
		}
		if len(rec) <= colFXY1 || len(rec) <= colFXY2 {
			continue
		}

		fxy1Str := strings.TrimSpace(rec[colFXY1])
		fxy2Str := strings.TrimSpace(rec[colFXY2])
		if len(fxy1Str) != 6 || len(fxy2Str) != 6 {
			continue
		}
		fxy1, err1 := strconv.Atoi(fxy1Str)
		fxy2, err2 := strconv.Atoi(fxy2Str)
		if err1 != nil || err2 != nil {
			continue
		}

		tableD[fxy1] = append(tableD[fxy1], fxy2)
	}
}

func LookupB(code int) (TableBEntry, bool) {
	ensureLoaded()
	e, ok := tableB[code]
	return e, ok
}

func LookupD(code int) ([]int, bool) {
	ensureLoaded()
	seq, ok := tableD[code]
	return seq, ok
}

func CountB() int {
	ensureLoaded()
	return len(tableB)
}

func CountD() int {
	ensureLoaded()
	return len(tableD)
}
