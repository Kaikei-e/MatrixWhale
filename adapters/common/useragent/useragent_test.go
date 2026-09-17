package useragent

import (
	"sync"
	"testing"
)

func TestBuildWithContactSet(t *testing.T) {
	t.Setenv("TEST_CONTACT_EMAIL", "ops@example.com")
	if got := Build("MatrixWhale/1.0", "TEST_CONTACT_EMAIL", "", nil); got != "MatrixWhale/1.0 (ops@example.com)" {
		t.Errorf("Build() = %q", got)
	}
}

func TestBuildWithoutContactAndNoFallback(t *testing.T) {
	t.Setenv("TEST_CONTACT_EMAIL", "")
	if got := Build("MatrixWhale/1.0", "TEST_CONTACT_EMAIL", "", nil); got != "MatrixWhale/1.0" {
		t.Errorf("Build() = %q", got)
	}
}

func TestBuildWithoutContactUsesFallback(t *testing.T) {
	t.Setenv("TEST_CONTACT_EMAIL", "")
	var once sync.Once
	got := Build("MatrixWhale/1.0", "TEST_CONTACT_EMAIL", "contact-email-not-configured", &once)
	if got != "MatrixWhale/1.0 (contact-email-not-configured)" {
		t.Errorf("Build() = %q", got)
	}
	// Calling again must not panic and must keep returning the fallback.
	if got := Build("MatrixWhale/1.0", "TEST_CONTACT_EMAIL", "contact-email-not-configured", &once); got != "MatrixWhale/1.0 (contact-email-not-configured)" {
		t.Errorf("Build() on second call = %q", got)
	}
}
