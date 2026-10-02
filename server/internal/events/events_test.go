package events

import (
	"context"
	"strconv"
	"testing"
	"time"
)

func numbered(i int) Event { return Event{Type: "changed", Client: strconv.Itoa(i)} }

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
		h.Publish(numbered(i))
		if e := <-fast; e != numbered(i) {
			t.Fatalf("fast got %+v, want %d", e, i)
		}
	}
	h.Publish(numbered(bufferSize))
	if e := <-fast; e != numbered(bufferSize) {
		t.Errorf("fast got %+v after the slow subscriber filled up", e)
	}
	for i := range bufferSize {
		if e, ok := <-slow; !ok || e != numbered(i) {
			t.Fatalf("slow got %+v, %v; want buffered event %d", e, ok, i)
		}
	}
	if e, ok := <-slow; ok {
		t.Errorf("slow got %+v, want its channel closed once it fell behind", e)
	}
	if h.Closed() {
		t.Error("Closed after dropping a subscriber, want only after Close")
	}

	h.Close()
	if !h.Closed() {
		t.Error("not Closed after Close")
	}
	if _, ok := <-fast; ok {
		t.Error("channel open after Close")
	}
	unsubscribeFast()
	h.Publish(numbered(0))
	late, _ := h.Subscribe()
	if _, ok := <-late; ok {
		t.Error("subscription after Close is open")
	}
}

func TestWait(t *testing.T) {
	h := NewHub()
	_, endFirst := h.Subscribe()
	endFirst()
	_, endDropped := h.Subscribe()
	for i := range bufferSize + 1 {
		h.Publish(numbered(i))
	}

	waited := make(chan struct{})
	go func() {
		h.Wait(context.Background())
		close(waited)
	}()
	expectWaiting := func(when string) {
		t.Helper()
		select {
		case <-waited:
			t.Fatalf("Wait returned %s", when)
		case <-time.After(20 * time.Millisecond):
		}
	}
	expectWaiting("before Close")
	h.Close()
	expectWaiting("while a dropped subscription's func had not run")
	endDropped()
	select {
	case <-waited:
	case <-time.After(2 * time.Second):
		t.Fatal("Wait did not return once the hub closed and every subscription ended")
	}

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	busy := NewHub()
	busy.Subscribe()
	busy.Wait(ctx)
}
