package spa

import (
	"io/fs"
	"net/http"
	"path"
	"strings"
)

// Handler answers any path that is not a file (except under assets/) with
// index.html, so the caller must route /api and /mcp elsewhere.
func Handler(fsys fs.FS) http.Handler {
	files := http.FileServerFS(fsys)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			w.Header().Set("Allow", "GET, HEAD")
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		name := strings.TrimPrefix(path.Clean(r.URL.Path), "/")
		if info, err := fs.Stat(fsys, name); name == "" || name == "index.html" || err != nil || info.IsDir() {
			// A missing hashed asset is a stale deploy; index.html in its place
			// would fail as a script with a MIME error instead of a 404.
			if strings.HasPrefix(name, "assets/") {
				http.NotFound(w, r)
				return
			}
			w.Header().Set("Cache-Control", "no-cache")
			http.ServeFileFS(w, r, fsys, "index.html")
			return
		}
		if strings.HasPrefix(name, "assets/") {
			w.Header().Set("Cache-Control", "public, max-age=31536000, immutable")
		}
		files.ServeHTTP(w, r)
	})
}
