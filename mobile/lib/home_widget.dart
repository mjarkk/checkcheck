import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// The iOS home-screen widget; does nothing on other platforms. Never
/// throws: when the widget can't get the connection, it asks to open the app.
abstract final class HomeWidget {
  static const _channel = MethodChannel('checkcheck/widget');

  /// Gives the widget its own copy of the connection, and reloads it.
  static Future<void> setConnection({
    required String server,
    required String token,
  }) => _invoke('setConnection', {'server': server, 'token': token});

  static Future<void> clearConnection() => _invoke('clearConnection');

  static Future<void> reload() => _invoke('reload');

  static Future<void> _invoke(String method, [Object? arguments]) async {
    if (defaultTargetPlatform != TargetPlatform.iOS) return;
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } on MissingPluginException {
      // Tests.
    } on PlatformException {
      // A failed keychain write: the widget keeps its old copy, if any.
    }
  }
}

/// Reloads the widget a second after [model] last notified, which its sync
/// loop does when it has sent the queued changes or loaded the list. A
/// pending reload happens at once when the app goes to the background.
class HomeWidgetReloader {
  HomeWidgetReloader(this.model) {
    model.addListener(_schedule);
    _lifecycle = AppLifecycleListener(onHide: _flush, onPause: _flush);
  }

  static const _delay = Duration(seconds: 1);

  final Listenable model;
  late final AppLifecycleListener _lifecycle;
  Timer? _pending;

  void _schedule() {
    _pending?.cancel();
    _pending = Timer(_delay, _reload);
  }

  void _flush() {
    if (_pending?.isActive ?? false) _reload();
  }

  void _reload() {
    _pending?.cancel();
    _pending = null;
    HomeWidget.reload().ignore();
  }

  void dispose() {
    model.removeListener(_schedule);
    _lifecycle.dispose();
    _pending?.cancel();
  }
}
