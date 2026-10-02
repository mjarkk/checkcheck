package main

import (
	"context"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	"checkcheck/internal/events"
	"checkcheck/internal/store"
)

func TestRoutes(t *testing.T) {
	st, err := store.Open(context.Background(), filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	ui := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { io.WriteString(w, "ui") })
	srv := httptest.NewServer(routes(st, events.NewHub(), "secret", ui))
	defer srv.Close()

	for _, tc := range []struct {
		method, path string
		auth         bool
		wantStatus   int
		wantBody     string
	}{
		{"GET", "/api/health", false, 200, `{"status":"ok"}`},
		{"GET", "/api/items", false, 401, `"error"`},
		{"GET", "/api/items", true, 200, `[]`},
		{"GET", "/api/nope", true, 404, `"error"`},
		{"GET", "/api", true, 404, `"error"`},
		{"POST", "/mcp", false, 401, `"error"`},
		{"POST", "/mcp/wrong", false, 401, `"error"`},
		{"GET", "/", false, 200, "ui"},
		{"GET", "/lists/1", false, 200, "ui"},
	} {
		req, _ := http.NewRequest(tc.method, srv.URL+tc.path, nil)
		if tc.auth {
			req.Header.Set("Authorization", "Bearer secret")
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		body, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		if resp.StatusCode != tc.wantStatus || !strings.Contains(string(body), tc.wantBody) {
			t.Errorf("%s %s: %d %s, want %d containing %s", tc.method, tc.path, resp.StatusCode, body, tc.wantStatus, tc.wantBody)
		}
	}
}

func TestMCPTokenInPath(t *testing.T) {
	ctx := context.Background()
	st, err := store.Open(ctx, filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	const token = "s3cret/with space?"
	srv := httptest.NewServer(routes(st, events.NewHub(), token, http.NotFoundHandler()))
	defer srv.Close()

	connect := func(pathToken string) (*mcp.ClientSession, error) {
		client := mcp.NewClient(&mcp.Implementation{Name: "test", Version: "0"}, nil)
		return client.Connect(ctx, &mcp.StreamableClientTransport{
			Endpoint:   srv.URL + "/mcp/" + url.PathEscape(pathToken),
			MaxRetries: -1,
		}, nil)
	}

	cs, err := connect(token)
	if err != nil {
		t.Fatalf("connect with the token in the path: %v", err)
	}
	defer cs.Close()
	if _, err := cs.ListTools(ctx, nil); err != nil {
		t.Errorf("list tools: %v", err)
	}

	if cs, err := connect("wrong"); err == nil {
		cs.Close()
		t.Error("connected with a wrong path token")
	}
}

func TestShutdownEndsEventStreams(t *testing.T) {
	st, err := store.Open(context.Background(), filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	srv := newServer("", st, events.NewHub(), "secret", http.NotFoundHandler())
	defer srv.Close()
	go srv.Serve(ln)

	req, _ := http.NewRequest("GET", "http://"+ln.Addr().String()+"/api/events", nil)
	req.Header.Set("Authorization", "Bearer secret")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status %d", resp.StatusCode)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if err := srv.Shutdown(ctx); err != nil {
		t.Fatalf("shutdown with an open event stream: %v", err)
	}
	if _, err := io.ReadAll(resp.Body); err != nil {
		t.Errorf("stream did not end cleanly: %v", err)
	}
}

func TestLoadTokenGeneratesOnceAndReuses(t *testing.T) {
	t.Setenv("CHECKCHECK_TOKEN", "")
	dir := t.TempDir()
	first, err := loadToken(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(first) != 64 {
		t.Errorf("token %q, want 64 hex chars", first)
	}
	info, err := os.Stat(filepath.Join(dir, "token"))
	if err != nil {
		t.Fatal(err)
	}
	if perm := info.Mode().Perm(); perm != 0o600 {
		t.Errorf("token file mode %o, want 600", perm)
	}
	second, err := loadToken(dir)
	if err != nil || second != first {
		t.Errorf("second load = %q, %v; want %q", second, err, first)
	}

	t.Setenv("CHECKCHECK_TOKEN", "from-env")
	if got, _ := loadToken(dir); got != "from-env" {
		t.Errorf("env token ignored: got %q", got)
	}
}
