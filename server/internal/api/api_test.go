package api

import (
	"bufio"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"checkcheck/internal/events"
	"checkcheck/internal/store"
)

const testToken = "secret"

func newTestServer(t *testing.T) *httptest.Server {
	t.Helper()
	return newTestServerWithHub(t, events.NewHub())
}

func newTestServerWithHub(t *testing.T, hub *events.Hub) *httptest.Server {
	t.Helper()
	st, err := store.Open(context.Background(), filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	srv := httptest.NewServer(Handler(st, hub, testToken))
	t.Cleanup(srv.Close)
	return srv
}

type client struct {
	t   *testing.T
	url string
}

func (c client) do(method, path, body string) (int, []byte) {
	c.t.Helper()
	var r io.Reader
	if body != "" {
		r = strings.NewReader(body)
	}
	req, err := http.NewRequest(method, c.url+path, r)
	if err != nil {
		c.t.Fatal(err)
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
	for _, path := range []string{"/api/items", "/api/events"} {
		for _, header := range []string{"", "Bearer wrong", "Basic " + testToken, testToken} {
			req, _ := http.NewRequest("GET", srv.URL+path, nil)
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
				t.Errorf("%s with Authorization %q: status %d body %v, want 401 with error", path, header, resp.StatusCode, body)
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

func TestEvents(t *testing.T) {
	hub := events.NewHub()
	srv := newTestServerWithHub(t, hub)
	req, _ := http.NewRequest("GET", srv.URL+"/api/events", nil)
	req.Header.Set("Authorization", "Bearer "+testToken)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	for k, want := range map[string]string{
		"Content-Type":      "text/event-stream",
		"Cache-Control":     "no-cache",
		"X-Accel-Buffering": "no",
	} {
		if got := resp.Header.Get(k); resp.StatusCode != http.StatusOK || got != want {
			t.Errorf("status %d %s %q, want 200 and %q", resp.StatusCode, k, got, want)
		}
	}
	body := bufio.NewReader(resp.Body)
	readMessage := func() string {
		t.Helper()
		var lines []string
		for {
			line, err := body.ReadString('\n')
			if err != nil {
				t.Fatalf("read stream after %q: %v", lines, err)
			}
			if line == "\n" {
				return strings.Join(lines, "")
			}
			lines = append(lines, line)
		}
	}
	if got := readMessage(); !strings.HasPrefix(got, ":") {
		t.Errorf("first message %q, want a comment that flushes the headers", got)
	}

	hub.Publish(events.Event{Name: "preview", Data: map[string]any{
		"link":    "https://example.com/post",
		"preview": store.Preview{Title: "A post\nwith a newline", SiteName: "Example"},
	}})
	want := "event: preview\n" + `data: {"link":"https://example.com/post","preview":{"title":"A post\nwith a newline","site_name":"Example"}}` + "\n"
	if got := readMessage(); got != want {
		t.Errorf("event message:\n%s\nwant\n%s", got, want)
	}

	hub.Close()
	if rest, err := io.ReadAll(body); err != nil || len(rest) != 0 {
		t.Errorf("after hub close: read %q, %v; want the stream to end", rest, err)
	}
}

func itoa(id int64) string {
	return strconv.FormatInt(id, 10)
}
