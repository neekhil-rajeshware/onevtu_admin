import 'package:flutter/material.dart';

/// Centred spinner with a caption, for a screen that has nothing to show yet.
class BusyView extends StatelessWidget {
  const BusyView({super.key, this.label});

  final String? label;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 26,
            height: 26,
            child: CircularProgressIndicator(strokeWidth: 2.4),
          ),
          if (label != null) ...[
            const SizedBox(height: 14),
            Text(label!, style: Theme.of(context).textTheme.bodySmall),
          ],
        ],
      ),
    );
  }
}

/// What went wrong, plus the one thing the person can do about it.
class ErrorView extends StatelessWidget {
  const ErrorView({super.key, required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 34, color: theme.colorScheme.error),
            const SizedBox(height: 14),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 20),
              OutlinedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Try again'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Nothing here yet — with the action that would change that.
class EmptyView extends StatelessWidget {
  const EmptyView({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: Colors.white.withValues(alpha: 0.24)),
            const SizedBox(height: 16),
            Text(title, style: theme.textTheme.titleMedium),
            if (subtitle != null) ...[
              const SizedBox(height: 8),
              Text(
                subtitle!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
            ],
            if (action != null) ...[const SizedBox(height: 20), action!],
          ],
        ),
      ),
    );
  }
}

/// A single place for "saved" / "went wrong" feedback, so the wording and the
/// colour are the same everywhere.
void showToast(BuildContext context, String message, {bool isError = false}) {
  if (!context.mounted) return;
  final scheme = Theme.of(context).colorScheme;
  ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? scheme.errorContainer : null,
        duration: Duration(seconds: isError ? 6 : 3),
      ),
    );
}

/// Confirms something that cannot be undone. Returns true when confirmed.
Future<bool> confirmDestructive(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Delete',
}) async {
  final answer = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
          onPressed: () => Navigator.pop(context, true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return answer ?? false;
}

/// A blocking spinner whose caption can change while it runs — for work that
/// takes long enough that "which of the 40 files is it on" is the question.
///
/// Always [ProgressBarrier.dismiss] it, on the failure path too, or the screen
/// stays behind a dialog that cannot be tapped away.
ProgressBarrier showProgressBarrier(BuildContext context, String label) {
  final caption = ValueNotifier<String>(label);
  final navigator = Navigator.of(context, rootNavigator: true);

  showDialog<void>(
    context: context,
    barrierDismissible: false,
    useRootNavigator: true,
    builder: (context) => PopScope(
      // Backing out of a half-finished bucket operation is worse than waiting.
      canPop: false,
      child: AlertDialog(
        content: Row(
          children: [
            const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2.4),
            ),
            const SizedBox(width: 18),
            Expanded(
              child: ValueListenableBuilder<String>(
                valueListenable: caption,
                builder: (_, text, _) => Text(text),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  return ProgressBarrier._(caption, navigator);
}

/// The handle on a [showProgressBarrier] dialog.
class ProgressBarrier {
  ProgressBarrier._(this._caption, this._navigator);

  final ValueNotifier<String> _caption;
  final NavigatorState _navigator;
  bool _dismissed = false;

  /// What the spinner says now. Ignored once dismissed, so a progress callback
  /// arriving late cannot throw.
  set label(String text) {
    if (!_dismissed) _caption.value = text;
  }

  void dismiss() {
    if (_dismissed) return;
    _dismissed = true;
    _navigator.pop();
    _caption.dispose();
  }
}
