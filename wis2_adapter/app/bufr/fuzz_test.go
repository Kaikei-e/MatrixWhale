package bufr

import (
	"os"
	"path/filepath"
	"testing"
)

func FuzzDecode(f *testing.F) {
	entries, err := os.ReadDir("testdata")
	if err == nil {
		for _, e := range entries {
			if filepath.Ext(e.Name()) == ".bufr" {
				data, err := os.ReadFile(filepath.Join("testdata", e.Name()))
				if err == nil && len(data) > 0 {
					f.Add(data)
				}
			}
		}
	}

	f.Add([]byte("BUFR\x00\x00\x10\x047777"))
	f.Add([]byte("GARBAGE NOT BUFR"))
	f.Add([]byte(""))

	f.Fuzz(func(t *testing.T, data []byte) {
		_, _ = Decode(data)
	})
}
