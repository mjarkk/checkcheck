import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'api/api_client.dart';
import 'home_widget.dart';
import 'screens/checklist_screen.dart';
import 'screens/setup_screen.dart';
import 'settings.dart';
import 'state/checklist_cache.dart';
import 'state/checklist_model.dart';
import 'theme.dart';

void main() {
  LicenseRegistry.addLicense(() async* {
    final license = await rootBundle.loadString('assets/fonts/OFL.txt');
    yield LicenseEntryWithLineBreaks(['Roboto Flex'], license);
  });
  runApp(
    CheckcheckApp(
      store: DeviceSettingsStore(),
      cache: DeviceChecklistCache(),
      httpClient: http.Client(),
    ),
  );
}

class CheckcheckApp extends StatefulWidget {
  const CheckcheckApp({
    super.key,
    required this.store,
    required this.cache,
    required this.httpClient,
    this.connectWebSocket,
  });

  final SettingsStore store;
  final ChecklistCache cache;
  final http.Client httpClient;

  /// Null opens real sockets.
  final WebSocketConnect? connectWebSocket;

  @override
  State<CheckcheckApp> createState() => _CheckcheckAppState();
}

class _CheckcheckAppState extends State<CheckcheckApp> {
  final _navigatorKey = GlobalKey<NavigatorState>();
  final _messengerKey = GlobalKey<ScaffoldMessengerState>();
  bool _loading = true;
  String? _lastUrl;
  ChecklistModel? _model;
  HomeWidgetReloader? _widgetReloader;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _widgetReloader?.dispose();
    _model?.dispose();
    super.dispose();
  }

  void _attachWidgetReloader(ChecklistModel? model) {
    _widgetReloader?.dispose();
    _widgetReloader = model == null ? null : HomeWidgetReloader(model);
  }

  Future<void> _load() async {
    ({String? url, String? token}) stored = (url: null, token: null);
    try {
      stored = await widget.store.load();
    } on Exception {
      // An unreadable store is treated as not configured: setup overwrites it.
    }
    ChecklistModel? model;
    if (stored case (url: final url?, token: final token?)) {
      model = await _openModel(ServerSettings(url: url, token: token));
    }
    if (!mounted) {
      model?.dispose();
      return;
    }
    setState(() {
      _loading = false;
      _lastUrl = stored.url;
      _model = model;
    });
    _attachWidgetReloader(model);
  }

  Future<ChecklistModel> _openModel(ServerSettings settings) =>
      ChecklistModel.open(
        api: ApiClient(
          baseUrl: settings.url,
          token: settings.token,
          httpClient: widget.httpClient,
          connectWebSocket: widget.connectWebSocket,
        ),
        cache: widget.cache,
        onUnauthorized: () =>
            _signOut(message: 'Token rejected — please sign in again'),
      );

  Future<void> _onConnected(ServerSettings settings) async {
    final model = await _openModel(settings);
    if (!mounted) {
      model.dispose();
      return;
    }
    setState(() {
      _lastUrl = settings.url;
      _model = model;
    });
    _attachWidgetReloader(model);
  }

  /// [forgetChecklist] deletes the offline copy; otherwise it is kept, with
  /// unsent changes, for when the same server is connected again.
  Future<void> _signOut({String? message, bool forgetChecklist = false}) async {
    final model = _model;
    if (model == null) return;
    _navigatorKey.currentState?.popUntil((route) => route.isFirst);
    setState(() => _model = null);
    _attachWidgetReloader(null);
    // Disposed after the frame that unmounts the screens listening to it, and
    // before the clear, so no save can land after it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      model.dispose();
      if (forgetChecklist) widget.cache.clear().ignore();
    });
    if (message != null) {
      _messengerKey.currentState?.showSnackBar(
        SnackBar(content: Text(message)),
      );
    }
    await widget.store.clearToken();
  }

  @override
  Widget build(BuildContext context) {
    final model = _model;
    return MaterialApp(
      title: 'CheckCheck',
      debugShowCheckedModeBanner: false,
      navigatorKey: _navigatorKey,
      scaffoldMessengerKey: _messengerKey,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: ThemeMode.system,
      home: _loading
          ? const Scaffold(
              body: Center(child: CircularProgressIndicator.adaptive()),
            )
          : model == null
          ? SetupScreen(
              store: widget.store,
              httpClient: widget.httpClient,
              initialUrl: _lastUrl,
              onConnected: _onConnected,
            )
          : ChecklistScreen(
              key: ObjectKey(model),
              model: model,
              onDisconnect: () => _signOut(forgetChecklist: true),
            ),
    );
  }
}
