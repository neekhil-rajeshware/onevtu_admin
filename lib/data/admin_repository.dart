import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../schema/field_spec.dart';
import '../schema/gate_assets.dart';
import '../schema/named_documents.dart';
import '../schema/table_spec.dart';

/// One dropdown option.
class LookupOption {
  const LookupOption(this.value, [this.label]);

  final String value;
  final String? label;

  String get display =>
      (label == null || label!.isEmpty || label == value) ? value : '$value — $label';
}

/// A friendlier error than PostgREST's own wording for the two failures this app
/// can actually produce.
class AdminWriteException implements Exception {
  AdminWriteException(this.message, {this.hint});

  final String message;
  final String? hint;

  @override
  String toString() => hint == null ? message : '$message\n$hint';
}

/// Generic CRUD over any [TableSpec]. There is one of these for the whole app;
/// nothing here knows the name of a single table.
class AdminRepository {
  AdminRepository(this._client);

  final SupabaseClient _client;

  static const int pageSize = 40;

  /// One page of rows, filtered and searched.
  Future<List<Map<String, dynamic>>> fetch(
    TableSpec spec, {
    String search = '',
    Map<String, String> filters = const {},
    int page = 0,
  }) async {
    // Always `*`: some columns are named like numbers (`gatepyqs."2014"`) and an
    // explicit select list would have to quote them.
    var query = _client.from(spec.table).select();

    for (final entry in filters.entries) {
      if (entry.value.isEmpty) continue;
      query = query.eq(entry.key, entry.value);
    }

    final term = _sanitizeSearch(search);
    if (term.isNotEmpty && spec.searchColumns.isNotEmpty) {
      query = query.or(
        spec.searchColumns.map((c) => '$c.ilike.%$term%').join(','),
      );
    }

    final from = page * pageSize;
    try {
      return await query
          .order(spec.orderBy ?? spec.primaryKey, ascending: spec.ascending)
          .range(from, from + pageSize - 1);
    } on PostgrestException catch (error) {
      throw AdminWriteException(error.message, hint: _hintFor(error));
    }
  }

  /// Row count for the dashboard. Cosmetic, so a failure returns null rather
  /// than breaking the screen.
  Future<int?> count(TableSpec spec) async {
    try {
      return await _client.from(spec.table).count(CountOption.exact);
    } catch (_) {
      return null;
    }
  }

  /// One row, fresh. Used after something outside the form writes to it — a
  /// push records its topic, its timestamp and any error on the row itself, and
  /// none of that is worth seeing unless it is re-read.
  Future<Map<String, dynamic>?> fetchOne(
    TableSpec spec,
    Object primaryKeyValue,
  ) async {
    try {
      return await _client
          .from(spec.table)
          .select()
          .eq(spec.primaryKey, primaryKeyValue)
          .maybeSingle();
    } on PostgrestException catch (error) {
      throw AdminWriteException(error.message, hint: _hintFor(error));
    }
  }

  Future<Map<String, dynamic>?> insert(
    TableSpec spec,
    Map<String, dynamic> values,
  ) async {
    final payload = Map<String, dynamic>.from(values);
    // A generated key must not be sent: `subjects.id` is GENERATED ALWAYS and
    // rejects an explicit value.
    if (spec.primaryKeyIsGenerated) payload.remove(spec.primaryKey);
    try {
      return await _client.from(spec.table).insert(payload).select().maybeSingle();
    } on PostgrestException catch (error) {
      throw AdminWriteException(error.message, hint: _hintFor(error));
    }
  }

  Future<Map<String, dynamic>?> update(
    TableSpec spec,
    Object primaryKeyValue,
    Map<String, dynamic> values,
  ) async {
    final payload = Map<String, dynamic>.from(values)..remove(spec.primaryKey);
    if (payload.isEmpty) return null;
    try {
      return await _client
          .from(spec.table)
          .update(payload)
          .eq(spec.primaryKey, primaryKeyValue)
          .select()
          .maybeSingle();
    } on PostgrestException catch (error) {
      throw AdminWriteException(error.message, hint: _hintFor(error));
    }
  }

  Future<void> delete(TableSpec spec, Object primaryKeyValue) async {
    try {
      await _client
          .from(spec.table)
          .delete()
          .eq(spec.primaryKey, primaryKeyValue);
    } on PostgrestException catch (error) {
      throw AdminWriteException(error.message, hint: _hintFor(error));
    }
  }

  /// Dropdown options, either rows of a reference table or the distinct values
  /// already present in a column.
  /// The subject name behind a subject code, or null when nothing matches.
  ///
  /// A `py_qp` row names the subject only by code, and the bucket files papers
  /// under `py_qp/<code> <name>/` — so the folder cannot be worked out from the
  /// row alone. Cached for the session: the same subject is uploaded to twenty
  /// times, once per exam session.
  Future<String?> subjectNameForCode(String code, {String schemeCode = ''}) async {
    final trimmed = code.trim();
    if (trimmed.isEmpty) return null;
    final cacheKey = '$schemeCode/$trimmed';
    if (_subjectNames.containsKey(cacheKey)) return _subjectNames[cacheKey];

    try {
      var query = _client.from('subjects').select('sub_name').or(
            'sem_1_sub_code.eq.$trimmed,sem_2_sub_code.eq.$trimmed',
          );
      if (schemeCode.isNotEmpty) query = query.eq('scheme_code', schemeCode);
      final row = await query.limit(1).maybeSingle();
      final name = (row?['sub_name'] as String?)?.trim();
      return _subjectNames[cacheKey] = (name?.isEmpty ?? true) ? null : name;
    } catch (error) {
      // Only a folder name depends on this, and the key stays editable, so a
      // failure is not worth interrupting an upload for.
      debugPrint('Subject name for $trimmed could not be read: $error');
      return null;
    }
  }

  final Map<String, String?> _subjectNames = {};

  Future<List<LookupOption>> lookup(Lookup lookup) async {
    final columns = lookup.labelColumn == null
        ? lookup.valueColumn
        : '${lookup.valueColumn},${lookup.labelColumn}';

    final rows = await _client
        .from(lookup.table)
        .select(columns)
        .order(lookup.orderBy ?? lookup.valueColumn, ascending: true)
        .limit(lookup.distinct ? 1000 : 300);

    final seen = <String>{};
    final options = <LookupOption>[];
    for (final row in rows) {
      final value = row[lookup.valueColumn]?.toString() ?? '';
      if (value.isEmpty || !seen.add(value)) continue;
      options.add(LookupOption(
        value,
        lookup.labelColumn == null ? null : row[lookup.labelColumn]?.toString(),
      ));
    }
    if (lookup.distinct) {
      options.sort((a, b) => a.value.compareTo(b.value));
    }
    return options;
  }

  /// PostgREST's `or=` takes a comma-separated list inside parentheses, so a
  /// search containing those characters would change the meaning of the filter.
  static String _sanitizeSearch(String term) =>
      term.trim().replaceAll(RegExp(r'[,()*%\\]'), ' ').trim();

  /// Turns the two errors this app can realistically hit into instructions.
  static String? _hintFor(PostgrestException error) {
    final message = error.message.toLowerCase();
    if (error.code == '42501' ||
        message.contains('row-level security') ||
        message.contains('violates row-level security policy')) {
      return 'The database refused this write. That means this account has no '
          'web_admins row, or the sign-in expired — sign out and back in.';
    }
    if (error.code == 'PGRST303' || message.contains('jwt expired')) {
      return 'The session token looks expired. If the phone clock is wrong, '
          'fix the date and time first — Supabase compares against it.';
    }
    if (error.code == '23505' || message.contains('duplicate key')) {
      return 'Something with that key already exists.';
    }
    if (error.code == '23502') {
      return 'A column the database requires was left empty.';
    }
    return null;
  }
}

/// Converts a form's text values into the JSON PostgREST expects, and a row's
/// JSON back into text for the form.
class FieldCodec {
  static final DateFormat _dateFormat = DateFormat('yyyy-MM-dd');
  static final DateFormat _dateTimeFormat = DateFormat('yyyy-MM-dd HH:mm');

  /// How a picked date is written into the form, and therefore how it is parsed
  /// back on save. `date` columns are plain calendar days with no zone.
  static String formatDate(DateTime value) => _dateFormat.format(value);

  /// How a picked instant is written into the form: local wall-clock time, which
  /// is what the person picking it means.
  static String formatDateTime(DateTime value) =>
      _dateTimeFormat.format(value.toLocal());

  /// Text (as typed) → JSON value for [field]. Returns null for "no value",
  /// which is what clears a column.
  static Object? encode(FieldSpec field, String raw) {
    final value = raw.trim();
    if (value.isEmpty) {
      // A NOT NULL column (gatepyqs."2014") must get '' rather than null, both
      // when a value is demanded and when a blank one is legitimate.
      return (field.required || field.notNull) &&
              field.type != FieldType.boolean
          ? ''
          : null;
    }
    switch (field.type) {
      case FieldType.integer:
        return int.tryParse(value);
      case FieldType.decimal:
        return num.tryParse(value);
      case FieldType.boolean:
        return value == 'true';
      case FieldType.tags:
        return value
            .split(',')
            .map((t) => t.trim())
            .where((t) => t.isNotEmpty)
            .toList();
      case FieldType.json:
        return jsonDecode(value);
      case FieldType.dateTime:
        // The form holds local wall-clock time with no zone, which Postgres
        // would read as UTC. Convert here so 9 pm means 9 pm in Bengaluru.
        final local = DateTime.tryParse(value);
        return local == null ? value : local.toUtc().toIso8601String();
      case FieldType.date:
      case FieldType.text:
      case FieldType.multiline:
      case FieldType.select:
      case FieldType.url:
      case FieldType.fileUrl:
        return value;
      // A `gatepyqs` year column and a `notes_link`/`study_materials` column are
      // all `text` that happens to hold JSON, so they go over the wire as the
      // string they are. Decoding here would send an object to a text column,
      // and PostgREST would stringify it back with whatever spacing it felt
      // like.
      case FieldType.gateAssets:
      case FieldType.documentList:
        return value;
    }
  }

  /// Row value → the text the form shows.
  static String decode(FieldSpec field, Object? value) {
    if (value == null) return '';
    switch (field.type) {
      case FieldType.tags:
        if (value is List) return value.join(', ');
        return value.toString();
      case FieldType.json:
        try {
          return const JsonEncoder.withIndent('  ').convert(value);
        } catch (_) {
          return value.toString();
        }
      // Stored as text, so this is normally already the JSON string. The Map
      // case is for the day the column becomes `jsonb`.
      case FieldType.gateAssets:
      case FieldType.documentList:
        if (value is Map || value is List) {
          try {
            return const JsonEncoder.withIndent('  ').convert(value);
          } catch (_) {
            return value.toString();
          }
        }
        return value.toString();
      case FieldType.boolean:
        return value == true ? 'true' : 'false';
      case FieldType.date:
        final parsed = DateTime.tryParse(value.toString());
        return parsed == null ? value.toString() : formatDate(parsed);
      case FieldType.dateTime:
        final parsed = DateTime.tryParse(value.toString());
        return parsed == null ? value.toString() : formatDateTime(parsed);
      default:
        return value.toString();
    }
  }

  /// Why [raw] cannot be saved, or null when it can.
  static String? validate(FieldSpec field, String raw) {
    final value = raw.trim();
    if (value.isEmpty) {
      if (field.required && field.type != FieldType.boolean) {
        return '${field.label} is required';
      }
      return null;
    }
    switch (field.type) {
      case FieldType.integer:
        return int.tryParse(value) == null ? 'Whole number expected' : null;
      case FieldType.decimal:
        return num.tryParse(value) == null ? 'Number expected' : null;
      case FieldType.json:
        try {
          jsonDecode(value);
          return null;
        } catch (_) {
          return 'Not valid JSON';
        }
      // The student app silently ignores a year cell it cannot read, so a typo
      // here would save, look saved, and show the student nothing. Checked by
      // the same reader the app uses: if nothing openable comes back out, the
      // cell is wrong.
      case FieldType.gateAssets:
        if (parseGateAssets(value).isNotEmpty) return null;
        if (value.startsWith('{') || value.startsWith('[')) {
          try {
            jsonDecode(value);
          } catch (_) {
            return 'Not valid JSON';
          }
          return 'No paper, answer key or solved paper in there — check the '
              'keys and that every link starts with https://';
        }
        return 'Should be a link, or the JSON the bucket button builds';
      // Same reasoning as the year cells above: the student app skips a link it
      // cannot open, so a typo here would save, look saved, and offer the
      // student a button that opens nothing.
      case FieldType.documentList:
        if (parseNamedDocuments(value).isNotEmpty) return null;
        if (value.startsWith('{') || value.startsWith('[')) {
          try {
            jsonDecode(value);
          } catch (_) {
            return 'Not valid JSON';
          }
          return 'No file in there — check every entry has a link that starts '
              'with https://';
        }
        return 'Should be a link, or the JSON the bucket button builds';
      case FieldType.url:
      case FieldType.fileUrl:
        final uri = Uri.tryParse(value);
        if (uri == null || !uri.hasScheme || !value.startsWith('http')) {
          return 'Should start with http:// or https://';
        }
        return null;
      case FieldType.date:
        return DateTime.tryParse(value) == null
            ? 'Use YYYY-MM-DD'
            : null;
      case FieldType.dateTime:
        return DateTime.tryParse(value) == null
            ? 'Use YYYY-MM-DD HH:MM'
            : null;
      default:
        return null;
    }
  }
}
