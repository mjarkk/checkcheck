package store

import "testing"

func TestFindLink(t *testing.T) {
	for _, tc := range []struct{ title, want string }{
		{"Milk", ""},
		{"Read https://example.com/post", "https://example.com/post"},
		{"(see https://en.wikipedia.org/wiki/Go_(game)).", "https://en.wikipedia.org/wiki/Go_(game)"},
		{"https://example.com/a.", "https://example.com/a"},
		{`"https://example.com/?q=1&r=2!"`, "https://example.com/?q=1&r=2"},
		{"really? https://example.com/x?!.,;:'", "https://example.com/x"},
		{"[docs](https://example.com/x)", "https://example.com/x"},
		{"{https://example.com/}", "https://example.com/"},
		{"[https://example.com/a[1]]", "https://example.com/a[1]"},
		{"https://example.com/))).", "https://example.com/"},
		{"https://example.com/f(x)", "https://example.com/f(x)"},
		{"https://example.com/(", "https://example.com/("},
		{"HTTPS://Example.com/Path", "HTTPS://Example.com/Path"},
		{"see hTtP://example.org", "hTtP://example.org"},
		{"first http://a.example then https://b.example", "http://a.example"},
		{"first https://b.example then http://a.example", "https://b.example"},
		{"tab\thttps://example.com/x\tafter", "https://example.com/x"},
		{"line\nhttps://example.com/x\nafter", "https://example.com/x"},
		{"url:https://example.com", "https://example.com"},
		{"café https://example.com/ü", "https://example.com/ü"},
		{"https://user:pw@example.com:8443/p#frag", "https://user:pw@example.com:8443/p#frag"},
		{"ftp://example.com", ""},
		{"example.com", ""},
		{"https://", ""},
		{"https://.", ""},
		{"https:///path", ""},
		{"http://:80/x", ""},
		{"http://[::1", ""},
		{"http://example.com:port", ""},
		{"http://%zz.example", ""},
		{"https:// then https://example.com", ""},
	} {
		if got := findLink(tc.title); got != tc.want {
			t.Errorf("findLink(%q) = %q, want %q", tc.title, got, tc.want)
		}
	}
}
