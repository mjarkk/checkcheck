package linkpreview

import (
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/netip"
	"syscall"
	"time"
)

const (
	timeout      = 10 * time.Second
	maxRedirects = 5
)

var errNotPublic = errors.New("not a public address")

// NewClient returns a client that only connects to public addresses. The
// check runs on the address actually dialed, so it also covers redirects and
// DNS answers that change between lookups.
func NewClient() *http.Client {
	return newClient(publicOnly)
}

func newClient(control func(network, address string, c syscall.RawConn) error) *http.Client {
	dialer := &net.Dialer{Timeout: timeout, Control: control}
	return &http.Client{
		// No Proxy: the guard would then check the proxy's address instead
		// of the target's.
		Transport: &http.Transport{
			DialContext:           dialer.DialContext,
			ForceAttemptHTTP2:     true,
			TLSHandshakeTimeout:   timeout,
			ResponseHeaderTimeout: timeout,
			MaxIdleConns:          8,
			IdleConnTimeout:       30 * time.Second,
		},
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			if len(via) > maxRedirects {
				return fmt.Errorf("more than %d redirects", maxRedirects)
			}
			if req.URL.Scheme != "http" && req.URL.Scheme != "https" {
				return fmt.Errorf("redirect to unsupported scheme %q", req.URL.Scheme)
			}
			return nil
		},
	}
}

func publicOnly(_, address string, _ syscall.RawConn) error {
	host, _, err := net.SplitHostPort(address)
	if err != nil {
		return err
	}
	ip, err := netip.ParseAddr(host)
	if err != nil {
		return err
	}
	if !isPublic(ip) {
		return fmt.Errorf("%s: %w", ip, errNotPublic)
	}
	return nil
}

var nat64 = netip.MustParsePrefix("64:ff9b::/96")

// Special-purpose ranges (RFC 6890 and successors) that netip's predicates
// don't already rule out.
var nonPublic = []netip.Prefix{
	netip.MustParsePrefix("0.0.0.0/8"),
	netip.MustParsePrefix("100.64.0.0/10"),
	netip.MustParsePrefix("192.0.0.0/24"),
	netip.MustParsePrefix("192.0.2.0/24"),
	netip.MustParsePrefix("198.18.0.0/15"),
	netip.MustParsePrefix("198.51.100.0/24"),
	netip.MustParsePrefix("203.0.113.0/24"),
	netip.MustParsePrefix("240.0.0.0/4"),
	netip.MustParsePrefix("::/96"),
	netip.MustParsePrefix("64:ff9b:1::/48"),
	netip.MustParsePrefix("100::/64"),
	netip.MustParsePrefix("2001::/23"),
	netip.MustParsePrefix("2001:db8::/32"),
	netip.MustParsePrefix("2002::/16"),
	netip.MustParsePrefix("fec0::/10"),
}

func isPublic(ip netip.Addr) bool {
	ip = ip.Unmap()
	// DNS64 gives IPv4-only hosts these addresses on IPv6-only networks, so
	// judge the IPv4 address they translate to.
	if nat64.Contains(ip) {
		b := ip.As16()
		ip = netip.AddrFrom4([4]byte(b[12:]))
	}
	if !ip.IsGlobalUnicast() || ip.IsPrivate() {
		return false
	}
	for _, p := range nonPublic {
		if p.Contains(ip) {
			return false
		}
	}
	return true
}
