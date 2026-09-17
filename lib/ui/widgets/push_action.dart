import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/push_sender.dart';
import 'state_views.dart';

/// The Send-to-phones action for one announcement row.
///
/// Writing and sending are deliberately two steps. An announcement is a normal
/// row that the app's Circulars screen shows on its own; the push is an extra
/// that goes out when this is pressed. That way a typo is a quick edit rather
/// than a second notification to every student on the platform.
///
/// Pressing it checks who the row would reach before asking, because a push
/// cannot be recalled once FCM accepts it, and the audience comes from three
/// columns that are easy to get wrong.
class PushSendButton extends StatefulWidget {
  const PushSendButton({
    super.key,
    required this.row,
    this.onSent,
    this.beforeSend,
    this.enabled = true,
  });

  /// The announcement, as read from `notifications`.
  final Map<String, dynamic> row;

  /// Called after a send was attempted — success or failure — so the caller can
  /// re-read the row and show what was recorded on it.
  final Future<void> Function()? onSent;

  /// Runs before anything is checked; false abandons the send. The editor uses it
  /// to insist on a save first, because the function reads the row out of the
  /// database and never sees the form.
  final Future<bool> Function()? beforeSend;

  /// Greyed rather than hidden while the screen is busy with something else, so
  /// the row of actions does not shuffle.
  final bool enabled;

  @override
  State<PushSendButton> createState() => _PushSendButtonState();
}

class _PushSendButtonState extends State<PushSendButton> {
  bool _busy = false;

  String get _id => widget.row['id']?.toString() ?? '';

  bool get _sent {
    final at = widget.row['push_sent_at']?.toString().trim() ?? '';
    return at.isNotEmpty;
  }

  Future<void> _run() async {
    final before = widget.beforeSend;
    if (before != null && !await before()) return;
    if (!mounted) return;

    if (_id.isEmpty) {
      showToast(context, 'Save the announcement first', isError: true);
      return;
    }

    final sender = context.read<PushSender>();

    setState(() => _busy = true);
    final PushPreview preview;
    try {
      preview = await sender.preview(_id);
    } on PushException catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      showToast(context, 'Could not check: ${error.message}', isError: true);
      return;
    }
    if (!mounted) return;
    setState(() => _busy = false);

    if (!preview.secretConfigured) {
      await _showNotSetUp();
      return;
    }
    if (!await _confirm(preview) || !mounted) return;

    setState(() => _busy = true);
    try {
      await sender.send(_id);
      if (!mounted) return;
      setState(() => _busy = false);
      showToast(context, 'Sent to ${describePushAudience(widget.row)}.');
    } on PushException catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      await _showFailure(error);
    }
    // Either way the row may have changed: a failed send is recorded on it too,
    // in `push_error`, which is the only trace of what went wrong.
    await widget.onSent?.call();
  }

  /// A dry run that reports no secret is a setup problem, not a typo — and the
  /// fix is three clicks away in a console nobody remembers the path to.
  Future<void> _showNotSetUp() {
    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sending is not set up yet'),
        content: const Text(
          'Supabase has no FCM_SERVICE_ACCOUNT secret, so the push would fail. '
          'Add it under Edge Functions → Secrets, using the JSON from Firebase '
          'Console → Project settings → Service accounts → Generate new private '
          'key.\n\nThe announcement itself is already live in the app.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<bool> _confirm(PushPreview preview) async {
    final theme = Theme.of(context);
    final title = widget.row['title']?.toString().trim() ?? '';
    final answer = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Send to phones?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '“${title.isEmpty ? 'This announcement' : title}” goes to '
              '${describePushAudience(widget.row)} straight away, and cannot be '
              'undone.',
            ),
            if (preview.alreadySent) ...[
              const SizedBox(height: 14),
              Text(
                'This was already sent once. Sending again notifies everyone a '
                'second time.',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.error),
              ),
            ],
            const SizedBox(height: 14),
            // The topic is shown because it is where a mistyped branch becomes
            // visible: a branch string that does not match `profiles` builds a
            // topic no device is subscribed to, and the send then succeeds
            // while reaching nobody.
            Text(
              'Topic ${preview.topic}'
              '${preview.olderSpellings == 0 ? '' : ' + ${preview.olderSpellings} older spelling'
                  '${preview.olderSpellings == 1 ? '' : 's'}'}',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Icons.send_outlined, size: 17),
            label: const Text('Send now'),
          ),
        ],
      ),
    );
    return answer ?? false;
  }

  /// A dialog rather than a toast: the function's message is the whole point and
  /// is often a full instruction.
  Future<void> _showFailure(PushException error) {
    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Not sent'),
        content: Text(error.message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Push turned off on the row means the announcement is meant to sit in the
    // app quietly, so there is nothing to offer.
    if (widget.row['push_enabled'] == false) return const SizedBox.shrink();

    final theme = Theme.of(context);
    if (_busy) {
      return const Padding(
        padding: EdgeInsets.all(14),
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2.2),
        ),
      );
    }

    return IconButton(
      tooltip: _sent ? 'Sent already — send again' : 'Send to phones',
      icon: Icon(
        _sent ? Icons.mark_email_read_outlined : Icons.send_outlined,
        size: 19,
        color: _sent ? theme.disabledColor : theme.colorScheme.primary,
      ),
      onPressed: widget.enabled ? _run : null,
    );
  }
}
