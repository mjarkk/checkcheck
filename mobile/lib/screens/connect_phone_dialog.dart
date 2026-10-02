import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr/qr.dart';

import '../connect.dart';
import 'feedback.dart';
import 'motion.dart';

Future<void> showConnectPhoneDialog(
  BuildContext context, {
  required String server,
  required String token,
}) => showAppDialog<void>(
  context,
  (_) => _ConnectPhoneDialog(server: server, token: token),
);

enum _CopyState { idle, copied, failed }

class _ConnectPhoneDialog extends StatefulWidget {
  const _ConnectPhoneDialog({required this.server, required this.token});

  final String server;
  final String token;

  @override
  State<_ConnectPhoneDialog> createState() => _ConnectPhoneDialogState();
}

class _ConnectPhoneDialogState extends State<_ConnectPhoneDialog> {
  late final _server = TextEditingController(text: widget.server);
  var _copy = _CopyState.idle;

  @override
  void dispose() {
    _server.dispose();
    super.dispose();
  }

  Future<void> _copyLink(String link) async {
    try {
      await Clipboard.setData(ClipboardData(text: link));
      if (mounted) setState(() => _copy = _CopyState.copied);
    } on PlatformException {
      if (mounted) setState(() => _copy = _CopyState.failed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final server = _server.text.trim().replaceFirst(RegExp(r'/+$'), '');
    final url = _parseHttpUrl(server);
    final link = buildConnectUri(server: server, token: widget.token);

    return Dialog(
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                // The web's .dialog-head reaches 8px up and right into the
                // dialog's 24px padding.
                padding: const EdgeInsets.fromLTRB(24, 16, 16, 0),
                child: Row(
                  spacing: 8,
                  children: [
                    Expanded(
                      child: Text(
                        'Connect phone',
                        style: theme.dialogTheme.titleTextStyle,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Scan this code with the checkcheck app on another '
                      'phone.',
                      style: theme.dialogTheme.contentTextStyle,
                    ),
                    const SizedBox(height: 20),
                    TextField(
                      controller: _server,
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      enableSuggestions: false,
                      textInputAction: TextInputAction.done,
                      onChanged: (_) => setState(() => _copy = _CopyState.idle),
                      decoration: InputDecoration(
                        labelText: 'Server URL',
                        helperText: url == null ? null : _hint(url),
                        helperMaxLines: 2,
                        errorText: url == null
                            ? 'Enter a full URL, such as '
                                  'https://check.example.com.'
                            : null,
                        errorMaxLines: 2,
                      ),
                    ),
                    const SizedBox(height: 20),
                    AspectRatio(
                      aspectRatio: 1,
                      // Fixed roles keep the code dark-on-light in both
                      // themes: phone scanners struggle with inverted codes.
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: colors.primaryFixed,
                          borderRadius: BorderRadius.circular(28),
                        ),
                        child: url == null
                            ? Padding(
                                padding: const EdgeInsets.all(24),
                                child: Center(
                                  child: Text(
                                    'No code until the server URL is valid.',
                                    textAlign: TextAlign.center,
                                    style: theme.textTheme.bodyLarge?.copyWith(
                                      color: colors.onPrimaryFixedVariant,
                                    ),
                                  ),
                                ),
                              )
                            : RiseIn(child: _QrCode(link)),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: colors.tertiaryContainer,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        spacing: 10,
                        children: [
                          Icon(
                            Icons.key,
                            size: 20,
                            color: colors.onTertiaryContainer,
                          ),
                          Expanded(
                            child: Text(
                              'This code contains your access token. Only '
                              'show it to devices you trust.',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: colors.onTertiaryContainer,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      spacing: 8,
                      children: [
                        if (url != null)
                          TextButton.icon(
                            onPressed: () => _copyLink(link),
                            icon: const Icon(Icons.content_copy, size: 18),
                            label: Text(switch (_copy) {
                              _CopyState.idle => 'Copy link',
                              _CopyState.copied => 'Copied',
                              _CopyState.failed => "Couldn't copy",
                            }),
                          ),
                        FilledButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Done'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Uri? _parseHttpUrl(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null || uri.host.isEmpty) return null;
  return uri.isScheme('http') || uri.isScheme('https') ? uri : null;
}

String _hint(Uri url) {
  final host = url.host;
  final loopback =
      host == 'localhost' ||
      host.endsWith('.localhost') ||
      host.startsWith('127.') ||
      host == '::1';
  return loopback
      ? "Other phones can't reach localhost. Use the server's network address."
      : 'An address the other phone can reach, without /api.';
}

class _QrCode extends StatelessWidget {
  const _QrCode(this.data);

  final String data;

  @override
  Widget build(BuildContext context) => Semantics(
    image: true,
    label: "QR code with this server's address and your access token",
    child: CustomPaint(
      painter: _QrPainter(
        data,
        Theme.of(context).colorScheme.onPrimaryFixedVariant,
      ),
    ),
  );
}

class _QrPainter extends CustomPainter {
  _QrPainter(this.data, this.color);

  final String data;
  final Color color;

  static const _quietZone = 3;
  static const _cornerRadius = 0.35;

  late final _image = QrImage(
    QrCode(
      payload: QrPayload.fromString(data),
      errorCorrectLevel: QrErrorCorrectLevel.medium,
    ),
  );
  late final _path = _modulePath(_image);

  // Clockwise from the top right, with the edge directions arriving at and
  // leaving each corner on a clockwise trace.
  static const _corners = [
    (dx: 1, dy: -1, into: Offset(1, 0), out: Offset(0, 1)),
    (dx: 1, dy: 1, into: Offset(0, 1), out: Offset(-1, 0)),
    (dx: -1, dy: 1, into: Offset(-1, 0), out: Offset(0, -1)),
    (dx: -1, dy: -1, into: Offset(0, -1), out: Offset(1, 0)),
  ];

  // In module units. Every subpath winds clockwise, so overlaps and shared
  // edges union without seams under the nonzero fill rule.
  static Path _modulePath(QrImage image) {
    final n = image.moduleCount;
    bool dark(int x, int y) =>
        x >= 0 && y >= 0 && x < n && y < n && image.isDark(y, x);
    Offset corner(int x, int y, int dx, int dy) =>
        Offset(x + 0.5 + dx / 2, y + 0.5 + dy / 2);
    const r = _cornerRadius;
    const radius = Radius.circular(r);
    final path = Path();
    for (var y = 0; y < n; y++) {
      var x = 0;
      while (x < n) {
        if (!dark(x, y)) {
          for (final c in _corners) {
            if (!dark(x + c.dx, y) || !dark(x, y + c.dy)) continue;
            final p = corner(x, y, c.dx, c.dy);
            final from = p + c.out * r;
            final to = p - c.into * r;
            path
              ..moveTo(p.dx, p.dy)
              ..lineTo(from.dx, from.dy)
              ..arcToPoint(to, radius: radius, clockwise: false)
              ..close();
          }
          x++;
          continue;
        }
        var end = x + 1;
        while (dark(end, y)) {
          end++;
        }
        path.moveTo((x + end) / 2, y.toDouble());
        for (final c in _corners) {
          final cell = c.dx > 0 ? end - 1 : x;
          final p = corner(cell, y, c.dx, c.dy);
          final rounded =
              !dark(cell + c.dx, y) &&
              !dark(cell, y + c.dy) &&
              !dark(cell + c.dx, y + c.dy);
          if (!rounded) {
            path.lineTo(p.dx, p.dy);
            continue;
          }
          final from = p - c.into * r;
          final to = p + c.out * r;
          path
            ..lineTo(from.dx, from.dy)
            ..arcToPoint(to, radius: radius);
        }
        path.close();
        x = end;
      }
    }
    return path;
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas
      ..scale(size.width / (_image.moduleCount + 2 * _quietZone))
      ..translate(_quietZone.toDouble(), _quietZone.toDouble())
      ..drawPath(_path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_QrPainter old) => old.data != data || old.color != color;
}
