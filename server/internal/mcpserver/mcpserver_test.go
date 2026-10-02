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
		"list_items": true, "add_item": true, "set_item_checked": true, "rename_item": true,
		"move_item": true, "delete_item": true,
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

	item, _ := call[store.Item](t, cs, "add_item", map[string]any{"title": "Milk", "category_id": cat.ID})
	if item.CategoryID == nil || *item.CategoryID != cat.ID {
		t.Fatalf("add_item = %+v", item)
	}
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
	item, res := call[store.Item](t, cs, "add_item", map[string]any{"title": "Read " + link})
	if res.IsError || item.Link == nil || *item.Link != link || item.Preview == nil || *item.Preview != want {
		t.Errorf("add_item = %+v, error %v; want link %s with preview %+v", item, res.IsError, link, want)
	}
	call[store.Item](t, cs, "add_item", map[string]any{"title": "Milk"})
	all, res := call[itemList](t, cs, "list_items", map[string]any{})
	if res.IsError || len(all.Items) != 2 || all.Items[0].Preview == nil || all.Items[1].Link != nil {
		t.Errorf("list_items = %+v, error %v", all, res.IsError)
	}
}
