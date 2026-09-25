package wnm

import (
	"crypto/sha512"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"net/url"
	"strings"
	"time"

	"golang.org/x/crypto/sha3"
)

type WNMMessage struct {
	ID         string          `json:"id"`
	Type       string          `json:"type"`
	Geometry   json.RawMessage `json:"geometry,omitempty"`
	Properties WNMProperties   `json:"properties"`
	Links      []WNMLink       `json:"links"`
}

type WNMProperties struct {
	DataID    string        `json:"data_id"`
	PubTime   string        `json:"pubtime"`
	DateTime  *string       `json:"datetime"`
	Integrity *WNMIntegrity `json:"integrity,omitempty"`
	Content   *WNMContent   `json:"content,omitempty"`
	ObjectID  *string       `json:"OBJECTID,omitempty"`
}

type WNMIntegrity struct {
	Method string `json:"method"`
	Value  string `json:"value"`
}

type WNMContent struct {
	Encoding string `json:"encoding"`
	Size     int    `json:"size"`
	Value    string `json:"value"`
}

type WNMLink struct {
	Href   string `json:"href"`
	Rel    string `json:"rel"`
	Type   string `json:"type"`
	Title  string `json:"title,omitempty"`
	Length int64  `json:"length,omitempty"`
}

func ClassifyTopic(topic string) (channel, centreID, kind string) {
	if strings.HasPrefix(topic, "cache/") {
		channel = "cache"
	} else if strings.HasPrefix(topic, "origin/") {
		channel = "origin"
	} else {
		channel = "other"
	}

	parts := strings.Split(topic, "/")
	if len(parts) > 3 {
		centreID = parts[3]
	}

	if strings.Contains(topic, "/weather/advisories-warnings") {
		kind = "warnings"
	} else if strings.Contains(topic, "/trajectory") {
		kind = "trajectory"
	} else if strings.Contains(topic, "/surface-based-observations/synop") {
		kind = "synop"
	} else {
		kind = "other"
	}

	return channel, centreID, kind
}

func ParseWNM(data []byte) (*WNMMessage, error) {
	var msg WNMMessage
	if err := json.Unmarshal(data, &msg); err != nil {
		return nil, err
	}
	return &msg, nil
}

func FormatRFC3339(ts string) (string, error) {
	t, err := time.Parse(time.RFC3339Nano, ts)
	if err != nil {
		t, err = time.Parse(time.RFC3339, ts)
		if err != nil {
			return ts, err
		}
	}
	return t.UTC().Format(time.RFC3339Nano), nil
}

func CheckIntegrity(data []byte, integrity *WNMIntegrity) bool {
	if integrity == nil || integrity.Method == "" || integrity.Value == "" {
		return true
	}

	normMethod := strings.ToLower(strings.ReplaceAll(integrity.Method, "-", ""))
	var sum []byte

	switch normMethod {
	case "sha512":
		h := sha512.Sum512(data)
		sum = h[:]
	case "sha3512":
		h := sha3.Sum512(data)
		sum = h[:]
	default:
		return false
	}

	actualB64 := base64.StdEncoding.EncodeToString(sum)
	actualHex := hex.EncodeToString(sum)

	return integrity.Value == actualB64 || strings.EqualFold(integrity.Value, actualHex)
}

func FindCanonicalLink(links []WNMLink) *WNMLink {
	for i := range links {
		if strings.EqualFold(links[i].Rel, "canonical") && links[i].Href != "" {
			return &links[i]
		}
	}
	return nil
}

func FindGeometryLink(links []WNMLink) *WNMLink {
	for i := range links {
		if strings.EqualFold(links[i].Rel, "geometry") && links[i].Href != "" {
			return &links[i]
		}
	}
	return nil
}

func FindLicenseLink(links []WNMLink) *WNMLink {
	for i := range links {
		if strings.EqualFold(links[i].Rel, "license") && links[i].Href != "" {
			return &links[i]
		}
	}
	return nil
}

func FindDataFallbackLinks(links []WNMLink) []WNMLink {
	var candidates []WNMLink
	for _, l := range links {
		if strings.TrimSpace(l.Href) == "" {
			continue
		}
		rel := strings.ToLower(strings.TrimSpace(l.Rel))
		switch rel {
		case "canonical", "license", "geometry", "json", "describedby":
			continue
		default:
			candidates = append(candidates, l)
		}
	}
	return candidates
}

func FindXMLFallbackLinks(links []WNMLink) []WNMLink {
	return FindDataFallbackLinks(links)
}

func ResolveAreaKey(objectID *string, geomLinkHref string) *string {
	if objectID != nil && strings.TrimSpace(*objectID) != "" {
		k := strings.TrimSpace(*objectID)
		return &k
	}
	if geomLinkHref != "" {
		u, err := url.Parse(geomLinkHref)
		if err == nil && u.Path != "" {
			p := u.Path
			return &p
		}
	}
	return nil
}
