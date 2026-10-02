import 'package:checkcheck/home_widget.dart';
import 'package:checkcheck/settings.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

const _channel = MethodChannel('checkcheck/widget');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<MethodCall> calls;

  /// Answers every call on the widget channel; [failWith] makes them fail.
  void mockChannel({PlatformException? failWith}) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          calls.add(call);
          if (failWith != null) throw failWith;
          return null;
        });
  }

  setUp(() {
    calls = [];
    mockChannel();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  group('DeviceSettingsStore', () {
    void stored({String? url, String? token}) {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.withData({'server_url': ?url});
      FlutterSecureStorage.setMockInitialValues({'server_token': ?token});
    }

    setUp(() {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      stored();
    });

    tearDown(() => debugDefaultTargetPlatformOverride = null);

    test('save gives the widget a copy of the connection', () async {
      final store = DeviceSettingsStore();
      await store.save(
        const ServerSettings(url: 'https://check.example.com', token: 't1'),
      );
      expect(calls, [
        isMethodCall(
          'setConnection',
          arguments: {'server': 'https://check.example.com', 'token': 't1'},
        ),
      ]);
    });

    test('load copies a stored connection', () async {
      stored(url: 'http://10.0.0.2:8080', token: 't2');
      final settings = await DeviceSettingsStore().load();
      expect(settings, (url: 'http://10.0.0.2:8080', token: 't2'));
      expect(calls, [
        isMethodCall(
          'setConnection',
          arguments: {'server': 'http://10.0.0.2:8080', 'token': 't2'},
        ),
      ]);
    });

    test('load copies nothing without a token', () async {
      stored(url: 'https://check.example.com');
      await DeviceSettingsStore().load();
      stored(token: 't3');
      await DeviceSettingsStore().load();
      expect(calls, isEmpty);
    });

    test('clearToken deletes the copy', () async {
      stored(url: 'https://check.example.com', token: 't4');
      final store = DeviceSettingsStore();
      await store.clearToken();
      expect(calls, [isMethodCall('clearConnection', arguments: null)]);
      expect(await store.load(), (
        url: 'https://check.example.com',
        token: null,
      ));
    });

    test('a failed copy still signs in', () async {
      mockChannel(failWith: PlatformException(code: 'keychain'));
      final store = DeviceSettingsStore();
      await store.save(
        const ServerSettings(url: 'https://check.example.com', token: 't5'),
      );
      expect(calls, hasLength(1));
      expect(await store.load(), (
        url: 'https://check.example.com',
        token: 't5',
      ));
    });

    test('a missing bridge is ignored', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, null);
      final store = DeviceSettingsStore();
      await store.save(
        const ServerSettings(url: 'https://check.example.com', token: 't6'),
      );
      await store.clearToken();
      expect(await store.load(), (
        url: 'https://check.example.com',
        token: null,
      ));
    });

    test('does nothing off iOS', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final store = DeviceSettingsStore();
      await store.save(
        const ServerSettings(url: 'https://check.example.com', token: 't7'),
      );
      await store.load();
      await store.clearToken();
      expect(calls, isEmpty);
    });
  });

  group('HomeWidgetReloader', () {
    final ios = TargetPlatformVariant.only(TargetPlatform.iOS);

    testWidgets('reloads a second after the last change', (tester) async {
      final model = ChangeNotifier();
      final reloader = HomeWidgetReloader(model);
      addTearDown(reloader.dispose);

      model.notifyListeners();
      await tester.pump(const Duration(milliseconds: 600));
      model.notifyListeners();
      await tester.pump(const Duration(milliseconds: 900));
      expect(calls, isEmpty);
      await tester.pump(const Duration(milliseconds: 100));
      expect(calls, [isMethodCall('reload', arguments: null)]);
      await tester.pump(const Duration(seconds: 5));
      expect(calls, hasLength(1));
    }, variant: ios);

    testWidgets('reloads at once when the app is hidden', (tester) async {
      final model = ChangeNotifier();
      final reloader = HomeWidgetReloader(model);
      addTearDown(reloader.dispose);
      final binding = tester.binding;

      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await tester.pump();
      expect(calls, isEmpty, reason: 'nothing to reload');
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

      model.notifyListeners();
      await tester.pump(const Duration(milliseconds: 200));
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(calls, [isMethodCall('reload', arguments: null)]);
      await tester.pump(const Duration(seconds: 2));
      expect(calls, hasLength(1));

      binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    }, variant: ios);

    testWidgets('stops when disposed', (tester) async {
      final model = ChangeNotifier();
      final reloader = HomeWidgetReloader(model);

      model.notifyListeners();
      reloader.dispose();
      model.notifyListeners();
      await tester.pump(const Duration(seconds: 2));
      expect(calls, isEmpty);
    }, variant: ios);
  });
}
