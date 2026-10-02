package linkpreview

import (
	"context"
	"fmt"
	"io"
	"mime"
	"net/http"
	"net/url"
	"strings"
	"unicode/utf8"

	"golang.org/x/net/html"
	"golang.org/x/net/html/atom"
	"golang.org/x/net/html/charset"

	"checkcheck/internal/store"
)

const (
	userAgent    = "Mozilla/5.0 (compatible; checkcheck/1.0; +link-preview)"
	maxBodyBytes = 2 << 20
	maxURLLen    = 2048

	maxTitleLen       = 300
	maxDescriptionLen = 1000
	maxSiteNameLen    = 100
)

// Fetch reads what the page at link shows about itself. A page that shows
// nothing gives the zero Preview and no error.
func Fetch(ctx context.Context, client *http.Client, link string) (store.Preview, error) {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, link, nil)
	if err != nil {
		return store.Preview{}, err
	}
	if req.URL.Scheme != "http" && req.URL.Scheme != "https" {
		return store.Preview{}, fmt.Errorf("unsupported scheme %q", req.URL.Scheme)
	}
	req.Header.Set("User-Agent", userAgent)
	req.Header.Set("Accept", "text/html,application/xhtml+xml")
	resp, err := client.Do(req)
	if err != nil {
		return store.Preview{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		return store.Preview{}, fmt.Errorf("status %s", resp.Status)
	}
	contentType := resp.Header.Get("Content-Type")
	if mediaType, _, _ := mime.ParseMediaType(contentType); mediaType != "text/html" && mediaType != "application/xhtml+xml" {
		return store.Preview{}, fmt.Errorf("content type %q is not HTML", contentType)
	}
	body, err := charset.NewReader(io.LimitReader(resp.Body, maxBodyBytes), contentType)
	if err != nil {
		return store.Preview{}, err
	}
	return parse(body, resp.Request.URL)
}

func parse(r io.Reader, base *url.URL) (store.Preview, error) {
	meta := map[string]string{}
	var title, icon, touchIcon string
	inTitle := false
	z := html.NewTokenizer(r)
head:
	for {
		tt := z.Next()
		switch tt {
		case html.ErrorToken:
			if err := z.Err(); err != io.EOF {
				return store.Preview{}, err
			}
			break head
		case html.TextToken:
			if inTitle {
				title += string(z.Text())
			}
		case html.EndTagToken:
			name, _ := z.TagName()
			switch atom.Lookup(name) {
			case atom.Head:
				break head
			case atom.Title:
				inTitle = false
			}
		case html.StartTagToken, html.SelfClosingTagToken:
			name, _ := z.TagName()
			switch atom.Lookup(name) {
			case atom.Body:
				break head
			case atom.Title:
				inTitle = tt == html.StartTagToken && title == ""
			case atom.Meta:
				a := attrs(z)
				key := strings.ToLower(a["property"])
				if key == "" {
					key = strings.ToLower(a["name"])
				}
				if _, seen := meta[key]; key != "" && !seen && strings.TrimSpace(a["content"]) != "" {
					meta[key] = a["content"]
				}
			case atom.Link:
				a := attrs(z)
				for _, rel := range strings.Fields(strings.ToLower(a["rel"])) {
					switch {
					case rel == "icon" && icon == "":
						icon = resolve(base, a["href"])
					case rel == "apple-touch-icon" && touchIcon == "":
						touchIcon = resolve(base, a["href"])
					}
				}
			}
		}
	}

	p := store.Preview{
		Title:       text(maxTitleLen, meta["og:title"], meta["twitter:title"], title),
		Description: text(maxDescriptionLen, meta["og:description"], meta["twitter:description"], meta["description"]),
		Image: firstURL(base, meta["og:image:secure_url"], meta["og:image"], meta["og:image:url"],
			meta["twitter:image"], meta["twitter:image:src"]),
		SiteName: text(maxSiteNameLen, meta["og:site_name"]),
	}
	if p.Title == "" && p.Description == "" && p.Image == "" {
		return store.Preview{}, nil
	}
	p.Icon = firstURL(base, icon, touchIcon, "/favicon.ico")
	return p, nil
}

func attrs(z *html.Tokenizer) map[string]string {
	a := map[string]string{}
	for {
		key, val, more := z.TagAttr()
		if _, seen := a[string(key)]; !seen {
			a[string(key)] = string(val)
		}
		if !more {
			return a
		}
	}
}

// text returns the first candidate that isn't blank, with whitespace
// collapsed and cut to max characters.
func text(max int, candidates ...string) string {
	for _, c := range candidates {
		s := strings.Join(strings.Fields(c), " ")
		if s == "" {
			continue
		}
		if utf8.RuneCountInString(s) <= max {
			return s
		}
		return strings.TrimRight(string([]rune(s)[:max-1]), " ") + "…"
	}
	return ""
}

func firstURL(base *url.URL, candidates ...string) string {
	for _, c := range candidates {
		if u := resolve(base, c); u != "" {
			return u
		}
	}
	return ""
}

// resolve returns ref as an absolute http(s) URL, or "" when it isn't one.
func resolve(base *url.URL, ref string) string {
	ref = strings.TrimSpace(ref)
	if ref == "" || len(ref) > maxURLLen {
		return ""
	}
	u, err := base.Parse(ref)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
		return ""
	}
	return u.String()
}
