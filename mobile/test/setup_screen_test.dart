import 'package:checkcheck/screens/setup_screen.dart';
import 'package:checkcheck/settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fakes.dart';

void main() {
  late FakeSettingsStore store;
  late List<ServerSettings> connected;

  Future<void> pumpSetup(
    WidgetTester tester,
    http.Client client, {
    String? initialUrl,
  }) async {
    store = FakeSettingsStore();
    connected = [];
    await tester.pumpWidget(
      MaterialApp(
        home: SetupScreen(
          store: store,
          httpClient: client,
          initialUrl: initialUrl,
          onConnected: connected.add,
        ),
      ),
    );
  }

  Finder field(String label) => find.widgetWithText(TextField, label);

  Future<void> connect(WidgetTester tester, String url, String token) async {
    await tester.enterText(field('Server URL'), url);
    await tester.enterText(field('Token'), token);
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();
  }

  testWidgets('saves and reports verified settings', (tester) async {
    await pumpSetup(tester, FakeServer(token: 'dev').client);

    await connect(tester, 'http://localhost:8081/', 'dev');

    expect(connected.single.url, 'http://localhost:8081');
    expect(connected.single.token, 'dev');
    expect(store.url, 'http://localhost:8081');
    expect(store.token, 'dev');
  });

  testWidgets('shows a disabled busy button while connecting', (tester) async {
    await pumpSetup(
      tester,
      MockClient((_) async {
        await Future<void>.delayed(const Duration(seconds: 1));
        throw http.ClientException('refused');
      }),
    );
    await tester.enterText(field('Server URL'), 'http://localhost:8081');
    await tester.enterText(field('Token'), 'dev');
    FilledButton button(String label) => tester.widget(
      find.ancestor(
        of: find.text(label),
        matching: find.bySubtype<FilledButton>(),
      ),
    );

    await tester.tap(find.text('Connect'));
    await tester.pump();
    expect(find.text('Connect'), findsNothing);
    expect(button('Connecting…').onPressed, isNull);
    expect(button('Scan QR code').onPressed, isNull);

    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.text('Connecting…'), findsNothing);
    expect(button('Connect').onPressed, isNotNull);
    expect(find.text("Can't reach the server"), findsOneWidget);
  });

  testWidgets('a rejected token is reported and nothing is saved', (
    tester,
  ) async {
    await pumpSetup(tester, FakeServer(token: 'dev').client);

    await connect(tester, 'http://localhost:8081', 'wrong');

    expect(find.text('Token rejected'), findsOneWidget);
    expect(connected, isEmpty);
    expect(store.token, isNull);
  });

  testWidgets('a non-CheckCheck server is reported', (tester) async {
    await pumpSetup(
      tester,
      MockClient((_) async => http.Response('<html></html>', 200)),
    );

    await connect(tester, 'example.com', 'dev');

    expect(
      find.text("That doesn't look like a CheckCheck server"),
      findsOneWidget,
    );
    expect(connected, isEmpty);
  });

  testWidgets('connecting with both fields empty does nothing', (tester) async {
    var requests = 0;
    await pumpSetup(
      tester,
      MockClient((_) async {
        requests++;
        return http.Response('', 200);
      }),
    );

    await connect(tester, '  ', '');

    expect(find.byType(SnackBar), findsNothing);
    expect(requests, 0);
    expect(connected, isEmpty);
  });

  testWidgets('pasting a connect link fills both fields', (tester) async {
    await pumpSetup(tester, FakeServer().client);

    await tester.enterText(
      field('Server URL'),
      'checkcheck://connect?server=http%3A%2F%2Flocalhost%3A8081&token=dev%2B1',
    );
    await tester.pump();

    expect(find.text('http://localhost:8081'), findsOneWidget);
    final token = tester.widget<TextField>(field('Token'));
    expect(token.controller!.text, 'dev+1');
  });

  testWidgets('an incomplete connect link is reported on connect', (
    tester,
  ) async {
    await pumpSetup(tester, FakeServer().client);

    await connect(tester, 'checkcheck://connect?token=dev', 'dev');

    expect(
      find.text('That connect link is missing the server or token'),
      findsOneWidget,
    );
    expect(connected, isEmpty);
  });

  testWidgets('prefills the last URL and toggles token visibility', (
    tester,
  ) async {
    await pumpSetup(
      tester,
      FakeServer().client,
      initialUrl: 'https://check.example.com',
    );

    expect(find.text('https://check.example.com'), findsOneWidget);
    bool obscured() => tester
        .widget<EditableText>(
          find.descendant(
            of: field('Token'),
            matching: find.byType(EditableText),
          ),
        )
        .obscureText;
    expect(obscured(), isTrue);

    await tester.tap(find.byTooltip('Show token'));
    await tester.pump();

    expect(obscured(), isFalse);
  });
}
