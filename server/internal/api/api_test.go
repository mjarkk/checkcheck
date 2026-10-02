package api

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"

	"checkcheck/internal/events"
	"checkcheck/internal/store"
)

const testToken = "secret"

func newTestServer(t *testing.T) *httptest.Server {
	t.Helper()
	srv, _ := newTestServerWithHub(t, events.NewHub())
	return srv
}

func newTestServerWithHub(t *testing.T, hub *events.Hub) (*httptest.Server, *store.Store) {
	t.Helper()
	st, err := store.Open(context.Background(), filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	srv := httptest.NewServer(Handler(st, hub, testToken))
	t.Cleanup(srv.Close)
	return srv, st
}

type client struct {
	t   *testing.T
	url string
}

func (c client) do(method, path, body string) (int, []byte) {
	c.t.Helper()
	return c.doWith(method, path, body, nil)
}

func (c client) doWith(method, path, body string, header http.Header) (int, []byte) {
	c.t.Helper()
	var r io.Reader
	if body != "" {
		r = strings.NewReader(body)
	}
	req, err := http.NewRequest(method, c.url+path, r)
	if err != nil {
		c.t.Fatal(err)
	}
	for k, v := range header {
		req.Header[k] = v
	}
	req.Header.Set("Authorization", "Bearer "+testToken)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		c.t.Fatal(err)
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		c.t.Fatal(err)
	}
	return resp.StatusCode, b
}

func (c client) expect(method, path, body string, wantStatus int, into any) {
	c.t.Helper()
	status, b := c.do(method, path, body)
	if status != wantStatus {
		c.t.Fatalf("%s %s %s: status %d, want %d; body %s", method, path, body, status, wantStatus, b)
	}
	if into != nil {
		if err := json.Unmarshal(b, into); err != nil {
			c.t.Fatalf("%s %s: decode %s: %v", method, path, b, err)
		}
	}
}

func TestAuth(t *testing.T) {
	srv := newTestServer(t)
	for _, method := range []string{"GET", "POST"} {
		for _, header := range []string{"", "Bearer wrong", "Basic " + testToken, testToken} {
			req, _ := http.NewRequest(method, srv.URL+"/api/items", nil)
			if header != "" {
				req.Header.Set("Authorization", header)
			}
			resp, err := http.DefaultClient.Do(req)
			if err != nil {
				t.Fatal(err)
			}
			var body map[string]string
			json.NewDecoder(resp.Body).Decode(&body)
			resp.Body.Close()
			if resp.StatusCode != http.StatusUnauthorized || body["error"] == "" {
				t.Errorf("%s /api/items with Authorization %q: status %d body %v, want 401 with error", method, header, resp.StatusCode, body)
			}
		}
	}

	resp, err := http.Get(srv.URL + "/api/health")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Errorf("health without token: status %d, want 200", resp.StatusCode)
	}

	req, _ := http.NewRequest("GET", srv.URL+"/api/items", nil)
	req.Header.Set("Authorization", "bearer "+testToken)
	resp, err = http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Errorf("lowercase scheme: status %d, want 200", resp.StatusCode)
	}
}

func TestUnknownRoutesAreJSON404(t *testing.T) {
	c := client{t, newTestServer(t).URL}
	for _, tc := range []struct{ method, path string }{
		{"GET", "/api/nope"},
		{"GET", "/api/"},
		{"PUT", "/api/items"},
		{"PUT", "/api/items/1"},
		{"POST", "/api/categories/1"},
		{"POST", "/api/categories/order"},
	} {
		var body map[string]string
		c.expect(tc.method, tc.path, "", http.StatusNotFound, &body)
		if body["error"] == "" {
			t.Errorf("%s %s: body %v, want error message", tc.method, tc.path, body)
		}
	}
}

func TestCategoriesAndItems(t *testing.T) {
	c := client{t, newTestServer(t).URL}

	var empty []any
	c.expect("GET", "/api/items", "", http.StatusOK, &empty)
	if empty == nil {
		t.Error("empty item list must be [], not null")
	}

	var groceries store.Category
	c.expect("POST", "/api/categories", `{"name":" Groceries "}`, http.StatusCreated, &groceries)
	if groceries.Name != "Groceries" || groceries.ID == 0 {
		t.Fatalf("created %+v", groceries)
	}
	c.expect("POST", "/api/categories", `{"name":"groceries"}`, http.StatusConflict, nil)
	c.expect("POST", "/api/categories", `{"name":""}`, http.StatusBadRequest, nil)
	c.expect("POST", "/api/categories", `{"name":`, http.StatusBadRequest, nil)
	c.expect("POST", "/api/categories", `{"name":`+`"`+strings.Repeat("x", maxBodyBytes)+`"}`, http.StatusBadRequest, nil)

	var hardware store.Category
	c.expect("POST", "/api/categories", `{"name":"hardware"}`, http.StatusCreated, &hardware)
	c.expect("PATCH", "/api/categories/"+itoa(hardware.ID), `{"name":"Hardware"}`, http.StatusOK, &hardware)
	if hardware.Name != "Hardware" {
		t.Errorf("renamed %+v", hardware)
	}
	c.expect("PATCH", "/api/categories/"+itoa(hardware.ID), `{"name":"GROCERIES"}`, http.StatusConflict, nil)
	c.expect("PATCH", "/api/categories/999", `{"name":"x"}`, http.StatusNotFound, nil)
	c.expect("PATCH", "/api/categories/abc", `{"name":"x"}`, http.StatusBadRequest, nil)

	var item store.Item
	c.expect("POST", "/api/items", `{"title":"Milk","category_id":`+itoa(groceries.ID)+`}`, http.StatusCreated, &item)
	if item.Title != "Milk" || item.Checked || item.CategoryID == nil || *item.CategoryID != groceries.ID {
		t.Fatalf("created %+v", item)
	}
	c.expect("POST", "/api/items", `{"title":"Milk","category_id":999}`, http.StatusBadRequest, nil)
	c.expect("POST", "/api/items", `{"title":"Milk","category_id":"1"}`, http.StatusBadRequest, nil)
	c.expect("POST", "/api/items", `{"title":"  "}`, http.StatusBadRequest, nil)

	var loose store.Item
	c.expect("POST", "/api/items", `{"title":"Nails","category_id":null}`, http.StatusCreated, &loose)
	if loose.CategoryID != nil {
		t.Errorf("explicit null category: %+v", loose)
	}

	path := "/api/items/" + itoa(item.ID)
	c.expect("PATCH", path, `{"checked":true}`, http.StatusOK, &item)
	if !item.Checked || item.CategoryID == nil {
		t.Fatalf("omitted category_id must be left alone: %+v", item)
	}
	c.expect("PATCH", path, `{"category_id":999}`, http.StatusBadRequest, nil)
	c.expect("PATCH", path, `{"title":""}`, http.StatusBadRequest, nil)
	c.expect("PATCH", path, `{"category_id":null}`, http.StatusOK, &item)
	if item.CategoryID != nil || !item.Checked {
		t.Fatalf("null category_id must uncategorize: %+v", item)
	}
	c.expect("PATCH", path, `{"category_id":`+itoa(hardware.ID)+`,"title":"Glue"}`, http.StatusOK, &item)
	if item.CategoryID == nil || *item.CategoryID != hardware.ID || item.Title != "Glue" {
		t.Fatalf("move+rename: %+v", item)
	}
	c.expect("PATCH", "/api/items/999", `{"checked":true}`, http.StatusNotFound, nil)

	c.expect("DELETE", "/api/categories/"+itoa(hardware.ID), "", http.StatusNoContent, nil)
	c.expect("DELETE", "/api/categories/"+itoa(hardware.ID), "", http.StatusNotFound, nil)

	var items []store.Item
	c.expect("GET", "/api/items", "", http.StatusOK, &items)
	if len(items) != 2 || items[0].ID != item.ID || items[0].CategoryID != nil {
		t.Fatalf("after category delete: %+v", items)
	}

	var cats []store.Category
	c.expect("GET", "/api/categories", "", http.StatusOK, &cats)
	if len(cats) != 1 || cats[0].ID != groceries.ID {
		t.Fatalf("categories: %+v", cats)
	}

	c.expect("DELETE", path, "", http.StatusNoContent, nil)
	c.expect("DELETE", path, "", http.StatusNotFound, nil)
}

func TestRecentlyDeleted(t *testing.T) {
	c := client{t, newTestServer(t).URL}

	var none []store.DeletedItem
	c.expect("GET", "/api/items/deleted", "", http.StatusOK, &none)
	if none == nil {
		t.Error("empty deleted list must be [], not null")
	}

	var groceries store.Category
	c.expect("POST", "/api/categories", `{"name":"Groceries"}`, http.StatusCreated, &groceries)
	var item store.Item
	c.expect("POST", "/api/items", `{"title":"Milk","category_id":`+itoa(groceries.ID)+`}`, http.StatusCreated, &item)
	path := "/api/items/" + itoa(item.ID)
	c.expect("PATCH", path, `{"checked":true}`, http.StatusOK, &item)
	c.expect("DELETE", path, "", http.StatusNoContent, nil)

	var items []store.Item
	c.expect("GET", "/api/items", "", http.StatusOK, &items)
	if len(items) != 0 {
		t.Errorf("items = %+v, want the deleted one left out", items)
	}
	var deleted []map[string]any
	c.expect("GET", "/api/items/deleted", "", http.StatusOK, &deleted)
	if len(deleted) != 1 || deleted[0]["title"] != "Milk" || deleted[0]["checked"] != true || deleted[0]["deleted_at"] == nil {
		t.Fatalf("deleted = %+v", deleted)
	}
	if _, ok := deleted[0]["category_id"]; ok {
		t.Errorf("deleted item has a category_id: %+v", deleted[0])
	}
	c.expect("PATCH", path, `{"checked":false}`, http.StatusNotFound, nil)
	c.expect("DELETE", path, "", http.StatusNotFound, nil)

	var restored store.Item
	c.expect("POST", path+"/restore", "", http.StatusOK, &restored)
	if restored.ID != item.ID || restored.CategoryID != nil || !restored.Checked {
		t.Errorf("restored = %+v, want it uncategorized and still checked", restored)
	}
	c.expect("POST", path+"/restore", "", http.StatusNotFound, nil)
	c.expect("POST", "/api/items/999/restore", "", http.StatusNotFound, nil)
	c.expect("POST", "/api/items/abc/restore", "", http.StatusBadRequest, nil)
	c.expect("GET", "/api/items/deleted", "", http.StatusOK, &deleted)
	if len(deleted) != 0 {
		t.Errorf("deleted after restore = %+v", deleted)
	}
}

func TestCategoryOrder(t *testing.T) {
	c := client{t, newTestServer(t).URL}
	order := func() string {
		t.Helper()
		status, b := c.do("GET", "/api/categories/order", "")
		if status != http.StatusOK {
			t.Fatalf("GET order: status %d; body %s", status, b)
		}
		return strings.TrimSpace(string(b))
	}
	if got := order(); got != `{"order":[null]}` {
		t.Errorf("empty order = %s, want only Uncategorized", got)
	}
	ids := map[string]string{}
	for _, name := range []string{"b", "a"} {
		var cat store.Category
		c.expect("POST", "/api/categories", `{"name":"`+name+`"}`, http.StatusCreated, &cat)
		ids[name] = itoa(cat.ID)
	}
	a, b := ids["a"], ids["b"]
	if got, want := order(), `{"order":[`+b+`,`+a+`,null]}`; got != want {
		t.Errorf("order = %s, want %s", got, want)
	}
	var raw []map[string]any
	c.expect("GET", "/api/categories", "", http.StatusOK, &raw)
	if _, ok := raw[0]["position"]; ok {
		t.Errorf("category %v exposes position; the order is /api/categories/order only", raw[0])
	}

	body := `{"order":[null,` + a + `,` + b + `]}`
	status, got := c.do("PUT", "/api/categories/order", body)
	if status != http.StatusOK || strings.TrimSpace(string(got)) != body {
		t.Errorf("PUT %s: status %d body %s, want 200 with the new order", body, status, got)
	}
	if got := order(); got != body {
		t.Errorf("order = %s, want %s", got, body)
	}
	var cats []store.Category
	c.expect("GET", "/api/categories", "", http.StatusOK, &cats)
	if len(cats) != 2 || itoa(cats[0].ID) != a || itoa(cats[1].ID) != b {
		t.Errorf("categories = %+v, want in category order", cats)
	}

	var cat store.Category
	c.expect("POST", "/api/categories", `{"name":"c"}`, http.StatusCreated, &cat)
	ids["c"] = itoa(cat.ID)
	if got, want := order(), `{"order":[null,`+a+`,`+b+`,`+ids["c"]+`]}`; got != want {
		t.Errorf("after create: order = %s, want %s", got, want)
	}
	c.expect("DELETE", "/api/categories/"+a, "", http.StatusNoContent, nil)
	want := `{"order":[null,` + b + `,` + ids["c"] + `]}`
	if got := order(); got != want {
		t.Errorf("after delete: order = %s, want %s", got, want)
	}

	for _, body := range []string{
		`{"order":[` + b + `,null]}`,
		`{"order":[` + b + `,` + b + `,null]}`,
		`{"order":[` + b + `,` + ids["c"] + `,` + a + `,null]}`,
		`{"order":[` + b + `,` + ids["c"] + `]}`,
		`{"order":[null,` + b + `,` + ids["c"] + `,null]}`,
		`{}`,
		`{"order":`,
		`{"order":["` + b + `",` + ids["c"] + `,null]}`,
		`{"order":[1.5,null]}`,
	} {
		c.expect("PUT", "/api/categories/order", body, http.StatusBadRequest, nil)
	}
	if got := order(); got != want {
		t.Errorf("after rejected PUTs: order = %s, want %s", got, want)
	}
}

func TestItemOrder(t *testing.T) {
	c := client{t, newTestServer(t).URL}
	var cat store.Category
	c.expect("POST", "/api/categories", `{"name":"Groceries"}`, http.StatusCreated, &cat)
	ids := map[string]string{}
	for _, title := range []string{"a", "b", "c"} {
		var it store.Item
		c.expect("POST", "/api/items", `{"title":"`+title+`"}`, http.StatusCreated, &it)
		ids[title] = itoa(it.ID)
	}
	order := func() string {
		t.Helper()
		var items []store.Item
		c.expect("GET", "/api/items", "", http.StatusOK, &items)
		var out []string
		for _, it := range items {
			out = append(out, it.Title)
		}
		return strings.Join(out, ",")
	}
	if got := order(); got != "a,b,c" {
		t.Fatalf("order = %q, want new items appended", got)
	}
	var raw []map[string]any
	c.expect("GET", "/api/items", "", http.StatusOK, &raw)
	if _, ok := raw[0]["position"]; ok {
		t.Errorf("item %v exposes position; the order is the list order only", raw[0])
	}

	for _, tc := range []struct{ item, body, want string }{
		{"c", `{"before_id":` + ids["a"] + `}`, "c,a,b"},
		{"b", `{"before_id":` + ids["a"] + `}`, "c,b,a"},
		{"c", `{"before_id":null}`, "b,a,c"},
		{"a", `{"title":"a"}`, "b,a,c"},
	} {
		c.expect("PATCH", "/api/items/"+ids[tc.item], tc.body, http.StatusOK, nil)
		if got := order(); got != tc.want {
			t.Errorf("PATCH %s %s: order = %q, want %q", tc.item, tc.body, got, tc.want)
		}
	}

	var item store.Item
	c.expect("PATCH", "/api/items/"+ids["c"], `{"checked":true,"category_id":`+itoa(cat.ID)+`,"before_id":`+ids["a"]+`}`, http.StatusOK, &item)
	if !item.Checked || item.CategoryID == nil || *item.CategoryID != cat.ID {
		t.Errorf("check+categorize+move: %+v", item)
	}
	if got := order(); got != "b,c,a" {
		t.Errorf("after check+categorize+move: order = %q, want b,c,a", got)
	}

	c.expect("PATCH", "/api/items/"+ids["c"], `{"before_id":`+ids["c"]+`}`, http.StatusBadRequest, nil)
	c.expect("PATCH", "/api/items/"+ids["c"], `{"checked":false,"before_id":999}`, http.StatusBadRequest, nil)
	c.expect("PATCH", "/api/items/"+ids["c"], `{"before_id":"1"}`, http.StatusBadRequest, nil)
	c.expect("PATCH", "/api/items/999", `{"before_id":null}`, http.StatusNotFound, nil)
	var items []store.Item
	c.expect("GET", "/api/items", "", http.StatusOK, &items)
	if !items[1].Checked {
		t.Errorf("rejected PATCH was partly applied: %+v", items[1])
	}
	if got := order(); got != "b,c,a" {
		t.Errorf("after rejected PATCHes: order = %q, want unchanged", got)
	}

	c.expect("DELETE", "/api/items/"+ids["c"], "", http.StatusNoContent, nil)
	var d store.Item
	c.expect("POST", "/api/items", `{"title":"d"}`, http.StatusCreated, &d)
	ids["d"] = itoa(d.ID)
	c.expect("PATCH", "/api/items/"+ids["d"], `{"before_id":`+ids["a"]+`}`, http.StatusOK, nil)
	if got := order(); got != "b,d,a" {
		t.Errorf("after delete, create and move: order = %q, want b,d,a", got)
	}
}

func TestTimestampsAreRFC3339UTC(t *testing.T) {
	c := client{t, newTestServer(t).URL}
	var raw map[string]any
	c.expect("POST", "/api/items", `{"title":"Milk"}`, http.StatusCreated, &raw)
	for _, k := range []string{"created_at", "updated_at"} {
		s, _ := raw[k].(string)
		if !strings.HasSuffix(s, "Z") || len(s) != len("2026-10-01T15:04:05Z") {
			t.Errorf("%s = %q, want RFC 3339 UTC", k, s)
		}
	}
	for _, k := range []string{"category_id", "link", "preview"} {
		if v, ok := raw[k]; !ok || v != nil {
			t.Errorf("%s = %v (present %v), want explicit null", k, v, ok)
		}
	}
}

func TestItemLink(t *testing.T) {
	c := client{t, newTestServer(t).URL}
	var it store.Item
	c.expect("POST", "/api/items", `{"title":"Read (https://example.com/post)."}`, http.StatusCreated, &it)
	if it.Link == nil || *it.Link != "https://example.com/post" || it.Preview != nil {
		t.Errorf("created %+v, want link https://example.com/post and no preview yet", it)
	}
	var raw map[string]any
	c.expect("PATCH", "/api/items/"+itoa(it.ID), `{"title":"Read it later"}`, http.StatusOK, &raw)
	if v, ok := raw["link"]; !ok || v != nil {
		t.Errorf("link after removing it = %v (present %v), want explicit null", v, ok)
	}
}

func dialEvents(t *testing.T, srv *httptest.Server) *websocket.Conn {
	t.Helper()
	conn, _, err := websocket.Dial(t.Context(), "ws"+strings.TrimPrefix(srv.URL, "http")+"/api/events", nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.CloseNow() })
	return conn
}

func sendText(t *testing.T, conn *websocket.Conn, msg string) {
	t.Helper()
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()
	if err := conn.Write(ctx, websocket.MessageText, []byte(msg)); err != nil {
		t.Fatal(err)
	}
}

func receiveText(t *testing.T, conn *websocket.Conn) string {
	t.Helper()
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()
	typ, msg, err := conn.Read(ctx)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if typ != websocket.MessageText {
		t.Errorf("message type %v, want text", typ)
	}
	return string(msg)
}

// closeCode reads until the server closes conn and returns its close code.
func closeCode(t *testing.T, conn *websocket.Conn) websocket.StatusCode {
	t.Helper()
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()
	for {
		if _, _, err := conn.Read(ctx); err != nil {
			return websocket.CloseStatus(err)
		}
	}
}

const authMessage = `{"type":"auth","token":"` + testToken + `","client":"tab-1"}`

func TestEventsAuth(t *testing.T) {
	srv := newTestServer(t)
	for _, tc := range []struct {
		first string
		want  websocket.StatusCode
	}{
		{`{"type":"auth","token":"wrong"}`, closeUnauthorized},
		{`{"type":"auth","token":""}`, closeUnauthorized},
		{`{"type":"auth"}`, websocket.StatusPolicyViolation},
		{`{"type":"auth","token":1}`, websocket.StatusPolicyViolation},
		{`{"type":"hello","token":"` + testToken + `"}`, websocket.StatusPolicyViolation},
		{`{"token":"` + testToken + `"}`, websocket.StatusPolicyViolation},
		{`auth ` + testToken, websocket.StatusPolicyViolation},
	} {
		conn := dialEvents(t, srv)
		sendText(t, conn, tc.first)
		if got := closeCode(t, conn); got != tc.want {
			t.Errorf("first message %s: closed with %v, want %v", tc.first, got, tc.want)
		}
	}

	conn := dialEvents(t, srv)
	if err := conn.Write(t.Context(), websocket.MessageBinary, []byte(authMessage)); err != nil {
		t.Fatal(err)
	}
	if got := closeCode(t, conn); got != websocket.StatusPolicyViolation {
		t.Errorf("binary auth message: closed with %v, want %v", got, websocket.StatusPolicyViolation)
	}

	conn = dialEvents(t, srv)
	sendText(t, conn, `{"type":"auth","token":"`+testToken+`"}`)
	if got := receiveText(t, conn); got != `{"type":"ready"}` {
		t.Errorf("auth without client: got %s, want ready", got)
	}

	defer func(d time.Duration) { authTimeout = d }(authTimeout)
	authTimeout = 50 * time.Millisecond
	conn = dialEvents(t, srv)
	if got := closeCode(t, conn); got != websocket.StatusPolicyViolation {
		t.Errorf("no auth message: closed with %v, want %v", got, websocket.StatusPolicyViolation)
	}
}

func TestEvents(t *testing.T) {
	hub := events.NewHub()
	srv, _ := newTestServerWithHub(t, hub)
	conn := dialEvents(t, srv)
	sendText(t, conn, authMessage)
	if got := receiveText(t, conn); got != `{"type":"ready"}` {
		t.Fatalf("after auth: got %s, want ready", got)
	}

	for _, tc := range []struct {
		e    events.Event
		want string
	}{
		{events.Event{Type: "changed", Client: "tab-2"}, `{"type":"changed","client":"tab-2"}`},
		{events.Event{Type: "changed"}, `{"type":"changed"}`},
		{
			events.Event{Type: "preview", Link: "https://example.com/post", Preview: &store.Preview{Title: "A post", SiteName: "Example"}},
			`{"type":"preview","link":"https://example.com/post","preview":{"title":"A post","site_name":"Example"}}`,
		},
	} {
		hub.Publish(tc.e)
		if got := receiveText(t, conn); got != tc.want {
			t.Errorf("published %+v: got %s, want %s", tc.e, got, tc.want)
		}
	}

	chatty := dialEvents(t, srv)
	sendText(t, chatty, authMessage)
	receiveText(t, chatty)
	sendText(t, chatty, `{"type":"ping"}`)
	if got := closeCode(t, chatty); got != websocket.StatusPolicyViolation {
		t.Errorf("message after auth: closed with %v, want %v", got, websocket.StatusPolicyViolation)
	}

	hub.Close()
	if got := closeCode(t, conn); got != websocket.StatusGoingAway {
		t.Errorf("after hub close: closed with %v, want %v", got, websocket.StatusGoingAway)
	}
}

func TestEventsPing(t *testing.T) {
	defer func(d time.Duration) { pingInterval = d }(pingInterval)
	pingInterval = 20 * time.Millisecond
	conn := dialEvents(t, newTestServer(t))
	sendText(t, conn, authMessage)
	receiveText(t, conn)
	for range 2 {
		if got := receiveText(t, conn); got != `{"type":"ping"}` {
			t.Errorf("idle socket got %s, want ping", got)
		}
	}
}

func TestEventsDisconnectsASubscriberThatFellBehind(t *testing.T) {
	hub := events.NewHub()
	srv, _ := newTestServerWithHub(t, hub)
	conn := dialEvents(t, srv)
	conn.SetReadLimit(-1)
	sendText(t, conn, authMessage)
	receiveText(t, conn)

	// Big enough that, while the client doesn't read, the socket buffers
	// hold far fewer of these than the hub buffers.
	big := events.Event{Type: "preview", Link: strings.Repeat("x", 1<<20)}
	for range 48 {
		hub.Publish(big)
	}
	if got := closeCode(t, conn); got != websocket.StatusTryAgainLater {
		t.Errorf("after falling behind: closed with %v, want %v", got, websocket.StatusTryAgainLater)
	}
}

func TestIdempotencyKey(t *testing.T) {
	srv, st := newTestServerWithHub(t, events.NewHub())
	c := client{t, srv.URL}
	key := func(k string) http.Header { return http.Header{"Idempotency-Key": {k}} }
	post := func(path, body string, header http.Header, wantStatus int) map[string]any {
		t.Helper()
		status, b := c.doWith("POST", path, body, header)
		var v map[string]any
		json.Unmarshal(b, &v)
		if status != wantStatus {
			t.Fatalf("POST %s %s with %v: status %d, want %d; body %s", path, body, header, status, wantStatus, b)
		}
		return v
	}
	count := func(path string) int {
		t.Helper()
		var list []any
		c.expect("GET", path, "", http.StatusOK, &list)
		return len(list)
	}

	const link = "https://example.com/post"
	if err := st.SavePreview(context.Background(), link, store.Preview{Title: "A post"}); err != nil {
		t.Fatal(err)
	}
	item := post("/api/items", `{"title":"Read `+link+`"}`, key("k1"), http.StatusCreated)
	again := post("/api/items", `{"title":""}`, key("k1"), http.StatusCreated)
	if again["id"] != item["id"] || again["title"] != item["title"] || again["preview"] == nil {
		t.Errorf("replay = %v, want %v with its preview", again, item)
	}
	cat := post("/api/categories", `{"name":"Groceries"}`, key("k1"), http.StatusCreated)
	if again := post("/api/categories", `{"name":"Other"}`, key("k1"), http.StatusCreated); again["id"] != cat["id"] {
		t.Errorf("category replay = %v, want %v", again, cat)
	}
	if n := count("/api/items"); n != 1 {
		t.Errorf("%d items, want 1", n)
	}
	if n := count("/api/categories"); n != 1 {
		t.Errorf("%d categories, want 1", n)
	}

	for _, header := range []http.Header{key(""), key(strings.Repeat("é", 101)), {"Idempotency-Key": {"a", "b"}}} {
		for _, path := range []string{"/api/items", "/api/categories"} {
			if body := post(path, `{"title":"x","name":"x"}`, header, http.StatusBadRequest); body["error"] == nil {
				t.Errorf("POST %s with %v: body %v, want an error", path, header, body)
			}
		}
	}
	post("/api/items", `{"title":"x"}`, key(strings.Repeat("é", 100)), http.StatusCreated)

	post("/api/items", `{"title":" "}`, key("k2"), http.StatusBadRequest)
	post("/api/categories", `{"name":"groceries"}`, key("k2"), http.StatusConflict)
	post("/api/items", `{"title":"Eggs"}`, key("k2"), http.StatusCreated)
	post("/api/categories", `{"name":"Hardware"}`, key("k2"), http.StatusCreated)
	post("/api/items", `{"title":"Eggs"}`, nil, http.StatusCreated)
	post("/api/items", `{"title":"Eggs"}`, nil, http.StatusCreated)
	if n := count("/api/items"); n != 5 {
		t.Errorf("%d items, want 5", n)
	}

	c.expect("DELETE", "/api/items/"+itoa(int64(item["id"].(float64))), "", http.StatusNoContent, nil)
	post("/api/items", `{"title":"Read `+link+`"}`, key("k1"), http.StatusNotFound)
	c.expect("DELETE", "/api/categories/"+itoa(int64(cat["id"].(float64))), "", http.StatusNoContent, nil)
	post("/api/categories", `{"name":"Groceries"}`, key("k1"), http.StatusNotFound)
}

func TestWritesReportChangesWithTheClientID(t *testing.T) {
	srv, st := newTestServerWithHub(t, events.NewHub())
	c := client{t, srv.URL}
	changes := make(chan string, 16)
	st.OnChange(func(ctx context.Context) { changes <- ClientID(ctx) })
	expectChanges := func(what string, want ...string) {
		t.Helper()
		var got []string
		for len(changes) > 0 {
			got = append(got, <-changes)
		}
		if strings.Join(got, " ") != strings.Join(want, " ") || len(got) != len(want) {
			t.Errorf("%s: changes from %q, want %q", what, got, want)
		}
	}
	tab := http.Header{"X-Checkcheck-Client": {"tab-1"}}
	call := func(method, path, body string, header http.Header, wantStatus int) []byte {
		t.Helper()
		status, b := c.doWith(method, path, body, header)
		if status != wantStatus {
			t.Fatalf("%s %s: status %d, want %d; body %s", method, path, status, wantStatus, b)
		}
		return b
	}

	var cat store.Category
	json.Unmarshal(call("POST", "/api/categories", `{"name":"a"}`, tab, http.StatusCreated), &cat)
	var item store.Item
	json.Unmarshal(call("POST", "/api/items", `{"title":"a"}`, tab, http.StatusCreated), &item)
	expectChanges("creates", "tab-1", "tab-1")
	for _, w := range []struct{ method, path, body string }{
		{"PATCH", "/api/categories/" + itoa(cat.ID), `{"name":"b"}`},
		{"PUT", "/api/categories/order", `{"order":[null,` + itoa(cat.ID) + `]}`},
		{"PATCH", "/api/items/" + itoa(item.ID), `{"checked":true,"before_id":null}`},
		{"DELETE", "/api/items/" + itoa(item.ID), ""},
		{"POST", "/api/items/" + itoa(item.ID) + "/restore", ""},
		{"DELETE", "/api/categories/" + itoa(cat.ID), ""},
	} {
		status, b := c.doWith(w.method, w.path, w.body, tab)
		if status >= 300 {
			t.Fatalf("%s %s: status %d; body %s", w.method, w.path, status, b)
		}
		expectChanges(w.method+" "+w.path, "tab-1")
	}

	for _, path := range []string{"/api/items", "/api/items/deleted", "/api/categories", "/api/categories/order"} {
		call("GET", path, "", tab, http.StatusOK)
	}
	call("PATCH", "/api/items/999", `{"checked":true}`, tab, http.StatusNotFound)
	expectChanges("reads and a failed write")

	keyed := http.Header{"X-Checkcheck-Client": {"tab-1"}, "Idempotency-Key": {"k"}}
	call("POST", "/api/items", `{"title":"b"}`, keyed, http.StatusCreated)
	call("POST", "/api/items", `{"title":"b"}`, keyed, http.StatusCreated)
	expectChanges("a keyed create and its replay", "tab-1")

	call("POST", "/api/items", `{"title":"c"}`, http.Header{"X-Checkcheck-Client": {strings.Repeat("é", 64)}}, http.StatusCreated)
	call("POST", "/api/items", `{"title":"c"}`, http.Header{"X-Checkcheck-Client": {strings.Repeat("é", 65)}}, http.StatusCreated)
	call("POST", "/api/items", `{"title":"c"}`, nil, http.StatusCreated)
	expectChanges("client ids of 64 and 65 characters and none", strings.Repeat("é", 64), "", "")
}

func itoa(id int64) string {
	return strconv.FormatInt(id, 10)
}
