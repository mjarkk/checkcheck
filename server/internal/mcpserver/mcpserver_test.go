package mcpserver

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	"checkcheck/internal/api"
	"checkcheck/internal/store"
)

type bearer struct {
	token string
	next  http.RoundTripper
}

func (b bearer) RoundTrip(r *http.Request) (*http.Response, error) {
	r = r.Clone(r.Context())
	r.Header.Set("Authorization", "Bearer "+b.token)
	return b.next.RoundTrip(r)
}

func setup(t *testing.T) (*store.Store, string) {
	t.Helper()
	st, err := store.Open(context.Background(), filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { st.Close() })
	srv := httptest.NewServer(api.RequireToken("secret", Handler(st)))
	t.Cleanup(srv.Close)
	return st, srv.URL
}

func connect(ctx context.Context, url, token string) (*mcp.ClientSession, error) {
	httpClient := &http.Client{Transport: bearer{token, http.DefaultTransport}}
	if token == "" {
		httpClient = http.DefaultClient
	}
	client := mcp.NewClient(&mcp.Implementation{Name: "test", Version: "0"}, nil)
	return client.Connect(ctx, &mcp.StreamableClientTransport{
		Endpoint:   url,
		HTTPClient: httpClient,
		MaxRetries: -1,
	}, nil)
}

func call[T any](t *testing.T, cs *mcp.ClientSession, name string, args any) (T, *mcp.CallToolResult) {
	t.Helper()
	res, err := cs.CallTool(context.Background(), &mcp.CallToolParams{Name: name, Arguments: args})
	if err != nil {
		t.Fatalf("%s: protocol error %v", name, err)
	}
	var out T
	if !res.IsError {
		b, err := json.Marshal(res.StructuredContent)
		if err != nil {
			t.Fatal(err)
		}
		if err := json.Unmarshal(b, &out); err != nil {
			t.Fatalf("%s: decode %s: %v", name, b, err)
		}
	}
	return out, res
}

func TestRejectsMissingOrWrongToken(t *testing.T) {
	_, url := setup(t)
	for _, token := range []string{"", "wrong"} {
		cs, err := connect(context.Background(), url, token)
		if err == nil {
			cs.Close()
			t.Errorf("token %q: connected, want auth failure", token)
		}
	}
}

func TestTools(t *testing.T) {
	ctx := context.Background()
	st, url := setup(t)
	cs, err := connect(ctx, url, "secret")
	if err != nil {
		t.Fatal(err)
	}
	defer cs.Close()

	tools, err := cs.ListTools(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]bool{
		"list_categories": true, "create_category": true, "rename_category": true, "delete_category": true,
		"list_items": true, "add_items": true, "set_item_checked": true, "rename_item": true,
		"move_item": true, "delete_items": true,
	}
	for _, tool := range tools.Tools {
		if !want[tool.Name] {
			t.Errorf("unexpected tool %q", tool.Name)
		}
		delete(want, tool.Name)
	}
	if len(want) != 0 {
		t.Errorf("missing tools %v", want)
	}

	cat, _ := call[store.Category](t, cs, "create_category", map[string]any{"name": "Groceries"})
	if cat.Name != "Groceries" {
		t.Fatalf("create_category = %+v", cat)
	}
	if _, res := call[store.Category](t, cs, "create_category", map[string]any{"name": "groceries"}); !res.IsError {
		t.Error("duplicate category: want tool error")
	}

	added, _ := call[itemList](t, cs, "add_items", map[string]any{"items": []any{map[string]any{"title": "Milk", "category_id": cat.ID}}})
	if len(added.Items) != 1 || added.Items[0].CategoryID == nil || *added.Items[0].CategoryID != cat.ID {
		t.Fatalf("add_items = %+v", added)
	}
	item := added.Items[0]
	nails, err := st.CreateItem(ctx, "Nails", nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := st.UpdateItem(ctx, nails.ID, store.ItemUpdate{SetBefore: true, BeforeID: &item.ID}); err != nil {
		t.Fatal(err)
	}

	filtered, _ := call[itemList](t, cs, "list_items", map[string]any{"category_id": cat.ID})
	if len(filtered.Items) != 1 || filtered.Items[0].ID != item.ID {
		t.Errorf("list_items filtered = %+v", filtered)
	}
	all, _ := call[itemList](t, cs, "list_items", map[string]any{})
	if len(all.Items) != 2 || all.Items[0].ID != nails.ID {
		t.Errorf("list_items = %+v, want list order", all)
	}
	if _, res := call[itemList](t, cs, "list_items", map[string]any{"category_id": 999}); !res.IsError {
		t.Error("list_items unknown category: want tool error")
	}

	checked, _ := call[store.Item](t, cs, "set_item_checked", map[string]any{"item_id": item.ID, "checked": true})
	if !checked.Checked {
		t.Errorf("set_item_checked = %+v", checked)
	}
	moved, _ := call[store.Item](t, cs, "move_item", map[string]any{"item_id": item.ID})
	if moved.CategoryID != nil || !moved.Checked {
		t.Errorf("move_item without category = %+v", moved)
	}
	if _, res := call[store.Item](t, cs, "move_item", map[string]any{"item_id": item.ID, "category_id": 999}); !res.IsError {
		t.Error("move_item to unknown category: want tool error")
	}
	if _, res := call[store.Item](t, cs, "rename_item", map[string]any{"item_id": 999, "title": "x"}); !res.IsError {
		t.Error("rename_item unknown id: want tool error")
	}
	if _, res := call[store.Item](t, cs, "set_item_checked", map[string]any{"item_id": item.ID}); !res.IsError {
		t.Error("set_item_checked without checked: want tool error")
	}

	deleted, _ := call[store.Category](t, cs, "delete_category", map[string]any{"category_id": cat.ID})
	if deleted.ID != cat.ID {
		t.Errorf("delete_category = %+v", deleted)
	}
	cats, _ := call[categoryList](t, cs, "list_categories", nil)
	if len(cats.Categories) != 0 {
		t.Errorf("list_categories = %+v", cats)
	}

	a, err := st.CreateCategory(ctx, "A")
	if err != nil {
		t.Fatal(err)
	}
	b, err := st.CreateCategory(ctx, "B")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := st.SetCategoryOrder(ctx, []*int64{&b.ID, nil, &a.ID}); err != nil {
		t.Fatal(err)
	}
	cats, _ = call[categoryList](t, cs, "list_categories", nil)
	if len(cats.Categories) != 2 || cats.Categories[0].ID != b.ID {
		t.Errorf("list_categories = %+v, want category order", cats)
	}
}

func TestItemsCarryLinkPreviews(t *testing.T) {
	ctx := context.Background()
	st, url := setup(t)
	cs, err := connect(ctx, url, "secret")
	if err != nil {
		t.Fatal(err)
	}
	defer cs.Close()

	const link = "https://example.com/post"
	want := store.Preview{Title: "A post", SiteName: "Example"}
	if err := st.SavePreview(ctx, link, want); err != nil {
		t.Fatal(err)
	}
	added, res := call[itemList](t, cs, "add_items", map[string]any{"items": []any{
		map[string]any{"title": "Read " + link},
		map[string]any{"title": "Milk"},
	}})
	if res.IsError || len(added.Items) != 2 {
		t.Fatalf("add_items = %+v, error %v", added, res.IsError)
	}
	if item := added.Items[0]; item.Link == nil || *item.Link != link || item.Preview == nil || *item.Preview != want {
		t.Errorf("add_items[0] = %+v; want link %s with preview %+v", item, link, want)
	}
	all, res := call[itemList](t, cs, "list_items", map[string]any{})
	if res.IsError || len(all.Items) != 2 || all.Items[0].Preview == nil || all.Items[1].Link != nil {
		t.Errorf("list_items = %+v, error %v", all, res.IsError)
	}
}

func TestAddItems(t *testing.T) {
	ctx := context.Background()
	st, url := setup(t)
	cs, err := connect(ctx, url, "secret")
	if err != nil {
		t.Fatal(err)
	}
	defer cs.Close()
	cat, err := st.CreateCategory(ctx, "Groceries")
	if err != nil {
		t.Fatal(err)
	}

	added, res := call[itemList](t, cs, "add_items", map[string]any{"items": []any{
		map[string]any{"title": "Milk", "category_id": cat.ID},
		map[string]any{"title": "Fix bike"},
		map[string]any{"title": "Bread", "category_id": cat.ID},
	}})
	if res.IsError || len(added.Items) != 3 {
		t.Fatalf("add_items = %+v, error %v", added, res.IsError)
	}
	for i, want := range []struct {
		title    string
		category *int64
	}{{"Milk", &cat.ID}, {"Fix bike", nil}, {"Bread", &cat.ID}} {
		got := added.Items[i]
		if got.Title != want.title || (got.CategoryID == nil) != (want.category == nil) ||
			(got.CategoryID != nil && *got.CategoryID != *want.category) {
			t.Errorf("add_items[%d] = %+v, want %q in category %v", i, got, want.title, want.category)
		}
	}

	for name, items := range map[string][]any{
		"unknown category": {map[string]any{"title": "Eggs"}, map[string]any{"title": "Nails", "category_id": 999}},
		"empty title":      {map[string]any{"title": "Eggs"}, map[string]any{"title": " "}},
		"no items":         {},
	} {
		if _, res := call[itemList](t, cs, "add_items", map[string]any{"items": items}); !res.IsError {
			t.Errorf("%s: want tool error", name)
		}
	}
	all, _ := call[itemList](t, cs, "list_items", map[string]any{})
	if len(all.Items) != 3 {
		t.Errorf("list_items after failed add_items = %+v, want only the first 3", all)
	}
}

func TestDeleteItems(t *testing.T) {
	ctx := context.Background()
	st, url := setup(t)
	cs, err := connect(ctx, url, "secret")
	if err != nil {
		t.Fatal(err)
	}
	defer cs.Close()
	created, err := st.CreateItems(ctx, []store.NewItem{{Title: "Milk"}, {Title: "Eggs"}, {Title: "Bread"}})
	if err != nil {
		t.Fatal(err)
	}
	milk, eggs, bread := created[0], created[1], created[2]

	deleted, res := call[itemList](t, cs, "delete_items", map[string]any{"item_ids": []any{bread.ID, milk.ID}})
	if res.IsError || len(deleted.Items) != 2 || deleted.Items[0].Title != "Bread" || deleted.Items[1].Title != "Milk" {
		t.Fatalf("delete_items = %+v, error %v; want Bread, Milk", deleted, res.IsError)
	}

	for name, ids := range map[string][]any{
		"unknown id":      {eggs.ID, 999},
		"already deleted": {eggs.ID, milk.ID},
		"no ids":          {},
	} {
		if _, res := call[itemList](t, cs, "delete_items", map[string]any{"item_ids": ids}); !res.IsError {
			t.Errorf("%s: want tool error", name)
		}
	}
	all, _ := call[itemList](t, cs, "list_items", map[string]any{})
	if len(all.Items) != 1 || all.Items[0].ID != eggs.ID {
		t.Errorf("list_items after failed delete_items = %+v, want Eggs kept", all)
	}
}

func TestEachWriteToolReportsOneChange(t *testing.T) {
	ctx := context.Background()
	st, url := setup(t)
	changes := make(chan string, 16)
	st.OnChange(func(ctx context.Context) { changes <- api.ClientID(ctx) })
	cs, err := connect(ctx, url, "secret")
	if err != nil {
		t.Fatal(err)
	}
	defer cs.Close()
	expect := func(tool string, want int) {
		t.Helper()
		got := 0
		for len(changes) > 0 {
			if client := <-changes; client != "" {
				t.Errorf("%s: change from client %q, want none", tool, client)
			}
			got++
		}
		if got != want {
			t.Errorf("%s: %d changes, want %d", tool, got, want)
		}
	}

	cat, _ := call[store.Category](t, cs, "create_category", map[string]any{"name": "a"})
	expect("create_category", 1)
	added, _ := call[itemList](t, cs, "add_items", map[string]any{"items": []any{
		map[string]any{"title": "x"}, map[string]any{"title": "z"},
	}})
	expect("add_items", 1)
	item := added.Items[0]
	for _, tc := range []struct {
		tool string
		args map[string]any
	}{
		{"rename_category", map[string]any{"category_id": cat.ID, "name": "b"}},
		{"set_item_checked", map[string]any{"item_id": item.ID, "checked": true}},
		{"rename_item", map[string]any{"item_id": item.ID, "title": "y"}},
		{"move_item", map[string]any{"item_id": item.ID, "category_id": cat.ID}},
		{"delete_items", map[string]any{"item_ids": []any{item.ID, added.Items[1].ID}}},
		{"delete_category", map[string]any{"category_id": cat.ID}},
	} {
		if _, res := call[map[string]any](t, cs, tc.tool, tc.args); res.IsError {
			t.Fatalf("%s: tool error %+v", tc.tool, res.Content)
		}
		expect(tc.tool, 1)
	}
	call[categoryList](t, cs, "list_categories", nil)
	call[itemList](t, cs, "list_items", map[string]any{})
	call[itemList](t, cs, "delete_items", map[string]any{"item_ids": []any{item.ID}})
	call[itemList](t, cs, "add_items", map[string]any{"items": []any{map[string]any{"title": "x"}, map[string]any{"title": ""}}})
	expect("reads and failed writes", 0)
}
