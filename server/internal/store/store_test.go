package store

import (
	"context"
	"database/sql"
	"errors"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

func openTest(t *testing.T) *Store {
	t.Helper()
	s, err := Open(context.Background(), filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	return s
}

func ptr[T any](v T) *T { return &v }

func titles(t *testing.T, s *Store) string {
	t.Helper()
	items, err := s.ListItems(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	var out []string
	for _, it := range items {
		out = append(out, it.Title)
	}
	return strings.Join(out, ",")
}

// categoryOrder renders CategoryOrder as names, with "-" for Uncategorized,
// and checks that ListCategories follows it.
func categoryOrder(t *testing.T, s *Store) string {
	t.Helper()
	ctx := context.Background()
	cats, err := s.ListCategories(ctx)
	if err != nil {
		t.Fatal(err)
	}
	order, err := s.CategoryOrder(ctx)
	if err != nil {
		t.Fatal(err)
	}
	names := map[int64]string{}
	var listed []string
	for _, c := range cats {
		names[c.ID] = c.Name
		listed = append(listed, c.Name)
	}
	var out, ordered []string
	for _, id := range order {
		if id == nil {
			out = append(out, "-")
			continue
		}
		out = append(out, names[*id])
		ordered = append(ordered, names[*id])
	}
	if strings.Join(ordered, ",") != strings.Join(listed, ",") {
		t.Errorf("ListCategories = %v, want category order %v", listed, out)
	}
	return strings.Join(out, ",")
}

func TestReopenKeepsDataAndSchemaVersion(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "test.db")
	s, err := Open(ctx, path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.CreateCategory(ctx, "Groceries"); err != nil {
		t.Fatal(err)
	}
	s.Close()

	s, err = Open(ctx, path)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	var version int
	if err := s.db.QueryRow("PRAGMA user_version").Scan(&version); err != nil {
		t.Fatal(err)
	}
	if version != len(migrations) {
		t.Errorf("user_version = %d, want %d", version, len(migrations))
	}
	cats, err := s.ListCategories(ctx)
	if err != nil || len(cats) != 1 {
		t.Fatalf("categories after reopen = %v, %v", cats, err)
	}
}

func TestCategories(t *testing.T) {
	ctx := context.Background()
	s := openTest(t)

	b, err := s.CreateCategory(ctx, "  beta ")
	if err != nil {
		t.Fatal(err)
	}
	if b.Name != "beta" {
		t.Errorf("name = %q, want trimmed", b.Name)
	}
	if _, err := s.CreateCategory(ctx, "Alpha"); err != nil {
		t.Fatal(err)
	}
	if _, err := s.CreateCategory(ctx, "BETA"); !errors.Is(err, ErrConflict) {
		t.Errorf("duplicate name: err = %v, want ErrConflict", err)
	}
	for _, name := range []string{"", "   ", strings.Repeat("x", 101)} {
		if _, err := s.CreateCategory(ctx, name); !errors.Is(err, ErrInvalid) {
			t.Errorf("CreateCategory(%q): err = %v, want ErrInvalid", name, err)
		}
	}
	if _, err := s.CreateCategory(ctx, strings.Repeat("é", 100)); err != nil {
		t.Errorf("100 multi-byte chars: %v", err)
	}

	cats, err := s.ListCategories(ctx)
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, c := range cats {
		names = append(names, c.Name)
	}
	if got := strings.Join(names[:2], ","); got != "beta,Alpha" {
		t.Errorf("order = %q, want creation order", got)
	}

	renamed, err := s.RenameCategory(ctx, b.ID, "Beta")
	if err != nil {
		t.Fatalf("case-only rename of itself: %v", err)
	}
	if renamed.Name != "Beta" || !renamed.CreatedAt.Equal(b.CreatedAt) {
		t.Errorf("renamed = %+v", renamed)
	}
	if _, err := s.RenameCategory(ctx, b.ID, "alpha"); !errors.Is(err, ErrConflict) {
		t.Errorf("rename to existing: err = %v, want ErrConflict", err)
	}
	if _, err := s.RenameCategory(ctx, 999, "x"); !errors.Is(err, ErrNotFound) {
		t.Errorf("rename missing: err = %v, want ErrNotFound", err)
	}
	if _, err := s.DeleteCategory(ctx, 999); !errors.Is(err, ErrNotFound) {
		t.Errorf("delete missing: err = %v, want ErrNotFound", err)
	}
}

func TestCategoryOrder(t *testing.T) {
	ctx := context.Background()
	s := openTest(t)
	if got := categoryOrder(t, s); got != "-" {
		t.Errorf("empty order = %q, want only Uncategorized", got)
	}
	ids := map[string]int64{}
	create := func(name string) {
		t.Helper()
		c, err := s.CreateCategory(ctx, name)
		if err != nil {
			t.Fatal(err)
		}
		ids[name] = c.ID
	}
	for _, name := range []string{"b", "a", "c"} {
		create(name)
	}
	if got := categoryOrder(t, s); got != "b,a,c,-" {
		t.Fatalf("order = %q, want new categories before Uncategorized", got)
	}

	orderOf := func(names string) []*int64 {
		var order []*int64
		for _, name := range strings.Split(names, ",") {
			if name == "-" {
				order = append(order, nil)
			} else {
				order = append(order, ptr(ids[name]))
			}
		}
		return order
	}
	set := func(names string) {
		t.Helper()
		got, err := s.SetCategoryOrder(ctx, orderOf(names))
		if err != nil {
			t.Fatalf("set %s: %v", names, err)
		}
		if !reflect.DeepEqual(got, orderOf(names)) {
			t.Errorf("set %s returned %v", names, got)
		}
		if got := categoryOrder(t, s); got != names {
			t.Errorf("after set %s: order = %q", names, got)
		}
	}
	set("-,a,b,c")
	create("d")
	if got := categoryOrder(t, s); got != "-,a,b,c,d" {
		t.Errorf("order = %q, want a new category at the end when Uncategorized is not last", got)
	}
	set("a,-,c,b,d")
	create("e")
	if got := categoryOrder(t, s); got != "a,-,c,b,d,e" {
		t.Errorf("order = %q, want a new category at the end when Uncategorized is not last", got)
	}

	a, b, c, d, e := ptr(ids["a"]), ptr(ids["b"]), ptr(ids["c"]), ptr(ids["d"]), ptr(ids["e"])
	for _, tc := range []struct {
		name  string
		order []*int64
	}{
		{"missing id", []*int64{a, b, c, d, nil}},
		{"duplicate id", []*int64{a, b, c, d, d, nil}},
		{"unknown id", []*int64{a, b, c, d, ptr(int64(999)), nil}},
		{"no null", []*int64{a, b, c, d, e}},
		{"two nulls", []*int64{a, nil, b, c, d, e, nil}},
		{"empty", nil},
	} {
		if _, err := s.SetCategoryOrder(ctx, tc.order); !errors.Is(err, ErrInvalid) {
			t.Errorf("%s: err = %v, want ErrInvalid", tc.name, err)
		}
	}
	if got := categoryOrder(t, s); got != "a,-,c,b,d,e" {
		t.Errorf("after rejected orders: order = %q, want unchanged", got)
	}

	if _, err := s.DeleteCategory(ctx, ids["c"]); err != nil {
		t.Fatal(err)
	}
	if got := categoryOrder(t, s); got != "a,-,b,d,e" {
		t.Errorf("after delete: order = %q, want the rest unchanged", got)
	}
	set("a,b,d,e,-")
	if _, err := s.DeleteCategory(ctx, ids["e"]); err != nil {
		t.Fatal(err)
	}
	create("f")
	if got := categoryOrder(t, s); got != "a,b,d,f,-" {
		t.Errorf("after delete+create: order = %q, want a,b,d,f,-", got)
	}
}

func TestDeleteCategoryUncategorizesItems(t *testing.T) {
	ctx := context.Background()
	s := openTest(t)
	c, err := s.CreateCategory(ctx, "Groceries")
	if err != nil {
		t.Fatal(err)
	}
	it, err := s.CreateItem(ctx, "Milk", &c.ID)
	if err != nil {
		t.Fatal(err)
	}
	if it.CategoryID == nil || *it.CategoryID != c.ID {
		t.Fatalf("category_id = %v, want %d", it.CategoryID, c.ID)
	}
	deleted, err := s.DeleteCategory(ctx, c.ID)
	if err != nil {
		t.Fatal(err)
	}
	if deleted.Name != "Groceries" {
		t.Errorf("deleted = %+v", deleted)
	}
	items, err := s.ListItems(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 1 || items[0].CategoryID != nil {
		t.Errorf("items = %+v, want one uncategorized", items)
	}
}

func TestItems(t *testing.T) {
	ctx := context.Background()
	s := openTest(t)
	c, err := s.CreateCategory(ctx, "Groceries")
	if err != nil {
		t.Fatal(err)
	}

	if _, err := s.CreateItem(ctx, "Milk", ptr(int64(999))); !errors.Is(err, ErrInvalid) {
		t.Errorf("unknown category: err = %v, want ErrInvalid", err)
	}
	if _, err := s.CreateItem(ctx, " ", nil); !errors.Is(err, ErrInvalid) {
		t.Errorf("blank title: err = %v, want ErrInvalid", err)
	}
	if _, err := s.CreateItem(ctx, strings.Repeat("x", 501), nil); !errors.Is(err, ErrInvalid) {
		t.Errorf("long title: err = %v, want ErrInvalid", err)
	}

	first, err := s.CreateItem(ctx, " Milk ", &c.ID)
	if err != nil {
		t.Fatal(err)
	}
	if first.Title != "Milk" || first.Checked {
		t.Errorf("created = %+v", first)
	}
	second, err := s.CreateItem(ctx, "Bread", nil)
	if err != nil {
		t.Fatal(err)
	}

	got, err := s.UpdateItem(ctx, first.ID, ItemUpdate{Checked: ptr(true)})
	if err != nil {
		t.Fatal(err)
	}
	if !got.Checked || got.Title != "Milk" || got.CategoryID == nil {
		t.Errorf("after check = %+v, want only checked changed", got)
	}
	got, err = s.UpdateItem(ctx, first.ID, ItemUpdate{SetCategory: true})
	if err != nil {
		t.Fatal(err)
	}
	if got.CategoryID != nil || !got.Checked {
		t.Errorf("after uncategorize = %+v", got)
	}
	got, err = s.UpdateItem(ctx, first.ID, ItemUpdate{Title: ptr("Oat milk"), SetCategory: true, CategoryID: &c.ID})
	if err != nil {
		t.Fatal(err)
	}
	if got.Title != "Oat milk" || got.CategoryID == nil || *got.CategoryID != c.ID {
		t.Errorf("after rename+move = %+v", got)
	}
	if _, err := s.UpdateItem(ctx, first.ID, ItemUpdate{SetCategory: true, CategoryID: ptr(int64(999))}); !errors.Is(err, ErrInvalid) {
		t.Errorf("move to unknown category: err = %v, want ErrInvalid", err)
	}
	if _, err := s.UpdateItem(ctx, first.ID, ItemUpdate{Title: ptr("")}); !errors.Is(err, ErrInvalid) {
		t.Errorf("empty title: err = %v, want ErrInvalid", err)
	}
	if _, err := s.UpdateItem(ctx, 999, ItemUpdate{Checked: ptr(true)}); !errors.Is(err, ErrNotFound) {
		t.Errorf("update missing: err = %v, want ErrNotFound", err)
	}

	items, err := s.ListItems(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 2 || items[0].ID != first.ID || items[1].ID != second.ID {
		t.Errorf("items = %+v, want creation order", items)
	}

	if _, err := s.DeleteItem(ctx, second.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := s.DeleteItem(ctx, second.ID); !errors.Is(err, ErrNotFound) {
		t.Errorf("second delete: err = %v, want ErrNotFound", err)
	}
	third, err := s.CreateItem(ctx, "Eggs", nil)
	if err != nil {
		t.Fatal(err)
	}
	if third.ID == second.ID {
		t.Errorf("deleted id %d was reused", second.ID)
	}
}

func TestItemOrder(t *testing.T) {
	ctx := context.Background()
	s := openTest(t)
	c, err := s.CreateCategory(ctx, "Groceries")
	if err != nil {
		t.Fatal(err)
	}
	ids := map[string]int64{}
	for _, title := range []string{"a", "b", "c", "d"} {
		it, err := s.CreateItem(ctx, title, nil)
		if err != nil {
			t.Fatal(err)
		}
		ids[title] = it.ID
	}
	if got := titles(t, s); got != "a,b,c,d" {
		t.Fatalf("order = %q, want new items appended", got)
	}

	move := func(title string, before *int64) {
		t.Helper()
		if _, err := s.UpdateItem(ctx, ids[title], ItemUpdate{SetBefore: true, BeforeID: before}); err != nil {
			t.Fatalf("move %s: %v", title, err)
		}
	}
	for _, tc := range []struct {
		title, before, want string
	}{
		{"d", "a", "d,a,b,c"},
		{"d", "c", "a,b,d,c"},
		{"a", "c", "b,d,a,c"},
		{"c", "b", "c,b,d,a"},
		{"c", "", "b,d,a,c"},
		{"c", "", "b,d,a,c"},
	} {
		var before *int64
		if tc.before != "" {
			before = ptr(ids[tc.before])
		}
		move(tc.title, before)
		if got := titles(t, s); got != tc.want {
			t.Errorf("after moving %s before %q: order = %q, want %q", tc.title, tc.before, got, tc.want)
		}
	}

	got, err := s.UpdateItem(ctx, ids["c"], ItemUpdate{
		Checked: ptr(true), SetCategory: true, CategoryID: &c.ID, SetBefore: true, BeforeID: ptr(ids["b"]),
	})
	if err != nil {
		t.Fatal(err)
	}
	if !got.Checked || got.CategoryID == nil || *got.CategoryID != c.ID {
		t.Errorf("after check+move = %+v", got)
	}
	if got := titles(t, s); got != "c,b,d,a" {
		t.Errorf("after check+move: order = %q, want c,b,d,a", got)
	}

	if _, err := s.UpdateItem(ctx, ids["a"], ItemUpdate{SetBefore: true, BeforeID: ptr(ids["a"])}); !errors.Is(err, ErrInvalid) {
		t.Errorf("move before itself: err = %v, want ErrInvalid", err)
	}
	if _, err := s.UpdateItem(ctx, ids["c"], ItemUpdate{Checked: ptr(false), SetBefore: true, BeforeID: ptr(int64(999))}); !errors.Is(err, ErrInvalid) {
		t.Errorf("move before unknown item: err = %v, want ErrInvalid", err)
	}
	if _, err := s.UpdateItem(ctx, ids["c"], ItemUpdate{SetCategory: true, CategoryID: ptr(int64(999)), SetBefore: true}); !errors.Is(err, ErrInvalid) {
		t.Errorf("move to unknown category: err = %v, want ErrInvalid", err)
	}
	if _, err := s.UpdateItem(ctx, 999, ItemUpdate{SetBefore: true}); !errors.Is(err, ErrNotFound) {
		t.Errorf("move missing: err = %v, want ErrNotFound", err)
	}
	items, err := s.ListItems(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if !items[0].Checked || items[0].CategoryID == nil {
		t.Errorf("failed updates were partly applied: %+v", items[0])
	}
	if got := titles(t, s); got != "c,b,d,a" {
		t.Errorf("after failed moves: order = %q, want unchanged", got)
	}

	if _, err := s.DeleteItem(ctx, ids["b"]); err != nil {
		t.Fatal(err)
	}
	e, err := s.CreateItem(ctx, "e", nil)
	if err != nil {
		t.Fatal(err)
	}
	ids["e"] = e.ID
	if got := titles(t, s); got != "c,d,a,e" {
		t.Errorf("after delete+create: order = %q, want c,d,a,e", got)
	}
	move("e", ptr(ids["d"]))
	move("c", nil)
	if got := titles(t, s); got != "e,d,a,c" {
		t.Errorf("after moves around a deleted item: order = %q, want e,d,a,c", got)
	}
}

func deletedTitles(t *testing.T, s *Store) string {
	t.Helper()
	items, err := s.ListDeletedItems(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	var out []string
	for _, it := range items {
		out = append(out, it.Title)
	}
	return strings.Join(out, ",")
}

func TestRecentlyDeleted(t *testing.T) {
	ctx := context.Background()
	s := openTest(t)
	c, err := s.CreateCategory(ctx, "Groceries")
	if err != nil {
		t.Fatal(err)
	}
	ids := map[string]int64{}
	for _, title := range []string{"a", "b", "c", "d", "e"} {
		it, err := s.CreateItem(ctx, title, &c.ID)
		if err != nil {
			t.Fatal(err)
		}
		ids[title] = it.ID
	}
	if _, err := s.UpdateItem(ctx, ids["c"], ItemUpdate{Checked: ptr(true)}); err != nil {
		t.Fatal(err)
	}
	if got := deletedTitles(t, s); got != "" {
		t.Fatalf("deleted before deleting = %q", got)
	}

	deletedAt := func(title, at string) {
		t.Helper()
		if _, err := s.db.Exec("UPDATE items SET deleted_at = ? WHERE id = ?", at, ids[title]); err != nil {
			t.Fatal(err)
		}
	}
	for _, title := range []string{"d", "a", "c"} {
		deleted, err := s.DeleteItem(ctx, ids[title])
		if err != nil {
			t.Fatal(err)
		}
		if deleted.Title != title || deleted.CategoryID == nil {
			t.Errorf("DeleteItem returned %+v, want the item as it was", deleted)
		}
	}
	recent := formatTime(time.Now().Add(-time.Minute))
	deletedAt("a", recent)
	deletedAt("c", recent)
	deletedAt("d", formatTime(time.Now().Add(-48*time.Hour)))
	if got := titles(t, s); got != "b,e" {
		t.Errorf("items = %q, want deleted ones left out", got)
	}
	if got := deletedTitles(t, s); got != "a,c,d" {
		t.Errorf("deleted = %q, want newest first, then list order", got)
	}

	if _, err := s.UpdateItem(ctx, ids["a"], ItemUpdate{Checked: ptr(true)}); !errors.Is(err, ErrNotFound) {
		t.Errorf("update deleted: err = %v, want ErrNotFound", err)
	}
	if _, err := s.DeleteItem(ctx, ids["a"]); !errors.Is(err, ErrNotFound) {
		t.Errorf("delete deleted: err = %v, want ErrNotFound", err)
	}
	if _, err := s.UpdateItem(ctx, ids["b"], ItemUpdate{SetBefore: true, BeforeID: ptr(ids["a"])}); !errors.Is(err, ErrInvalid) {
		t.Errorf("move before deleted: err = %v, want ErrInvalid", err)
	}

	const longAgo = "2026-01-01T00:00:00Z"
	if _, err := s.db.Exec("UPDATE items SET updated_at = ? WHERE id = ?", longAgo, ids["a"]); err != nil {
		t.Fatal(err)
	}
	if _, err := s.DeleteCategory(ctx, c.ID); err != nil {
		t.Fatal(err)
	}
	items, err := s.ListDeletedItems(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if formatTime(items[0].UpdatedAt) != longAgo || !items[1].Checked {
		t.Errorf("deleted = %+v, want them as they were when deleted", items)
	}

	restored, err := s.RestoreItem(ctx, ids["c"])
	if err != nil {
		t.Fatal(err)
	}
	if restored.CategoryID != nil || !restored.Checked || restored.Title != "c" {
		t.Errorf("restored = %+v, want uncategorized and still checked", restored)
	}
	if _, err := s.RestoreItem(ctx, ids["d"]); err != nil {
		t.Fatal(err)
	}
	if got := titles(t, s); got != "b,e,c,d" {
		t.Errorf("items = %q, want restored ones appended", got)
	}
	if got := deletedTitles(t, s); got != "a" {
		t.Errorf("deleted = %q, want only a", got)
	}
	if _, err := s.RestoreItem(ctx, ids["c"]); !errors.Is(err, ErrNotFound) {
		t.Errorf("restore live item: err = %v, want ErrNotFound", err)
	}
	if _, err := s.RestoreItem(ctx, 999); !errors.Is(err, ErrNotFound) {
		t.Errorf("restore unknown: err = %v, want ErrNotFound", err)
	}

	deletedAt("a", formatTime(time.Now().Add(-DeletedRetention-time.Minute)))
	if got := deletedTitles(t, s); got != "" {
		t.Errorf("deleted = %q, want the expired one left out", got)
	}
	if _, err := s.RestoreItem(ctx, ids["a"]); !errors.Is(err, ErrNotFound) {
		t.Errorf("restore expired: err = %v, want ErrNotFound", err)
	}
	if _, err := s.DeleteItem(ctx, ids["b"]); err != nil {
		t.Fatal(err)
	}
	if n, err := s.PurgeDeleted(ctx); err != nil || n != 1 {
		t.Errorf("PurgeDeleted = %d, %v, want 1 erased", n, err)
	}
	var rows int
	if err := s.db.QueryRow("SELECT COUNT(*) FROM items WHERE id = ?", ids["a"]).Scan(&rows); err != nil || rows != 0 {
		t.Errorf("expired item still stored: %d rows, %v", rows, err)
	}
	if got := deletedTitles(t, s); got != "b" {
		t.Errorf("deleted after purge = %q, want b kept", got)
	}
	f, err := s.CreateItem(ctx, "f", nil)
	if err != nil {
		t.Fatal(err)
	}
	if f.ID <= ids["e"] {
		t.Errorf("new id %d reuses an erased one", f.ID)
	}
}

func TestMigrationBackfillsOrder(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "test.db")
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	for _, q := range []string{
		migrations[0],
		"PRAGMA user_version = 1",
		`INSERT INTO items (id, title, created_at, updated_at) VALUES
			(1, 'third', '2026-10-01T12:00:00Z', '2026-10-01T12:00:00Z'),
			(2, 'first', '2026-09-30T12:00:00Z', '2026-10-02T12:00:00Z'),
			(3, 'fourth', '2026-10-01T12:00:00Z', '2026-10-01T12:00:00Z'),
			(4, 'second', '2026-10-01T11:59:59Z', '2026-10-01T11:59:59Z')`,
	} {
		if _, err := db.Exec(q); err != nil {
			t.Fatal(err)
		}
	}
	db.Close()

	s, err := Open(ctx, path)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if got := titles(t, s); got != "first,second,third,fourth" {
		t.Errorf("migrated order = %q, want by created_at, then id", got)
	}
	if _, err := s.CreateItem(ctx, "fifth", nil); err != nil {
		t.Fatal(err)
	}
	if got := titles(t, s); got != "first,second,third,fourth,fifth" {
		t.Errorf("after create: order = %q, want appended", got)
	}
}

func TestMigrationBackfillsCategoryOrder(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "test.db")
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	for _, q := range []string{
		migrations[0],
		migrations[1],
		"PRAGMA user_version = 2",
		`INSERT INTO categories (id, name, created_at, updated_at) VALUES
			(1, 'beta', '2026-10-01T12:00:00Z', '2026-10-01T12:00:00Z'),
			(2, 'charlie', '2026-10-01T12:00:00Z', '2026-10-01T12:00:00Z'),
			(3, 'Bravo', '2026-10-01T12:00:00Z', '2026-10-01T12:00:00Z'),
			(4, 'Alpha', '2026-10-01T12:00:00Z', '2026-10-01T12:00:00Z')`,
	} {
		if _, err := db.Exec(q); err != nil {
			t.Fatal(err)
		}
	}
	db.Close()

	s, err := Open(ctx, path)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	if got := categoryOrder(t, s); got != "Alpha,beta,Bravo,charlie,-" {
		t.Errorf("migrated order = %q, want case-insensitive by name, then Uncategorized", got)
	}
	if _, err := s.CreateCategory(ctx, "delta"); err != nil {
		t.Fatal(err)
	}
	if got := categoryOrder(t, s); got != "Alpha,beta,Bravo,charlie,delta,-" {
		t.Errorf("after create: order = %q, want before Uncategorized", got)
	}
}

func TestPreviews(t *testing.T) {
	ctx := context.Background()
	s := openTest(t)
	var requested []string
	s.OnMissingPreview(func(link string) { requested = append(requested, link) })
	expectRequested := func(want ...string) {
		t.Helper()
		if strings.Join(requested, " ") != strings.Join(want, " ") {
			t.Errorf("requested %q, want %q", requested, want)
		}
		requested = nil
	}

	plain, err := s.CreateItem(ctx, "Milk", nil)
	if err != nil {
		t.Fatal(err)
	}
	if plain.Link != nil || plain.Preview != nil {
		t.Errorf("item without link = %+v", plain)
	}
	expectRequested()

	const post, other = "https://example.com/post", "https://example.com/other"
	it, err := s.CreateItem(ctx, "Read "+post+".", nil)
	if err != nil {
		t.Fatal(err)
	}
	if it.Link == nil || *it.Link != post || it.Preview != nil {
		t.Errorf("created = %+v, want link %s and no preview yet", it, post)
	}
	expectRequested(post)
	if _, err := s.CreateItem(ctx, "Again "+post, nil); err != nil {
		t.Fatal(err)
	}
	expectRequested(post)
	if _, err := s.ListItems(ctx); err != nil {
		t.Fatal(err)
	}
	expectRequested(post)

	want := Preview{Title: "A post", Description: "About things", Image: "https://example.com/og.png", SiteName: "Example", Icon: "https://example.com/favicon.ico"}
	if err := s.SavePreview(ctx, post, want); err != nil {
		t.Fatal(err)
	}
	items, err := s.ListItems(ctx)
	if err != nil {
		t.Fatal(err)
	}
	expectRequested()
	if items[0].Preview != nil {
		t.Errorf("item without link got preview %+v", items[0].Preview)
	}
	for _, item := range items[1:] {
		if item.Preview == nil || *item.Preview != want {
			t.Errorf("item %q preview = %+v, want %+v", item.Title, item.Preview, want)
		}
	}
	got, err := s.UpdateItem(ctx, it.ID, ItemUpdate{Checked: ptr(true)})
	if err != nil {
		t.Fatal(err)
	}
	if got.Preview == nil || *got.Preview != want {
		t.Errorf("updated preview = %+v, want %+v", got.Preview, want)
	}

	got, err = s.UpdateItem(ctx, it.ID, ItemUpdate{Title: ptr("Read " + other)})
	if err != nil {
		t.Fatal(err)
	}
	if got.Link == nil || *got.Link != other || got.Preview != nil {
		t.Errorf("after retitle = %+v, want link %s and no preview", got, other)
	}
	expectRequested(other)
	if err := s.SavePreview(ctx, other, Preview{}); err != nil {
		t.Fatal(err)
	}
	items, err = s.ListItems(ctx)
	if err != nil {
		t.Fatal(err)
	}
	expectRequested()
	if items[1].Preview != nil {
		t.Errorf("nothing found: preview = %+v, want nil", items[1].Preview)
	}

	got, err = s.UpdateItem(ctx, it.ID, ItemUpdate{Title: ptr("No link")})
	if err != nil {
		t.Fatal(err)
	}
	if got.Link != nil || got.Preview != nil {
		t.Errorf("after removing the link = %+v", got)
	}
	expectRequested()
}

func TestMigrationKeepsItemsAndFindsTheirLinks(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "test.db")
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	for _, q := range append(migrations[:3:3],
		"PRAGMA user_version = 3",
		`INSERT INTO items (id, title, position, created_at, updated_at) VALUES
			(1, 'Read https://example.com/post', 1, '2026-10-01T12:00:00Z', '2026-10-01T12:00:00Z')`,
	) {
		if _, err := db.Exec(q); err != nil {
			t.Fatal(err)
		}
	}
	db.Close()

	s, err := Open(ctx, path)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	items, err := s.ListItems(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 1 || items[0].Link == nil || *items[0].Link != "https://example.com/post" || items[0].Preview != nil {
		t.Fatalf("migrated items = %+v", items)
	}
	if err := s.SavePreview(ctx, "https://example.com/post", Preview{Title: "A post"}); err != nil {
		t.Fatal(err)
	}
	if items, err = s.ListItems(ctx); err != nil || items[0].Preview == nil || items[0].Preview.Title != "A post" {
		t.Errorf("after save: items = %+v, %v", items, err)
	}
}
