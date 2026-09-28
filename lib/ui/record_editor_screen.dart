import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/admin_repository.dart';
import '../data/lookup_cache.dart';
import '../r2/bucket_layout.dart';
import '../r2/r2_client.dart';
import '../r2/r2_credentials.dart';
import '../r2/upload_flow.dart';
import '../schema/catalog.dart';
import '../schema/field_spec.dart';
import '../schema/table_spec.dart';
import 'bucket_screen.dart';
import 'documents_screen.dart';
import 'gate_assets_screen.dart';
import 'widgets/field_editor.dart';
import 'widgets/moderation_action.dart';
import 'widgets/push_action.dart';
import 'widgets/state_views.dart';

/// Creates or edits one row of any table in the catalog.
///
/// There is exactly one of these screens for every table: the form is
/// built from [TableSpec.fields], so a new table becomes editable by adding it
/// to the catalog and nothing else.
class RecordEditorScreen extends StatefulWidget {
  const RecordEditorScreen({
    super.key,
    required this.spec,
    this.row,
    this.duplicate = false,
  });

  final TableSpec spec;

  /// Null to create; a row to edit.
  final Map<String, dynamic>? row;

  /// Prefill from [row] but insert a new record — the quick way to add the same
  /// subject under another branch.
  final bool duplicate;

  @override
  State<RecordEditorScreen> createState() => _RecordEditorScreenState();
}

class _RecordEditorScreenState extends State<RecordEditorScreen> {
  final _formKey = GlobalKey<FormState>();
  final Map<String, TextEditingController> _controllers = {};
  final Map<String, String> _initial = {};

  R2Client? _r2;
  String _r2Key = '';

  /// The row as last read from the database. Replaced whenever something writes
  /// to it behind the form's back: a push records its topic, its timestamp and any
  /// error, and a review writes the status plus who stamped it and when.
  Map<String, dynamic> _row = const {};

  bool _dirty = false;
  bool _saving = false;

  /// The name behind this row's subject code, once it has been looked up.
  ///
  /// Only ever set on a `py_qp` row, and only so the screen says which subject
  /// it is: that table has no name column, so its title would otherwise be a
  /// code above twenty fields of exam sessions.
  String _subjectName = '';

  bool get _isEditing => widget.row != null && !widget.duplicate;

  TableSpec get _spec => widget.spec;

  /// True for a `py_qp` row: one subject, one field per exam session, and not a
  /// single column in it that spells a subject name.
  bool get _isPapersRow => _spec.fields
      .any((field) => field.bucketFolder == BucketFolder.questionPaper);

  @override
  void initState() {
    super.initState();
    _row = widget.row ?? const {};
    for (final field in _spec.fields) {
      // A duplicate still prefills from the row it was copied off; only a
      // genuinely new row falls back to the column's default.
      final text = widget.row == null
          ? (field.defaultValue ?? '')
          : FieldCodec.decode(field, widget.row![field.column]);
      _initial[field.column] = text;
      _controllers[field.column] = TextEditingController(text: text);
    }
    if (_isPapersRow && widget.row != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadSubjectName());
    }
  }

  /// Reads the subject's name for [_title]. A failure is cosmetic — the title
  /// falls back to the codes it has — so nothing is reported.
  Future<void> _loadSubjectName() async {
    final subject = await context.read<AdminRepository>().subjectForCode(
          _subjectCode(),
        );
    if (!mounted || subject == null) return;
    setState(() => _subjectName = subject.name);
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    _r2?.dispose();
    super.dispose();
  }

  R2Client? _resolveR2() {
    final credentials = context.read<R2CredentialStore>().credentials;
    if (!credentials.isComplete) return null;
    final key = '${credentials.accountId}|${credentials.accessKeyId}|'
        '${credentials.secretAccessKey}|${credentials.bucket}';
    if (_r2 == null || _r2Key != key) {
      _r2?.dispose();
      _r2 = R2Client(credentials);
      _r2Key = key;
    }
    return _r2;
  }

  /// Only what actually changed is sent. Round-tripping every column would
  /// rewrite values the person never looked at — and would push a re-encoded
  /// timestamp back into a column that was already correct.
  Map<String, dynamic> _payload() {
    final values = <String, dynamic>{};
    for (final field in _spec.writableFields) {
      // A hand-keyed primary key is set at creation and never rewritten.
      if (_isEditing && field.column == _spec.primaryKey) continue;

      final text = _controllers[field.column]!.text;
      if (_isEditing && text == _initial[field.column]) continue;

      final encoded = FieldCodec.encode(field, text);
      if (!_isEditing && encoded == null) continue; // let defaults apply
      values[field.column] = encoded;
    }
    return values;
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) {
      showToast(context, 'Some fields need fixing', isError: true);
      return;
    }

    final payload = _payload();
    if (payload.isEmpty) {
      showToast(context, _isEditing ? 'Nothing changed' : 'Nothing to save');
      return;
    }

    setState(() => _saving = true);
    final repository = context.read<AdminRepository>();
    try {
      if (_isEditing) {
        await repository.update(
          _spec,
          widget.row![_spec.primaryKey] as Object,
          payload,
        );
      } else {
        await repository.insert(_spec, payload);
      }
      if (!mounted) return;
      // A new scheme or branch has to show up in the dropdowns that read it.
      context.read<LookupCache>().invalidate();
      showToast(context, _isEditing ? 'Saved' : 'Created');
      Navigator.pop(context, true);
    } on AdminWriteException catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      await _showWriteFailure(error);
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      showToast(context, 'Could not save: $error', isError: true);
    }
  }

  /// A refused write gets a dialog rather than a toast: the hint is the whole
  /// point, and it is too long to read before a snackbar disappears.
  Future<void> _showWriteFailure(AdminWriteException error) {
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
              Text(
                error.hint!,
                style: Theme.of(context).textTheme.bodySmall,
              ),
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

  Future<void> _delete() async {
    final label = _title();
    final confirmed = await confirmDestructive(
      context,
      title: 'Delete this row?',
      message: '$label is removed from ${_spec.table} immediately, and the app '
          'stops showing it. This cannot be undone.',
    );
    if (!confirmed || !mounted) return;

    setState(() => _saving = true);
    final repository = context.read<AdminRepository>();
    try {
      await repository.delete(_spec, widget.row![_spec.primaryKey] as Object);
      if (!mounted) return;
      showToast(context, 'Deleted');
      Navigator.pop(context, true);
    } on AdminWriteException catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      await _showWriteFailure(error);
    }
  }

  Future<bool> _confirmDiscard() async {
    if (!_dirty) return true;
    return confirmDestructive(
      context,
      title: 'Discard changes?',
      message: 'This row has edits that have not been saved.',
      confirmLabel: 'Discard',
    );
  }

  /// The push is built from the saved row, not from this form — the Edge Function
  /// re-reads the announcement out of the database. So an unsaved edit would send
  /// the old wording, which is worth refusing rather than explaining afterwards.
  Future<bool> _readyToSend() async {
    if (!_dirty) return true;
    showToast(
      context,
      'Save your changes first — the push is built from the saved row',
      isError: true,
    );
    return false;
  }

  /// Shows what a push or a review recorded: the topic it went to and any error,
  /// or the new status with its stamp.
  Future<void> _refreshRow() async {
    final repository = context.read<AdminRepository>();
    try {
      final fresh = await repository.fetchOne(
        _spec,
        widget.row![_spec.primaryKey] as Object,
      );
      if (fresh == null || !mounted) return;
      setState(() {
        _row = fresh;
        // Only the columns this form never edits are refreshed. Rewriting a field
        // someone is halfway through typing would throw their edit away.
        for (final field in _spec.fields.where((f) => f.readOnly)) {
          final text = FieldCodec.decode(field, fresh[field.column]);
          _initial[field.column] = text;
          _controllers[field.column]!.text = text;
        }
      });
    } on AdminWriteException {
      // Cosmetic. The write has already happened and its outcome is on the row
      // whether or not this screen manages to show it.
    }
  }

  /// The back gesture with unsaved edits: ask, then leave if they say so.
  Future<void> _leaveWithoutSaving() async {
    if (!await _confirmDiscard()) return;
    if (!mounted) return;
    Navigator.pop(context);
  }

  String _title() {
    if (widget.row == null) return 'New ${_spec.title.toLowerCase()}';
    final headline = [
      // The name goes first because the title is ellipsised: a code cut off the
      // end is still how the row is found in the list, half a subject name is
      // not.
      if (_subjectName.isNotEmpty) _subjectName,
      ..._spec.titleColumns
          .map((c) => widget.row![c]?.toString().trim() ?? '')
          .where((v) => v.isNotEmpty),
    ];
    if (headline.isEmpty) return '${widget.row![_spec.primaryKey]}';
    return headline.join(' · ');
  }

  /// Writes one link column on its own, without waiting for Save.
  ///
  /// Only for an upload that renamed the file: the object the row pointed at has
  /// been archived by then, so the row is already stale and closing the form
  /// without saving would leave the app — and every student in it — a dead link.
  /// Nothing else in the form is touched, so Save still has its usual work.
  Future<void> _persistLink(FieldSpec field, String url) async {
    if (!_isEditing) return; // nothing in the database points anywhere yet
    if (_initial[field.column] == url) return;

    final repository = context.read<AdminRepository>();
    try {
      await repository.update(
        _spec,
        widget.row![_spec.primaryKey] as Object,
        {field.column: FieldCodec.encode(field, url)},
      );
      if (!mounted) return;
      // The form has to agree with the database now, or Save would send the same
      // column again and the discard prompt would invent unsaved edits.
      _initial[field.column] = url;
      _row = {..._row, field.column: url};
      showToast(context, 'New link saved to ${field.label.toLowerCase()}');
    } on AdminWriteException catch (error) {
      if (!mounted) return;
      await _showWriteFailure(error);
    }
  }

  /// Where the bucket wants a file for this row, and what it should be called.
  ///
  /// Read from the form rather than from the saved row, so filing a syllabus under
  /// the semester you have just picked works before the first Save. Anything the
  /// layout cannot place comes back as nulls and the upload simply asks — see
  /// `bucket_layout.dart` on why a guessed folder is worse than a question.
  /// The subject a `py_qp` row is for: its semester-1 code, or semester 2 when
  /// that is the one filled in. Shown in the picker's title, so the person can
  /// see whose papers they are ticking.
  String _subjectCode() {
    final codes = _subjectCodes();
    return codes.isEmpty ? '' : codes.first;
  }

  /// Both codes the row names its subject by — the same subject under two
  /// semesters, and either may be the one filled in: 5 of the 55 `py_qp` rows
  /// carry only the semester-2 code, and the folder is named after whichever the
  /// person who made it happened to use.
  List<String> _subjectCodes() => [
        for (final column in const ['sem_1_sub_code', 'sem_2_sub_code'])
          if ((_controllers[column]?.text ?? '').trim().isNotEmpty)
            _controllers[column]!.text.trim(),
      ];

  Future<({String prefix, String? name, String subjectName})> _plannedDestination(
    FieldSpec field,
  ) async {
    if (field.bucketFolder == BucketFolder.flat) {
      return (prefix: field.uploadPrefix ?? '', name: null, subjectName: '');
    }

    final cache = context.read<LookupCache>();
    final repository = context.read<AdminRepository>();
    final row = {
      for (final entry in _controllers.entries) entry.key: entry.value.text.trim(),
    };

    Future<Map<String, String>> namesOf(Lookup lookup) async {
      try {
        final options = await cache.options(lookup);
        return {for (final option in options) option.value: option.label ?? ''};
      } on LookupException {
        return const {}; // unresolved beats wrong
      }
    }

    final names = BucketNames(
      schemes: await namesOf(schemeLookup),
      branches: await namesOf(branchLookup),
    );

    // A question paper is filed under `py_qp/<code> <subject name>/`, inside the
    // semester the subject is really taught in.
    //
    // Read off the subject, not off this row: a `py_qp` row carries its own
    // `scheme_code`, `semester` and `branch_code` and none of them is a
    // placement — every row in the table is a first-year subject under
    // `scheme-2025/1st_year/`, while those columns hold group numbers (a
    // `semester` of 1–8) and stray values. Taken at face value they sent the
    // picker to `AG_…/4th_sem/py_qp/…`, which does not exist, so it listed
    // nothing at all.
    var subjectName = '';
    if (field.bucketFolder == BucketFolder.questionPaper) {
      final subject = await repository.subjectForCode(_subjectCode());
      subjectName = subject?.name ?? '';
      if (subject != null) {
        // A subject with no scheme recorded leaves the row's value alone rather
        // than blanking a field the person can see is filled in.
        if (subject.scheme.isNotEmpty) row['scheme_code'] = subject.scheme;
        // Semester is overwritten even when the subject has none: no semester
        // means first year, whereas the row's own number is a group label.
        row['semester'] = subject.semester;
        if (subject.branch.isNotEmpty) row['branch'] = subject.branch;
      }
    }

    var prefix = bucketFolderFor(
          field.bucketFolder,
          row,
          names: names,
          subjectName: subjectName,
        ) ??
        '';

    // The subject's folder is then asked of the bucket rather than trusted, for
    // the same reason as above: most of `py_qp/` was named by hand and is not
    // `<code> <name>` shape. See `subjectFolderIn`.
    if (prefix.isNotEmpty && field.bucketFolder == BucketFolder.questionPaper) {
      final real = await _filedSubjectFolder(prefix, _subjectCodes());
      if (real != null) prefix = real;
    }

    return (
      prefix: prefix,
      name: bucketBaseNameFor(
        field.bucketFolder,
        row,
        column: field.column,
        subjectName: subjectName,
      ),
      // Handed back so the picker can say whose papers these are. The code alone
      // is what the *folder* is named after, not what the subject is called.
      subjectName: subjectName,
    );
  }

  /// The subject's folder as the bucket actually spells it, or null to keep
  /// [built] — which is right for a subject nothing has been filed under yet,
  /// and is what makes the folder on the first upload.
  ///
  /// [codes] are tried in turn against one listing: the row may name the subject
  /// by either of its two semester codes, and the folder by only one of them.
  ///
  /// Costs one listing per button press, and is deliberately not cached: the
  /// person may have just uploaded into it from the Bucket screen.
  Future<String?> _filedSubjectFolder(String built, List<String> codes) async {
    final client = _resolveR2();
    if (client == null || codes.isEmpty) return null;
    // `…/py_qp/<name>/` → `…/py_qp/`, so the folders come back as prefixes.
    final cut = built.lastIndexOf('/', built.length - 2);
    if (cut == -1) return null;
    try {
      final listing = await client.list(
        prefix: built.substring(0, cut + 1),
        maxKeys: 1000,
      );
      for (final code in codes) {
        final found = subjectFolderIn(listing.prefixes, code);
        if (found != null) return found;
      }
      return null;
    } catch (_) {
      // Not worth interrupting an upload over: an unreachable bucket means the
      // upload is about to fail loudly anyway, with a better message than this.
      return null;
    }
  }

  FileFieldActions _fileActions(bool configured) {
    return FileFieldActions(
      isConfigured: configured,
      onUpload: (field) async {
        final client = _resolveR2();
        if (client == null) return null;
        // What the column points at now, so the upload replaces that file —
        // archiving it — instead of dropping a second copy beside it.
        final before = _controllers[field.column]!.text.trim();
        final destination = await _plannedDestination(field);
        if (!mounted) return null;
        final result = await pickAndUploadToR2(
          context,
          client: client,
          prefix: destination.prefix,
          suggestedName: destination.name,
          currentUrl: before,
        );
        if (result == null) return null;
        if (before.isNotEmpty && before != result.url) {
          await _persistLink(field, result.url);
        }
        return result.url;
      },
      onBrowse: (field) async {
        // Opens where the file for this row belongs, so picking one is scrolling
        // a short list rather than the whole bucket.
        final destination = await _plannedDestination(field);
        if (!mounted) return null;
        return Navigator.of(context).push<String>(
          MaterialPageRoute(
            builder: (_) => BucketScreen(
              pickMode: true,
              initialPrefix: destination.prefix.isEmpty
                  ? ''
                  : destination.prefix.endsWith('/')
                      ? destination.prefix
                      : '${destination.prefix}/',
            ),
          ),
        );
      },
      onBuildGateAssets: (field) async {
        final client = _resolveR2();
        if (client == null) return null;

        // Two columns hold this JSON, and the folder kind is what says which.
        // A `gatepyqs` column *is* the year (`2024`), and its folder is the
        // branch's. A `py_qp` column is the exam session (`june_july_2025`),
        // whose year is part of the name, and whose folder is the subject's.
        final isSession = field.bucketFolder == BucketFolder.questionPaper;
        final year = isSession ? null : int.tryParse(field.column.trim());
        final sessionKey = isSession ? field.column.trim() : '';

        final destination = await _plannedDestination(field);
        if (!mounted) return null;
        if (destination.prefix.isEmpty || (!isSession && year == null)) {
          // Guessing a folder here would list somebody else's papers, which is
          // worse than saying so.
          showToast(
            context,
            isSession
                ? 'Fill in the scheme, semester and subject code first — that '
                    'is what says which folder the papers are in.'
                : 'Fill in the branch code first — that is what says which '
                    'folder the papers are in.',
            isError: true,
          );
          return null;
        }
        // Whose papers are being ticked — the code to match against the folder,
        // and the name because a code alone does not say what the subject is.
        // Resolved just now rather than at open, because the code above is
        // editable and the folder follows it.
        final subjectLabel = isSession
            ? [_subjectCode(), destination.subjectName]
                .where((part) => part.isNotEmpty)
                .join(' · ')
            : '';
        return Navigator.of(context).push<String>(
          MaterialPageRoute(
            builder: (_) => GateAssetsScreen(
              prefix: destination.prefix.endsWith('/')
                  ? destination.prefix
                  : '${destination.prefix}/',
              credentials: context.read<R2CredentialStore>().credentials,
              year: year,
              sessionKey: sessionKey,
              contextLabel: isSession
                  ? _subjectCode()
                  : (_controllers['code']?.text ?? '').trim(),
              subjectLabel: subjectLabel,
              initialValue: _controllers[field.column]?.text ?? '',
            ),
          ),
        );
      },
      onBuildDocuments: (field) async {
        final client = _resolveR2();
        if (client == null) return null;
        final destination = await _plannedDestination(field);
        if (!mounted) return null;
        if (destination.prefix.isEmpty) {
          // A new row with no scheme or semester yet. The folder is what says
          // which subject these files are for, so an empty one would list the
          // whole bucket and let the wrong subject's notes be ticked.
          showToast(
            context,
            'Fill in the scheme, semester and subject code first — that is what '
            'says which folder the files are in.',
            isError: true,
          );
          return null;
        }
        return Navigator.of(context).push<String>(
          MaterialPageRoute(
            builder: (_) => DocumentsScreen(
              prefix: destination.prefix.endsWith('/')
                  ? destination.prefix
                  : '${destination.prefix}/',
              credentials: context.read<R2CredentialStore>().credentials,
              title: field.label,
              // An entry the cell never named is called whatever the column is
              // called — `Notes`, `Study materials` — which is also what the
              // summary line under the text box will show.
              fallbackName: field.label,
              initialValue: _controllers[field.column]?.text ?? '',
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final lookups = context.read<LookupCache>();
    final r2Ready = context.watch<R2CredentialStore>().credentials.isComplete;
    final fileActions = _fileActions(r2Ready);

    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leaveWithoutSaving();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_title(), overflow: TextOverflow.ellipsis),
          actions: [
            if (_isEditing && _spec.canSendPush)
              PushSendButton(
                row: _row,
                enabled: !_saving,
                beforeSend: _readyToSend,
                onSent: _refreshRow,
              ),
            if (_isEditing && _spec.canModerate)
              ModerationAction(
                spec: _spec,
                row: _row,
                enabled: !_saving,
                onReviewed: _refreshRow,
              ),
            if (_isEditing && _spec.canCreate)
              IconButton(
                tooltip: 'Duplicate',
                icon: const Icon(Icons.copy_all_outlined),
                onPressed: _saving
                    ? null
                    : () => Navigator.of(context).pushReplacement(
                          MaterialPageRoute(
                            builder: (_) => RecordEditorScreen(
                              spec: _spec,
                              row: widget.row,
                              duplicate: true,
                            ),
                          ),
                        ),
              ),
            if (_isEditing && _spec.canDelete)
              IconButton(
                tooltip: 'Delete',
                icon: const Icon(Icons.delete_outline),
                onPressed: _saving ? null : _delete,
              ),
          ],
        ),
        body: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 120),
            children: [
              if (widget.duplicate)
                _Banner(
                  icon: Icons.copy_all_outlined,
                  text: 'Copied from ${_title()}. Saving creates a new row — '
                      'change whatever makes it different first.',
                ),
              if (_isEditing)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    '${_spec.table} · ${_spec.primaryKey} '
                    '${widget.row![_spec.primaryKey]}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              for (final field in _spec.fields)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: FieldEditor(
                    field: field,
                    controller: _controllers[field.column]!,
                    lookups: lookups,
                    fileActions: fileActions,
                    enabled: !_saving &&
                        !(_isEditing && field.column == _spec.primaryKey),
                    onChanged: () {
                      // Recomputed rather than latched, because an upload can
                      // write its own column straight to the database: latching
                      // would leave the form insisting on edits it no longer has,
                      // and refusing a push over them.
                      final dirty = _spec.fields.any((f) =>
                          _controllers[f.column]!.text != _initial[f.column]);
                      if (dirty != _dirty) setState(() => _dirty = dirty);
                    },
                  ),
                ),
            ],
          ),
        ),
        bottomNavigationBar: SafeArea(
          minimum: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: FilledButton.icon(
            onPressed: _saving ? null : _save,
            icon: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2.2),
                  )
                : const Icon(Icons.save_outlined, size: 18),
            label: Text(
              _saving
                  ? 'Saving…'
                  : _isEditing
                      ? 'Save changes'
                      : 'Create',
            ),
          ),
        ),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, size: 17, color: theme.colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: theme.textTheme.bodySmall)),
        ],
      ),
    );
  }
}
