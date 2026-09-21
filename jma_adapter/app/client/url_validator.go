package client

import (
	"errors"
	"fmt"
	"net/url"
	"regexp"
	"strings"
)

var (
	ErrInvalidScheme         = errors.New("invalid URL scheme: must be https")
	ErrInvalidHost           = errors.New("invalid URL host: must match allowed JMA host")
	ErrCredentialsNotAllowed = errors.New("URL credentials/userinfo not allowed")
	ErrPortNotAllowed        = errors.New("custom port not allowed")
	ErrQueryNotAllowed       = errors.New("URL query parameters not allowed")
	ErrFragmentNotAllowed    = errors.New("URL fragment not allowed")
	ErrPathTraversal         = errors.New("path traversal detected in URL")
	ErrUnallowedFeedPath     = errors.New("feed path not in allowlist")
	ErrUnallowedDataPath     = errors.New("data path not in allowlist")
)

// Conservative regex for /developer/xml/data/*.xml filenames
var dataPathRegex = regexp.MustCompile(`^/developer/xml/data/[A-Za-z0-9_.-]+\.xml$`)

// Allowed feed paths
var allowedFeedPaths = map[string]bool{
	"/developer/xml/feed/extra.xml":     true,
	"/developer/xml/feed/extra_l.xml":   true,
	"/developer/xml/feed/eqvol.xml":     true,
	"/developer/xml/feed/eqvol_l.xml":   true,
	"/developer/xml/feed/regular.xml":   true,
	"/developer/xml/feed/regular_l.xml": true,
	"/developer/xml/feed/other.xml":     true,
	"/developer/xml/feed/other_l.xml":   true,
}

// URLValidator enforces strict validation and allowlisting on JMA URLs.
type URLValidator struct {
	allowedHost string
	allowHTTP   bool // enabled only for mock test environments
}

// NewURLValidator creates a new URLValidator.
func NewURLValidator(allowedHost string, allowHTTP bool) *URLValidator {
	return &URLValidator{
		allowedHost: allowedHost,
		allowHTTP:   allowHTTP,
	}
}

func (v *URLValidator) validateCommon(rawURL string) (*url.URL, error) {
	u, err := url.Parse(rawURL)
	if err != nil {
		return nil, fmt.Errorf("parse URL: %w", err)
	}

	// Scheme check
	if u.Scheme == "http" {
		if !v.allowHTTP {
			return nil, ErrInvalidScheme
		}
	} else if u.Scheme != "https" {
		return nil, ErrInvalidScheme
	}

	// Host check
	hostname := u.Hostname()
	if v.allowedHost != "" && !strings.EqualFold(hostname, v.allowedHost) {
		return nil, fmt.Errorf("%w: got %s, expected %s", ErrInvalidHost, hostname, v.allowedHost)
	}

	// Credentials check
	if u.User != nil {
		return nil, ErrCredentialsNotAllowed
	}

	// Port check (in non-test environments port should be empty for standard 443)
	if !v.allowHTTP && u.Port() != "" {
		return nil, ErrPortNotAllowed
	}

	// Query parameters check
	if u.RawQuery != "" {
		return nil, ErrQueryNotAllowed
	}

	// Fragment check
	if u.Fragment != "" {
		return nil, ErrFragmentNotAllowed
	}

	// Path traversal check (both unescaped and escaped)
	if strings.Contains(u.Path, "..") || strings.Contains(u.RawPath, "..") ||
		strings.Contains(rawURL, "%2e") || strings.Contains(rawURL, "%2E") {
		return nil, ErrPathTraversal
	}

	return u, nil
}

// ValidateFeedURL ensures the URL is an authorized feed URL.
func (v *URLValidator) ValidateFeedURL(rawURL string) (*url.URL, error) {
	u, err := v.validateCommon(rawURL)
	if err != nil {
		return nil, err
	}

	cleanPath := u.Path
	if !allowedFeedPaths[cleanPath] {
		return nil, fmt.Errorf("%w: path %s", ErrUnallowedFeedPath, cleanPath)
	}

	return u, nil
}

// ValidateDataURL ensures the URL is an authorized child data XML URL.
func (v *URLValidator) ValidateDataURL(rawURL string) (*url.URL, error) {
	u, err := v.validateCommon(rawURL)
	if err != nil {
		return nil, err
	}

	cleanPath := u.Path
	if !dataPathRegex.MatchString(cleanPath) {
		return nil, fmt.Errorf("%w: path %s", ErrUnallowedDataPath, cleanPath)
	}

	return u, nil
}
