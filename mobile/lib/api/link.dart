// Go's unicode.IsSpace, which the server splits on; Dart's \s differs at
// U+0085 and U+FEFF.
final _space = RegExp(
  '[\t\n\u000B\f\r \u0085\u00A0\u1680\u2000-\u200A\u2028\u2029\u202F\u205F\u3000]',
);
final _scheme = RegExp('https?://', caseSensitive: false);

const _sentencePunctuation = '.,;:!?\'"';
const _brackets = {')': '(', ']': '[', '}': '{'};

/// The link rule in /API.md's "Link previews", as the server applies it
/// (server/internal/store/link.go), so an edit shows its link before the
/// server answers. Null when [title] has none.
String? findLink(String title) {
  final start = title.indexOf(_scheme);
  if (start < 0) return null;
  var link = title.substring(start);
  final end = link.indexOf(_space);
  if (end >= 0) link = link.substring(0, end);
  while (link.isNotEmpty && _trimmable(link)) {
    link = link.substring(0, link.length - 1);
  }
  return _hasHost(link) ? link : null;
}

/// Whether [link]'s last character ends the sentence around the link rather
/// than the link itself.
bool _trimmable(String link) {
  final last = link[link.length - 1];
  if (_sentencePunctuation.contains(last)) return true;
  final opener = _brackets[last];
  if (opener == null) return false;
  return last.allMatches(link).length > opener.allMatches(link).length;
}

// The rest ports what Go's url.Parse (Go 1.27, strict colons) rejects in an
// http(s) URL, plus URL.Hostname() being empty: Dart's Uri.parse accepts
// more, such as bad percent-escapes.

bool _hasHost(String link) {
  final hash = link.indexOf('#');
  if (hash >= 0 && !_unescapes(link.substring(hash + 1))) return false;
  var rest = hash < 0 ? link : link.substring(0, hash);
  if (rest.codeUnits.any((c) => c < 0x20 || c == 0x7f)) return false;
  final query = rest.indexOf('?');
  if (query >= 0) rest = rest.substring(0, query);
  rest = rest.substring(rest.indexOf('//') + 2);
  final slash = rest.indexOf('/');
  if (slash >= 0 && !_unescapes(rest.substring(slash))) return false;
  final authority = slash < 0 ? rest : rest.substring(0, slash);

  final at = authority.lastIndexOf('@');
  if (at >= 0) {
    final userinfo = authority.substring(0, at);
    if (!_validUserinfo(userinfo) || !_unescapes(userinfo)) return false;
  }
  final host = authority.substring(at + 1);

  final open = host.lastIndexOf('[');
  if (open > 0) return false;
  if (open == 0) {
    final close = host.lastIndexOf(']');
    if (close < 0 || !_validOptionalPort(host.substring(close + 1))) {
      return false;
    }
    final address = host.substring(1, close);
    final zone = address.indexOf('%25');
    final ip = zone < 0 ? address : address.substring(0, zone);
    if (zone >= 0 &&
        (address.length == zone + 3 ||
            !_unescapes(address.substring(zone), _Part.zone))) {
      return false;
    }
    return _unescapes(ip, _Part.host) && _isIPv6(ip);
  }
  final colon = host.indexOf(':');
  if (colon >= 0 && !_validOptionalPort(host.substring(colon))) return false;
  return _unescapes(host, _Part.host) &&
      (colon < 0 ? host : host.substring(0, colon)).isNotEmpty;
}

enum _Part { other, host, zone }

/// Whether Go's unescape accepts [s] as (part of) [part].
bool _unescapes(String s, [_Part part = _Part.other]) {
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if (c != 0x25) {
      if (part != _Part.other && c < 0x80 && !_hostChar(c)) return false;
      continue;
    }
    if (i + 2 >= s.length) return false;
    final high = _hex(s.codeUnitAt(i + 1));
    final low = _hex(s.codeUnitAt(i + 2));
    if (high == null || low == null) return false;
    final percent = high == 2 && low == 5;
    // A host may escape only non-ASCII bytes; a zone only what a host may
    // hold unescaped, and spaces.
    if (part == _Part.host && high < 8 && !percent) return false;
    final byte = high << 4 | low;
    if (part == _Part.zone && !percent && byte != 0x20 && !_hostChar(byte)) {
      return false;
    }
    i += 2;
  }
  return true;
}

int? _hex(int c) => switch (c) {
  >= 0x30 && <= 0x39 => c - 0x30,
  >= 0x41 && <= 0x46 => c - 0x41 + 10,
  >= 0x61 && <= 0x66 => c - 0x61 + 10,
  _ => null,
};

bool _alphanumeric(int c) =>
    (c >= 0x30 && c <= 0x39) ||
    (c >= 0x41 && c <= 0x5a) ||
    (c >= 0x61 && c <= 0x7a);

bool _hostChar(int c) =>
    _alphanumeric(c) || '!\$&\'()*+,;=:[]<>"-_.~'.codeUnits.contains(c);

bool _validUserinfo(String s) => s.runes.every(
  (c) => _alphanumeric(c) || '-._:~!\$&\'()*+,;=%@'.codeUnits.contains(c),
);

bool _validOptionalPort(String port) =>
    port.isEmpty || RegExp(r'^:\d*$').hasMatch(port);

/// Go's netip.ParseAddr accepting [ip] as anything but plain IPv4.
bool _isIPv6(String ip) {
  if (!ip.contains(':')) return false;
  try {
    Uri.parseIPv6Address(ip);
    return true;
  } on FormatException {
    return false;
  }
}
