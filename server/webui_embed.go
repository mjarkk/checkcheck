//go:build !dev

package main

import (
	"embed"
	"io/fs"
	"net/http"

	"checkcheck/internal/spa"
)

// Fails to compile until the frontend is built into webui/; use -tags dev to
// run without it.
//
//go:embed all:webui
var embedded embed.FS

func webUI() http.Handler {
	dist, err := fs.Sub(embedded, "webui")
	if err != nil {
		panic(err)
	}
	return spa.Handler(dist)
}
