import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'gate_assets.dart' show looksLikeUrl;

/// One file a cell lists by name — `subjects.notes_link` and
/// `branches.study_materials`, which hold the same JSON.
///
/// A subject has several sets of notes and a branch publishes several study
/// materials, so both columns are a *list* where every other link column in the
/// database is a single URL:
///
/// ```json
/// [{"name": "Module 1", "link": "https://…"},
///  {"name": "Module 2", "link": "https://…"}]
/// ```
///
/// The reader on the other end is `SubjectDoc.parseList` in the student app;
/// this is the editor's half of the same contract. The two must agree on what a
/// cell may contain, which is why [parseNamedDocuments] accepts exactly what
/// that one accepts and no more.
@immutable
class NamedDocument {
  const NamedDocument({required this.name, required this.url});

  /// What the student's button reads. [parseNamedDocuments] fills it in for an
  /// entry the cell left unnamed, so this is never empty coming out of there.
  final String name;

  final String url;

  NamedDocument copyWith({String? name, String? url}) =>
      NamedDocument(name: name ?? this.name, url: url ?? this.url);

  @override
  bool operator ==(Object other) =>
      other is NamedDocument && other.name == name && other.url == url;

  @override
  int get hashCode => Object.hash(name, url);
}

/// Parses a `notes_link` / `study_materials` cell into the files it holds, in
/// the order written.
///
/// The column is `text` rather than `jsonb` deliberately — the same call as the
/// `gatepyqs` year cells, and for the same reason: this app writes a plain
/// string, and a half-written cell should cost that subject its notes button
/// rather than have Postgres reject the whole row. So the reader is tolerant:
/// a single object instead of a list, a list of bare URLs, and one bare URL —
/// what a subject with one set of notes looks like — all read. Key spelling is
/// loose (`link`/`url`/`href`/`file`, `name`/`title`/`label`).
///
/// Anything unreadable yields nothing rather than throwing, and so does any
/// entry that isn't URL-shaped — see [looksLikeUrl] for why that matters more
/// than it looks. [fallbackName] names the entries the cell left unnamed, so a
/// subject with three of them does not offer three identical buttons.
List<NamedDocument> parseNamedDocuments(
  Object? cell, {
  String fallbackName = 'Document',
}) {
  final decoded = _decode(cell);
  if (decoded == null) return const [];

  final documents = <NamedDocument>[];

  void addOne(Object? item) {
    if (item == null) return;
    if (item is Map) {
      final url = _firstString(item, const ['link', 'url', 'href', 'file']);
      if (!looksLikeUrl(url)) return;
      documents.add(NamedDocument(
        name: _firstString(item, const ['name', 'title', 'label']),
        url: url,
      ));
      return;
    }
    final url = item.toString().trim();
    if (!looksLikeUrl(url)) return;
    documents.add(NamedDocument(name: '', url: url));
  }

  if (decoded is List) {
    for (final item in decoded) {
      addOne(item);
    }
  } else {
    // A single entry, or a bare URL.
    addOne(decoded);
  }

  return _named(documents, fallbackName);
}

/// The cell text for [documents] — pretty-printed, because a person opens this
/// column in a spreadsheet and in the form's text box, and a single long line is
/// unreadable in both.
///
/// Empty in, empty out: an empty string clears the column rather than storing
/// `[]`, which the student app would read as a subject with no notes anyway but
/// which looks like data to whoever opens the sheet next.
String encodeNamedDocuments(List<NamedDocument> documents) {
  final body = <Map<String, String>>[];
  for (final document in documents) {
    final url = document.url.trim();
    if (url.isEmpty) continue;
    body.add({
      // Left out when empty rather than written as "": the student app numbers
      // the unnamed ones by position, which reads better than a blank button.
      if (document.name.trim().isNotEmpty) 'name': document.name.trim(),
      'link': url,
    });
  }
  if (body.isEmpty) return '';
  return const JsonEncoder.withIndent('  ').convert(body);
}

/// What to call a file the picker has just ticked, guessed from the bucket
/// object's own name: `Module_1_Notes.pdf` → `Module 1 Notes`.
///
/// A guess and nothing more — it is what the name field opens with, and tapping
/// it is how it gets corrected. Hyphens are kept, because a name that has one
/// (`Unit-3`) was written that way on purpose.
String guessDocumentName(String fileName) {
  final dot = fileName.lastIndexOf('.');
  final stem = dot > 0 ? fileName.substring(0, dot) : fileName;
  return stem.replaceAll('_', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// Reads a cell into a List, Map or String. Returns null for anything empty or
/// unparseable, so one bad cell shows as a subject with no notes rather than
/// failing the whole catalogue's load.
Object? _decode(Object? cell) {
  if (cell == null) return null;
  if (cell is Map || cell is List) return cell; // already jsonb
  final text = cell.toString().trim();
  if (text.isEmpty) return null;
  if (!text.startsWith('{') && !text.startsWith('[')) return text;
  try {
    return jsonDecode(text);
  } catch (_) {
    return null;
  }
}

/// Names the entries the cell left unnamed, so a subject with three sets of
/// notes does not offer three identical buttons. A lone one still reads plainly
/// — "Notes" rather than "Notes 1" — because that is the common case.
List<NamedDocument> _named(List<NamedDocument> documents, String fallback) {
  if (documents.isEmpty) return const [];
  if (documents.length == 1) {
    final only = documents.single;
    return [
      only.name.isEmpty
          ? NamedDocument(name: fallback, url: only.url)
          : only,
    ];
  }
  return [
    for (var i = 0; i < documents.length; i++)
      documents[i].name.isNotEmpty
          ? documents[i]
          : NamedDocument(
              name: '$fallback ${i + 1}',
              url: documents[i].url,
            ),
  ];
}

/// The first of [keys] present on [map] with a non-empty value, matched
/// ignoring case and underscores so the cell can spell the key either way.
String _firstString(Map<dynamic, dynamic> map, List<String> keys) {
  for (final key in keys) {
    for (final entry in map.entries) {
      if (entry.key.toString().toLowerCase().replaceAll('_', '') != key) {
        continue;
      }
      final value = (entry.value ?? '').toString().trim();
      if (value.isNotEmpty) return value;
    }
  }
  return '';
}
