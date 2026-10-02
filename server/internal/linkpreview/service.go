package linkpreview

import (
	"context"
	"log/slog"
	"net/http"
	"sync"
	"time"

	"checkcheck/internal/events"
	"checkcheck/internal/store"
)

const (
	maxParallel = 4
	retryAfter  = 10 * time.Minute
)

type Service struct {
	st     *store.Store
	hub    *events.Hub
	client *http.Client
	now    func() time.Time

	ctx    context.Context
	cancel context.CancelFunc
	wg     sync.WaitGroup
	slots  chan struct{}

	mu       sync.Mutex
	closed   bool
	inFlight map[string]bool
	retryAt  map[string]time.Time
}

func NewService(st *store.Store, hub *events.Hub, client *http.Client) *Service {
	ctx, cancel := context.WithCancel(context.Background())
	return &Service{
		st:       st,
		hub:      hub,
		client:   client,
		now:      time.Now,
		ctx:      ctx,
		cancel:   cancel,
		slots:    make(chan struct{}, maxParallel),
		inFlight: map[string]bool{},
		retryAt:  map[string]time.Time{},
	}
}

// Request starts fetching link unless that is already under way or failed
// less than retryAfter ago. It never blocks.
func (s *Service) Request(link string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed || s.inFlight[link] {
		return
	}
	if t, ok := s.retryAt[link]; ok {
		if s.now().Before(t) {
			return
		}
		delete(s.retryAt, link)
	}
	s.inFlight[link] = true
	s.wg.Add(1)
	go s.fetch(link)
}

func (s *Service) fetch(link string) {
	defer s.wg.Done()
	failed := false
	// Cleared only once the result is saved, since until then every list
	// requests the link again.
	defer func() {
		s.mu.Lock()
		defer s.mu.Unlock()
		delete(s.inFlight, link)
		if failed {
			s.retryAt[link] = s.now().Add(retryAfter)
		}
	}()

	select {
	case s.slots <- struct{}{}:
	case <-s.ctx.Done():
		return
	}
	p, err := Fetch(s.ctx, s.client, link)
	<-s.slots
	if err != nil {
		if s.ctx.Err() == nil {
			slog.Info("link preview fetch failed", "link", link, "err", err)
			failed = true
		}
		return
	}
	if err := s.st.SavePreview(s.ctx, link, p); err != nil {
		if s.ctx.Err() == nil {
			slog.Error("save link preview", "link", link, "err", err)
			failed = true
		}
		return
	}
	if p != (store.Preview{}) {
		s.hub.Publish(events.Event{Type: "preview", Link: link, Preview: &p})
	}
}

// Close stops all fetches and waits for them to end. Requests after Close are
// ignored.
func (s *Service) Close() {
	s.mu.Lock()
	s.closed = true
	s.mu.Unlock()
	s.cancel()
	s.wg.Wait()
}
