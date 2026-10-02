package spa

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"testing/fstest"
)

func TestHandler(t *testing.T) {
	h := Handler(fstest.MapFS{
		"index.html":       {Data: []byte("<html>app</html>")},
		"favicon.svg":      {Data: []byte("<svg/>")},
		"assets/app-1a.js": {Data: []byte("console.log(1)")},
	})

	for _, tc := range []struct {
		path, wantBody, wantCache string
		wantStatus                int
	}{
		{"/", "<html>app</html>", "no-cache", 200},
		{"/lists/groceries", "<html>app</html>", "no-cache", 200},
		{"/assets", "<html>app</html>", "no-cache", 200},
		{"/favicon.svg", "<svg/>", "", 200},
		{"/assets/app-1a.js", "console.log(1)", "public, max-age=31536000, immutable", 200},
		{"/assets/app-old.js", "", "", 404},
	} {
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest("GET", tc.path, nil))
		if rec.Code != tc.wantStatus {
			t.Errorf("%s: status %d, want %d", tc.path, rec.Code, tc.wantStatus)
			continue
		}
		if tc.wantBody != "" && rec.Body.String() != tc.wantBody {
			t.Errorf("%s: body %q, want %q", tc.path, rec.Body, tc.wantBody)
		}
		if got := rec.Header().Get("Cache-Control"); got != tc.wantCache {
			t.Errorf("%s: Cache-Control %q, want %q", tc.path, got, tc.wantCache)
		}
	}

	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("GET", "/assets/app-1a.js", nil))
	if ct := rec.Header().Get("Content-Type"); !strings.HasPrefix(ct, "text/javascript") {
		t.Errorf("js Content-Type = %q", ct)
	}

	rec = httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("POST", "/favicon.svg", nil))
	if rec.Code != http.StatusMethodNotAllowed {
		t.Errorf("POST: status %d, want 405", rec.Code)
	}

	rec = httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest("GET", "/index.html", nil))
	if rec.Code != http.StatusMovedPermanently || rec.Header().Get("Location") != "./" {
		t.Errorf("/index.html: status %d Location %q, want redirect to ./", rec.Code, rec.Header().Get("Location"))
	}
}
