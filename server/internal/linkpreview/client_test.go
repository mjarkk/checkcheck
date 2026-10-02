package linkpreview

import (
	"context"
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"testing"
)

func TestIsPublic(t *testing.T) {
	for _, tc := range []struct {
		ip   string
		want bool
	}{
		{"8.8.8.8", true},
		{"140.82.121.4", true},
		{"2606:4700:4700::1111", true},
		{"64:ff9b::808:808", true},
		{"127.0.0.1", false},
		{"127.1.2.3", false},
		{"10.1.2.3", false},
		{"172.16.0.1", false},
		{"192.168.1.1", false},
		{"169.254.169.254", false},
		{"0.0.0.0", false},
		{"0.1.2.3", false},
		{"100.64.0.1", false},
		{"192.0.2.1", false},
		{"198.18.0.1", false},
		{"224.0.0.1", false},
		{"240.0.0.1", false},
		{"255.255.255.255", false},
		{"::", false},
		{"::1", false},
		{"::127.0.0.1", false},
		{"::ffff:127.0.0.1", false},
		{"::ffff:10.0.0.1", false},
		{"64:ff9b::7f00:1", false},
		{"64:ff9b::a9fe:a9fe", false},
		{"fe80::1", false},
		{"fc00::1", false},
		{"fd12:3456::1", false},
		{"fec0::1", false},
		{"ff02::1", false},
		{"2001:db8::1", false},
		{"2001::1", false},
		{"2002:7f00:1::1", false},
	} {
		if got := isPublic(netip.MustParseAddr(tc.ip)); got != tc.want {
			t.Errorf("isPublic(%s) = %v, want %v", tc.ip, got, tc.want)
		}
	}
}

func TestClientRefusesLoopback(t *testing.T) {
	hit := false
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hit = true
		w.Header().Set("Content-Type", "text/html")
		w.Write([]byte(`<title>secret</title>`))
	}))
	defer srv.Close()
	_, port, _ := net.SplitHostPort(srv.Listener.Addr().String())
	for _, u := range []string{srv.URL, "http://localhost:" + port} {
		_, err := Fetch(context.Background(), NewClient(), u)
		if !errors.Is(err, errNotPublic) {
			t.Errorf("%s: err = %v, want %v", u, err, errNotPublic)
		}
	}
	if hit {
		t.Error("server was reached")
	}
}
