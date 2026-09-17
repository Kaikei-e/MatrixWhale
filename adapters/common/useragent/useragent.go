// Package useragent builds the User-Agent header adapters send to source
// feeds, identifying MatrixWhale and an operator contact email.
package useragent

import (
	"fmt"
	"log/slog"
	"os"
	"sync"
)

// Build reads contactEnvVar and returns "product (contact)". When the
// variable is unset, it returns fallback instead of the contact, or bare
// product when fallback is empty. warnOnce, when non-nil, logs a warning the
// first time the fallback is used; pass nil to never warn.
func Build(product, contactEnvVar, fallback string, warnOnce *sync.Once) string {
	contact := os.Getenv(contactEnvVar)
	if contact != "" {
		return fmt.Sprintf("%s (%s)", product, contact)
	}
	if fallback == "" {
		return product
	}
	if warnOnce != nil {
		warnOnce.Do(func() {
			slog.Warn(contactEnvVar + " is not set; falling back to placeholder contact in User-Agent")
		})
	}
	return fmt.Sprintf("%s (%s)", product, fallback)
}
