package tables

import (
	"testing"
)

func TestTablesLoaded(t *testing.T) {
	cb := CountB()
	cd := CountD()
	if cb < 1800 {
		t.Fatalf("expected >= 1800 Table B entries, got %d", cb)
	}
	if cd < 600 {
		t.Fatalf("expected >= 600 Table D entries, got %d", cd)
	}

	// Test a few specific entries
	e, ok := LookupB(1001) // 0 01 001: WMO block number
	if !ok {
		t.Fatalf("expected 001001 in Table B")
	}
	if e.Width != 7 || e.Scale != 0 || e.Reference != 0 {
		t.Fatalf("unexpected entry for 001001: %+v", e)
	}

	seq, ok := LookupD(301150)
	if !ok {
		t.Fatalf("expected 301150 in Table D")
	}
	if len(seq) != 4 {
		t.Fatalf("expected 4 descriptors in 301150, got %d", len(seq))
	}
}
