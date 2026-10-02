package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"strings"
	"time"
	"unicode/utf8"

	"modernc.org/sqlite"
	sqlite3 "modernc.org/sqlite/lib"
)

var (
	ErrNotFound = errors.New("not found")
	ErrConflict = errors.New("already exists")
	ErrInvalid  = errors.New("invalid input")
)

type Category struct {
	ID        int64     `json:"id"`
	Name      string    `json:"name"`
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
}

type Item struct {
	ID         int64     `json:"id"`
	Title      string    `json:"title"`
	Checked    bool      `json:"checked"`
	CategoryID *int64    `json:"category_id"`
	Link       *string   `json:"link"`
	Preview    *Preview  `json:"preview"`
	CreatedAt  time.Time `json:"created_at"`
	UpdatedAt  time.Time `json:"updated_at"`
}

// DeletedItem holds an item's fields as they were when it was deleted.
type DeletedItem struct {
	ID        int64     `json:"id"`
	Title     string    `json:"title"`
	Checked   bool      `json:"checked"`
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
	DeletedAt time.Time `json:"deleted_at"`
}

const DeletedRetention = 30 * 24 * time.Hour

type Preview struct {
	Title       string `json:"title,omitempty"`
	Description string `json:"description,omitempty"`
	Image       string `json:"image,omitempty"`
	SiteName    string `json:"site_name,omitempty"`
	Icon        string `json:"icon,omitempty"`
}

// ItemUpdate leaves nil fields unchanged. CategoryID is applied only when
// SetCategory is true, so a nil CategoryID can mean "uncategorize". Likewise
// BeforeID only when SetBefore is true: the item moves directly before item
// BeforeID in the list order, or to the end when BeforeID is nil.
type ItemUpdate struct {
	Title       *string
	Checked     *bool
	SetCategory bool
	CategoryID  *int64
	SetBefore   bool
	BeforeID    *int64
}

const (
	maxNameLen  = 100
	maxTitleLen = 500
)

// AUTOINCREMENT so a deleted id is never handed out again: clients and LLMs
// holding a stale id must get a 404, not someone else's item.
var migrations = []string{
	`CREATE TABLE categories (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		name TEXT NOT NULL UNIQUE COLLATE NOCASE,
		created_at TEXT NOT NULL,
		updated_at TEXT NOT NULL
	);
	CREATE TABLE items (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		title TEXT NOT NULL,
		checked INTEGER NOT NULL DEFAULT 0,
		category_id INTEGER REFERENCES categories(id) ON DELETE SET NULL,
		created_at TEXT NOT NULL,
		updated_at TEXT NOT NULL
	);
	CREATE INDEX items_category_id ON items(category_id);`,
	`ALTER TABLE items ADD COLUMN position INTEGER NOT NULL DEFAULT 0;
	UPDATE items SET position = ranked.n
		FROM (SELECT id, ROW_NUMBER() OVER (ORDER BY created_at, id) AS n FROM items) AS ranked
		WHERE items.id = ranked.id;
	CREATE INDEX items_position ON items(position);`,
	// Uncategorized has no row in categories, so its slot in the category
	// order is a setting in the same position space as categories.position.
	`ALTER TABLE categories ADD COLUMN position INTEGER NOT NULL DEFAULT 0;
	UPDATE categories SET position = ranked.n
		FROM (SELECT id, ROW_NUMBER() OVER (ORDER BY name, id) AS n FROM categories) AS ranked
		WHERE categories.id = ranked.id;
	CREATE TABLE settings (key TEXT PRIMARY KEY, value INTEGER NOT NULL);
	INSERT INTO settings (key, value) SELECT 'uncategorized_position', COUNT(*) + 1 FROM categories;`,
	`CREATE TABLE link_previews (
		url TEXT PRIMARY KEY,
		title TEXT NOT NULL DEFAULT '',
		description TEXT NOT NULL DEFAULT '',
		image TEXT NOT NULL DEFAULT '',
		site_name TEXT NOT NULL DEFAULT '',
		icon TEXT NOT NULL DEFAULT '',
		fetched_at TEXT NOT NULL
	);`,
	`ALTER TABLE items ADD COLUMN deleted_at TEXT;
	CREATE INDEX items_deleted_at ON items(deleted_at);`,
	// No foreign key on target_id: a key must outlive what it made, so a
	// replay after a delete is a 404 rather than a second create.
	`CREATE TABLE idempotency_keys (
		kind TEXT NOT NULL,
		key TEXT NOT NULL,
		target_id INTEGER NOT NULL,
		created_at TEXT NOT NULL,
		PRIMARY KEY (kind, key)
	);`,
}

const keyRetention = 30 * 24 * time.Hour

type Store struct {
	db        *sql.DB
	onMissing func(link string)
	onChange  func(ctx context.Context)
}

func Open(ctx context.Context, path string) (*Store, error) {
	q := url.Values{
		"_pragma": {"busy_timeout(5000)", "foreign_keys(1)", "journal_mode(WAL)"},
		"_txlock": {"immediate"},
	}
	db, err := sql.Open("sqlite", path+"?"+q.Encode())
	if err != nil {
		return nil, err
	}
	s := &Store{db: db}
	if err := s.migrate(ctx); err != nil {
		db.Close()
		return nil, err
	}
	return s, nil
}

func (s *Store) Close() error {
	return s.db.Close()
}

// OnMissingPreview sets f to be called with every link that an item returned
// by ListItems, CreateItem, CreateItems or UpdateItem has no stored preview
// for, so it can be fetched. f must not block. Call it before the store is
// used concurrently.
func (s *Store) OnMissingPreview(f func(link string)) {
	s.onMissing = f
}

// OnChange sets f to be called once after every committed write that changes
// what a list returns, with the ctx of the call that made it. Saving a
// preview, purging and a create replayed by its key are not such writes. f
// must not block. Call it before the store is used concurrently.
func (s *Store) OnChange(f func(ctx context.Context)) {
	s.onChange = f
}

func (s *Store) changed(ctx context.Context) {
	if s.onChange != nil {
		s.onChange(ctx)
	}
}

func (s *Store) migrate(ctx context.Context) error {
	var version int
	if err := s.db.QueryRowContext(ctx, "PRAGMA user_version").Scan(&version); err != nil {
		return fmt.Errorf("read schema version: %w", err)
	}
	if version > len(migrations) {
		return fmt.Errorf("database schema version %d is newer than this binary supports (%d)", version, len(migrations))
	}
	for v := version; v < len(migrations); v++ {
		tx, err := s.db.BeginTx(ctx, nil)
		if err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, migrations[v]); err != nil {
			tx.Rollback()
			return fmt.Errorf("migration %d: %w", v+1, err)
		}
		if _, err := tx.ExecContext(ctx, fmt.Sprintf("PRAGMA user_version = %d", v+1)); err != nil {
			tx.Rollback()
			return fmt.Errorf("migration %d: %w", v+1, err)
		}
		if err := tx.Commit(); err != nil {
			return fmt.Errorf("migration %d: %w", v+1, err)
		}
	}
	return nil
}

func now() string {
	return formatTime(time.Now())
}

func formatTime(t time.Time) string {
	return t.UTC().Format(time.RFC3339)
}

// Deleted items whose deleted_at sorts before this are past restoring.
func deletedCutoff() string {
	return formatTime(time.Now().Add(-DeletedRetention))
}

func keyCutoff() string {
	return formatTime(time.Now().Add(-keyRetention))
}

// Keys are per kind, so one key can name both an item and a category create.
const (
	itemKey     = "item"
	categoryKey = "category"
)

// lookupKey returns the id that key made, if it made one within keyRetention.
// The empty key never made anything.
func lookupKey(ctx context.Context, tx *sql.Tx, kind, key string) (id int64, found bool, err error) {
	if key == "" {
		return 0, false, nil
	}
	err = tx.QueryRowContext(ctx,
		"SELECT target_id FROM idempotency_keys WHERE kind = ? AND key = ? AND created_at >= ?",
		kind, key, keyCutoff()).Scan(&id)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, false, nil
	}
	return id, err == nil, err
}

func rememberKey(ctx context.Context, tx *sql.Tx, kind, key string, id int64) error {
	if key == "" {
		return nil
	}
	// REPLACE: an expired key stays stored until PurgeDeleted erases it.
	_, err := tx.ExecContext(ctx,
		"INSERT OR REPLACE INTO idempotency_keys (kind, key, target_id, created_at) VALUES (?, ?, ?, ?)",
		kind, key, id, now())
	return err
}

type scanner interface {
	Scan(dest ...any) error
}

const categoryColumns = "id, name, created_at, updated_at"

func scanCategory(row scanner) (Category, error) {
	var c Category
	var created, updated string
	if err := row.Scan(&c.ID, &c.Name, &created, &updated); err != nil {
		return Category{}, err
	}
	var err error
	if c.CreatedAt, err = time.Parse(time.RFC3339, created); err != nil {
		return Category{}, err
	}
	if c.UpdatedAt, err = time.Parse(time.RFC3339, updated); err != nil {
		return Category{}, err
	}
	return c, nil
}

const itemColumns = "id, title, checked, category_id, created_at, updated_at"

func scanItem(row scanner) (Item, error) {
	var it Item
	var created, updated string
	if err := row.Scan(&it.ID, &it.Title, &it.Checked, &it.CategoryID, &created, &updated); err != nil {
		return Item{}, err
	}
	var err error
	if it.CreatedAt, err = time.Parse(time.RFC3339, created); err != nil {
		return Item{}, err
	}
	if it.UpdatedAt, err = time.Parse(time.RFC3339, updated); err != nil {
		return Item{}, err
	}
	if link := findLink(it.Title); link != "" {
		it.Link = &link
	}
	return it, nil
}

func cleanText(field, v string, max int) (string, error) {
	v = strings.TrimSpace(v)
	if v == "" {
		return "", fmt.Errorf("%w: %s must not be empty", ErrInvalid, field)
	}
	if utf8.RuneCountInString(v) > max {
		return "", fmt.Errorf("%w: %s must be at most %d characters", ErrInvalid, field, max)
	}
	return v, nil
}

func sqliteCode(err error) int {
	var e *sqlite.Error
	if errors.As(err, &e) {
		return e.Code()
	}
	return 0
}

func categoryErr(err error, id int64, name string) error {
	switch {
	case errors.Is(err, sql.ErrNoRows):
		return fmt.Errorf("category %d %w", id, ErrNotFound)
	case sqliteCode(err) == sqlite3.SQLITE_CONSTRAINT_UNIQUE:
		return fmt.Errorf("category %q %w", name, ErrConflict)
	}
	return err
}

func itemErr(err error, id int64, categoryID *int64) error {
	switch {
	case errors.Is(err, sql.ErrNoRows):
		return fmt.Errorf("item %d %w", id, ErrNotFound)
	case sqliteCode(err) == sqlite3.SQLITE_CONSTRAINT_FOREIGNKEY && categoryID != nil:
		return fmt.Errorf("%w: category %d does not exist", ErrInvalid, *categoryID)
	}
	return err
}

func (s *Store) ListCategories(ctx context.Context) ([]Category, error) {
	rows, err := s.db.QueryContext(ctx, "SELECT "+categoryColumns+" FROM categories ORDER BY position, id")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	categories := []Category{}
	for rows.Next() {
		c, err := scanCategory(rows)
		if err != nil {
			return nil, err
		}
		categories = append(categories, c)
	}
	return categories, rows.Err()
}

func (s *Store) GetCategory(ctx context.Context, id int64) (Category, error) {
	c, err := scanCategory(s.db.QueryRowContext(ctx, "SELECT "+categoryColumns+" FROM categories WHERE id = ?", id))
	return c, categoryErr(err, id, "")
}

func (s *Store) CreateCategory(ctx context.Context, name string) (Category, error) {
	return s.CreateCategoryWithKey(ctx, "", name)
}

// CreateCategoryWithKey is CreateCategory, except that a key that already
// made a category within keyRetention makes nothing: it returns that category
// as it is now, whatever name says, or ErrNotFound once it is deleted. A
// failed create doesn't use up the key.
func (s *Store) CreateCategoryWithKey(ctx context.Context, key, name string) (Category, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return Category{}, err
	}
	defer tx.Rollback()
	id, found, err := lookupKey(ctx, tx, categoryKey, key)
	if err != nil {
		return Category{}, err
	}
	if found {
		c, err := scanCategory(tx.QueryRowContext(ctx, "SELECT "+categoryColumns+" FROM categories WHERE id = ?", id))
		return c, categoryErr(err, id, "")
	}
	name, err = cleanText("name", name, maxNameLen)
	if err != nil {
		return Category{}, err
	}
	var last, uncategorized int64
	if err := tx.QueryRowContext(ctx,
		"SELECT COALESCE(MAX(position), 0), "+uncategorizedPosition+" FROM categories").Scan(&last, &uncategorized); err != nil {
		return Category{}, err
	}
	pos := last + 1
	if uncategorized >= last {
		pos = uncategorized
		if _, err := tx.ExecContext(ctx, setUncategorizedPosition, pos+1); err != nil {
			return Category{}, err
		}
	}
	ts := now()
	c, err := scanCategory(tx.QueryRowContext(ctx,
		"INSERT INTO categories (name, position, created_at, updated_at) VALUES (?, ?, ?, ?) RETURNING "+categoryColumns,
		name, pos, ts, ts))
	if err != nil {
		return Category{}, categoryErr(err, 0, name)
	}
	if err := rememberKey(ctx, tx, categoryKey, key, c.ID); err != nil {
		return Category{}, err
	}
	if err := tx.Commit(); err != nil {
		return Category{}, err
	}
	s.changed(ctx)
	return c, nil
}

func (s *Store) RenameCategory(ctx context.Context, id int64, name string) (Category, error) {
	name, err := cleanText("name", name, maxNameLen)
	if err != nil {
		return Category{}, err
	}
	c, err := scanCategory(s.db.QueryRowContext(ctx,
		"UPDATE categories SET name = ?, updated_at = ? WHERE id = ? RETURNING "+categoryColumns,
		name, now(), id))
	if err != nil {
		return Category{}, categoryErr(err, id, name)
	}
	s.changed(ctx)
	return c, nil
}

// DeleteCategory uncategorizes the category's items.
func (s *Store) DeleteCategory(ctx context.Context, id int64) (Category, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return Category{}, err
	}
	defer tx.Rollback()
	// ON DELETE SET NULL would uncategorize the items too, but without
	// touching their updated_at.
	if _, err := tx.ExecContext(ctx,
		"UPDATE items SET category_id = NULL, updated_at = ? WHERE category_id = ? AND deleted_at IS NULL", now(), id); err != nil {
		return Category{}, err
	}
	c, err := scanCategory(tx.QueryRowContext(ctx, "DELETE FROM categories WHERE id = ? RETURNING "+categoryColumns, id))
	if err != nil {
		return Category{}, categoryErr(err, id, "")
	}
	if err := tx.Commit(); err != nil {
		return Category{}, err
	}
	s.changed(ctx)
	return c, nil
}

const (
	uncategorizedPosition    = "(SELECT value FROM settings WHERE key = 'uncategorized_position')"
	setUncategorizedPosition = "UPDATE settings SET value = ? WHERE key = 'uncategorized_position'"
)

// CategoryOrder lists every category id plus one nil for Uncategorized.
func (s *Store) CategoryOrder(ctx context.Context) ([]*int64, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT id FROM (
			SELECT id, position FROM categories
			UNION ALL SELECT NULL, `+uncategorizedPosition+`
		) ORDER BY position, id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var order []*int64
	for rows.Next() {
		var id *int64
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		order = append(order, id)
	}
	return order, rows.Err()
}

// SetCategoryOrder takes an order in CategoryOrder's shape and returns it.
func (s *Store) SetCategoryOrder(ctx context.Context, order []*int64) ([]*int64, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	rows, err := tx.QueryContext(ctx, "SELECT id FROM categories")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	exists := map[int64]bool{}
	for rows.Next() {
		var id int64
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		exists[id] = true
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	listed := map[int64]bool{}
	nulls := 0
	for _, id := range order {
		switch {
		case id == nil:
			nulls++
		case !exists[*id]:
			return nil, fmt.Errorf("%w: category %d does not exist", ErrInvalid, *id)
		case listed[*id]:
			return nil, fmt.Errorf("%w: category %d is listed twice", ErrInvalid, *id)
		default:
			listed[*id] = true
		}
	}
	if nulls != 1 || len(listed) != len(exists) {
		return nil, fmt.Errorf("%w: order must list every category id once plus one null for Uncategorized", ErrInvalid)
	}
	for i, id := range order {
		if id == nil {
			_, err = tx.ExecContext(ctx, setUncategorizedPosition, i+1)
		} else {
			_, err = tx.ExecContext(ctx, "UPDATE categories SET position = ? WHERE id = ?", i+1, *id)
		}
		if err != nil {
			return nil, err
		}
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	s.changed(ctx)
	return order, nil
}

func (s *Store) ListItems(ctx context.Context) ([]Item, error) {
	rows, err := s.db.QueryContext(ctx, "SELECT "+itemColumns+" FROM items WHERE deleted_at IS NULL ORDER BY position, id")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := []Item{}
	for rows.Next() {
		it, err := scanItem(rows)
		if err != nil {
			return nil, err
		}
		items = append(items, it)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return items, s.attachPreviews(ctx, items)
}

func (s *Store) CreateItem(ctx context.Context, title string, categoryID *int64) (Item, error) {
	return s.CreateItemWithKey(ctx, "", title, categoryID)
}

// CreateItemWithKey is CreateItem, except that a key that already made an
// item within keyRetention makes nothing: it returns that item as it is now,
// whatever title and categoryID say, or ErrNotFound once it is deleted. A
// failed create doesn't use up the key.
func (s *Store) CreateItemWithKey(ctx context.Context, key, title string, categoryID *int64) (Item, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return Item{}, err
	}
	defer tx.Rollback()
	id, found, err := lookupKey(ctx, tx, itemKey, key)
	if err != nil {
		return Item{}, err
	}
	if found {
		it, err := scanItem(tx.QueryRowContext(ctx,
			"SELECT "+itemColumns+" FROM items WHERE id = ? AND deleted_at IS NULL", id))
		if err != nil {
			return Item{}, itemErr(err, id, nil)
		}
		return s.withPreview(ctx, it)
	}
	it, err := insertItem(ctx, tx, title, categoryID)
	if err != nil {
		return Item{}, err
	}
	if err := rememberKey(ctx, tx, itemKey, key, it.ID); err != nil {
		return Item{}, err
	}
	if err := tx.Commit(); err != nil {
		return Item{}, err
	}
	s.changed(ctx)
	return s.withPreview(ctx, it)
}

type NewItem struct {
	Title      string
	CategoryID *int64
}

// CreateItems creates all of items, in order, or none of them: an error names
// the first item that failed by its 1-based position. Fails on an empty list.
func (s *Store) CreateItems(ctx context.Context, items []NewItem) ([]Item, error) {
	if len(items) == 0 {
		return nil, fmt.Errorf("%w: items must not be empty", ErrInvalid)
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	created := make([]Item, len(items))
	for i, n := range items {
		if created[i], err = insertItem(ctx, tx, n.Title, n.CategoryID); err != nil {
			return nil, fmt.Errorf("item %d of %d: %w", i+1, len(items), err)
		}
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	s.changed(ctx)
	return created, s.attachPreviews(ctx, created)
}

func insertItem(ctx context.Context, tx *sql.Tx, title string, categoryID *int64) (Item, error) {
	title, err := cleanText("title", title, maxTitleLen)
	if err != nil {
		return Item{}, err
	}
	ts := now()
	it, err := scanItem(tx.QueryRowContext(ctx,
		`INSERT INTO items (title, category_id, position, created_at, updated_at)
			VALUES (?, ?, (SELECT COALESCE(MAX(position), 0) + 1 FROM items), ?, ?) RETURNING `+itemColumns,
		title, categoryID, ts, ts))
	if err != nil {
		return Item{}, itemErr(err, 0, categoryID)
	}
	return it, nil
}

func (s *Store) UpdateItem(ctx context.Context, id int64, u ItemUpdate) (Item, error) {
	if u.Title != nil {
		title, err := cleanText("title", *u.Title, maxTitleLen)
		if err != nil {
			return Item{}, err
		}
		u.Title = &title
	}
	if u.SetBefore && u.BeforeID != nil && *u.BeforeID == id {
		return Item{}, fmt.Errorf("%w: an item cannot be moved before itself", ErrInvalid)
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return Item{}, err
	}
	defer tx.Rollback()
	it, err := scanItem(tx.QueryRowContext(ctx, `UPDATE items SET
			title = COALESCE(?, title),
			checked = COALESCE(?, checked),
			category_id = CASE WHEN ? THEN ? ELSE category_id END,
			updated_at = ?
		WHERE id = ? AND deleted_at IS NULL RETURNING `+itemColumns,
		u.Title, u.Checked, u.SetCategory, u.CategoryID, now(), id))
	if err != nil {
		return Item{}, itemErr(err, id, u.CategoryID)
	}
	if u.SetBefore {
		if err := moveItem(ctx, tx, id, u.BeforeID); err != nil {
			return Item{}, err
		}
	}
	if err := tx.Commit(); err != nil {
		return Item{}, err
	}
	s.changed(ctx)
	return s.withPreview(ctx, it)
}

func moveItem(ctx context.Context, tx *sql.Tx, id int64, beforeID *int64) error {
	if beforeID == nil {
		_, err := tx.ExecContext(ctx,
			"UPDATE items SET position = (SELECT MAX(position) + 1 FROM items) WHERE id = ?", id)
		return err
	}
	var pos int64
	err := tx.QueryRowContext(ctx, "SELECT position FROM items WHERE id = ? AND deleted_at IS NULL", *beforeID).Scan(&pos)
	if errors.Is(err, sql.ErrNoRows) {
		return fmt.Errorf("%w: item %d does not exist", ErrInvalid, *beforeID)
	}
	if err != nil {
		return err
	}
	_, err = tx.ExecContext(ctx,
		"UPDATE items SET position = CASE WHEN id = ? THEN ? ELSE position + 1 END WHERE position >= ? OR id = ?",
		id, pos, pos, id)
	return err
}

// DeleteItem moves the item to Recently deleted, where only ListDeletedItems
// and RestoreItem see it.
func (s *Store) DeleteItem(ctx context.Context, id int64) (Item, error) {
	deleted, err := s.DeleteItems(ctx, []int64{id})
	if err != nil {
		return Item{}, err
	}
	return deleted[0], nil
}

// DeleteItems is DeleteItem for all of ids, in order, or for none of them when
// one is unknown or already deleted. A repeated id counts once. Fails on an
// empty list.
func (s *Store) DeleteItems(ctx context.Context, ids []int64) ([]Item, error) {
	if len(ids) == 0 {
		return nil, fmt.Errorf("%w: item ids must not be empty", ErrInvalid)
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	ts := now()
	deleted := []Item{}
	seen := map[int64]bool{}
	for _, id := range ids {
		if seen[id] {
			continue
		}
		seen[id] = true
		it, err := scanItem(tx.QueryRowContext(ctx,
			"UPDATE items SET deleted_at = ? WHERE id = ? AND deleted_at IS NULL RETURNING "+itemColumns, ts, id))
		if err != nil {
			return nil, itemErr(err, id, nil)
		}
		deleted = append(deleted, it)
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	s.changed(ctx)
	return deleted, nil
}

// ListDeletedItems returns the items deleted within DeletedRetention, most
// recently deleted first and those deleted in the same second in list order.
func (s *Store) ListDeletedItems(ctx context.Context) ([]DeletedItem, error) {
	rows, err := s.db.QueryContext(ctx,
		`SELECT id, title, checked, created_at, updated_at, deleted_at FROM items
			WHERE deleted_at >= ? ORDER BY deleted_at DESC, position, id`, deletedCutoff())
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := []DeletedItem{}
	for rows.Next() {
		it, err := scanDeletedItem(rows)
		if err != nil {
			return nil, err
		}
		items = append(items, it)
	}
	return items, rows.Err()
}

func scanDeletedItem(row scanner) (DeletedItem, error) {
	var it DeletedItem
	var created, updated, deleted string
	if err := row.Scan(&it.ID, &it.Title, &it.Checked, &created, &updated, &deleted); err != nil {
		return DeletedItem{}, err
	}
	var err error
	if it.CreatedAt, err = time.Parse(time.RFC3339, created); err != nil {
		return DeletedItem{}, err
	}
	if it.UpdatedAt, err = time.Parse(time.RFC3339, updated); err != nil {
		return DeletedItem{}, err
	}
	if it.DeletedAt, err = time.Parse(time.RFC3339, deleted); err != nil {
		return DeletedItem{}, err
	}
	return it, nil
}

// RestoreItem makes a deleted item from ListDeletedItems a normal one again,
// uncategorized and at the end of the list order. Any other id is
// ErrNotFound.
func (s *Store) RestoreItem(ctx context.Context, id int64) (Item, error) {
	it, err := scanItem(s.db.QueryRowContext(ctx, `UPDATE items SET
			deleted_at = NULL,
			category_id = NULL,
			position = (SELECT MAX(position) + 1 FROM items),
			updated_at = ?
		WHERE id = ? AND deleted_at >= ? RETURNING `+itemColumns,
		now(), id, deletedCutoff()))
	if err != nil {
		return Item{}, itemErr(err, id, nil)
	}
	s.changed(ctx)
	return s.withPreview(ctx, it)
}

// PurgeDeleted erases the items deleted longer than DeletedRetention ago and
// returns how many there were. It also erases the expired idempotency keys.
func (s *Store) PurgeDeleted(ctx context.Context) (int64, error) {
	if _, err := s.db.ExecContext(ctx, "DELETE FROM idempotency_keys WHERE created_at < ?", keyCutoff()); err != nil {
		return 0, err
	}
	res, err := s.db.ExecContext(ctx, "DELETE FROM items WHERE deleted_at < ?", deletedCutoff())
	if err != nil {
		return 0, err
	}
	return res.RowsAffected()
}

func (s *Store) withPreview(ctx context.Context, it Item) (Item, error) {
	items := []Item{it}
	err := s.attachPreviews(ctx, items)
	return items[0], err
}

func (s *Store) attachPreviews(ctx context.Context, items []Item) error {
	var links []string
	for _, it := range items {
		if it.Link != nil {
			links = append(links, *it.Link)
		}
	}
	if len(links) == 0 {
		return nil
	}
	linksJSON, err := json.Marshal(links)
	if err != nil {
		return err
	}
	rows, err := s.db.QueryContext(ctx,
		`SELECT url, title, description, image, site_name, icon FROM link_previews
			WHERE url IN (SELECT value FROM json_each(?))`, string(linksJSON))
	if err != nil {
		return err
	}
	defer rows.Close()
	stored := map[string]*Preview{}
	for rows.Next() {
		var link string
		var p Preview
		if err := rows.Scan(&link, &p.Title, &p.Description, &p.Image, &p.SiteName, &p.Icon); err != nil {
			return err
		}
		var found *Preview
		if p != (Preview{}) {
			found = &p
		}
		stored[link] = found
	}
	if err := rows.Err(); err != nil {
		return err
	}
	missing := map[string]bool{}
	for i, it := range items {
		if it.Link == nil {
			continue
		}
		p, ok := stored[*it.Link]
		items[i].Preview = p
		if !ok && !missing[*it.Link] && s.onMissing != nil {
			missing[*it.Link] = true
			s.onMissing(*it.Link)
		}
	}
	return nil
}

// SavePreview stores what was found at link, replacing any earlier result.
// The zero Preview records that nothing was found.
func (s *Store) SavePreview(ctx context.Context, link string, p Preview) error {
	_, err := s.db.ExecContext(ctx,
		`INSERT OR REPLACE INTO link_previews (url, title, description, image, site_name, icon, fetched_at)
			VALUES (?, ?, ?, ?, ?, ?, ?)`,
		link, p.Title, p.Description, p.Image, p.SiteName, p.Icon, now())
	return err
}
