package mcpserver

import (
	"context"
	"log/slog"
	"net/http"
	"slices"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	"checkcheck/internal/store"
)

const instructions = `checkcheck is the user's personal checklist: items with a title that can be checked off, each optionally filed under one category.
Items and categories are referred to by numeric id. Call list_categories to map category names to ids and list_items to find item ids before changing anything.`

func Handler(st *store.Store) http.Handler {
	srv := mcp.NewServer(&mcp.Implementation{Name: "checkcheck", Version: "1.0.0"}, &mcp.ServerOptions{
		Instructions: instructions,
	})
	addTools(srv, st)
	return mcp.NewStreamableHTTPHandler(func(*http.Request) *mcp.Server { return srv }, &mcp.StreamableHTTPOptions{
		Stateless:    true,
		JSONResponse: true,
		// The bearer token already defeats DNS rebinding, and this check
		// rejects a reverse proxy on the same host that forwards the public
		// Host header.
		DisableLocalhostProtection: true,
		Logger:                     slog.Default(),
	})
}

type categoryIDArg struct {
	CategoryID int64 `json:"category_id" jsonschema:"id of the category"`
}

type itemIDArg struct {
	ItemID int64 `json:"item_id" jsonschema:"id of the item"`
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
		Name:        "add_item",
		Description: "Add an unchecked item and return it. Omit category_id to leave it uncategorized.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in struct {
		Title      string `json:"title" jsonschema:"item text, 1-500 characters"`
		CategoryID *int64 `json:"category_id,omitempty" jsonschema:"category to file the item under"`
	}) (*mcp.CallToolResult, store.Item, error) {
		it, err := st.CreateItem(ctx, in.Title, in.CategoryID)
		return nil, it, err
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
		Name:        "delete_item",
		Description: "Delete an item and return it. The user can restore it from Recently deleted in the app for 30 days. To mark an item done, use set_item_checked instead.",
	}, func(ctx context.Context, _ *mcp.CallToolRequest, in itemIDArg) (*mcp.CallToolResult, store.Item, error) {
		it, err := st.DeleteItem(ctx, in.ItemID)
		return nil, it, err
	})
}
