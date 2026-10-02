import 'package:checkcheck/settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('normalizeServerUrl', () {
    test('trims and drops trailing slashes', () {
      expect(
        normalizeServerUrl('  https://check.example.com///  '),
        'https://check.example.com',
      );
    });

    test('assumes https:// when no scheme was typed', () {
      expect(
        normalizeServerUrl('check.example.com'),
        'https://check.example.com',
      );
      expect(normalizeServerUrl('localhost:8080/'), 'https://localhost:8080');
    });

    test('keeps http://, ports and path prefixes', () {
      expect(
        normalizeServerUrl('http://localhost:8080'),
        'http://localhost:8080',
      );
      expect(
        normalizeServerUrl('https://example.com/checkcheck/'),
        'https://example.com/checkcheck',
      );
    });

    test('lowercases the scheme and host', () {
      expect(
        normalizeServerUrl('HTTPS://Check.Example.com'),
        'https://check.example.com',
      );
    });

    test('rejects empty input, other schemes and missing hosts', () {
      for (final input in [
        '',
        '   ',
        'ftp://example.com',
        'https://',
        'http:///x',
      ]) {
        expect(
          () => normalizeServerUrl(input),
          throwsFormatException,
          reason: input,
        );
      }
    });
  });
}
