package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io/fs"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"checkcheck/internal/api"
	"checkcheck/internal/events"
	"checkcheck/internal/linkpreview"
	"checkcheck/internal/mcpserver"
	"checkcheck/internal/store"
)

func main() {
	if err := run(); err != nil {
		slog.Error("fatal", "err", err)
		os.Exit(1)
	}
}

func run() error {
	addr := envOr("CHECKCHECK_ADDR", ":8080")
	dataDir := envOr("CHECKCHECK_DATA_DIR", "data")
	if err := os.MkdirAll(dataDir, 0o700); err != nil {
		return err
	}
	token, err := loadToken(dataDir)
	if err != nil {
		return err
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	st, err := store.Open(ctx, filepath.Join(dataDir, "checkcheck.db"))
	if err != nil {
		return fmt.Errorf("open database: %w", err)
	}
	defer st.Close()
	hub := events.NewHub()
	previews := linkpreview.NewService(st, hub, linkpreview.NewClient())
	defer previews.Close()
	st.OnMissingPreview(previews.Request)
	go purgeDeleted(ctx, st)

	srv := newServer(addr, st, hub, token, webUI())
	errc := make(chan error, 1)
	go func() { errc <- srv.ListenAndServe() }()
	slog.Info("listening", "addr", addr, "data_dir", dataDir)

	select {
	case err := <-errc:
		return err
	case <-ctx.Done():
	}
	slog.Info("shutting down")
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	return srv.Shutdown(shutdownCtx)
}

func newServer(addr string, st *store.Store, hub *events.Hub, token string, ui http.Handler) *http.Server {
	srv := &http.Server{Addr: addr, Handler: routes(st, hub, token, ui), ReadHeaderTimeout: 10 * time.Second}
	// Shutdown waits for every connection to go idle, which an open event
	// stream only does once the hub closes it.
	srv.RegisterOnShutdown(hub.Close)
	return srv
}

func routes(st *store.Store, hub *events.Hub, token string, ui http.Handler) http.Handler {
	mux := http.NewServeMux()
	mcp := mcpserver.Handler(st)
	mux.Handle("/api/", api.Handler(st, hub, token))
	mux.Handle("/mcp", api.RequireToken(token, mcp))
	mux.Handle("/mcp/{token}", api.RequirePathToken(token, mcp))
	mux.Handle("/", ui)
	return mux
}

// Hourly is enough: the store hides expired items itself, so this only frees
// their space.
func purgeDeleted(ctx context.Context, st *store.Store) {
	tick := time.NewTicker(time.Hour)
	defer tick.Stop()
	for {
		if n, err := st.PurgeDeleted(ctx); err != nil && ctx.Err() == nil {
			slog.Error("purge deleted items", "err", err)
		} else if n > 0 {
			slog.Info("purged deleted items", "count", n)
		}
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
		}
	}
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func loadToken(dataDir string) (string, error) {
	if t := os.Getenv("CHECKCHECK_TOKEN"); t != "" {
		return t, nil
	}
	path := filepath.Join(dataDir, "token")
	b, err := os.ReadFile(path)
	if err == nil {
		t := strings.TrimSpace(string(b))
		if t == "" {
			return "", fmt.Errorf("token file %s is empty", path)
		}
		return t, nil
	}
	if !errors.Is(err, fs.ErrNotExist) {
		return "", err
	}

	raw := make([]byte, 32)
	rand.Read(raw)
	t := hex.EncodeToString(raw)
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return "", err
	}
	if _, err := f.WriteString(t + "\n"); err != nil {
		f.Close()
		return "", err
	}
	if err := f.Close(); err != nil {
		return "", err
	}
	slog.Info("generated API token; use it as the Bearer token", "token", t, "path", path)
	return t, nil
}
