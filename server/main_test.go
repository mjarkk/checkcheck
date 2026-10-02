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

	"github.com/coder/websocket"
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

// openEvents connects to the event socket at base and waits for ready.
func openEvents(t *testing.T, base string) *websocket.Conn {
	t.Helper()
	conn, _, err := websocket.Dial(t.Context(), "ws"+strings.TrimPrefix(base, "http")+"/api/events", nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.CloseNow() })
	if err := conn.Write(t.Context(), websocket.MessageText, []byte(`{"type":"auth","token":"secret"}`)); err != nil {
		t.Fatal(err)
	}
	if got := readEvent(t, conn); got != `{"type":"ready"}` {
		t.Fatalf("after auth: got %s, want ready", got)
	}
	return conn
}

func readEvent(t *testing.T, conn *websocket.Conn) string {
	t.Helper()
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()
	_, msg, err := conn.Read(ctx)
	if err != nil {
		t.Fatalf("read event: %v", err)
	}
	return string(msg)
}

func TestShutdownClosesEventSocketsWithGoingAway(t *testing.T) {
	st, err := store.Open(context.Background(), filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	hub := events.NewHub()
	srv := newServer("", st, hub, "secret", http.NotFoundHandler())
	defer srv.Close()
	go srv.Serve(ln)
	conn := openEvents(t, "http://"+ln.Addr().String())
	// Reading is what answers the server's close frame, which shutdown waits
	// for.
	readErr := make(chan error, 1)
	go func() {
		_, _, err := conn.Read(context.Background())
		readErr <- err
	}()

	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
	defer cancel()
	if err := shutdown(ctx, srv, hub); err != nil {
		t.Fatalf("shutdown with an open event socket: %v", err)
	}
	if ctx.Err() != nil {
		t.Fatal("shutdown waited for its deadline")
	}
	select {
	case err := <-readErr:
		if got := websocket.CloseStatus(err); got != websocket.StatusGoingAway {
			t.Errorf("socket closed with %v (%v), want %v", got, err, websocket.StatusGoingAway)
		}
	case <-time.After(time.Second):
		t.Error("socket still open after shutdown")
	}
}

func TestWritesThroughAPIAndMCPPublishChanged(t *testing.T) {
	ctx := context.Background()
	st, err := store.Open(ctx, filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	hub := events.NewHub()
	publishChanges(st, hub)
	srv := httptest.NewServer(routes(st, hub, "secret", http.NotFoundHandler()))
	defer srv.Close()
	conn := openEvents(t, srv.URL)

	req, _ := http.NewRequest("POST", srv.URL+"/api/items", strings.NewReader(`{"title":"Milk"}`))
	req.Header.Set("Authorization", "Bearer secret")
	req.Header.Set("X-Checkcheck-Client", "tab-1")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("POST /api/items: status %d", resp.StatusCode)
	}
	if got, want := readEvent(t, conn), `{"type":"changed","client":"tab-1"}`; got != want {
		t.Errorf("after an API write: got %s, want %s", got, want)
	}

	client := mcp.NewClient(&mcp.Implementation{Name: "test", Version: "0"}, nil)
	cs, err := client.Connect(ctx, &mcp.StreamableClientTransport{Endpoint: srv.URL + "/mcp/secret", MaxRetries: -1}, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer cs.Close()
	res, err := cs.CallTool(ctx, &mcp.CallToolParams{Name: "add_items", Arguments: map[string]any{"items": []any{map[string]any{"title": "Eggs"}}}})
	if err != nil || res.IsError {
		t.Fatalf("add_items: %v, %+v", err, res)
	}
	if got, want := readEvent(t, conn), `{"type":"changed"}`; got != want {
		t.Errorf("after an MCP write: got %s, want %s", got, want)
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
