import 'package:checkcheck/connect.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fakes.dart';

void main() {
  group('parseConnectUri', () {
    test('reads server and token', () {
      expect(
        parseConnectUri(
          'checkcheck://connect?server=https%3A%2F%2Fcheck.example.com&token=3f9c',
        ),
        (server: 'https://check.example.com', token: '3f9c'),
      );
    });

    test('accepts surrounding whitespace, parameter order and a trailing /', () {
      expect(
        parseConnectUri(
          ' checkcheck://connect/?token=abc&server=http%3A%2F%2Flocalhost%3A8081\n',
        ),
        (server: 'http://localhost:8081', token: 'abc'),
      );
    });

    test('percent-decodes, keeping a bare + literal', () {
      expect(
        parseConnectUri(
          'checkcheck://connect?server=https%3A%2F%2Fexample.com%2Fcheck%20list'
          '&token=a%2Bb%26c%3Dd+e%25',
        ),
        (server: 'https://example.com/check list', token: 'a+b&c=d+e%'),
      );
    });

    test('is null when server or token is missing or blank', () {
      for (final input in [
        'checkcheck://connect?server=https%3A%2F%2Fx.example',
        'checkcheck://connect?token=abc',
        'checkcheck://connect?server=&token=abc',
        'checkcheck://connect?server=https%3A%2F%2Fx.example&token=%20',
        'checkcheck://connect',
      ]) {
        expect(parseConnectUri(input), isNull, reason: input);
      }
    });

    test('is null for other schemes, hosts and paths', () {
      for (final input in [
        'https://connect?server=https%3A%2F%2Fx.example&token=abc',
        'otherapp://connect?server=https%3A%2F%2Fx.example&token=abc',
        'checkcheck://login?server=https%3A%2F%2Fx.example&token=abc',
        'checkcheck://connect/extra?server=https%3A%2F%2Fx.example&token=abc',
        'https://check.example.com',
        '',
      ]) {
        expect(parseConnectUri(input), isNull, reason: input);
      }
    });

    test('is null for malformed percent-encoding', () {
      expect(
        parseConnectUri('checkcheck://connect?server=x&token=%E0%A4'),
        isNull,
      );
    });
  });

  group('buildConnectUri', () {
    test('percent-encodes both values like the webapp', () {
      expect(
        buildConnectUri(server: 'https://check.example.com', token: '3f9c'),
        'checkcheck://connect?server=https%3A%2F%2Fcheck.example.com'
        '&token=3f9c',
      );
    });

    test('round-trips through parseConnectUri', () {
      const server = 'http://192.168.1.20:8181/check list';
      const token = 'a+b&c=d e%/?';
      expect(parseConnectUri(buildConnectUri(server: server, token: token)), (
        server: server,
        token: token,
      ));
    });
  });

  group('verifyServer', () {
    test('normalises the URL and returns the settings', () async {
      final server = FakeServer(token: 'dev');

      final settings = await verifyServer(
        rawUrl: ' localhost:8081/ ',
        rawToken: ' dev ',
        httpClient: server.client,
      );

      expect(settings.url, 'https://localhost:8081');
      expect(settings.token, 'dev');
      expect(server.requests.map((r) => r.url.path), [
        '/api/health',
        '/api/categories',
      ]);
    });

    Future<String?> failure(
      http.Client client, {
      String url = 'http://localhost:8081',
      String token = 'dev',
    }) async {
      try {
        await verifyServer(rawUrl: url, rawToken: token, httpClient: client);
        return null;
      } on ConnectException catch (error) {
        return error.message;
      }
    }

    test('reports each failure in plain words', () async {
      expect(
        await failure(MockClient((_) => throw http.ClientException('refused'))),
        "Can't reach the server",
      );
      expect(
        await failure(MockClient((_) async => http.Response('<html>', 200))),
        "That doesn't look like a checkcheck server",
      );
      expect(
        await failure(FakeServer(token: 'dev').client, token: 'wrong'),
        'Token rejected',
      );
      expect(
        await failure(FakeServer().client, token: '  '),
        'Enter the token',
      );
      expect(
        await failure(FakeServer().client, url: 'ftp://x.example'),
        'Enter a URL starting with http:// or https://',
      );
    });
  });
}
