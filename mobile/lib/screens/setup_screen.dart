import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../connect.dart';
import '../settings.dart';
import '../theme.dart';
import 'controls.dart';
import 'feedback.dart';
import 'motion.dart';
import 'scan_screen.dart';

class SetupScreen extends StatefulWidget {
  const SetupScreen({
    super.key,
    required this.store,
    required this.httpClient,
    required this.onConnected,
    this.initialUrl,
  });

  final SettingsStore store;
  final http.Client httpClient;

  /// Called after the settings were verified and saved.
  final ValueChanged<ServerSettings> onConnected;
  final String? initialUrl;

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  late final _url = TextEditingController(text: widget.initialUrl);
  final _token = TextEditingController();
  bool _obscureToken = true;
  bool _connecting = false;

  @override
  void dispose() {
    _url.dispose();
    _token.dispose();
    super.dispose();
  }

  void _fill(ConnectLink link) {
    _url.value = TextEditingValue(
      text: link.server,
      selection: TextSelection.collapsed(offset: link.server.length),
    );
    _token.text = link.token;
  }

  void _onUrlChanged(String text) {
    if (parseConnectUri(text) case final link?) _fill(link);
  }

  Future<void> _scan() async {
    final link = await Navigator.push<ConnectLink>(
      context,
      MaterialPageRoute(builder: (_) => const ScanScreen()),
    );
    if (link == null || !mounted) return;
    _fill(link);
    await _connect();
  }

  Future<void> _connect() async {
    if (_connecting) return;
    if (_url.text.trim().isEmpty && _token.text.trim().isEmpty) return;
    if (_url.text.trim().toLowerCase().startsWith(connectLinkPrefix)) {
      showMessage(context, 'That connect link is missing the server or token');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() => _connecting = true);
    try {
      final settings = await verifyServer(
        rawUrl: _url.text,
        rawToken: _token.text,
        httpClient: widget.httpClient,
      );
      await widget.store.save(settings);
      widget.onConnected(settings);
    } on ConnectException catch (error) {
      if (mounted) showMessage(context, error.message);
    } on Exception {
      if (mounted) showMessage(context, "Couldn't save the connection");
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final card = DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceContainer,
        borderRadius: BorderRadius.circular(28),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Align(
              alignment: AlignmentDirectional.centerStart,
              child: Logo(size: 48),
            ),
            const SizedBox(height: 12),
            Text('checkcheck', style: theme.textTheme.displaySmall),
            const SizedBox(height: 16),
            Text.rich(
              const TextSpan(
                children: [
                  TextSpan(text: 'Scan the QR code from '),
                  TextSpan(
                    text: 'Connect phone',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  TextSpan(
                    text: ' in the web app, or enter the server URL and token.',
                  ),
                ],
              ),
              style: theme.textTheme.bodyLarge?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _url,
              enabled: !_connecting,
              keyboardType: TextInputType.url,
              autocorrect: false,
              enableSuggestions: false,
              textInputAction: TextInputAction.next,
              onChanged: _onUrlChanged,
              decoration: const InputDecoration(
                labelText: 'Server URL',
                hintText: 'https://checkcheck.example.com',
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _token,
              enabled: !_connecting,
              obscureText: _obscureToken,
              autocorrect: false,
              enableSuggestions: false,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _connect(),
              decoration: InputDecoration(
                labelText: 'Token',
                suffixIcon: IconButton(
                  tooltip: _obscureToken ? 'Show token' : 'Hide token',
                  icon: Icon(
                    _obscureToken
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                  onPressed: () =>
                      setState(() => _obscureToken = !_obscureToken),
                ),
              ),
            ),
            const SizedBox(height: 24),
            FilledButton(
              style: largeButton,
              onPressed: _connecting ? null : _connect,
              child: Text(_connecting ? 'Connecting…' : 'Connect'),
            ),
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
              style: largeButton,
              onPressed: _connecting ? null : _scan,
              icon: const Icon(Icons.qr_code_scanner_rounded),
              label: const Text('Scan QR code'),
            ),
          ],
        ),
      ),
    );
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 416),
              child: RiseIn(child: card),
            ),
          ),
        ),
      ),
    );
  }
}
