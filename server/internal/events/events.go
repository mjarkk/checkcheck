package events

import "sync"

type Event struct {
	Name string
	Data any
}

const bufferSize = 16

type Hub struct {
	mu     sync.Mutex
	subs   map[chan Event]bool
	closed bool
}

func NewHub() *Hub {
	return &Hub{subs: map[chan Event]bool{}}
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
	return ch, func() { h.drop(ch) }
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
	h.closed = true
	for ch := range h.subs {
		delete(h.subs, ch)
		close(ch)
	}
}

func (h *Hub) drop(ch chan Event) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.subs[ch] {
		delete(h.subs, ch)
		close(ch)
	}
}
