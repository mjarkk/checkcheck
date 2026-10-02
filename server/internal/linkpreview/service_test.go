package linkpreview

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"checkcheck/internal/events"
	"checkcheck/internal/store"
)

type hits struct {
	mu sync.Mutex
	n  map[string]int
}

func (h *hits) count(path string) int {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.n[path]
}

func TestService(t *testing.T) {
	ctx := context.Background()
	st, err := store.Open(ctx, filepath.Join(t.TempDir(), "test.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()

	release := make(chan struct{})
	h := &hits{n: map[string]int{}}
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		h.mu.Lock()
		h.n[r.URL.Path]++
		h.mu.Unlock()
		switch r.URL.Path {
		case "/slow":
			<-release
		case "/broken":
			http.Error(w, "oops", http.StatusInternalServerError)
			return
		case "/hang":
			<-r.Context().Done()
			return
		}
		w.Header().Set("Content-Type", "text/html")
		if r.URL.Path != "/empty" {
			w.Write([]byte(`<title>` + r.URL.Path + `</title>`))
		}
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()

	hub := events.NewHub()
	evs, _ := hub.Subscribe()
	svc := NewService(st, hub, newClient(nil))
	clock := time.Now()
	svc.now = func() time.Time { return clock }
	st.OnMissingPreview(svc.Request)
	add := func(path string) {
		t.Helper()
		if _, err := st.CreateItem(ctx, "Look at "+srv.URL+path, nil); err != nil {
			t.Fatal(err)
		}
	}
	list := func() []store.Item {
		t.Helper()
		items, err := st.ListItems(ctx)
		if err != nil {
			t.Fatal(err)
		}
		return items
	}
	expectNoEvent := func() {
		t.Helper()
		select {
		case e := <-evs:
			t.Errorf("unexpected event %+v", e)
		default:
		}
	}

	add("/slow")
	add("/slow")
	list()
	close(release)
	svc.wg.Wait()
	if n := h.count("/slow"); n != 1 {
		t.Errorf("/slow fetched %d times, want once while in flight", n)
	}
	e := <-evs
	data, _ := json.Marshal(e.Data)
	want := `{"link":"` + srv.URL + `/slow","preview":{"title":"/slow","icon":"` + srv.URL + `/favicon.ico"}}`
	if e.Name != "preview" || string(data) != want {
		t.Errorf("event %s %s, want preview %s", e.Name, data, want)
	}
	if items := list(); items[0].Preview == nil || items[0].Preview.Title != "/slow" {
		t.Errorf("stored preview = %+v", items[0].Preview)
	}

	add("/empty")
	svc.wg.Wait()
	expectNoEvent()
	list()
	svc.wg.Wait()
	if n := h.count("/empty"); n != 1 {
		t.Errorf("/empty fetched %d times, want once: nothing found is a result", n)
	}

	add("/broken")
	svc.wg.Wait()
	list()
	clock = clock.Add(retryAfter - time.Second)
	list()
	svc.wg.Wait()
	if n := h.count("/broken"); n != 1 {
		t.Errorf("/broken fetched %d times within %v, want once", n, retryAfter)
	}
	clock = clock.Add(time.Second)
	list()
	svc.wg.Wait()
	if n := h.count("/broken"); n != 2 {
		t.Errorf("/broken fetched %d times after %v, want a retry", n, retryAfter)
	}
	expectNoEvent()

	add("/hang")
	for h.count("/hang") == 0 {
		time.Sleep(time.Millisecond)
	}
	closed := make(chan struct{})
	go func() {
		svc.Close()
		close(closed)
	}()
	select {
	case <-closed:
	case <-time.After(2 * time.Second):
		t.Fatal("Close did not cancel the fetch in flight")
	}
	add("/after-close")
	svc.wg.Wait()
	if n := h.count("/after-close"); n != 0 {
		t.Errorf("fetched after Close")
	}
	for _, it := range list() {
		if *it.Link == srv.URL+"/hang" && it.Preview != nil {
			t.Errorf("cancelled fetch stored %+v", it.Preview)
		}
	}
}
