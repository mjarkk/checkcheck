import 'package:checkcheck/connect.dart';
import 'package:checkcheck/screens/connect_phone_dialog.dart';
import 'package:checkcheck/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late List<String> copied;

  setUp(() {
    copied = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
          }
          return null;
        });
  });

  Future<void> open(WidgetTester tester, {required String server}) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () =>
                showConnectPhoneDialog(context, server: server, token: 'tok'),
            child: const Text('Open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  Future<void> tapVisible(WidgetTester tester, String text) async {
    await tester.ensureVisible(find.text(text));
    await tester.pumpAndSettle();
    await tester.tap(find.text(text));
    await tester.pumpAndSettle();
  }

  Finder qrCode() => find.bySemanticsLabel(
    "QR code with this server's address and your access token",
  );

  testWidgets('shows the code and copies its link', (tester) async {
    await open(tester, server: 'https://check.example.com');

    expect(qrCode(), findsOneWidget);
    expect(
      find.text('An address the other phone can reach, without /api.'),
      findsOneWidget,
    );

    await tapVisible(tester, 'Copy link');

    expect(copied, [
      buildConnectUri(server: 'https://check.example.com', token: 'tok'),
    ]);
    expect(find.text('Copied'), findsOneWidget);
  });

  testWidgets('warns that other phones cannot reach localhost', (tester) async {
    await open(tester, server: 'http://localhost:8181');

    expect(
      find.text(
        "Other phones can't reach localhost. Use the server's network address.",
      ),
      findsOneWidget,
    );
    expect(qrCode(), findsOneWidget);
  });

  testWidgets('an edited server goes into the link without trailing slashes', (
    tester,
  ) async {
    await open(tester, server: 'http://localhost:8181');

    await tester.enterText(find.byType(TextField), 'http://192.168.1.20:8181/');
    await tester.pumpAndSettle();
    await tapVisible(tester, 'Copy link');

    expect(copied, [
      buildConnectUri(server: 'http://192.168.1.20:8181', token: 'tok'),
    ]);
  });

  testWidgets('an invalid server shows no code and no copy button', (
    tester,
  ) async {
    await open(tester, server: 'https://check.example.com');

    await tester.enterText(find.byType(TextField), 'check.example.com');
    await tester.pumpAndSettle();

    expect(qrCode(), findsNothing);
    expect(find.text('No code until the server URL is valid.'), findsOneWidget);
    expect(
      find.text('Enter a full URL, such as https://check.example.com.'),
      findsOneWidget,
    );
    expect(find.text('Copy link'), findsNothing);
  });

  testWidgets('Done closes the dialog', (tester) async {
    await open(tester, server: 'https://check.example.com');

    await tapVisible(tester, 'Done');

    expect(find.text('Connect phone'), findsNothing);
  });
}
