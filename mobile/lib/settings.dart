import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ServerSettings {
  const ServerSettings({required this.url, required this.token});

  final String url;
  final String token;
}

abstract interface class SettingsStore {
  Future<({String? url, String? token})> load();

  Future<void> save(ServerSettings settings);

  /// Keeps the URL so the setup screen can prefill it.
  Future<void> clearToken();
}

class DeviceSettingsStore implements SettingsStore {
  static const _urlKey = 'server_url';
  static const _tokenKey = 'server_token';

  final _prefs = SharedPreferencesAsync();
  final _secure = const FlutterSecureStorage();

  @override
  Future<({String? url, String? token})> load() async => (
    url: await _prefs.getString(_urlKey),
    token: await _secure.read(key: _tokenKey),
  );

  @override
  Future<void> save(ServerSettings settings) async {
    await _secure.write(key: _tokenKey, value: settings.token);
    await _prefs.setString(_urlKey, settings.url);
  }

  @override
  Future<void> clearToken() => _secure.delete(key: _tokenKey);
}

/// Trims, assumes https:// when no scheme was typed, and drops trailing
/// slashes. Throws a [FormatException] with a user-facing message when the
/// result isn't an http(s) URL with a host.
String normalizeServerUrl(String input) {
  var url = input.trim();
  if (url.isEmpty) throw const FormatException('Enter the server URL');
  if (!url.contains('://')) url = 'https://$url';
  while (url.endsWith('/')) {
    url = url.substring(0, url.length - 1);
  }
  final uri = Uri.tryParse(url);
  if (uri == null ||
      !(uri.isScheme('http') || uri.isScheme('https')) ||
      uri.host.isEmpty) {
    throw const FormatException(
      'Enter a URL starting with http:// or https://',
    );
  }
  return uri.toString();
}
