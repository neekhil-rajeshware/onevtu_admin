import 'package:flutter/material.dart';

import '../r2/r2_client.dart';
import '../r2/r2_credentials.dart';
import '../r2/upload_flow.dart';
import '../schema/named_documents.dart';
import 'widgets/state_views.dart';

/// Builds one `notes_link` / `study_materials` cell by ticking files in the
/// folder the row's own scheme, semester and subject point at.
///
/// The alternative is typing the JSON by hand, which on a phone is how a link
/// ends up with a `%20` in the middle of it. Here the URLs come from the bucket
/// itself and the shape is generated, so the only thing left to decide is what
/// each file should be called — and that is guessed from its name and only needs
/// correcting.
///
/// The files can also be uploaded from here, which is the point of this screen
/// over the GATE one: a subject with five sets of notes is five uploads, and
/// making somebody do those on the Bucket screen and then come back is how a
/// folder ends up half-filled.
///
/// Pops the cell text, or null if nothing was chosen.
class DocumentsScreen extends StatefulWidget {
  const DocumentsScreen({
    super.key,
    required this.prefix,
    required this.credentials,
    required this.title,
    this.initialValue = '',
    this.fallbackName = 'Document',
  });

  /// The folder this row's files belong in, e.g.
  /// `vtu/scheme-2025/AE_…/3rd_sem/notes/1BAE305 Introduction to UAV Systems/`.
  final String prefix;

  final R2Credentials credentials;

  /// What the column is called, e.g. `Notes`. Used as the screen title.
  final String title;

  /// What the column holds now. Files already listed come back ticked, and links
  /// that are not in the bucket (a Drive URL from before R2) are kept as they
  /// are — this screen must never be the reason one disappears.
  final String initialValue;

  /// What an entry the cell left unnamed is called, so a subject with three of
  /// them does not show three identical buttons. See `parseNamedDocuments`.
  final String fallbackName;

  @override
  State<DocumentsScreen> createState() => _DocumentsScreenState();
}

class _DocumentsScreenState extends State<DocumentsScreen> {
  R2Client? _client;

  final List<R2Object> _objects = [];

  /// URL → what it was chosen as. Keyed by URL so a file already in the cell and
  /// the same file in the listing are one entry, not two.
  final Map<String, NamedDocument> _chosen = {};

  /// Documents from [DocumentsScreen.initialValue] that no listed file matches —
  /// links to somewhere other than this bucket, or files since moved.
  final List<NamedDocument> _external = [];

  bool _loading = true;
  bool _uploading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _client = R2Client(widget.credentials);
    for (final document in parseNamedDocuments(
      widget.initialValue,
      fallbackName: widget.fallbackName,
    )) {
      _chosen[document.url] = document;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _client?.dispose();
    super.dispose();
  }

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

  /// Uploads straight into this row's folder and ticks what lands, so the file
  /// just added is published by the same Save as everything else on screen.
  Future<void> _upload() async {
    final client = _client;
    if (client == null) return;
    setState(() => _uploading = true);
    try {
      final result = await pickAndUploadToR2(
        context,
        client: client,
        prefix: widget.prefix,
      );
      if (result == null || !mounted) return;
      setState(() {
        _chosen[result.url] = NamedDocument(
          // The bucket key, not the picked file's own name: the key is what was
          // written down and what will be listed back.
          name: guessDocumentName(result.key.split('/').last),
          url: result.url,
        );
      });
      await _load();
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  void _toggle(R2Object object) {
    final url = widget.credentials.publicUrlFor(object.key);
    setState(() {
      if (_chosen.remove(url) != null) return;
      _chosen[url] = NamedDocument(
        name: guessDocumentName(object.name),
        url: url,
      );
    });
  }

  Future<void> _editName(String url) async {
    final document = _chosen[url];
    if (document == null) return;
    final controller = TextEditingController(text: document.name);
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Name'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: controller,
              autofocus: true,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                labelText: 'Name',
                helperText: 'What the student sees on the button.',
                helperMaxLines: 2,
              ),
              onSubmitted: (value) => Navigator.pop(dialogContext, value),
            ),
            const SizedBox(height: 12),
            Text(
              document.url,
              style: Theme.of(dialogContext).textTheme.bodySmall,
              maxLines: 3,
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
    if (name == null || !mounted) return;
    // An empty name is allowed and means "call it whatever you like": the
    // student app numbers those by position.
    setState(() => _chosen[url] = document.copyWith(name: name.trim()));
  }

  /// In the order the bucket lists them, so the folder and the form agree. Links
  /// that are not in the bucket keep their place at the end.
  List<NamedDocument> get _result => [
        for (final object in _objects)
          ?_chosen[widget.credentials.publicUrlFor(object.key)],
        ..._external,
      ];

  void _save() => Navigator.pop(context, encodeNamedDocuments(_result));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final chosen = _result;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            tooltip: 'Upload into this folder',
            onPressed: _loading || _uploading ? null : _upload,
            icon: const Icon(Icons.upload_file_outlined),
          ),
          IconButton(
            tooltip: 'Refresh',
            onPressed: _loading || _uploading ? null : _load,
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
                // Saving nothing is legitimate: it is how a row that was filled
                // in by mistake gets cleared.
                onPressed: _loading || _uploading ? null : _save,
                icon: const Icon(Icons.check),
                label: Text(chosen.isEmpty
                    ? 'Clear these files'
                    : 'Use ${chosen.length} '
                        '${chosen.length == 1 ? 'file' : 'files'}'),
              ),
            ],
          ),
        ),
      ),
      body: _uploading
          ? const BusyView(label: 'Uploading…')
          : _error != null
              ? ErrorView(message: _error!, onRetry: _load)
              : _loading
                  ? const BusyView(label: 'Listing the folder…')
                  : _objects.isEmpty && _external.isEmpty
                      ? EmptyView(
                          icon: Icons.folder_open_outlined,
                          title: 'Nothing in this folder yet',
                          subtitle: 'Upload the files with the button at the '
                              'top right — they go straight into '
                              '${widget.prefix} and are ticked for you.',
                        )
                      : ListView(
                          padding: const EdgeInsets.only(bottom: 24),
                          children: [
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                              child: Text(
                                'Tick the files that belong to this row. What '
                                'each one is called is guessed from its name — '
                                'tap the name to correct it.',
                                style: theme.textTheme.bodySmall,
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                              child: Text(
                                widget.prefix,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  fontFamily: 'monospace',
                                ),
                              ),
                            ),
                            for (final object in _objects)
                              _FileTile(
                                object: object,
                                document: _chosen[widget.credentials
                                    .publicUrlFor(object.key)],
                                onToggle: () => _toggle(object),
                                onName: () => _editName(
                                    widget.credentials.publicUrlFor(object.key)),
                              ),
                            if (_external.isNotEmpty) ...[
                              const Divider(height: 24),
                              Padding(
                                padding:
                                    const EdgeInsets.fromLTRB(16, 0, 16, 4),
                                child: Text(
                                  'Already on this row, but not in the folder',
                                  style: theme.textTheme.labelLarge,
                                ),
                              ),
                              Padding(
                                padding:
                                    const EdgeInsets.fromLTRB(16, 0, 16, 8),
                                child: Text(
                                  'Kept as they are — a link from before R2, or '
                                  'a file since moved. Remove one only if it is '
                                  'dead.',
                                  style: theme.textTheme.bodySmall,
                                ),
                              ),
                              for (final document in _external)
                                ListTile(
                                  leading: const Icon(Icons.link),
                                  title: Text(document.name),
                                  subtitle:
                                      Text(document.url, maxLines: 2),
                                  trailing: IconButton(
                                    tooltip: 'Remove',
                                    icon: Icon(
                                      Icons.close,
                                      size: 18,
                                      color: theme.colorScheme.error,
                                    ),
                                    onPressed: () => setState(() {
                                      _external.remove(document);
                                      _chosen.remove(document.url);
                                    }),
                                  ),
                                ),
                            ],
                          ],
                        ),
    );
  }

  static String _summary(List<NamedDocument> documents) {
    if (documents.isEmpty) return 'Nothing chosen — saving empties this column.';
    return documents.map((document) => document.name).join('   ·   ');
  }
}

/// One bucket file: a checkbox, and once ticked the one thing about it the
/// generated JSON needs.
class _FileTile extends StatelessWidget {
  const _FileTile({
    required this.object,
    required this.document,
    required this.onToggle,
    required this.onName,
  });

  final R2Object object;
  final NamedDocument? document;
  final VoidCallback onToggle;
  final VoidCallback onName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final chosen = document;

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
            child: ActionChip(
              avatar: const Icon(Icons.label_outline, size: 16),
              label: Text(
                chosen.name.isEmpty ? 'No name — numbered for you' : chosen.name,
              ),
              onPressed: onName,
            ),
          ),
        Divider(height: 1, color: theme.dividerColor),
      ],
    );
  }
}
