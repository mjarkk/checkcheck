import 'dart:async';

import 'package:flutter/material.dart';

import '../api/api_client.dart';
import 'motion.dart';

String describeError(Object error) => switch (error) {
  ConflictException() => 'A category with that name already exists',
  ApiException(:final message) => message,
  _ => 'Something went wrong',
};

/// Does nothing for [UnauthorizedException]: the app root signs out and
/// shows its own message.
void showError(BuildContext context, Object error) {
  if (error is UnauthorizedException || !context.mounted) return;
  showMessage(context, describeError(error));
}

/// How long an error notice stays: the web app's NOTICE_MS.
const noticeDuration = Duration(seconds: 6);

void showMessage(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message), duration: noticeDuration));
}

/// An error shown inside a dialog, where a SnackBar would be hidden behind
/// it, for [noticeDuration] or until dismissed.
mixin InlineNotice<T extends StatefulWidget> on State<T> {
  String? notice;
  Timer? _noticeTimer;

  void showNotice(String message) {
    _noticeTimer?.cancel();
    _noticeTimer = Timer(noticeDuration, dismissNotice);
    setState(() => notice = message);
  }

  void dismissNotice() {
    _noticeTimer?.cancel();
    setState(() => notice = null);
  }

  @override
  void dispose() {
    _noticeTimer?.cancel();
    super.dispose();
  }
}

/// Opens [builder]'s dialog inside the safe area, with the web app's rise-in.
Future<T?> showAppDialog<T>(BuildContext context, WidgetBuilder builder) =>
    showGeneralDialog<T>(
      context: context,
      barrierDismissible: true,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: Colors.black.withValues(alpha: 0.4),
      transitionDuration: fastSpatial.duration,
      pageBuilder: (context, _, _) => SafeArea(child: builder(context)),
      transitionBuilder: (context, animation, _, child) {
        final rise = CurvedAnimation(
          parent: animation,
          curve: fastSpatial,
          reverseCurve: Curves.easeIn,
        );
        return FadeTransition(
          opacity: CurvedAnimation(parent: animation, curve: effects),
          child: AnimatedBuilder(
            animation: rise,
            builder: (context, child) => Transform.translate(
              offset: Offset(0, 24 * (1 - rise.value)),
              child: Transform.scale(
                scale: 0.94 + 0.06 * rise.value,
                child: child,
              ),
            ),
            child: child,
          ),
        );
      },
    );

/// Resolves to true only when the user picked [confirmLabel].
Future<bool> confirm(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
}) async {
  final confirmed = await showAppDialog<bool>(context, (context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: theme.dialogTheme.titleTextStyle),
              const SizedBox(height: 16),
              Text(message, style: theme.dialogTheme.contentTextStyle),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                spacing: 8,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    style: FilledButton.styleFrom(
                      backgroundColor: colors.error,
                      foregroundColor: colors.onError,
                    ),
                    child: Text(confirmLabel),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  });
  return confirmed ?? false;
}
