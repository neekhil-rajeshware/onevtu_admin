import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/admin_repository.dart';
import '../../data/lookup_cache.dart';
import '../../schema/field_spec.dart';
import '../../schema/gate_assets.dart';
import '../../schema/named_documents.dart';
import 'row_thumbnail.dart';
import 'state_views.dart';

/// What a [FieldType.fileUrl] field can do besides hold text. Supplied by the
/// record editor, which owns the R2 client and the navigation.
class FileFieldActions {
  const FileFieldActions({
    required this.onUpload,
    required this.onBrowse,
    required this.onBuildGateAssets,
    required this.onBuildDocuments,
    required this.isConfigured,
  });

  /// Pick a local file and upload it, returning the public URL.
  final Future<String?> Function(FieldSpec field) onUpload;

  /// Browse the bucket and pick an existing object, returning its public URL.
  final Future<String?> Function(FieldSpec field) onBrowse;

  /// Tick several files in the branch's GATE folder and get back the JSON for a
  /// whole year — a [FieldType.gateAssets] column's one sane way in.
  final Future<String?> Function(FieldSpec field) onBuildGateAssets;

  /// Tick several files in this row's own folder and get back the JSON for a
  /// [FieldType.documentList] column — the same idea as [onBuildGateAssets],
  /// without the kinds and sessions, because a list of notes has no shape to
  /// get wrong beyond the names.
  final Future<String?> Function(FieldSpec field) onBuildDocuments;

  /// False until R2 credentials are saved; the buttons then explain themselves
  /// instead of failing.
  final bool isConfigured;
}

/// Renders and edits one column, according to its [FieldSpec].
///
/// Every type ends up in a `TextEditingController` holding text — the single
/// representation the form validates and `FieldCodec` converts on save. Pickers
/// and dropdowns write into that same controller rather than holding state of
/// their own, so there is only ever one source of truth per field.
class FieldEditor extends StatelessWidget {
  const FieldEditor({
    super.key,
    required this.field,
    required this.controller,
    required this.lookups,
    required this.onChanged,
    this.fileActions,
    this.enabled = true,
  });

  final FieldSpec field;
  final TextEditingController controller;
  final LookupCache lookups;
  final VoidCallback onChanged;
  final FileFieldActions? fileActions;
  final bool enabled;

  bool get _editable => enabled && !field.readOnly;

  @override
  Widget build(BuildContext context) {
    switch (field.type) {
      case FieldType.boolean:
        return _BooleanField(
          field: field,
          controller: controller,
          enabled: _editable,
          onChanged: onChanged,
        );
      case FieldType.select:
        return _SelectField(
          field: field,
          controller: controller,
          lookups: lookups,
          enabled: _editable,
          onChanged: onChanged,
        );
      case FieldType.date:
      case FieldType.dateTime:
        return _DateField(
          field: field,
          controller: controller,
          enabled: _editable,
          onChanged: onChanged,
        );
      case FieldType.fileUrl:
        return _FileUrlField(
          field: field,
          controller: controller,
          actions: fileActions,
          enabled: _editable,
          onChanged: onChanged,
        );
      case FieldType.gateAssets:
        return _GateAssetsField(
          field: field,
          controller: controller,
          actions: fileActions,
          enabled: _editable,
          onChanged: onChanged,
        );
      case FieldType.documentList:
        return _NamedDocumentsField(
          field: field,
          controller: controller,
          actions: fileActions,
          enabled: _editable,
          onChanged: onChanged,
        );
      default:
        return _TextField(
          field: field,
          controller: controller,
          enabled: _editable,
          onChanged: onChanged,
        );
    }
  }
}

class _TextField extends StatelessWidget {
  const _TextField({
    required this.field,
    required this.controller,
    required this.enabled,
    required this.onChanged,
    this.suffix,
  });

  final FieldSpec field;
  final TextEditingController controller;
  final bool enabled;
  final VoidCallback onChanged;
  final Widget? suffix;

  @override
  Widget build(BuildContext context) {
    final isCode = field.type == FieldType.json ||
        field.type == FieldType.gateAssets ||
        field.type == FieldType.documentList;
    final isTall = field.type == FieldType.multiline || isCode;
    final maxLines = field.maxLines < 1 ? 1 : field.maxLines;
    // A box this tall opens three lines high so the braces are readable, but
    // never taller than its own `maxLines`. `FieldSpec.maxLines` defaults to 1,
    // and TextFormField *asserts* rather than clamps when minLines exceeds
    // maxLines — so a field type that forgot to raise it does not get a cramped
    // box, it takes the entire record editor down on the first frame.
    final minLines = !isTall ? 1 : (maxLines < 3 ? maxLines : 3);
    return TextFormField(
      controller: controller,
      enabled: enabled,
      maxLines: maxLines,
      minLines: minLines,
      keyboardType: switch (field.type) {
        FieldType.integer => TextInputType.number,
        FieldType.decimal =>
          const TextInputType.numberWithOptions(decimal: true),
        FieldType.url || FieldType.fileUrl => TextInputType.url,
        FieldType.multiline ||
        FieldType.json ||
        FieldType.gateAssets ||
        FieldType.documentList =>
          TextInputType.multiline,
        _ => TextInputType.text,
      },
      style: isCode
          ? const TextStyle(fontFamily: 'monospace', fontSize: 13)
          : null,
      decoration: InputDecoration(
        labelText: field.required ? '${field.label} *' : field.label,
        helperText: field.type == FieldType.tags
            ? [field.help, 'Separate with commas.']
                .whereType<String>()
                .join(' ')
            : field.help,
        suffixIcon: suffix ??
            (field.type == FieldType.url
                ? _OpenUrlButton(controller: controller)
                : null),
      ),
      onChanged: (_) => onChanged(),
      validator: (value) => FieldCodec.validate(field, value ?? ''),
    );
  }
}

/// Opens whatever URL the field currently holds, so a link can be eyeballed
/// before it is saved into the live app.
class _OpenUrlButton extends StatelessWidget {
  const _OpenUrlButton({required this.controller});

  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: controller,
      builder: (context, value, _) {
        final text = value.text.trim();
        if (!text.startsWith('http')) return const SizedBox.shrink();
        return IconButton(
          tooltip: 'Open',
          icon: const Icon(Icons.open_in_new, size: 18),
          onPressed: () async {
            final uri = Uri.tryParse(text);
            if (uri == null) return;
            final opened =
                await launchUrl(uri, mode: LaunchMode.externalApplication);
            if (!opened && context.mounted) {
              showToast(context, 'Nothing could open that link', isError: true);
            }
          },
        );
      },
    );
  }
}

class _BooleanField extends StatefulWidget {
  const _BooleanField({
    required this.field,
    required this.controller,
    required this.enabled,
    required this.onChanged,
  });

  final FieldSpec field;
  final TextEditingController controller;
  final bool enabled;
  final VoidCallback onChanged;

  @override
  State<_BooleanField> createState() => _BooleanFieldState();
}

class _BooleanFieldState extends State<_BooleanField> {
  @override
  Widget build(BuildContext context) {
    final value = widget.controller.text == 'true';
    return SwitchListTile(
      value: value,
      onChanged: widget.enabled
          ? (next) {
              setState(() => widget.controller.text = next ? 'true' : 'false');
              widget.onChanged();
            }
          : null,
      title: Text(widget.field.label),
      subtitle: widget.field.help == null
          ? null
          : Text(widget.field.help!, style: Theme.of(context).textTheme.bodySmall),
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
      ),
    );
  }
}

/// Opens the searchable option sheet used by every select field and by the
/// collection filters. Returns null when dismissed, and `''` when the value was
/// cleared — the two are different answers.
Future<String?> chooseOption(
  BuildContext context, {
  required String title,
  required List<LookupOption> options,
  String current = '',
  bool allowFreeText = false,
}) async {
  final picked = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (context) => _OptionSheet(
      title: title,
      options: options,
      current: current,
      allowFreeText: allowFreeText,
    ),
  );
  if (picked == null) return null;
  return picked == _OptionSheet.clearSentinel ? '' : picked;
}

/// A value chosen from a list. Rendered as a text field with a picker rather
/// than a `DropdownButton`, because the options can arrive asynchronously, some
/// are very long strings, and a few columns accept free text too.
class _SelectField extends StatelessWidget {
  const _SelectField({
    required this.field,
    required this.controller,
    required this.lookups,
    required this.enabled,
    required this.onChanged,
  });

  final FieldSpec field;
  final TextEditingController controller;
  final LookupCache lookups;
  final bool enabled;
  final VoidCallback onChanged;

  Future<List<LookupOption>> _options() async {
    if (field.lookup != null) return lookups.options(field.lookup!);
    return (field.options ?? const []).map(LookupOption.new).toList();
  }

  Future<void> _choose(BuildContext context) async {
    final List<LookupOption> options;
    try {
      options = await _options();
    } on LookupException catch (error) {
      // Better a stated reason than an empty sheet: an empty list here is
      // indistinguishable from a reference table with no rows.
      if (context.mounted) {
        showToast(context, '$error Tap again to retry.', isError: true);
      }
      return;
    }
    if (!context.mounted) return;
    final picked = await chooseOption(
      context,
      title: field.label,
      options: options,
      current: controller.text,
      allowFreeText: field.freeTextSelect,
    );
    if (picked == null) return;
    controller.text = picked;
    onChanged();
  }

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      enabled: enabled,
      // Always the picker, never the keyboard. A tap on a field labelled with a
      // dropdown arrow has to show the list — leaving free-text columns editable
      // in place meant tapping one only raised the keyboard, and the list hid
      // behind a 24-pixel icon. Typing a value that is not in the list is still
      // possible: the sheet's search box offers whatever is typed.
      readOnly: true,
      onTap: enabled ? () => _choose(context) : null,
      decoration: InputDecoration(
        labelText: field.required ? '${field.label} *' : field.label,
        helperText: field.help,
        helperMaxLines: 3,
        suffixIcon: IconButton(
          tooltip: 'Choose',
          icon: const Icon(Icons.arrow_drop_down),
          onPressed: enabled ? () => _choose(context) : null,
        ),
      ),
      onChanged: (_) => onChanged(),
      validator: (value) => FieldCodec.validate(field, value ?? ''),
    );
  }
}

/// Searchable option list. `subjects.sub_category` values run to sixty
/// characters, so a plain dropdown would be unreadable on a phone.
class _OptionSheet extends StatefulWidget {
  const _OptionSheet({
    required this.title,
    required this.options,
    required this.current,
    required this.allowFreeText,
  });

  static const clearSentinel = '\u0000clear';

  final String title;
  final List<LookupOption> options;
  final String current;

  /// Whether a value outside the list is legitimate. The search box doubles as
  /// where it gets typed.
  final bool allowFreeText;

  @override
  State<_OptionSheet> createState() => _OptionSheetState();
}

class _OptionSheetState extends State<_OptionSheet> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final query = _query.trim();
    final matches = widget.options
        .where((o) =>
            _query.isEmpty ||
            o.display.toLowerCase().contains(_query.toLowerCase()))
        .toList();
    // Offer what was typed as a value of its own, unless it is already in the
    // list. This is the only way to enter a value a free-text column allows but
    // the reference table has never seen.
    final freeText = widget.allowFreeText &&
        query.isNotEmpty &&
        !widget.options.any((o) => o.value == query);
    final searchable = widget.options.length > 8 || widget.allowFreeText;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            Container(
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(widget.title,
                        style: Theme.of(context).textTheme.titleMedium),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(
                        context, _OptionSheet.clearSentinel),
                    child: const Text('Clear'),
                  ),
                ],
              ),
            ),
            if (searchable)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: TextField(
                  // A long list is worth typing into straight away; a short one
                  // would be hidden by the keyboard for no reason.
                  autofocus: widget.options.length > 8,
                  decoration: InputDecoration(
                    hintText:
                        widget.allowFreeText ? 'Search, or type a value' : 'Search',
                    prefixIcon: const Icon(Icons.search, size: 18),
                  ),
                  onChanged: (value) => setState(() => _query = value),
                ),
              ),
            Flexible(
              child: matches.isEmpty && !freeText
                  ? Padding(
                      padding: const EdgeInsets.all(28),
                      child: Text(
                        widget.options.isEmpty
                            ? 'Nothing to choose from — that table has no rows '
                                'yet.'
                            : 'Nothing matches "$query".',
                        textAlign: TextAlign.center,
                      ),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: matches.length + (freeText ? 1 : 0),
                      itemBuilder: (context, index) {
                        if (freeText && index == 0) {
                          return ListTile(
                            leading: const Icon(Icons.edit_outlined, size: 18),
                            title: Text('Use "$query"'),
                            onTap: () => Navigator.pop(context, query),
                          );
                        }
                        final option = matches[freeText ? index - 1 : index];
                        final selected = option.value == widget.current;
                        return ListTile(
                          title: Text(option.display),
                          trailing: selected
                              ? const Icon(Icons.check, size: 18)
                              : null,
                          onTap: () => Navigator.pop(context, option.value),
                        );
                      },
                    ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

class _DateField extends StatelessWidget {
  const _DateField({
    required this.field,
    required this.controller,
    required this.enabled,
    required this.onChanged,
  });

  final FieldSpec field;
  final TextEditingController controller;
  final bool enabled;
  final VoidCallback onChanged;

  Future<void> _pick(BuildContext context) async {
    final existing = DateTime.tryParse(controller.text);
    final date = await showDatePicker(
      context: context,
      initialDate: existing ?? DateTime.now(),
      firstDate: DateTime(2015),
      lastDate: DateTime(2040),
    );
    if (date == null) return;

    if (field.type == FieldType.date) {
      controller.text = FieldCodec.formatDate(date);
      onChanged();
      return;
    }

    if (!context.mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(existing ?? DateTime.now()),
    );
    final moment = DateTime(
      date.year,
      date.month,
      date.day,
      time?.hour ?? 0,
      time?.minute ?? 0,
    );
    controller.text = FieldCodec.formatDateTime(moment);
    onChanged();
  }

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      enabled: enabled,
      readOnly: true,
      onTap: enabled ? () => _pick(context) : null,
      decoration: InputDecoration(
        labelText: field.required ? '${field.label} *' : field.label,
        helperText: field.help,
        suffixIcon: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (controller.text.isNotEmpty && enabled)
              IconButton(
                tooltip: 'Clear',
                icon: const Icon(Icons.clear, size: 18),
                onPressed: () {
                  controller.clear();
                  onChanged();
                },
              ),
            IconButton(
              tooltip: 'Pick',
              icon: const Icon(Icons.event_outlined, size: 18),
              onPressed: enabled ? () => _pick(context) : null,
            ),
          ],
        ),
      ),
      validator: (value) => FieldCodec.validate(field, value ?? ''),
    );
  }
}

/// A URL that may be a file in the bucket: upload a new one, pick an existing
/// one, open it, or paste a link by hand. This is the join between the two
/// halves of the console.
class _FileUrlField extends StatelessWidget {
  const _FileUrlField({
    required this.field,
    required this.controller,
    required this.actions,
    required this.enabled,
    required this.onChanged,
  });

  final FieldSpec field;
  final TextEditingController controller;
  final FileFieldActions? actions;
  final bool enabled;
  final VoidCallback onChanged;

  Future<void> _run(
    BuildContext context,
    Future<String?> Function(FieldSpec) action,
  ) async {
    final config = actions;
    if (config == null || !config.isConfigured) {
      showToast(
        context,
        'Add your R2 keys under Bucket → settings first',
        isError: true,
      );
      return;
    }
    final url = await action(field);
    // A replacement usually keeps the object key, so the link comes back
    // identical — that is the point of it, and it is not an edit.
    if (url == null || url == controller.text) return;
    controller.text = url;
    onChanged();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _TextField(
          field: field,
          controller: controller,
          enabled: enabled,
          onChanged: onChanged,
          suffix: _OpenUrlButton(controller: controller),
        ),
        // Rebuilt from the controller so a freshly uploaded photo appears the
        // moment the link lands, without the editor having to know it happened.
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: controller,
          builder: (context, value, _) =>
              ImagePreview(url: value.text, title: field.label),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          children: [
            TextButton.icon(
              onPressed: enabled
                  ? () => _run(context, actions?.onUpload ?? _unavailable)
                  : null,
              icon: const Icon(Icons.upload_file_outlined, size: 17),
              label: const Text('Upload'),
            ),
            TextButton.icon(
              onPressed: enabled
                  ? () => _run(context, actions?.onBrowse ?? _unavailable)
                  : null,
              icon: const Icon(Icons.folder_open_outlined, size: 17),
              label: const Text('Pick from bucket'),
            ),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: controller,
              builder: (context, value, _) => value.text.trim().isEmpty
                  ? const SizedBox.shrink()
                  : TextButton.icon(
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: value.text.trim()));
                        showToast(context, 'Link copied');
                      },
                      icon: const Icon(Icons.copy_outlined, size: 17),
                      label: const Text('Copy'),
                    ),
            ),
          ],
        ),
      ],
    );
  }

  static Future<String?> _unavailable(FieldSpec field) async => null;
}

/// One `gatepyqs` year column: the generated JSON, the button that generates it,
/// and a plain-English reading of what is currently in there.
///
/// The text box stays editable on purpose — a year whose paper is on Drive
/// rather than in the bucket still has to be fillable, and being able to see the
/// JSON is what makes a wrong cell diagnosable at all. But the button is the
/// path meant to be used: it is the only one that cannot misspell a key or
/// forget to percent-encode a space.
class _GateAssetsField extends StatelessWidget {
  const _GateAssetsField({
    required this.field,
    required this.controller,
    required this.actions,
    required this.enabled,
    required this.onChanged,
  });

  final FieldSpec field;
  final TextEditingController controller;
  final FileFieldActions? actions;
  final bool enabled;
  final VoidCallback onChanged;

  Future<void> _build(BuildContext context) async {
    final config = actions;
    if (config == null || !config.isConfigured) {
      showToast(
        context,
        'Add your R2 keys under Bucket → settings first',
        isError: true,
      );
      return;
    }
    final value = await config.onBuildGateAssets(field);
    if (value == null || value == controller.text) return;
    controller.text = value;
    onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _TextField(
          field: field,
          controller: controller,
          enabled: enabled,
          onChanged: onChanged,
        ),
        const SizedBox(height: 6),
        // Read back through the same parser the student app uses, so this line
        // says what a student would actually be offered — not what was typed.
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: controller,
          builder: (context, value, _) {
            final summary = _describe(value.text);
            if (summary == null) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(summary, style: theme.textTheme.bodySmall),
            );
          },
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: enabled ? () => _build(context) : null,
            icon: const Icon(Icons.playlist_add_check_outlined, size: 18),
            label: const Text('Build from bucket'),
          ),
        ),
      ],
    );
  }

  /// `Paper (Session 1, Session 2) · Answer Key`, or null when the cell is empty.
  static String? _describe(String cell) {
    if (cell.trim().isEmpty) return null;
    final assets = parseGateAssets(cell);
    if (assets.isEmpty) return 'Nothing readable in here yet.';

    final parts = <String>[];
    for (final kind in GateAssetKind.values) {
      final ofKind = [
        for (final asset in assets)
          if (asset.kind == kind) asset,
      ];
      if (ofKind.isEmpty) continue;
      final labels = [
        for (final asset in ofKind)
          if (asset.label.isNotEmpty) asset.label,
      ];
      parts.add(labels.length == ofKind.length && labels.isNotEmpty
          ? '${kind.jsonKey} (${labels.join(', ')})'
          : ofKind.length == 1
              ? kind.jsonKey
              : '${kind.jsonKey} × ${ofKind.length}');
    }
    return parts.join('  ·  ');
  }
}

/// One `notes_link` / `study_materials` column: the generated JSON, the button
/// that generates it, and a plain-English reading of what is currently in there.
///
/// The same shape as [_GateAssetsField] and for the same two reasons: the text
/// box stays editable so a file that lives on Drive rather than in the bucket is
/// still fillable and a wrong cell is diagnosable at all, and the button is the
/// path meant to be used, because it is the only one that cannot misspell a key
/// or forget to percent-encode a space.
class _NamedDocumentsField extends StatelessWidget {
  const _NamedDocumentsField({
    required this.field,
    required this.controller,
    required this.actions,
    required this.enabled,
    required this.onChanged,
  });

  final FieldSpec field;
  final TextEditingController controller;
  final FileFieldActions? actions;
  final bool enabled;
  final VoidCallback onChanged;

  Future<void> _build(BuildContext context) async {
    final config = actions;
    if (config == null || !config.isConfigured) {
      showToast(
        context,
        'Add your R2 keys under Bucket → settings first',
        isError: true,
      );
      return;
    }
    final value = await config.onBuildDocuments(field);
    if (value == null || value == controller.text) return;
    controller.text = value;
    onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _TextField(
          field: field,
          controller: controller,
          enabled: enabled,
          onChanged: onChanged,
        ),
        const SizedBox(height: 6),
        // Read back through the same parser the student app uses, so this line
        // says what a student would actually be offered — not what was typed.
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: controller,
          builder: (context, value, _) {
            final summary = _describe(value.text, field.label);
            if (summary == null) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(summary, style: theme.textTheme.bodySmall),
            );
          },
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: enabled ? () => _build(context) : null,
            label: const Text('Pick files from bucket'),
            icon: const Icon(Icons.playlist_add_check_outlined, size: 18),
          ),
        ),
      ],
    );
  }

  /// `Module 1 · Module 2 · Lab Record`, or null when the column is empty.
  ///
  /// The names are what the student taps, so they are what is worth showing.
  /// The fallback has to be the field's own label — it is what an unnamed entry
  /// will be called — or this line would name a file something the app will not.
  static String? _describe(String cell, String fallbackName) {
    if (cell.trim().isEmpty) return null;
    final documents = parseNamedDocuments(cell, fallbackName: fallbackName);
    if (documents.isEmpty) return 'Nothing readable in here yet.';
    return documents.map((document) => document.name).join('  ·  ');
  }
}
