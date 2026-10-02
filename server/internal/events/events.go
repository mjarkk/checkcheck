package events

import (
	"context"
	"sync"

	"checkcheck/internal/store"
)

// Event is a message for the event sockets, which get it as this JSON.
type Event struct {
	Type    string         `json:"type"`
	Client  string         `json:"client,omitempty"`
	Link    string         `json:"link,omitempty"`
	Preview *store.Preview `json:"preview,omitempty"`
}

const bufferSize = 16

type Hub struct {
	mu     sync.Mutex
	subs   map[chan Event]bool
	open   int // subscriptions whose func hasn't been called yet
	closed bool
	idle   chan struct{}
}

func NewHub() *Hub {
	return &Hub{subs: map[chan Event]bool{}, idle: make(chan struct{})}
}

// Subscribe returns a channel of the events published from now on and a func
// that ends the subscription. The channel is closed when the subscription
// ends, when the subscriber falls behind and when the hub closes.
func (h *Hub) Subscribe() (<-chan Event, func()) {
	h.mu.Lock()
	defer h.mu.Unlock()
	ch := make(chan Event, bufferSize)
	if h.closed {
		close(ch)
		return ch, func() {}
	}
	h.subs[ch] = true
	h.open++
	var once sync.Once
	return ch, func() { once.Do(func() { h.end(ch) }) }
}

// Publish never blocks: a subscriber whose buffer is full is dropped instead.
func (h *Hub) Publish(e Event) {
	h.mu.Lock()
	defer h.mu.Unlock()
	for ch := range h.subs {
		select {
		case ch <- e:
		default:
			delete(h.subs, ch)
			close(ch)
		}
	}
}

func (h *Hub) Close() {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.closed {
		return
	}
	h.closed = true
	for ch := range h.subs {
		delete(h.subs, ch)
		close(ch)
	}
	h.checkIdle()
}

// Closed tells a subscriber whose channel closed whether the hub closed it
// or it fell behind.
func (h *Hub) Closed() bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.closed
}

// Wait returns once the hub is closed and every subscription has been ended
// by its func, or when ctx is done.
func (h *Hub) Wait(ctx context.Context) {
	select {
	case <-h.idle:
	case <-ctx.Done():
	}
}

func (h *Hub) end(ch chan Event) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.subs[ch] {
		delete(h.subs, ch)
		close(ch)
	}
	h.open--
	h.checkIdle()
}

func (h *Hub) checkIdle() {
	if h.closed && h.open == 0 {
		close(h.idle)
	}
}
