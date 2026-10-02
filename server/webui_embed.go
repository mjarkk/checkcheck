//go:build !dev

package main

import (
	"embed"
	"io/fs"
	"net/http"

	"checkcheck/internal/spa"
)

// Fails to compile until the frontend is built into web/dist; use -tags dev
// to run without it.
//
//go:embed all:web/dist
var embedded embed.FS

func webUI() http.Handler {
	dist, err := fs.Sub(embedded, "web/dist")
	if err != nil {
		panic(err)
	}
	return spa.Handler(dist)
}
