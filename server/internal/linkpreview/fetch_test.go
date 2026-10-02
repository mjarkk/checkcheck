package linkpreview

import (
	"context"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"

	"checkcheck/internal/store"
)

func TestParse(t *testing.T) {
	base, _ := url.Parse("https://example.com/blog/post?x=1")
	long := strings.Repeat("word ", 300)
	for _, tc := range []struct {
		name, html string
		want       store.Preview
	}{
		{"og tags", `<!doctype html><html><head>
			<title>Ignored</title>
			<meta name="description" content="Ignored">
			<meta property="og:title" content="A post">
			<meta property="og:description" content="About things">
			<meta property="og:image" content="https://cdn.example.com/og.png">
			<meta property="og:site_name" content="Example">
			<link rel="icon" href="https://example.com/icon.png">
			</head><body></body></html>`,
			store.Preview{Title: "A post", Description: "About things", Image: "https://cdn.example.com/og.png", SiteName: "Example", Icon: "https://example.com/icon.png"}},
		{"secure image first, then the first og:image", `<meta property="og:image" content="http://example.com/a.png">
			<meta property="og:image" content="http://example.com/b.png">
			<meta property="og:image:secure_url" content="https://example.com/a.png">`,
			store.Preview{Image: "https://example.com/a.png", Icon: "https://example.com/favicon.ico"}},
		{"og:image:url", `<meta property="og:image:url" content="/a.png">`,
			store.Preview{Image: "https://example.com/a.png", Icon: "https://example.com/favicon.ico"}},
		{"twitter fallback", `<title>Page title</title>
			<meta name="twitter:title" content="Tweet title">
			<meta name="twitter:description" content="Tweet description">
			<meta name="twitter:image" content="img/t.png">`,
			store.Preview{Title: "Tweet title", Description: "Tweet description", Image: "https://example.com/blog/img/t.png", Icon: "https://example.com/favicon.ico"}},
		{"title and description fallback", `<TITLE>Page title</TITLE><META NAME="Description" CONTENT="Page description">`,
			store.Preview{Title: "Page title", Description: "Page description", Icon: "https://example.com/favicon.ico"}},
		{"blank og values fall through", `<title>Page title</title><meta property="og:title" content="  ">`,
			store.Preview{Title: "Page title", Icon: "https://example.com/favicon.ico"}},
		{"relative urls", `<meta property="og:image" content="//cdn.example.com/i.png">
			<link rel="shortcut icon" href="../favicon.png">`,
			store.Preview{Image: "https://cdn.example.com/i.png", Icon: "https://example.com/favicon.png"}},
		{"apple-touch-icon without icon", `<title>t</title><link rel="apple-touch-icon" href="/touch.png">`,
			store.Preview{Title: "t", Icon: "https://example.com/touch.png"}},
		{"icon over apple-touch-icon", `<title>t</title><link rel="apple-touch-icon" href="/touch.png"><link rel="ICON" href="/i.svg">`,
			store.Preview{Title: "t", Icon: "https://example.com/i.svg"}},
		{"non-http urls skipped", `<title>t</title>
			<meta property="og:image" content="javascript:alert(1)">
			<meta name="twitter:image" content="/fallback.png">
			<link rel="icon" href="data:image/png;base64,AAAA">`,
			store.Preview{Title: "t", Image: "https://example.com/fallback.png", Icon: "https://example.com/favicon.ico"}},
		{"entities and whitespace", `<title>
				Tom &amp; Jerry&#8217;s   &lt;show&gt;
			</title>
			<meta property="og:description" content="A &quot;quoted&quot;&#10;line &eacute;">`,
			store.Preview{Title: "Tom & Jerry’s <show>", Description: `A "quoted" line é`, Icon: "https://example.com/favicon.ico"}},
		{"length caps", `<title>` + long + `</title><meta name="description" content="` + long + `">
			<meta property="og:site_name" content="` + long + `">`,
			store.Preview{
				Title:       strings.TrimSpace(long[:299]) + "…",
				Description: strings.TrimSpace(long[:999]) + "…",
				SiteName:    strings.TrimSpace(long[:99]) + "…",
				Icon:        "https://example.com/favicon.ico",
			}},
		{"stops at body", `<head><title>t</title></head><body><meta property="og:image" content="/a.png"></body>`,
			store.Preview{Title: "t", Icon: "https://example.com/favicon.ico"}},
		{"stops at body without head", `<title>t</title><body><meta property="og:image" content="/a.png">`,
			store.Preview{Title: "t", Icon: "https://example.com/favicon.ico"}},
		{"title in script ignored", `<script>document.write("<title>no</title>")</script>`, store.Preview{}},
		{"site name and icon alone are nothing", `<meta property="og:site_name" content="Example"><link rel="icon" href="/i.png">`,
			store.Preview{}},
		{"empty", ``, store.Preview{}},
	} {
		got, err := parse(strings.NewReader(tc.html), base)
		if err != nil {
			t.Errorf("%s: %v", tc.name, err)
		}
		if got != tc.want {
			t.Errorf("%s:\ngot  %+v\nwant %+v", tc.name, got, tc.want)
		}
	}
}

func TestFetch(t *testing.T) {
	var gotUA, gotAccept string
	mux := http.NewServeMux()
	page := func(contentType, body string) http.HandlerFunc {
		return func(w http.ResponseWriter, r *http.Request) {
			gotUA, gotAccept = r.Header.Get("User-Agent"), r.Header.Get("Accept")
			w.Header().Set("Content-Type", contentType)
			w.Write([]byte(body))
		}
	}
	mux.Handle("/page", page("text/html; charset=utf-8", `<title>Hello</title><link rel="icon" href="i.png">`))
	mux.Handle("/xhtml", page("application/xhtml+xml", `<title>Hello</title>`))
	mux.Handle("/latin1", page("text/html; charset=iso-8859-1", "<title>caf\xe9</title>"))
	mux.Handle("/meta-charset", page("text/html", "<meta charset=windows-1252><title>\x93caf\xe9\x94</title>"))
	mux.Handle("/json", page("application/json", `{}`))
	mux.Handle("/no-type", page("", `<title>Hello</title>`))
	mux.Handle("/huge", page("text/html", "<!--"+strings.Repeat("x", maxBodyBytes)+"--><title>Too late</title>"))
	mux.Handle("/missing", http.NotFoundHandler())
	mux.Handle("/to-page", http.RedirectHandler("/dir/../page", http.StatusFound))
	mux.HandleFunc("/hops/{n}", func(w http.ResponseWriter, r *http.Request) {
		n := r.PathValue("n")
		if n == "0" {
			page("text/html", `<title>Arrived</title>`)(w, r)
			return
		}
		http.Redirect(w, r, "/hops/"+string(n[0]-1), http.StatusFound)
	})
	mux.Handle("/to-ftp", http.RedirectHandler("ftp://example.com/", http.StatusFound))
	srv := httptest.NewServer(mux)
	defer srv.Close()
	client := newClient(nil)

	for _, tc := range []struct {
		path    string
		want    store.Preview
		wantErr bool
	}{
		{"/page", store.Preview{Title: "Hello", Icon: srv.URL + "/i.png"}, false},
		{"/xhtml", store.Preview{Title: "Hello", Icon: srv.URL + "/favicon.ico"}, false},
		{"/latin1", store.Preview{Title: "café", Icon: srv.URL + "/favicon.ico"}, false},
		{"/meta-charset", store.Preview{Title: "“café”", Icon: srv.URL + "/favicon.ico"}, false},
		{"/huge", store.Preview{}, false},
		{"/to-page", store.Preview{Title: "Hello", Icon: srv.URL + "/i.png"}, false},
		{"/hops/5", store.Preview{Title: "Arrived", Icon: srv.URL + "/favicon.ico"}, false},
		{"/hops/6", store.Preview{}, true},
		{"/to-ftp", store.Preview{}, true},
		{"/json", store.Preview{}, true},
		{"/no-type", store.Preview{}, true},
		{"/missing", store.Preview{}, true},
	} {
		got, err := Fetch(context.Background(), client, srv.URL+tc.path)
		if (err != nil) != tc.wantErr || got != tc.want {
			t.Errorf("%s: %+v, %v; want %+v, error %v", tc.path, got, err, tc.want, tc.wantErr)
		}
	}
	if gotUA != userAgent || gotAccept != "text/html,application/xhtml+xml" {
		t.Errorf("request headers User-Agent %q Accept %q", gotUA, gotAccept)
	}

	if _, err := Fetch(context.Background(), client, "file:///etc/passwd"); err == nil {
		t.Error("file URL fetched")
	}
}
