package mcpserver

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"slices"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	"checkcheck/internal/store"
)

const instructions = `CheckCheck is the user's personal checklist: items with a title that can be checked off, each optionally filed under one category.
Items and categories are referred to by numeric id. Call list_categories to map category names to ids and list_items to find item ids before changing anything.`

func Handler(st *store.Store) http.Handler {
	srv := mcp.NewServer(&mcp.Implementation{Name: "checkcheck", Title: "CheckCheck", Version: "1.0.0"}, &mcp.ServerOptions{
		Instructions: instructions,
	})
	addTools(srv, st)
	return announceToolsChanged(mcp.NewStreamableHTTPHandler(func(*http.Request) *mcp.Server { return srv }, &mcp.StreamableHTTPOptions{
		Stateless:    true,
		JSONResponse: true,
		// The bearer token already defeats DNS rebinding, and this check
		// rejects a reverse proxy on the same host that forwards the public
		// Host header.
		DisableLocalhostProtection: true,
		Logger:                     slog.Default(),
	}))
}

// Claude's connectors keep a stale tool list for servers that never announce
// changes, and a stateless server has no stream to announce them on. So this
// answers notifications/initialized with one, as github.com/back-to-code/go-mcp
// does, instead of the empty 202 the spec asks for; spec clients ignore it.
func announceToolsChanged(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			next.ServeHTTP(w, r)
			return
		}
		body, err := io.ReadAll(r.Body)
		if err != nil {
			http.Error(w, "failed to read body", http.StatusBadRequest)
			return
		}
		var msg struct {
			Method string          `json:"method"`
			ID     json.RawMessage `json:"id"`
		}
		if json.Unmarshal(body, &msg) == nil && msg.Method == "notifications/initialized" && msg.ID == nil {
			w.Header().Set("Content-Type", "application/json")
			io.WriteString(w, `{"jsonrpc":"2.0","method":"notifications/tools/list_changed"}`)
			return
		}
		r.Body = io.NopCloser(bytes.NewReader(body))
		next.ServeHTTP(w, r)
	})
}

type categoryIDArg struct {
	CategoryID int64 `json:"category_id" jsonschema:"id of the category"`
}

type itemIDArg struct {
	ItemID int64 `json:"item_id" jsonschema:"id of the item"`
}

type newItemArg struct {
	Title      string `json:"title" jsonschema:"item text, 1-500 characters"`
	CategoryID *int64 `json:"category_id,omitempty" jsonschema:"category to file the item under"`
}

// Lists are wrapped in an object because clients on older protocol versions
// require structuredContent to be one.
type categoryList struct {
	Categories []store.Category `json:"categories"`
}

type itemList struct {
	Items []store.Item `json:"items"`
}

func addTools(srv *mcp.Server, st *store.Store) {
	readOnly := &mcp.ToolAnnotations{ReadOnlyHint: true}

	mcp.AddTool(srv, &mcp.Tool{
		Name:        "list_categories",
		Description: "List all categories in the user's category order, which they arrange in the app. Use the returned ids as category_id in the other tools.",
		Annotations: readOnly,
	}, func(ctx context.Context, _ *mcp.CallToolRequest, _ struct{}) (*mcp.CallToolResult, categoryList, error) {
		cats, err := st.ListCategories(ctx)
		return nil, categoryList{cats}, err
	})

	mcp.AddTool(srv, &mcp.Tool{
		Name:        "create_category",
		Description: "Create a category and return it. Names are unique case-insensitively, so this fails if a category with the same name exists; call list_categories first to reuse one.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in struct {
		Name string `json:"name" jsonschema:"category name, 1-100 characters"`
	}) (*mcp.CallToolResult, store.Category, error) {
		c, err := st.CreateCategory(ctx, in.Name)
		return nil, c, err
	})

	mcp.AddTool(srv, &mcp.Tool{
		Name:        "rename_category",
		Description: "Rename a category and return it. Fails if another category already has that name (case-insensitively).",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in struct {
		categoryIDArg
		Name string `json:"name" jsonschema:"new category name, 1-100 characters"`
	}) (*mcp.CallToolResult, store.Category, error) {
		c, err := st.RenameCategory(ctx, in.CategoryID, in.Name)
		return nil, c, err
	})

	mcp.AddTool(srv, &mcp.Tool{
		Name:        "delete_category",
		Description: "Delete a category and return it. Its items are kept but become uncategorized. Confirm with the user before deleting.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in categoryIDArg) (*mcp.CallToolResult, store.Category, error) {
		c, err := st.DeleteCategory(ctx, in.CategoryID)
		return nil, c, err
	})

	mcp.AddTool(srv, &mcp.Tool{
		Name:        "list_items",
		Description: "List items in the user's list order, which they can rearrange in the app. Each item has a checked flag and a category_id, which is null for uncategorized items; an item whose title contains a URL has it as link, plus the page's preview once the server has fetched it. Pass category_id to list only that category's items; omit it to list all items.",
		Annotations: readOnly,
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in struct {
		CategoryID *int64 `json:"category_id,omitempty" jsonschema:"only list items in this category"`
	}) (*mcp.CallToolResult, itemList, error) {
		if in.CategoryID != nil {
			if _, err := st.GetCategory(ctx, *in.CategoryID); err != nil {
				return nil, itemList{}, err
			}
		}
		items, err := st.ListItems(ctx)
		if err != nil {
			return nil, itemList{}, err
		}
		if in.CategoryID != nil {
			items = slices.DeleteFunc(items, func(it store.Item) bool {
				return it.CategoryID == nil || *it.CategoryID != *in.CategoryID
			})
		}
		return nil, itemList{items}, nil
	})

	mcp.AddTool(srv, &mcp.Tool{
		Name:        "add_items",
		Description: "Add one or more unchecked items and return them, in the order given. Each item has its own optional category_id; omit it to leave that item uncategorized. Add everything the user asked for in one call. If any item is invalid, none are added.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in struct {
		Items []newItemArg `json:"items" jsonschema:"the items to add, at least one"`
	}) (*mcp.CallToolResult, itemList, error) {
		items := make([]store.NewItem, len(in.Items))
		for i, n := range in.Items {
			items[i] = store.NewItem{Title: n.Title, CategoryID: n.CategoryID}
		}
		created, err := st.CreateItems(ctx, items)
		return nil, itemList{created}, err
	})

	mcp.AddTool(srv, &mcp.Tool{
		Name:        "set_item_checked",
		Description: "Check off an item (checked: true) or uncheck it (checked: false), and return it.",
		Annotations: &mcp.ToolAnnotations{IdempotentHint: true},
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in struct {
		itemIDArg
		Checked bool `json:"checked" jsonschema:"true to check the item off, false to uncheck it"`
	}) (*mcp.CallToolResult, store.Item, error) {
		it, err := st.UpdateItem(ctx, in.ItemID, store.ItemUpdate{Checked: &in.Checked})
		return nil, it, err
	})

	mcp.AddTool(srv, &mcp.Tool{
		Name:        "rename_item",
		Description: "Change an item's title and return it.",
		Annotations: &mcp.ToolAnnotations{IdempotentHint: true},
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in struct {
		itemIDArg
		Title string `json:"title" jsonschema:"new item text, 1-500 characters"`
	}) (*mcp.CallToolResult, store.Item, error) {
		it, err := st.UpdateItem(ctx, in.ItemID, store.ItemUpdate{Title: &in.Title})
		return nil, it, err
	})

	mcp.AddTool(srv, &mcp.Tool{
		Name:        "move_item",
		Description: "Move an item to a category and return it. Omit category_id (or pass null) to make the item uncategorized.",
		Annotations: &mcp.ToolAnnotations{IdempotentHint: true},
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in struct {
		itemIDArg
		CategoryID *int64 `json:"category_id,omitempty" jsonschema:"destination category; omit or null for uncategorized"`
	}) (*mcp.CallToolResult, store.Item, error) {
		it, err := st.UpdateItem(ctx, in.ItemID, store.ItemUpdate{SetCategory: true, CategoryID: in.CategoryID})
		return nil, it, err
	})

	mcp.AddTool(srv, &mcp.Tool{
		Name:        "delete_items",
		Description: "Delete one or more items and return them, in the order given. The user can restore them from Recently deleted in the app for 30 days. Delete everything the user asked for in one call. If any id is unknown or already deleted, none are deleted. To mark items done, use set_item_checked instead.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in struct {
		ItemIDs []int64 `json:"item_ids" jsonschema:"ids of the items to delete, at least one"`
	}) (*mcp.CallToolResult, itemList, error) {
		deleted, err := st.DeleteItems(ctx, in.ItemIDs)
		return nil, itemList{deleted}, err
	})
}
