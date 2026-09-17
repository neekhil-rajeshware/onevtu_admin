import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/admin_repository.dart';
import '../../data/push_sender.dart';
import '../../data/store_notifier.dart';
import '../../schema/table_spec.dart';
import 'state_views.dart';

/// The three values `store.status` may hold. The CHECK constraint in
/// `docs/sql/020_store_listing_approval.sql` rejects anything else, so these are
/// spellings and not preferences.
abstract final class ListingStatus {
  static const String pending = 'pending';
  static const String approved = 'approved';
  static const String rejected = 'rejected';
}

/// Approve / Not approved for one Store listing.
///
/// A student's listing is created `pending` and nobody but its seller can see it
/// until this says otherwise — that is the whole point of the queue, so the two
/// buttons sit on the row rather than inside the editor only.
///
/// The review columns are read-only in the form on purpose: `status` is what the
/// public read policy tests, and the trigger stamps `reviewed_at` / `reviewed_by`
/// off a change to it. Writing them here keeps one path to all four, so a stamp
/// can never disagree with the status beside it.
class ModerationAction extends StatefulWidget {
  const ModerationAction({
    super.key,
    required this.spec,
    required this.row,
    this.onReviewed,
    this.enabled = true,
  });

  /// The table being moderated — `store`, and the source of its primary key.
  final TableSpec spec;

  /// The listing, as read from the table.
  final Map<String, dynamic> row;

  /// Called after a decision was written, so the caller can re-read the row or
  /// the list. A row that leaves the queue should stop being shown as waiting.
  final Future<void> Function()? onReviewed;

  /// Greyed rather than hidden while the screen is busy saving, so the row of
  /// actions does not shuffle.
  final bool enabled;

  @override
  State<ModerationAction> createState() => _ModerationActionState();
}

class _ModerationActionState extends State<ModerationAction> {
  bool _busy = false;

  Object? get _id => widget.row[widget.spec.primaryKey];

  String get _status =>
      widget.row['status']?.toString().trim() ?? ListingStatus.pending;

  /// Enough of the listing to see a mis-tap before it publishes.
  String get _summary {
    final title = widget.row['title']?.toString().trim() ?? '';
    final price = widget.row['price']?.toString().trim() ?? '';
    final seller = widget.row['seller_name']?.toString().trim() ?? '';
    final aside = [
      if (price.isNotEmpty) '₹$price',
      if (seller.isNotEmpty) 'from $seller',
    ].join(' ');
    return '“${title.isEmpty ? 'This listing' : title}”'
        '${aside.isEmpty ? '' : ' · $aside'}';
  }

  Future<void> _approve() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Put this on the Store?'),
        content: Text(
          '$_summary becomes visible to every student straight away. You can '
          'take it down again afterwards.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Icons.check, size: 17),
            label: const Text('Approve'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    // The note was the reason for a refusal that no longer stands; leaving it on
    // the row would be a rejection message attached to a live listing.
    await _write(
      {'status': ListingStatus.approved, 'review_note': null},
      'Approved — it is on the Store now.',
    );
  }

  Future<void> _reject() async {
    final note = await showDialog<String>(
      context: context,
      builder: (context) => _RejectDialog(summary: _summary, live: _isApproved),
    );
    if (note == null) return;

    await _write(
      {
        'status': ListingStatus.rejected,
        'review_note': note.isEmpty ? null : note,
      },
      note.isEmpty
          ? 'Turned down.'
          : 'Turned down — the seller sees your reason.',
    );
  }

  Future<void> _write(Map<String, dynamic> values, String done) async {
    final id = _id;
    if (id == null) return;

    setState(() => _busy = true);
    final repository = context.read<AdminRepository>();
    // Read before the first await, alongside the repository: after one, `context`
    // may belong to a widget that no longer exists.
    final notifier = context.read<StoreNotifier>();
    try {
      await repository.update(widget.spec, id, values);
      // Deliberately before the `mounted` check. The decision is in the database
      // by now, and the seller should hear it even if this row scrolled away or
      // the screen closed while the write was in flight.
      final pushFailure = await _notifySeller(notifier, id);
      if (!mounted) return;
      setState(() => _busy = false);
      showToast(
        context,
        pushFailure == null
            ? done
            : '$done But the seller was not notified — $pushFailure',
        // Flagged, because "decided but nobody told them" is the one outcome
        // here that leaves something for a person to do.
        isError: pushFailure != null,
      );
    } on AdminWriteException catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      await _showFailure(error);
      return; // nothing changed, so there is nothing to re-read
    } catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      showToast(context, 'Could not save: $error', isError: true);
      return;
    }
    await widget.onReviewed?.call();
  }

  /// Pushes the verdict to the seller. Returns null when they were told, and the
  /// reason when they were not.
  ///
  /// Never throws, which is the point of it being separate: the listing has
  /// already changed by the time this runs, so a notification that did not go out
  /// must not fall into [_write]'s catch and be reported as a failed decision.
  Future<String?> _notifySeller(StoreNotifier notifier, Object id) async {
    try {
      await notifier.notifySeller(id.toString());
      return null;
    } on PushException catch (error) {
      return error.message;
    } catch (error) {
      return error.toString();
    }
  }

  /// A dialog rather than a toast: a refused write here almost always means the
  /// sign-in has no second factor behind it, and that hint is an instruction.
  Future<void> _showFailure(AdminWriteException error) {
    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('The database refused this'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(error.message),
            if (error.hint != null) ...[
              const SizedBox(height: 14),
              Text(error.hint!, style: Theme.of(context).textTheme.bodySmall),
            ],
          ],
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

  bool get _isApproved => _status == ListingStatus.approved;
  bool get _isRejected => _status == ListingStatus.rejected;

  @override
  Widget build(BuildContext context) {
    // An unsaved row has nothing to review yet.
    if (_id == null) return const SizedBox.shrink();

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

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Already live: the only decision left is taking it down.
        if (!_isApproved)
          IconButton(
            tooltip: _isRejected ? 'Approve after all' : 'Approve',
            visualDensity: VisualDensity.compact,
            icon: Icon(
              Icons.check_circle_outline,
              size: 20,
              color: theme.colorScheme.primary,
            ),
            onPressed: widget.enabled ? _approve : null,
          ),
        // Already turned down: offering it again would only re-ask for the note.
        if (!_isRejected)
          IconButton(
            tooltip: _isApproved ? 'Take it down' : 'Not approved',
            visualDensity: VisualDensity.compact,
            icon: Icon(
              Icons.block_outlined,
              size: 20,
              color: theme.colorScheme.error,
            ),
            onPressed: widget.enabled ? _reject : null,
          ),
      ],
    );
  }
}

/// Asks for the reason a listing is turned down.
///
/// The reason is not paperwork: the seller reads it verbatim in My Listings, so
/// it is written to them rather than about them. The presets exist because typing
/// the same sentence on a phone forty times is how notes stop being written.
class _RejectDialog extends StatefulWidget {
  const _RejectDialog({required this.summary, required this.live});

  final String summary;

  /// True when the listing is already on the Store, so this takes it down.
  final bool live;

  @override
  State<_RejectDialog> createState() => _RejectDialogState();
}

class _RejectDialogState extends State<_RejectDialog> {
  /// Short label → what the seller actually reads.
  static const Map<String, String> _presets = {
    'Not a study item': 'The Store is for study things — books, notes, lab kits, '
        'drawing boards and instruments.',
    'Photo needed': 'Add a clear photo of the item you are selling.',
    'Price looks wrong': 'The price does not look right for this item. Check it '
        'and list it again.',
    'Contact in the text': 'Please leave phone numbers and links out of the '
        'description — buyers get your contact from the app itself.',
    'Duplicate': 'You have already listed this item.',
    'Not a real listing': 'This does not look like a real item for sale.',
  };

  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(widget.live ? 'Take this down?' : 'Not approved?'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.live
                  ? '${widget.summary} comes off the Store. The seller sees your '
                      'reason in My Listings.'
                  : '${widget.summary} stays off the Store. The seller sees your '
                      'reason in My Listings.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final preset in _presets.entries)
                  ActionChip(
                    label: Text(preset.key),
                    onPressed: () =>
                        setState(() => _controller.text = preset.value),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _controller,
              minLines: 2,
              maxLines: 4,
              // Matches the store_review_note_length constraint, so a long note
              // is stopped here rather than by the database.
              maxLength: 500,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Reason (optional)',
                hintText: 'What the seller should fix.',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: theme.colorScheme.error,
            foregroundColor: theme.colorScheme.onError,
          ),
          onPressed: () => Navigator.pop(context, _controller.text.trim()),
          icon: const Icon(Icons.block_outlined, size: 17),
          label: Text(widget.live ? 'Take down' : 'Turn down'),
        ),
      ],
    );
  }
}
