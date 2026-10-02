package api

import (
	"crypto/subtle"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"strconv"
	"strings"
	"time"

	"checkcheck/internal/events"
	"checkcheck/internal/store"
)

const (
	maxBodyBytes = 1 << 20
	pingInterval = 25 * time.Second
)

func Handler(st *store.Store, hub *events.Hub, token string) http.Handler {
	h := &handlers{st: st, hub: hub}
	authed := http.NewServeMux()
	authed.HandleFunc("GET /api/categories", h.listCategories)
	authed.HandleFunc("POST /api/categories", h.createCategory)
	authed.HandleFunc("PATCH /api/categories/{id}", h.renameCategory)
	authed.HandleFunc("DELETE /api/categories/{id}", h.deleteCategory)
	authed.HandleFunc("GET /api/categories/order", h.getCategoryOrder)
	authed.HandleFunc("PUT /api/categories/order", h.setCategoryOrder)
	authed.HandleFunc("GET /api/items", h.listItems)
	authed.HandleFunc("POST /api/items", h.createItem)
	authed.HandleFunc("PATCH /api/items/{id}", h.updateItem)
	authed.HandleFunc("DELETE /api/items/{id}", h.deleteItem)
	authed.HandleFunc("GET /api/items/deleted", h.listDeletedItems)
	authed.HandleFunc("POST /api/items/{id}/restore", h.restoreItem)
	authed.HandleFunc("GET /api/events", h.events)
	// Also catches known paths with an unsupported method, which therefore
	// get 404 rather than ServeMux's plain-text 405.
	authed.HandleFunc("/api/", func(w http.ResponseWriter, r *http.Request) {
		writeError(w, http.StatusNotFound, "not found")
	})

	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/health", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	})
	mux.Handle("/api/", RequireToken(token, authed))
	return mux
}

func RequireToken(token string, next http.Handler) http.Handler {
	want := []byte(token)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		scheme, got, _ := strings.Cut(r.Header.Get("Authorization"), " ")
		if !strings.EqualFold(scheme, "Bearer") || subtle.ConstantTimeCompare([]byte(got), want) != 1 {
			unauthorized(w)
			return
		}
		next.ServeHTTP(w, r)
	})
}

// RequirePathToken is RequireToken for clients that can't send headers, such as
// Claude's custom connectors. It must be registered on a route with a {token}
// wildcard, which is where it reads the token from.
func RequirePathToken(token string, next http.Handler) http.Handler {
	want := []byte(token)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if subtle.ConstantTimeCompare([]byte(r.PathValue("token")), want) != 1 {
			unauthorized(w)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func unauthorized(w http.ResponseWriter) {
	w.Header().Set("WWW-Authenticate", "Bearer")
	writeError(w, http.StatusUnauthorized, "missing or invalid token")
}

type handlers struct {
	st  *store.Store
	hub *events.Hub
}

func (h *handlers) listCategories(w http.ResponseWriter, r *http.Request) {
	cats, err := h.st.ListCategories(r.Context())
	respond(w, r, http.StatusOK, cats, err)
}

type categoryRequest struct {
	Name string `json:"name"`
}

func (h *handlers) createCategory(w http.ResponseWriter, r *http.Request) {
	var req categoryRequest
	if !decode(w, r, &req) {
		return
	}
	c, err := h.st.CreateCategory(r.Context(), req.Name)
	respond(w, r, http.StatusCreated, c, err)
}

func (h *handlers) renameCategory(w http.ResponseWriter, r *http.Request) {
	id, ok := pathID(w, r)
	if !ok {
		return
	}
	var req categoryRequest
	if !decode(w, r, &req) {
		return
	}
	c, err := h.st.RenameCategory(r.Context(), id, req.Name)
	respond(w, r, http.StatusOK, c, err)
}

func (h *handlers) deleteCategory(w http.ResponseWriter, r *http.Request) {
	id, ok := pathID(w, r)
	if !ok {
		return
	}
	_, err := h.st.DeleteCategory(r.Context(), id)
	respond(w, r, http.StatusNoContent, nil, err)
}

type categoryOrder struct {
	Order []*int64 `json:"order"`
}

func (h *handlers) getCategoryOrder(w http.ResponseWriter, r *http.Request) {
	order, err := h.st.CategoryOrder(r.Context())
	respond(w, r, http.StatusOK, categoryOrder{order}, err)
}

func (h *handlers) setCategoryOrder(w http.ResponseWriter, r *http.Request) {
	var req categoryOrder
	if !decode(w, r, &req) {
		return
	}
	order, err := h.st.SetCategoryOrder(r.Context(), req.Order)
	respond(w, r, http.StatusOK, categoryOrder{order}, err)
}

func (h *handlers) listItems(w http.ResponseWriter, r *http.Request) {
	items, err := h.st.ListItems(r.Context())
	respond(w, r, http.StatusOK, items, err)
}

func (h *handlers) createItem(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Title      string `json:"title"`
		CategoryID *int64 `json:"category_id"`
	}
	if !decode(w, r, &req) {
		return
	}
	it, err := h.st.CreateItem(r.Context(), req.Title, req.CategoryID)
	respond(w, r, http.StatusCreated, it, err)
}

func (h *handlers) updateItem(w http.ResponseWriter, r *http.Request) {
	id, ok := pathID(w, r)
	if !ok {
		return
	}
	var req struct {
		Title      *string          `json:"title"`
		Checked    *bool            `json:"checked"`
		CategoryID optional[*int64] `json:"category_id"`
		BeforeID   optional[*int64] `json:"before_id"`
	}
	if !decode(w, r, &req) {
		return
	}
	it, err := h.st.UpdateItem(r.Context(), id, store.ItemUpdate{
		Title:       req.Title,
		Checked:     req.Checked,
		SetCategory: req.CategoryID.Set,
		CategoryID:  req.CategoryID.Value,
		SetBefore:   req.BeforeID.Set,
		BeforeID:    req.BeforeID.Value,
	})
	respond(w, r, http.StatusOK, it, err)
}

func (h *handlers) deleteItem(w http.ResponseWriter, r *http.Request) {
	id, ok := pathID(w, r)
	if !ok {
		return
	}
	_, err := h.st.DeleteItem(r.Context(), id)
	respond(w, r, http.StatusNoContent, nil, err)
}

func (h *handlers) listDeletedItems(w http.ResponseWriter, r *http.Request) {
	items, err := h.st.ListDeletedItems(r.Context())
	respond(w, r, http.StatusOK, items, err)
}

func (h *handlers) restoreItem(w http.ResponseWriter, r *http.Request) {
	id, ok := pathID(w, r)
	if !ok {
		return
	}
	it, err := h.st.RestoreItem(r.Context(), id)
	respond(w, r, http.StatusOK, it, err)
}

func (h *handlers) events(w http.ResponseWriter, r *http.Request) {
	evs, unsubscribe := h.hub.Subscribe()
	defer unsubscribe()
	rc := http.NewResponseController(w)
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	// Stops nginx from buffering the stream.
	w.Header().Set("X-Accel-Buffering", "no")
	w.WriteHeader(http.StatusOK)
	// The headers only go out with the first flush.
	_, err := io.WriteString(w, ": connected\n\n")
	ping := time.NewTicker(pingInterval)
	defer ping.Stop()
	for {
		if err == nil {
			err = rc.Flush()
		}
		if err != nil {
			return
		}
		select {
		case <-r.Context().Done():
			return
		case <-ping.C:
			_, err = io.WriteString(w, ": ping\n\n")
		case e, ok := <-evs:
			if !ok {
				return
			}
			err = writeEvent(w, e)
		}
	}
}

func writeEvent(w io.Writer, e events.Event) error {
	data, err := json.Marshal(e.Data)
	if err != nil {
		return err
	}
	_, err = fmt.Fprintf(w, "event: %s\ndata: %s\n\n", e.Name, data)
	return err
}

// optional tells an omitted field (Set false) from an explicit null. Declare
// fields of it by value: on null, encoding/json nils a pointer field without
// calling UnmarshalJSON.
type optional[T any] struct {
	Set   bool
	Value T
}

func (o *optional[T]) UnmarshalJSON(b []byte) error {
	o.Set = true
	return json.Unmarshal(b, &o.Value)
}

func pathID(w http.ResponseWriter, r *http.Request) (int64, bool) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid id")
		return 0, false
	}
	return id, true
}

func decode(w http.ResponseWriter, r *http.Request, v any) bool {
	err := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxBodyBytes)).Decode(v)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON body: "+err.Error())
		return false
	}
	return true
}

func respond(w http.ResponseWriter, r *http.Request, status int, v any, err error) {
	switch {
	case err == nil:
		if status == http.StatusNoContent {
			w.WriteHeader(status)
			return
		}
		writeJSON(w, status, v)
	case errors.Is(err, store.ErrInvalid):
		writeError(w, http.StatusBadRequest, err.Error())
	case errors.Is(err, store.ErrNotFound):
		writeError(w, http.StatusNotFound, err.Error())
	case errors.Is(err, store.ErrConflict):
		writeError(w, http.StatusConflict, err.Error())
	default:
		slog.ErrorContext(r.Context(), "request failed", "method", r.Method, "path", r.URL.Path, "err", err)
		writeError(w, http.StatusInternalServerError, "internal error")
	}
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]string{"error": msg})
}
