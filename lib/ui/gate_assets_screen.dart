import 'package:flutter/material.dart';

import '../r2/r2_client.dart';
import '../r2/r2_credentials.dart';
import '../schema/gate_assets.dart';
import 'widgets/state_views.dart';

/// Builds one `gatepyqs` year cell, or one `py_qp` exam session cell, by ticking
/// files in the R2 folder they live in.
///
/// The alternative is typing the JSON by hand into a text box on a phone, which
/// is how a year ends up with a `%20` in the middle of a link or a key spelt
/// `Anwser Key`. Here the URLs come from the bucket itself and the shape is
/// generated, so the only thing left to get right is which file is which — and
/// even that is guessed from the file name and only needs correcting.
///
/// The two columns hold the same JSON, and differ only in what the folder is
/// organised by: a GATE branch folder is split by *kind* (the year is in the
/// file name), while a subject's `py_qp/` folder holds every session of that
/// subject. So [year] picks the files in one case and [sessionKey] in the other,
/// and exactly one of them is set.
///
/// Pops the cell text, or null if nothing was chosen.
class GateAssetsScreen extends StatefulWidget {
  const GateAssetsScreen({
    super.key,
    required this.prefix,
    required this.credentials,
    this.year,
    this.sessionKey = '',
    this.contextLabel = '',
    this.subjectLabel = '',
    this.initialValue = '',
  }) : assert(year != null || sessionKey != '',
            'Set either the GATE year or the exam session, not neither.');

  /// The folder the files live in — a GATE branch folder
  /// (`vtu/gatepyqs/CS_Computer_Science_Engineering/`) or a subject's papers
  /// (`vtu/scheme-2025/…/3rd_sem/py_qp/1BAE305 Introduction to UAV Systems/`).
  final String prefix;

  final R2Credentials credentials;

  /// The `gatepyqs` column being filled in, e.g. `2024`. Null for a session.
  /// Files named after another year are hidden behind a switch rather than
  /// dropped — a folder is not always tidy.
  final int? year;

  /// The `py_qp` column being filled in, e.g. `june_july_2025`. Empty for a
  /// GATE year. Files belonging to another sitting are behind the same switch.
  final String sessionKey;

  /// Shown after the year or session in the title: the GATE branch code, or the
  /// subject code.
  ///
  /// Short, because the title is one ellipsised line.
  final String contextLabel;

  /// Whose papers these are, in full — `BCS403 · Introduction to UAV Systems`,
  /// or just the code when the name could not be read. Said in the sentence above
  /// the list rather than in the title, which has no room for it; empty for a
  /// GATE year, where the branch in the title already says it.
  final String subjectLabel;

  /// What the column holds now. Files already listed come back ticked, and links
  /// that are not in the bucket (a Drive URL from before R2) are kept as they
  /// are — this screen must never be the reason one disappears.
  final String initialValue;

  @override
  State<GateAssetsScreen> createState() => _GateAssetsScreenState();
}

class _GateAssetsScreenState extends State<GateAssetsScreen> {
  R2Client? _client;

  final List<R2Object> _objects = [];

  /// URL → what it was chosen as. Keyed by URL so a file already in the cell and
  /// the same file in the listing are one entry, not two.
  final Map<String, GateAsset> _chosen = {};

  /// Assets from [GateAssetsScreen.initialValue] that no listed file matches —
  /// links to somewhere other than this bucket, or files since moved.
  final List<GateAsset> _external = [];

  bool _loading = true;
  bool _showOthers = false;
  String? _error;

  /// True when this run is filling a `py_qp` session rather than a GATE year.
  bool get _isSession => widget.sessionKey.isNotEmpty;

  /// What the title says after the year or session — the scope of this run.
  String get _scope => _isSession
      ? pyqpSessionLabel(widget.sessionKey)
      : 'GATE ${widget.year}';

  String get _title =>
      '$_scope${widget.contextLabel.isEmpty ? '' : ' — ${widget.contextLabel}'}';

  @override
  void initState() {
    super.initState();
    _client = R2Client(widget.credentials);
    for (final asset in parseGateAssets(widget.initialValue)) {
      _chosen[asset.url] = asset;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _client?.dispose();
    super.dispose();
  }

  /// Every file under the folder, at any depth: the folders inside it are
  /// somebody's filing, and which year or sitting a file is for is read off its
  /// name, not off where it sits.
  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final objects = await _client!.objectsUnder(widget.prefix);
      if (!mounted) return;
      final files = [
        for (final object in objects)
          // Folder markers are not files, and the archive is last year's
          // mistakes — neither belongs in a list of things to publish.
          if (!object.key.endsWith('/') &&
              !object.key.contains('/deleted_old_files/'))
            object,
      ]..sort((a, b) => a.key.toLowerCase().compareTo(b.key.toLowerCase()));

      final listed = {
        for (final object in files) widget.credentials.publicUrlFor(object.key),
      };
      setState(() {
        _objects
          ..clear()
          ..addAll(files);
        _external
          ..clear()
          ..addAll([
            for (final entry in _chosen.entries)
              if (!listed.contains(entry.key)) entry.value,
          ]);
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error is R2Exception
            ? '$error'
            : 'Could not list ${widget.prefix}: $error';
      });
    }
  }

  /// Files for the year or session being filled in.
  ///
  /// A GATE year is read off the file's *name* (`GATE_2024_CS.pdf`) after checking
  /// for a year *folder*, which in practice never exists. A `py_qp` session is read
  /// off the file's path below this folder, via [pyqpSessionMatches], because a
  /// subject's folder holds every session it has papers for — and each session is
  /// usually a folder of its own.
  ///
  /// Either way a file that says nothing about its year or sitting stays visible,
  /// because it could be for either and hiding it would leave the folder looking
  /// empty.
  List<R2Object> get _visible {
    if (_showOthers) return _objects;
    if (_isSession) {
      return [
        for (final object in _objects)
          if (pyqpSessionMatches(_belowPrefix(object.key), widget.sessionKey))
            object,
      ];
    }

    final year = widget.year!;
    return [
      for (final object in _objects)
        if (gateYearFromKey(object.key) == year ||
            (gateYearFromKey(object.key) == null &&
                (gateYearIn(object.name) == null ||
                    gateYearIn(object.name) == year)))
          object,
    ];
  }

  /// The part of a key below the folder being listed — a file's own name, plus
  /// any folder it sits in.
  ///
  /// A session is usually a folder (`…/py_qp/1BBEE105 …/DEC JAN 2026/x.pdf`), so
  /// the name on its own frequently says nothing about which sitting a file is
  /// for. Everything above the prefix is dropped deliberately: it holds
  /// `scheme-2025`, and a year read out of that would match every session.
  String _belowPrefix(String key) =>
      key.startsWith(widget.prefix) ? key.substring(widget.prefix.length) : key;

  /// The folders a file sits in below the one being listed, or empty when it is
  /// directly in it. Shown so two files of the same name from two sittings are
  /// not two identical rows.
  String _folderOf(String key) {
    final below = _belowPrefix(key);
    final cut = below.lastIndexOf('/');
    return cut == -1 ? '' : below.substring(0, cut);
  }

  int get _hiddenCount => _objects.length - _visible.length;

  /// What a file most likely is, and what to call it, from its name.
  ///
  /// The kind is the same question in both modes; the label is not — a GATE year
  /// has sessions ("Session 1"), a `py_qp` sitting has papers ("Paper A").
  GateAsset _assetFor(R2Object object) {
    final kind = gateKindFromKey(object.key) ?? guessGateAssetKind(object.name);
    var label = _isSession
        ? guessPaperLabel(object.name)
        : guessGateSessionLabel(object.name);
    // "Paper A solved" is Paper A's solved paper, and the chip should say which
    // paper rather than repeat the button it sits under.
    if (kind == GateAssetKind.solvedPaper) label = solvedLabelFor(label);
    return GateAsset(kind: kind, label: label, url: '');
  }

  void _toggle(R2Object object) {
    final url = widget.credentials.publicUrlFor(object.key);
    setState(() {
      if (_chosen.remove(url) != null) return;
      // A kind folder beats a guess from the file name: someone chose that
      // folder, whereas the name is just what the file happened to be called.
      // No such folder exists for a `py_qp` subject, so there every file falls
      // back to the guess.
      _chosen[url] = _assetFor(object).copyWith(url: url);
    });
  }

  void _setKind(String url, GateAssetKind kind) {
    final asset = _chosen[url];
    if (asset == null) return;
    setState(() {
      _chosen[url] = asset.copyWith(
        kind: kind,
        // The noun in the label has to follow the kind, or a file corrected from
        // paper to solved paper keeps saying "Paper A" under a Solved Papers
        // button. A label that is neither — a typed one, or GATE's "Session 1" —
        // is left exactly as it is.
        label: kind == GateAssetKind.solvedPaper
            ? solvedLabelFor(asset.label)
            : asset.label.replaceFirst(RegExp(r'^Solved '), 'Paper '),
      );
    });
  }

  Future<void> _editLabel(String url) async {
    final asset = _chosen[url];
    if (asset == null) return;
    final controller = TextEditingController(text: asset.label);
    // A GATE year has sessions; a VTU sitting has papers. Same field, and the
    // two suggestions are the two things anyone ever types in it.
    final suggestions = _isSession
        ? const ['Paper A', 'Paper B', 'Paper C']
        : const ['Session 1', 'Session 2'];
    final label = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(_isSession ? 'Paper label' : 'Session label'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: controller,
              autofocus: true,
              decoration: InputDecoration(
                labelText: 'Label',
                helperText: 'Shown to students when $_scope has more than one '
                    'of this kind. Leave empty if there is only one.',
                helperMaxLines: 3,
              ),
              onSubmitted: (value) => Navigator.pop(dialogContext, value),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                for (final suggestion in suggestions)
                  ActionChip(
                    label: Text(suggestion),
                    onPressed: () => Navigator.pop(dialogContext, suggestion),
                  ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('Set'),
          ),
        ],
      ),
    );
    if (label == null || !mounted) return;
    setState(() => _chosen[url] = asset.copyWith(label: label.trim()));
  }

  /// In kind order, and inside a kind in the order the bucket lists them, so
  /// Session 1 comes before Session 2 without anyone arranging it. Links that
  /// are not in the bucket keep their place at the end of their kind.
  List<GateAsset> get _result {
    final listed = [
      for (final object in _objects)
        ?_chosen[widget.credentials.publicUrlFor(object.key)],
    ];
    return [
      for (final kind in GateAssetKind.values) ...[
        for (final asset in listed)
          if (asset.kind == kind) asset,
        for (final asset in _external)
          if (asset.kind == kind) asset,
      ],
    ];
  }

  void _save() => Navigator.pop(context, encodeGateAssets(_result));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final chosen = _result;

    return Scaffold(
      appBar: AppBar(
        title: Text(_title),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                _summary(chosen),
                style: theme.textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              FilledButton.icon(
                // Saving nothing is legitimate: it is how a year or a session
                // that was filled in by mistake gets cleared.
                onPressed: _loading ? null : _save,
                icon: const Icon(Icons.check),
                label: Text(chosen.isEmpty
                    ? 'Clear $_scope'
                    : 'Use ${chosen.length} '
                        '${chosen.length == 1 ? 'file' : 'files'}'),
              ),
            ],
          ),
        ),
      ),
      body: _error != null
          ? ErrorView(message: _error!, onRetry: _load)
          : _loading
              ? const BusyView(label: 'Listing the folder…')
              : _objects.isEmpty && _external.isEmpty
                  ? EmptyView(
                      icon: Icons.folder_open_outlined,
                      title: 'Nothing in this folder yet',
                      subtitle: 'Upload the $_scope papers to '
                          '${widget.prefix} from the Bucket screen, then come '
                          'back here.',
                    )
                  : ListView(
                      padding: const EdgeInsets.only(bottom: 24),
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                          child: Text(
                            'Tick the files for $_scope'
                            '${widget.subjectLabel.isEmpty ? '' : ' of ${widget.subjectLabel}'}. '
                            'What each one is is guessed from its name — tap the '
                            'chips to correct it.',
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                        if (_hiddenCount > 0 || _showOthers)
                          SwitchListTile(
                            value: _showOthers,
                            onChanged: (value) =>
                                setState(() => _showOthers = value),
                            dense: true,
                            title: Text(_isSession
                                ? 'Show files from other sessions'
                                : 'Show files from other years'),
                            subtitle: Text(_showOthers
                                ? 'Showing everything in the folder'
                                : '$_hiddenCount hidden'),
                          ),
                        for (final object in _visible)
                          _FileTile(
                            object: object,
                            folder: _folderOf(object.key),
                            asset: _chosen[
                                widget.credentials.publicUrlFor(object.key)],
                            onToggle: () => _toggle(object),
                            onKind: (kind) => _setKind(
                                widget.credentials.publicUrlFor(object.key),
                                kind),
                            onLabel: () => _editLabel(
                                widget.credentials.publicUrlFor(object.key)),
                          ),
                        if (_external.isNotEmpty) ...[
                          const Divider(height: 24),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                            child: Text(
                              'Already in $_scope, but not in the bucket',
                              style: theme.textTheme.labelLarge,
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                            child: Text(
                              'Kept as they are. Remove one only if the link is '
                              'dead — nothing else points at it.',
                              style: theme.textTheme.bodySmall,
                            ),
                          ),
                          for (final asset in _external)
                            ListTile(
                              leading: const Icon(Icons.link),
                              title: Text(asset.kind.singular +
                                  (asset.label.isEmpty
                                      ? ''
                                      : ' · ${asset.label}')),
                              subtitle: Text(asset.url, maxLines: 2),
                              trailing: IconButton(
                                tooltip: 'Remove',
                                icon: Icon(Icons.close,
                                    size: 18, color: theme.colorScheme.error),
                                onPressed: () => setState(() {
                                  _external.remove(asset);
                                  _chosen.remove(asset.url);
                                }),
                              ),
                            ),
                        ],
                      ],
                    ),
    );
  }

  static String _summary(List<GateAsset> assets) {
    if (assets.isEmpty) return 'Nothing chosen — saving empties this year.';
    return [
      for (final kind in GateAssetKind.values)
        if (assets.where((a) => a.kind == kind).isNotEmpty)
          '${assets.where((a) => a.kind == kind).length} × ${kind.jsonKey}',
    ].join('   ·   ');
  }
}

/// One bucket file: a checkbox, and once ticked the two things about it that the
/// generated JSON needs.
class _FileTile extends StatelessWidget {
  const _FileTile({
    required this.object,
    required this.asset,
    required this.onToggle,
    required this.onKind,
    required this.onLabel,
    this.folder = '',
  });

  final R2Object object;

  /// The folders this file sits in below the one being listed, or empty when it
  /// is directly in it.
  final String folder;
  final GateAsset? asset;
  final VoidCallback onToggle;
  final ValueChanged<GateAssetKind> onKind;
  final VoidCallback onLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final chosen = asset;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        CheckboxListTile(
          value: chosen != null,
          onChanged: (_) => onToggle(),
          controlAffinity: ListTileControlAffinity.leading,
          title: Text(object.name),
          subtitle: Text(folder.isEmpty
              ? object.readableSize
              : '$folder · ${object.readableSize}'),
        ),
        if (chosen != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(56, 0, 16, 12),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (final kind in GateAssetKind.values)
                  ChoiceChip(
                    label: Text(kind.singular),
                    selected: chosen.kind == kind,
                    onSelected: (_) => onKind(kind),
                  ),
                ActionChip(
                  avatar: const Icon(Icons.label_outline, size: 16),
                  label: Text(
                    chosen.label.isEmpty ? 'No session label' : chosen.label,
                  ),
                  onPressed: onLabel,
                ),
              ],
            ),
          ),
        Divider(height: 1, color: theme.dividerColor),
      ],
    );
  }
}
