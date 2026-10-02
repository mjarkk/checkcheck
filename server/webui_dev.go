//go:build dev

package main

import (
	"log/slog"
	"net/http"
	"strings"
)

// The Vite dev server proxies /api and /mcp back to this process.
func webUI() http.Handler {
	target := strings.TrimSuffix(envOr("CHECKCHECK_DEV_WEB_URL", "http://localhost:5173"), "/")
	slog.Info("dev build: redirecting web UI", "to", target)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			w.Header().Set("Allow", "GET, HEAD")
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		http.Redirect(w, r, target+r.URL.RequestURI(), http.StatusFound)
	})
}
