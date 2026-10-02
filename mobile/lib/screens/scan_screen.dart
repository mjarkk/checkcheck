import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../connect.dart';

/// Pops with the scanned [ConnectLink], or null when the user backs out or
/// the camera is unavailable.
class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  final _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
  );
  bool _done = false;
  bool _sawForeignCode = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final barcode in capture.barcodes) {
      final link = parseConnectUri(barcode.rawValue ?? '');
      if (link != null) {
        _done = true;
        Navigator.pop(context, link);
        return;
      }
    }
    if (!_sawForeignCode) setState(() => _sawForeignCode = true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan QR code')),
      body: MobileScanner(
        controller: _controller,
        onDetect: _onDetect,
        errorBuilder: (context, error) => _CameraUnavailable(error),
        overlayBuilder: (context, constraints) => _ScanOverlay(
          hint: _sawForeignCode
              ? "That isn't a CheckCheck code. Use the QR code from the "
                    'CheckCheck web app.'
              : 'Point the camera at the QR code in the CheckCheck web app.',
        ),
      ),
    );
  }
}

class _ScanOverlay extends StatelessWidget {
  const _ScanOverlay({required this.hint});

  final String hint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Stack(
      children: [
        Center(
          child: Container(
            width: 260,
            height: 260,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(32),
              border: Border.all(color: theme.colorScheme.primary, width: 4),
            ),
          ),
        ),
        Positioned(
          left: 24,
          right: 24,
          bottom: 48,
          child: SafeArea(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: theme.colorScheme.inverseSurface,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  hint,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: theme.colorScheme.onInverseSurface,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _CameraUnavailable extends StatelessWidget {
  const _CameraUnavailable(this.error);

  final MobileScannerException error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final message = switch (error.errorCode) {
      MobileScannerErrorCode.permissionDenied =>
        'CheckCheck has no access to the camera. Allow it in Settings, or '
            'enter the server URL and token by hand.',
      _ =>
        'No camera is available on this device. Enter the server URL and '
            'token by hand.',
    };
    return ColoredBox(
      color: theme.colorScheme.surface,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            spacing: 16,
            children: [
              Icon(
                Icons.no_photography_outlined,
                size: 56,
                color: theme.colorScheme.primary,
              ),
              Text(
                "Can't use the camera",
                style: theme.textTheme.titleLarge,
                textAlign: TextAlign.center,
              ),
              Text(
                message,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Enter manually'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
