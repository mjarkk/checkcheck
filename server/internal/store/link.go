package store

import (
	"net/url"
	"strings"
	"unicode"
)

// findLink implements the link rule in API.md's "Link previews".
func findLink(title string) string {
	start := -1
	for i := range len(title) {
		if hasPrefixFold(title[i:], "http://") || hasPrefixFold(title[i:], "https://") {
			start = i
			break
		}
	}
	if start < 0 {
		return ""
	}
	link := title[start:]
	if end := strings.IndexFunc(link, unicode.IsSpace); end >= 0 {
		link = link[:end]
	}
	for link != "" && trimmable(link) {
		link = link[:len(link)-1]
	}
	u, err := url.Parse(link)
	if err != nil || u.Hostname() == "" {
		return ""
	}
	return link
}

func hasPrefixFold(s, prefix string) bool {
	return len(s) >= len(prefix) && strings.EqualFold(s[:len(prefix)], prefix)
}

// trimmable reports whether link's last byte is punctuation that ends the
// sentence around the link rather than the link itself.
func trimmable(link string) bool {
	last := link[len(link)-1]
	if strings.IndexByte(".,;:!?'\"", last) >= 0 {
		return true
	}
	for _, pair := range []string{"()", "[]", "{}"} {
		if last == pair[1] {
			return strings.Count(link, pair[1:]) > strings.Count(link, pair[:1])
		}
	}
	return false
}
