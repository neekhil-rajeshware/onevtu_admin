import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/admin_repository.dart';
import '../data/lookup_cache.dart';
import '../r2/archive.dart';
import '../r2/bucket_layout.dart';
import '../r2/r2_client.dart';
import '../r2/r2_credentials.dart';
import '../r2/upload_flow.dart';
import '../schema/catalog.dart';
import '../schema/field_spec.dart';
import 'r2_settings_screen.dart';
import 'widgets/state_views.dart';

/// The Cloudflare R2 half of the console: browse, upload, replace, delete.
///
/// In [pickMode] it is the same screen with one difference — tapping a file pops
/// with its public URL, which is how a `syllabus_link` gets filled in from an
/// object that already exists.
class BucketScreen extends StatefulWidget {
  const BucketScreen({
    super.key,
    this.pickMode = false,
    this.initialPrefix = '',
  });

  final bool pickMode;
  final String initialPrefix;

  @override
  State<BucketScreen> createState() => _BucketScreenState();
}

class _BucketScreenState extends State<BucketScreen> {
  R2Client? _client;
  String _clientKey = '';

  late String _prefix;
  final List<String> _folders = [];
  final List<R2Object> _objects = [];
  String? _nextToken;

  bool _loading = false;
  bool _loadingMore = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _prefix = widget.initialPrefix;
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _client?.dispose();
    super.dispose();
  }

  /// One client per set of credentials, rebuilt if they are edited mid-session
  /// so a corrected secret takes effect without leaving the screen.
  R2Client? _resolveClient() {
    final credentials = context.read<R2CredentialStore>().credentials;
    if (!credentials.isComplete) return null;
    final key = '${credentials.accountId}|${credentials.accessKeyId}|'
        '${credentials.secretAccessKey}|${credentials.bucket}';
    if (_client == null || _clientKey != key) {
      _client?.dispose();
      _client = R2Client(credentials);
      _clientKey = key;
    }
    return _client;
  }

  Future<void> _load() async {
    final client = _resolveClient();
    if (client == null) {
      setState(() {
        _loading = false;
        _error = null;
        _folders.clear();
        _objects.clear();
      });
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final listing = await client.list(prefix: _prefix);
      if (!mounted) return;
      setState(() {
        _folders
          ..clear()
          ..addAll(listing.prefixes);
        _objects
          ..clear()
          ..addAll(listing.objects);
        _nextToken = listing.nextToken;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error is R2Exception ? '$error' : 'Could not list the bucket: $error';
      });
    }
  }

  Future<void> _loadMore() async {
    final client = _client;
    final token = _nextToken;
    if (client == null || token == null || _loadingMore) return;

    setState(() => _loadingMore = true);
    try {
      final listing =
          await client.list(prefix: _prefix, continuationToken: token);
      if (!mounted) return;
      setState(() {
        _folders.addAll(listing.prefixes);
        _objects.addAll(listing.objects);
        _nextToken = listing.nextToken;
        _loadingMore = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
      showToast(context, '$error', isError: true);
    }
  }

  void _openFolder(String prefix) {
    setState(() => _prefix = prefix);
    _load();
  }

  /// Up one level. Returns false when already at the root, which is the signal
  /// to let the back gesture close the screen.
  bool _goUp() {
    if (_prefix.isEmpty) return false;
    final trimmed =
        _prefix.endsWith('/') ? _prefix.substring(0, _prefix.length - 1) : _prefix;
    final slash = trimmed.lastIndexOf('/');
    _openFolder(slash == -1 ? '' : trimmed.substring(0, slash + 1));
    return true;
  }

  Future<void> _upload() async {
    final client = _resolveClient();
    if (client == null) {
      await _openSettings();
      return;
    }
    final result = await pickAndUploadToR2(context, client: client, prefix: _prefix);
    if (result == null) return;
    if (widget.pickMode && mounted) {
      Navigator.pop(context, result.url);
      return;
    }
    await _load();
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const R2SettingsScreen()),
    );
    if (mounted) await _load();
  }

  /// Creates a folder here and opens it, which is the only reason to want one:
  /// somewhere to upload the next batch of files into.
  ///
  /// The name is usually one the layout already knows — see [_askForFolderName] —
  /// and a semester folder brings its `py_qp/` and `deleted_old_files/` with it, so
  /// the tree is right the first time rather than after the first upload.
  Future<void> _newFolder() async {
    final client = _resolveClient();
    if (client == null) {
      await _openSettings();
      return;
    }

    final name = await _askForFolderName();
    if (name == null || name.isEmpty || !mounted) return;
    final prefix = '$_prefix$name/';

    try {
      // A folder that already has files in it is not created again — that would
      // add a redundant marker next to them.
      if (_folders.contains(prefix) || await client.exists(prefix)) {
        if (mounted) showToast(context, '$name is already there');
        return;
      }
      await client.createFolder(prefix);
      for (final child in requiredChildrenOf(prefix)) {
        await client.createFolder('$prefix$child/');
      }
    } catch (error) {
      if (mounted) showToast(context, '$error', isError: true);
      return;
    }

    if (!mounted) return;
    showToast(context, 'Created $name');
    _openFolder(prefix);
  }

  /// One name, sanitized the same way an uploaded file's is. Slashes are allowed
  /// and make the whole nested path in one go.
  ///
  /// The names the layout expects here are offered as chips, because this is where
  /// the structure is either followed or quietly broken: `AE_Aeronautical_Engineering`
  /// typed by hand from a phone keyboard is one wrong underscore away from a second
  /// folder for the same branch.
  Future<String?> _askForFolderName() async {
    final suggestions = await _suggestedFolders();
    if (!mounted) return null;

    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('New folder'),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Inside ${_prefix.isEmpty ? 'the bucket root' : _prefix}',
                style: Theme.of(dialogContext).textTheme.bodySmall,
              ),
              if (suggestions.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  'The layout expects',
                  style: Theme.of(dialogContext).textTheme.labelLarge,
                ),
                const SizedBox(height: 4),
                // Bounded, because a branch list is thirty long.
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 220),
                  child: SingleChildScrollView(
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        for (final name in suggestions)
                          ActionChip(
                            label: Text(name),
                            onPressed: () => Navigator.pop(dialogContext, name),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                decoration: const InputDecoration(
                  labelText: 'Or another name',
                  helperText: 'a/b makes both levels. Capitals and spaces are '
                      'kept — the bucket uses them.',
                  helperMaxLines: 2,
                ),
                onSubmitted: (value) =>
                    Navigator.pop(dialogContext, _folderPath(value)),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, _folderPath(controller.text)),
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }

  /// What belongs inside the folder being looked at, minus what is already there.
  ///
  /// Scheme and branch folders are named from the database, so a branch added last
  /// week is offered without editing any code. A lookup that will not load leaves
  /// the list shorter rather than blocking the dialog.
  Future<List<String>> _suggestedFolders() async {
    final cache = context.read<LookupCache>();
    Future<List<LookupOption>> optionsOf(Lookup lookup) async {
      try {
        return await cache.options(lookup);
      } on LookupException {
        return const [];
      }
    }

    final schemes = await optionsOf(schemeLookup);
    final branches = await optionsOf(branchLookup);
    return [
      ...standardChildrenOf(
        _prefix,
        schemeNames: schemes.map((option) => option.label ?? option.value),
        branches: {
          for (final option in branches) option.value: option.label ?? '',
        },
      ),
    ]..removeWhere((name) => _folders.contains('$_prefix$name/'));
  }

  /// Every segment cleaned the way a file name is: only what would break a URL is
  /// taken out, so `AE_Aeronautical_Engineering` survives being typed by hand.
  static String _folderPath(String typed) => typed
      .split('/')
      .map((segment) => segment.trim())
      .where((segment) => segment.isNotEmpty)
      .map(sanitizeKeySegment)
      .join('/');

  /// Deletes a folder and everything under it, recursively — the one operation
  /// here that can break hundreds of rows at once, so it counts first and says
  /// what it found before doing anything.
  Future<void> _deleteFolder(String folder) async {
    final client = _client;
    if (client == null) return;

    final counting = showProgressBarrier(context, 'Counting what is in there…');
    final List<R2Object> contents;
    try {
      contents = await client.objectsUnder(folder);
    } catch (error) {
      counting.dismiss();
      if (mounted) showToast(context, '$error', isError: true);
      return;
    }
    counting.dismiss();
    if (!mounted) return;

    final files = contents.where((o) => !isFolderMarker(o.key)).toList();
    final bytes = files.fold<int>(0, (sum, o) => sum + o.size);
    final permanent = isInArchive(folder);
    final name = _folderLabel(folder);

    final confirmed = await confirmDestructive(
      context,
      title: files.isEmpty ? 'Delete this empty folder?' : 'Delete $name?',
      message: [
        if (files.isEmpty)
          '$folder has no files in it.'
        else
          '${files.length} ${files.length == 1 ? 'file' : 'files'}'
              ' (${formatBytes(bytes)}) under $folder.',
        if (files.isNotEmpty)
          permanent
              // The archive is the one folder whose deletion is real.
              ? 'These are already archived copies, so this is permanent.'
              : 'They are moved to $archiveFolderName/ rather than destroyed, but '
                  'their public links stop working straight away — any row still '
                  'pointing at one will break.',
        if (files.isNotEmpty) ...[
          for (final file in files.take(3)) '· ${file.name}',
          if (files.length > 3) '· and ${files.length - 3} more',
        ],
      ].join('\n'),
      confirmLabel: files.isEmpty
          ? 'Delete'
          : 'Delete ${files.length} ${files.length == 1 ? 'file' : 'files'}',
    );
    if (!confirmed || !mounted) return;

    final keys = contents.map((o) => o.key).toList();
    final progress = showProgressBarrier(context, 'Deleting 1 of ${keys.length}…');
    try {
      await archiveAndDelete(
        client,
        keys: keys,
        onProgress: (done, total) {
          if (done < total) progress.label = 'Deleting ${done + 1} of $total…';
        },
      );
    } catch (error) {
      progress.dismiss();
      if (mounted) {
        // Part of it is gone: the count is not worth guessing at, so the listing
        // is reloaded and shows exactly what survived.
        showToast(context, 'Stopped part way: $error', isError: true);
        await _load();
      }
      return;
    }
    progress.dismiss();
    if (!mounted) return;
    showToast(context, permanent ? 'Deleted $name' : 'Moved $name to $archiveFolderName/');
    await _load();
  }

  Future<void> _delete(R2Object object) async {
    final client = _client;
    if (client == null) return;
    final permanent = isInArchive(object.key);
    final confirmed = await confirmDestructive(
      context,
      title: 'Delete this file?',
      message: permanent
          ? '${object.key} is an archived copy, so this removes it for good.'
          : '${object.key} is moved to $archiveFolderName/ rather than destroyed, but '
              'its public link stops working straight away. Any row still '
              'pointing at that link will break — check the database first if '
              'you are not sure.',
    );
    if (!confirmed || !mounted) return;

    final progress = showProgressBarrier(context, 'Deleting…');
    try {
      await archiveAndDelete(client, keys: [object.key]);
      progress.dismiss();
      if (!mounted) return;
      showToast(
        context,
        permanent
            ? 'Deleted ${object.name}'
            : 'Moved ${object.name} to $archiveFolderName/',
      );
      await _load();
    } catch (error) {
      progress.dismiss();
      if (mounted) showToast(context, '$error', isError: true);
    }
  }



  Future<void> _openObject(R2Object object) async {
    final credentials = context.read<R2CredentialStore>().credentials;
    final url = credentials.publicUrlFor(object.key);

    if (widget.pickMode) {
      Navigator.pop(context, url);
      return;
    }

    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            ListTile(
              title: Text(object.name),
              subtitle: Text(
                '${object.readableSize}  ·  ${object.key}',
                maxLines: 2,
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.copy_outlined),
              title: const Text('Copy public link'),
              onTap: () {
                Clipboard.setData(ClipboardData(text: url));
                Navigator.pop(sheetContext);
                showToast(context, 'Link copied');
              },
            ),
            ListTile(
              leading: const Icon(Icons.open_in_new),
              title: const Text('Open'),
              onTap: () async {
                Navigator.pop(sheetContext);
                final uri = Uri.tryParse(url);
                if (uri != null) {
                  await launchUrl(uri, mode: LaunchMode.externalApplication);
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.upload_file_outlined),
              title: const Text('Replace with a new file'),
              subtitle: const Text('Keeps the same link'),
              onTap: () async {
                Navigator.pop(sheetContext);
                await _replace(object);
              },
            ),
            ListTile(
              leading: Icon(Icons.delete_outline,
                  color: Theme.of(context).colorScheme.error),
              title: const Text('Delete'),
              onTap: () async {
                Navigator.pop(sheetContext);
                await _delete(object);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// Uploads over an existing key, so every row already linking to it picks up
  /// the new file without a single database edit. The file it displaces is kept
  /// in the archive folder by the upload itself.
  Future<void> _replace(R2Object object) async {
    final client = _client;
    if (client == null) return;
    final result = await pickAndUploadToR2(
      context,
      client: client,
      suggestedKey: object.key,
    );
    if (result != null) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final credentials = context.watch<R2CredentialStore>().credentials;
    final theme = Theme.of(context);

    return PopScope(
      canPop: _prefix.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _goUp();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.pickMode ? 'Pick a file' : 'Bucket'),
          actions: [
            // Not while picking a file: that trip is about choosing one, and a
            // half-made folder is not a choice.
            if (credentials.isComplete && !widget.pickMode)
              IconButton(
                tooltip: 'New folder',
                onPressed: _loading ? null : _newFolder,
                icon: const Icon(Icons.create_new_folder_outlined),
              ),
            IconButton(
              tooltip: 'R2 keys',
              onPressed: _openSettings,
              icon: const Icon(Icons.key_outlined),
            ),
            IconButton(
              tooltip: 'Refresh',
              onPressed: _loading ? null : _load,
              icon: const Icon(Icons.refresh),
            ),
          ],
          bottom: credentials.isComplete
              ? PreferredSize(
                  preferredSize: const Size.fromHeight(38),
                  child: _Breadcrumb(
                    bucket: credentials.bucket,
                    prefix: _prefix,
                    onNavigate: _openFolder,
                  ),
                )
              : null,
        ),
        floatingActionButton: credentials.isComplete
            ? FloatingActionButton.extended(
                onPressed: _upload,
                icon: const Icon(Icons.upload_file),
                label: const Text('Upload'),
              )
            : null,
        body: !credentials.isComplete
            ? EmptyView(
                icon: Icons.key_off_outlined,
                title: 'No R2 keys yet',
                subtitle: 'Add the account id and an API token with Object Read '
                    '& Write, and this becomes a file manager for the bucket.',
                action: FilledButton(
                  onPressed: _openSettings,
                  child: const Text('Add keys'),
                ),
              )
            : _error != null
                ? ErrorView(message: _error!, onRetry: _load)
                : _loading
                    ? const BusyView(label: 'Listing the bucket…')
                    : RefreshIndicator(
                        onRefresh: _load,
                        child: _folders.isEmpty && _objects.isEmpty
                            ? ListView(
                                children: [
                                  SizedBox(
                                    height: 380,
                                    child: EmptyView(
                                      icon: Icons.folder_open_outlined,
                                      title: _prefix.isEmpty
                                          ? 'The bucket is empty'
                                          : 'Nothing in this folder',
                                      subtitle: widget.pickMode
                                          ? 'Upload a file to get started.'
                                          : 'Upload a file, or make a folder '
                                              'with the icon in the top bar.',
                                    ),
                                  ),
                                ],
                              )
                            : ListView.separated(
                                padding: const EdgeInsets.only(bottom: 96),
                                itemCount: _folders.length +
                                    _objects.length +
                                    (_nextToken != null ? 1 : 0),
                                separatorBuilder: (_, _) =>
                                    const Divider(height: 1),
                                itemBuilder: (context, index) {
                                  if (index < _folders.length) {
                                    final folder = _folders[index];
                                    return ListTile(
                                      leading: const Icon(Icons.folder_outlined),
                                      title: Text(_folderLabel(folder)),
                                      trailing: widget.pickMode
                                          ? const Icon(Icons.chevron_right,
                                              size: 18)
                                          : IconButton(
                                              tooltip: 'Delete folder',
                                              icon: Icon(
                                                Icons.delete_outline,
                                                size: 20,
                                                color: theme.colorScheme.error,
                                              ),
                                              onPressed: () =>
                                                  _deleteFolder(folder),
                                            ),
                                      onTap: () => _openFolder(folder),
                                    );
                                  }

                                  final fileIndex = index - _folders.length;
                                  if (fileIndex < _objects.length) {
                                    final object = _objects[fileIndex];
                                    return ListTile(
                                      leading: Icon(_iconFor(object.name),
                                          color: theme.colorScheme.primary),
                                      title: Text(object.name),
                                      subtitle: Text(object.readableSize),
                                      trailing: Icon(
                                        widget.pickMode
                                            ? Icons.check_circle_outline
                                            : Icons.more_horiz,
                                        size: 18,
                                      ),
                                      onTap: () => _openObject(object),
                                    );
                                  }

                                  return Padding(
                                    padding: const EdgeInsets.all(16),
                                    child: OutlinedButton(
                                      onPressed: _loadingMore ? null : _loadMore,
                                      child: Text(_loadingMore
                                          ? 'Loading…'
                                          : 'Load more files'),
                                    ),
                                  );
                                },
                              ),
                      ),
      ),
    );
  }

  static String _folderLabel(String prefix) {
    final trimmed =
        prefix.endsWith('/') ? prefix.substring(0, prefix.length - 1) : prefix;
    final slash = trimmed.lastIndexOf('/');
    return slash == -1 ? trimmed : trimmed.substring(slash + 1);
  }

  static IconData _iconFor(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.pdf')) return Icons.picture_as_pdf_outlined;
    if (lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.webp')) {
      return Icons.image_outlined;
    }
    if (lower.endsWith('.mp4') || lower.endsWith('.webm')) {
      return Icons.movie_outlined;
    }
    return Icons.insert_drive_file_outlined;
  }
}

/// bucket / folder / folder — every crumb tappable.
class _Breadcrumb extends StatelessWidget {
  const _Breadcrumb({
    required this.bucket,
    required this.prefix,
    required this.onNavigate,
  });

  final String bucket;
  final String prefix;
  final ValueChanged<String> onNavigate;

  @override
  Widget build(BuildContext context) {
    final parts = prefix
        .split('/')
        .where((p) => p.isNotEmpty)
        .toList();
    final style = Theme.of(context).textTheme.bodySmall;

    return Align(
      alignment: Alignment.centerLeft,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        reverse: true,
        child: Row(
          children: [
            InkWell(
              onTap: () => onNavigate(''),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                child: Text(bucket, style: style),
              ),
            ),
            for (var i = 0; i < parts.length; i++) ...[
              Text('/', style: style),
              InkWell(
                onTap: () => onNavigate('${parts.take(i + 1).join('/')}/'),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                  child: Text(parts[i], style: style),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
