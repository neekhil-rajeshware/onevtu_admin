import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/admin_repository.dart';
import '../data/lookup_cache.dart';
import '../schema/field_spec.dart';
import '../schema/subject_names.dart';
import '../schema/table_spec.dart';
import 'record_editor_screen.dart';
import 'widgets/field_editor.dart';
import 'widgets/moderation_action.dart';
import 'widgets/push_action.dart';
import 'widgets/row_thumbnail.dart';
import 'widgets/state_views.dart';

/// The list of rows for one table: search, filter, page, tap to edit.
///
/// Like the editor there is one of these for the whole catalog — everything it
/// shows comes out of the [TableSpec].
class CollectionScreen extends StatefulWidget {
  const CollectionScreen({
    super.key,
    required this.spec,
    this.initialFilters = const {},
  });

  final TableSpec spec;

  /// Filters the screen opens already narrowed by, keyed on column name exactly
  /// as [FilterSpec.column] spells it — a key no filter declares is ignored by
  /// the chips but still sent to the query, so it has to match.
  ///
  /// Here for the push notice, which has to land on the pending queue rather than
  /// on every listing ever made. The chips show the seeded value, so it reads as
  /// a filter the admin could have set and can clear, not as a different screen.
  final Map<String, String> initialFilters;

  @override
  State<CollectionScreen> createState() => _CollectionScreenState();
}

class _CollectionScreenState extends State<CollectionScreen> {
  final _searchController = TextEditingController();
  final _scrollController = ScrollController();
  final List<Map<String, dynamic>> _rows = [];
  final Map<String, String> _filters = {};

  Timer? _debounce;
  int _page = 0;
  bool _hasMore = true;
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;

  TableSpec get _spec => widget.spec;

  /// Subject code to subject name, empty until it arrives — and only ever
  /// populated for a spec that asks for it. See [_loadSubjectNames].
  Map<String, String> _subjectNames = const {};

  @override
  void initState() {
    super.initState();
    _filters.addAll(widget.initialFilters);
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _load();
      _loadSubjectNames();
    });
  }

  /// Reads the subject names once for the screen, not once per reload.
  ///
  /// Deliberately not awaited by [_load]: the rows are what the screen is for,
  /// and a row renders fine without its subject's name — it gains one when this
  /// lands. A reload would otherwise re-read 221 subjects on every filter tap.
  ///
  /// A failure is logged and nothing else, so it looks exactly like the names
  /// still being on their way. That is allowed here and nowhere near the rows
  /// themselves: the code is the row's identity and is already on screen, so a
  /// missing name is a list without its gloss, not a list that is wrong.
  Future<void> _loadSubjectNames() async {
    if (_spec.subjectCodeColumns.isEmpty) return;
    try {
      final names = await context.read<AdminRepository>().subjectNames();
      if (!mounted) return;
      setState(() => _subjectNames = names);
    } catch (error) {
      debugPrint('Subject names could not be read: $error');
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    if (position.pixels > position.maxScrollExtent - 400) _loadMore();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _page = 0;
      _hasMore = true;
    });
    try {
      final rows = await context.read<AdminRepository>().fetch(
            _spec,
            search: _searchController.text,
            filters: _filters,
          );
      if (!mounted) return;
      setState(() {
        _rows
          ..clear()
          ..addAll(rows);
        _hasMore = rows.length == AdminRepository.pageSize;
        _loading = false;
      });
    } on AdminWriteException catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.hint == null
            ? error.message
            : '${error.message}\n\n${error.hint}';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load ${_spec.table}: $error';
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || _loading || !_hasMore) return;
    setState(() => _loadingMore = true);
    try {
      final rows = await context.read<AdminRepository>().fetch(
            _spec,
            search: _searchController.text,
            filters: _filters,
            page: _page + 1,
          );
      if (!mounted) return;
      setState(() {
        _page += 1;
        _rows.addAll(rows);
        _hasMore = rows.length == AdminRepository.pageSize;
        _loadingMore = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadingMore = false;
        _hasMore = false;
      });
      showToast(context, 'Could not load more: $error', isError: true);
    }
  }

  void _onSearchChanged(String _) {
    // Rebuild so the clear button appears as soon as there is text, then query
    // once the typing stops.
    setState(() {});
    _debounce?.cancel();
    // Long enough that typing a subject code doesn't fire five queries.
    _debounce = Timer(const Duration(milliseconds: 350), _load);
  }

  Future<void> _pickFilter(FilterSpec filter) async {
    final List<LookupOption> options;
    try {
      options = filter.lookup != null
          ? await context.read<LookupCache>().options(filter.lookup!)
          : (filter.options ?? const <String>[]).map(LookupOption.new).toList();
    } on LookupException catch (error) {
      if (mounted) {
        showToast(context, '$error Tap again to retry.', isError: true);
      }
      return;
    }
    if (!mounted) return;

    final picked = await chooseOption(
      context,
      title: filter.label,
      options: options,
      current: _filters[filter.column] ?? '',
    );
    if (picked == null) return;

    setState(() {
      if (picked.isEmpty) {
        _filters.remove(filter.column);
      } else {
        _filters[filter.column] = picked;
      }
    });
    await _load();
  }

  Future<void> _openEditor({Map<String, dynamic>? row}) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => RecordEditorScreen(spec: _spec, row: row),
      ),
    );
    if (changed == true) await _load();
  }

  String _titleFor(Map<String, dynamic> row) {
    final columns =
        _spec.titleColumns.isEmpty ? [_spec.primaryKey] : _spec.titleColumns;
    final parts = columns
        .map((c) => row[c]?.toString().trim() ?? '')
        .where((v) => v.isNotEmpty)
        .toList();
    if (parts.isEmpty) return '(untitled)';

    // The subject's name after its code, where the spec names code columns: a
    // code alone does not say which subject the row is. Appended only once the
    // index has arrived, so a row never flashes a dash on its way in; a code the
    // index does not know keeps the dash, which is how a mistyped code looks
    // wrong here instead of looking like a subject nobody has named.
    if (_subjectNames.isNotEmpty) {
      parts.add(subjectNameFor(_subjectNames, row, _spec.subjectCodeColumns) ??
          '—');
    }
    return parts.join(' · ');
  }

  String _subtitleFor(Map<String, dynamic> row) {
    final parts = <String>[];
    for (final column in _spec.subtitleColumns) {
      final value = row[column];
      if (value == null || value.toString().trim().isEmpty) continue;
      final label = _spec.fieldFor(column)?.label ?? column;
      parts.add('$label: $value');
    }
    return parts.join('   ');
  }

  /// True when at least one link column on this row is filled — the fastest way
  /// to see which subjects already have a syllabus attached.
  bool _hasFile(Map<String, dynamic> row) {
    for (final field in _spec.fields) {
      if (field.type != FieldType.fileUrl) continue;
      final value = row[field.column];
      if (value != null && value.toString().trim().isNotEmpty) return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasFileColumns =
        _spec.fields.any((f) => f.type == FieldType.fileUrl);

    return Scaffold(
      appBar: AppBar(
        title: Text(_spec.title),
        bottom: PreferredSize(
          preferredSize: Size.fromHeight(_spec.filters.isEmpty ? 62 : 108),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
                child: TextField(
                  controller: _searchController,
                  onChanged: _onSearchChanged,
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: _spec.searchColumns.isEmpty
                        ? 'Search is off for this table'
                        : 'Search ${_spec.searchColumns.join(', ')}',
                    prefixIcon: const Icon(Icons.search, size: 18),
                    suffixIcon: _searchController.text.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.clear, size: 18),
                            onPressed: () {
                              _searchController.clear();
                              _load();
                            },
                          ),
                  ),
                  enabled: _spec.searchColumns.isNotEmpty,
                ),
              ),
              if (_spec.filters.isNotEmpty)
                SizedBox(
                  height: 46,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                    children: [
                      for (final filter in _spec.filters) ...[
                        FilterChip(
                          label: Text(_filters[filter.column] == null
                              ? filter.label
                              : '${filter.label}: ${_filters[filter.column]}'),
                          selected: _filters.containsKey(filter.column),
                          onSelected: (_) => _pickFilter(filter),
                        ),
                        const SizedBox(width: 8),
                      ],
                      if (_filters.isNotEmpty)
                        ActionChip(
                          avatar: const Icon(Icons.clear, size: 15),
                          label: const Text('Clear'),
                          onPressed: () {
                            setState(_filters.clear);
                            _load();
                          },
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
      floatingActionButton: _spec.canCreate
          ? FloatingActionButton.extended(
              onPressed: () => _openEditor(),
              icon: const Icon(Icons.add),
              label: const Text('Add'),
            )
          : null,
      body: _error != null
          ? ErrorView(message: _error!, onRetry: _load)
          : _loading
              ? const BusyView(label: 'Loading…')
              : RefreshIndicator(
                  onRefresh: _load,
                  child: _rows.isEmpty
                      ? ListView(
                          children: [
                            SizedBox(
                              height: 360,
                              child: EmptyView(
                                icon: _spec.icon,
                                title: _searchController.text.isEmpty &&
                                        _filters.isEmpty
                                    ? 'No rows yet'
                                    : 'Nothing matches',
                                subtitle: _searchController.text.isEmpty &&
                                        _filters.isEmpty
                                    ? _spec.description
                                    : 'Try a different search or clear the '
                                        'filters.',
                              ),
                            ),
                          ],
                        )
                      : ListView.separated(
                          controller: _scrollController,
                          padding: const EdgeInsets.only(bottom: 96),
                          itemCount: _rows.length + (_hasMore ? 1 : 0),
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (context, index) {
                            if (index >= _rows.length) {
                              return const Padding(
                                padding: EdgeInsets.symmetric(vertical: 22),
                                child: Center(
                                  child: SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2.2),
                                  ),
                                ),
                              );
                            }

                            final row = _rows[index];
                            final subtitle = _subtitleFor(row);
                            final thumbnail = _spec.thumbnailColumn;
                            return ListTile(
                              // Only where the spec names a picture column, so
                              // every other table keeps its tighter rows.
                              leading: thumbnail == null
                                  ? null
                                  : RowThumbnail(
                                      url: row[thumbnail]?.toString() ?? '',
                                      title: _titleFor(row),
                                    ),
                              title: Text(_titleFor(row)),
                              subtitle: subtitle.isEmpty
                                  ? null
                                  : Text(subtitle,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis),
                              // Sending is the one action worth reaching without
                              // opening the row, so on announcements it takes the
                              // trailing slot outright — and on the store queue,
                              // so is deciding.
                              trailing: _spec.canSendPush
                                  ? PushSendButton(row: row, onSent: _load)
                                  : _spec.canModerate
                                      ? ModerationAction(
                                          spec: _spec,
                                          row: row,
                                          onReviewed: _load,
                                        )
                                      : hasFileColumns
                                          ? Icon(
                                              _hasFile(row)
                                                  ? Icons.attach_file
                                                  : Icons.link_off,
                                              size: 16,
                                              color: _hasFile(row)
                                                  ? theme.colorScheme.primary
                                                  : theme.disabledColor,
                                            )
                                          : const Icon(Icons.chevron_right,
                                              size: 18),
                              onTap: () => _openEditor(row: row),
                            );
                          },
                        ),
                ),
    );
  }
}
