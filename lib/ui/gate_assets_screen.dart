import 'package:flutter/material.dart';

import '../r2/r2_client.dart';
import '../r2/r2_credentials.dart';
import '../schema/gate_assets.dart';
import 'widgets/state_views.dart';

/// Builds one `gatepyqs` year cell by ticking files in the branch's R2 folder.
///
/// The alternative is typing the JSON by hand into a text box on a phone, which
/// is how a year ends up with a `%20` in the middle of a link or a key spelt
/// `Anwser Key`. Here the URLs come from the bucket itself and the shape is
/// generated, so the only thing left to get right is which file is which — and
/// even that is guessed from the file name and only needs correcting.
///
/// Pops the cell text, or null if nothing was chosen.
class GateAssetsScreen extends StatefulWidget {
  const GateAssetsScreen({
    super.key,
    required this.prefix,
    required this.credentials,
    required this.year,
    this.branchCode = '',
    this.initialValue = '',
  });

  /// The branch's folder, e.g. `vtu/gatepyqs/CS_Computer_Science_Engineering/`.
  final String prefix;

  final R2Credentials credentials;

  /// The column being filled in. Files named after another year are hidden
  /// behind a switch rather than dropped — a folder is not always tidy.
  final int year;

  final String branchCode;

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
  bool _showOtherYears = false;
  String? _error;

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

  /// Every file under the branch folder, at any depth: the folders inside it are
  /// somebody's filing (`2024/`, `keys/`), and which year a file is for is read
  /// off its name, not off where it sits.
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

  /// Files for this year: a file's name decides — `GATE_2024_CS.pdf`.
  ///
  /// The folder is checked first only because a path *could* carry a year
  /// segment; the three kind folders under a branch carry no year, so in
  /// practice every file falls through to the name. A file whose name carries no
  /// year stays visible, because it could be for any year and hiding it would
  /// leave the folder looking empty.
  List<R2Object> get _visible {
    if (_showOtherYears) return _objects;
    return [
      for (final object in _objects)
        if (gateYearFromKey(object.key) == widget.year ||
            (gateYearFromKey(object.key) == null &&
                (gateYearIn(object.name) == null ||
                    gateYearIn(object.name) == widget.year)))
          object,
    ];
  }

  int get _hiddenCount => _objects.length - _visible.length;

  void _toggle(R2Object object) {
    final url = widget.credentials.publicUrlFor(object.key);
    setState(() {
      if (_chosen.remove(url) != null) return;
      _chosen[url] = GateAsset(
        // A kind folder beats a guess from the file name: someone chose that
        // folder, whereas the name is just what the file happened to be called.
        // No such folder exists since the year tree came out, so in practice
        // every file falls back to the guess.
        kind: gateKindFromKey(object.key) ?? guessGateAssetKind(object.name),
        label: guessGateSessionLabel(object.name),
        url: url,
      );
    });
  }

  void _setKind(String url, GateAssetKind kind) {
    final asset = _chosen[url];
    if (asset == null) return;
    setState(() => _chosen[url] = asset.copyWith(kind: kind));
  }

  Future<void> _editLabel(String url) async {
    final asset = _chosen[url];
    if (asset == null) return;
    final controller = TextEditingController(text: asset.label);
    final label = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Session label'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Label',
                helperText: 'Shown to students when a year has more than one of '
                    'this kind. Leave empty if there is only one.',
                helperMaxLines: 3,
              ),
              onSubmitted: (value) => Navigator.pop(dialogContext, value),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                for (final suggestion in const ['Session 1', 'Session 2'])
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
        title: Text('GATE ${widget.year}'
            '${widget.branchCode.isEmpty ? '' : ' — ${widget.branchCode}'}'),
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
                // Saving nothing is legitimate: it is how a year that was filled
                // in by mistake gets cleared.
                onPressed: _loading ? null : _save,
                icon: const Icon(Icons.check),
                label: Text(chosen.isEmpty
                    ? 'Clear this year'
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
              ? const BusyView(label: 'Listing the branch folder…')
              : _objects.isEmpty && _external.isEmpty
                  ? EmptyView(
                      icon: Icons.folder_open_outlined,
                      title: 'Nothing in this folder yet',
                      subtitle: 'Upload the ${widget.year} papers to '
                          '${widget.prefix} from the Bucket screen, then come '
                          'back here.',
                    )
                  : ListView(
                      padding: const EdgeInsets.only(bottom: 24),
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                          child: Text(
                            'Tick the files for ${widget.year}. What each one is '
                            'is guessed from its name — tap the chips to '
                            'correct it.',
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                        if (_hiddenCount > 0 || _showOtherYears)
                          SwitchListTile(
                            value: _showOtherYears,
                            onChanged: (value) =>
                                setState(() => _showOtherYears = value),
                            dense: true,
                            title: const Text('Show files from other years'),
                            subtitle: Text(_showOtherYears
                                ? 'Showing everything in the folder'
                                : '$_hiddenCount hidden'),
                          ),
                        for (final object in _visible)
                          _FileTile(
                            object: object,
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
                              'Already in this year, but not in the bucket',
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
  });

  final R2Object object;
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
          subtitle: Text(object.readableSize),
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
