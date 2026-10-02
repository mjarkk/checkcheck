import 'package:http/http.dart' as http;

import 'api/api_client.dart';
import 'settings.dart';

typedef ConnectLink = ({String server, String token});

const connectLinkPrefix = 'checkcheck://connect';

/// The QR payload from /API.md for [server] (no trailing slash) and [token].
String buildConnectUri({required String server, required String token}) =>
    '$connectLinkPrefix?server=${Uri.encodeComponent(server)}'
    '&token=${Uri.encodeComponent(token)}';

/// Parses the QR payload from /API.md,
/// `checkcheck://connect?server=<pct-encoded>&token=<pct-encoded>`.
///
/// Null when [input] isn't such a URI, or its server or token is missing or
/// blank. The server is returned as-is; [verifyServer] normalises it.
ConnectLink? parseConnectUri(String input) {
  final uri = Uri.tryParse(input.trim());
  if (uri == null ||
      !uri.isScheme('checkcheck') ||
      uri.host != 'connect' ||
      (uri.path.isNotEmpty && uri.path != '/')) {
    return null;
  }
  // Not uri.queryParameters: that decodes '+' as a space, but the webapp
  // percent-encodes, so a bare '+' is a literal (CHECKCHECK_TOKEN can hold
  // one).
  final params = <String, String>{};
  for (final pair in uri.query.split('&')) {
    final separator = pair.indexOf('=');
    if (separator <= 0) continue;
    try {
      params.putIfAbsent(
        Uri.decodeComponent(pair.substring(0, separator)),
        () => Uri.decodeComponent(pair.substring(separator + 1)),
      );
    } on FormatException {
      return null;
    }
  }
  final server = params['server']?.trim() ?? '';
  final token = params['token']?.trim() ?? '';
  if (server.isEmpty || token.isEmpty) return null;
  return (server: server, token: token);
}

class ConnectException implements Exception {
  const ConnectException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Resolves to the settings to persist once [rawUrl] answers as a checkcheck
/// server and accepts [rawToken]. Throws a [ConnectException] with a
/// user-facing message otherwise.
Future<ServerSettings> verifyServer({
  required String rawUrl,
  required String rawToken,
  required http.Client httpClient,
}) async {
  final String url;
  try {
    url = normalizeServerUrl(rawUrl);
  } on FormatException catch (error) {
    throw ConnectException(error.message);
  }
  final token = rawToken.trim();
  if (token.isEmpty) throw const ConnectException('Enter the token');

  final api = ApiClient(baseUrl: url, token: token, httpClient: httpClient);
  try {
    if (!await api.checkHealth()) {
      throw const ConnectException(
        "That doesn't look like a checkcheck server",
      );
    }
    await api.listCategories();
  } on UnauthorizedException {
    throw const ConnectException('Token rejected');
  } on NetworkException {
    throw const ConnectException("Can't reach the server");
  } on ApiException catch (error) {
    throw ConnectException(error.message);
  }
  return ServerSettings(url: url, token: token);
}
