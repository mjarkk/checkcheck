package events

import "testing"

func TestHub(t *testing.T) {
	h := NewHub()
	fast, unsubscribeFast := h.Subscribe()
	slow, _ := h.Subscribe()
	gone, unsubscribe := h.Subscribe()
	unsubscribe()
	unsubscribe()
	if _, ok := <-gone; ok {
		t.Error("unsubscribed channel still open")
	}

	for i := range bufferSize {
		h.Publish(Event{Name: "n", Data: i})
		if e := <-fast; e.Data != i {
			t.Fatalf("fast got %+v, want %d", e, i)
		}
	}
	h.Publish(Event{Name: "n", Data: bufferSize})
	if e := <-fast; e.Data != bufferSize {
		t.Errorf("fast got %+v after the slow subscriber filled up", e)
	}
	for i := range bufferSize {
		if e, ok := <-slow; !ok || e.Data != i {
			t.Fatalf("slow got %+v, %v; want buffered event %d", e, ok, i)
		}
	}
	if e, ok := <-slow; ok {
		t.Errorf("slow got %+v, want its channel closed once it fell behind", e)
	}

	h.Close()
	if _, ok := <-fast; ok {
		t.Error("channel open after Close")
	}
	unsubscribeFast()
	h.Publish(Event{Name: "n"})
	late, _ := h.Subscribe()
	if _, ok := <-late; ok {
		t.Error("subscription after Close is open")
	}
}
