package client

import (
	"errors"
	"testing"
)

func TestURLValidator(t *testing.T) {
	v := NewURLValidator("www.data.jma.go.jp", false)

	// Valid Feed URLs
	validFeeds := []string{
		"https://www.data.jma.go.jp/developer/xml/feed/eqvol.xml",
		"https://www.data.jma.go.jp/developer/xml/feed/eqvol_l.xml",
		"https://www.data.jma.go.jp/developer/xml/feed/extra.xml",
		"https://www.data.jma.go.jp/developer/xml/feed/extra_l.xml",
	}
	for _, u := range validFeeds {
		if _, err := v.ValidateFeedURL(u); err != nil {
			t.Fatalf("expected valid feed URL %s, got error: %v", u, err)
		}
	}

	// Valid Data URLs
	validData := []string{
		"https://www.data.jma.go.jp/developer/xml/data/20260921012500_0_VXSE53_010000.xml",
		"https://www.data.jma.go.jp/developer/xml/data/20260920150214_0_VFVO52_400000.xml",
		"https://www.data.jma.go.jp/developer/xml/data/custom-report_123.xml",
	}
	for _, u := range validData {
		if _, err := v.ValidateDataURL(u); err != nil {
			t.Fatalf("expected valid data URL %s, got error: %v", u, err)
		}
	}

	// Reject HTTP
	if _, err := v.ValidateFeedURL("http://www.data.jma.go.jp/developer/xml/feed/eqvol.xml"); !errors.Is(err, ErrInvalidScheme) {
		t.Fatalf("expected ErrInvalidScheme, got %v", err)
	}

	// Reject wrong host
	if _, err := v.ValidateFeedURL("https://evil.com/developer/xml/feed/eqvol.xml"); !errors.Is(err, ErrInvalidHost) {
		t.Fatalf("expected ErrInvalidHost, got %v", err)
	}

	// Reject userinfo/creds
	if _, err := v.ValidateFeedURL("https://user:pass@www.data.jma.go.jp/developer/xml/feed/eqvol.xml"); !errors.Is(err, ErrCredentialsNotAllowed) {
		t.Fatalf("expected ErrCredentialsNotAllowed, got %v", err)
	}

	// Reject custom port
	if _, err := v.ValidateFeedURL("https://www.data.jma.go.jp:8443/developer/xml/feed/eqvol.xml"); !errors.Is(err, ErrPortNotAllowed) {
		t.Fatalf("expected ErrPortNotAllowed, got %v", err)
	}

	// Reject query
	if _, err := v.ValidateFeedURL("https://www.data.jma.go.jp/developer/xml/feed/eqvol.xml?query=attack"); !errors.Is(err, ErrQueryNotAllowed) {
		t.Fatalf("expected ErrQueryNotAllowed, got %v", err)
	}

	// Reject fragment
	if _, err := v.ValidateFeedURL("https://www.data.jma.go.jp/developer/xml/feed/eqvol.xml#anchor"); !errors.Is(err, ErrFragmentNotAllowed) {
		t.Fatalf("expected ErrFragmentNotAllowed, got %v", err)
	}

	// Reject path traversal
	traversals := []string{
		"https://www.data.jma.go.jp/developer/xml/feed/../other/secret.xml",
		"https://www.data.jma.go.jp/developer/xml/data/%2e%2e/feed/eqvol.xml",
	}
	for _, u := range traversals {
		if _, err := v.ValidateFeedURL(u); !errors.Is(err, ErrPathTraversal) {
			t.Fatalf("expected ErrPathTraversal for %s, got %v", u, err)
		}
	}

	// Reject unallowed feed
	if _, err := v.ValidateFeedURL("https://www.data.jma.go.jp/developer/xml/feed/unauthorized.xml"); !errors.Is(err, ErrUnallowedFeedPath) {
		t.Fatalf("expected ErrUnallowedFeedPath, got %v", err)
	}

	// Reject unallowed data extension
	if _, err := v.ValidateDataURL("https://www.data.jma.go.jp/developer/xml/data/payload.exe"); !errors.Is(err, ErrUnallowedDataPath) {
		t.Fatalf("expected ErrUnallowedDataPath, got %v", err)
	}

	// Test allowHTTP for mock tests
	mockValidator := NewURLValidator("127.0.0.1", true)
	if _, err := mockValidator.ValidateFeedURL("http://127.0.0.1:9999/developer/xml/feed/eqvol.xml"); err != nil {
		t.Fatalf("expected valid mock URL, got %v", err)
	}
}
