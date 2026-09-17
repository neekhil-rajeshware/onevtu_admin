/// What one `gatepyqs` year cell holds, and how it is built from bucket files.
///
/// A GATE year is not one file: there is the question paper, the official answer
/// key and a solved paper, and for the bigger branches two of each because GATE
/// runs Session 1 and Session 2 on the same day. So each year column holds JSON:
///
/// ```json
/// {
///   "Paper": [
///     {"label": "Session 1", "url": "https://…"},
///     {"label": "Session 2", "url": "https://…"}
///   ],
///   "Answer Key": "https://…",
///   "Solved Papers": "https://…"
/// }
/// ```
///
/// The column is `text`, not `jsonb` — the content sheet writes it as a plain
/// string, and a half-typed cell should show as one year's tile saying "not
/// available" rather than have Postgres reject the whole row. See
/// `docs/sql/026_gate_pyq_json.sql` in the student app, whose
/// `lib/models/content/gate_paper.dart` is the reader this file writes for. The
/// parsing below is deliberately the same shape as that reader's: what this app
/// can read back, the student app can too.
library;

import 'dart:convert';

/// The three things a GATE year can offer a student.
enum GateAssetKind {
  paper('Paper', 'Paper'),
  answerKey('Answer Key', 'Answer Key'),
  solvedPaper('Solved Papers', 'Solved Paper');

  const GateAssetKind(this.jsonKey, this.singular);

  /// The key written into the cell, and the label the student app puts on the
  /// button. Spelt the way it reads in a spreadsheet, not the way a column is
  /// named — the reader matches loosely anyway.
  final String jsonKey;

  /// One of them, for naming a single row in the picker.
  final String singular;
}

/// One openable file of one kind, for one session of one year.
class GateAsset {
  const GateAsset({required this.kind, this.label = '', required this.url});

  final GateAssetKind kind;

  /// Session label as it will appear on the student's picker, e.g. `Session 1`.
  /// Empty when the year has a single unlabelled file of this kind.
  final String label;

  final String url;

  GateAsset copyWith({GateAssetKind? kind, String? label, String? url}) =>
      GateAsset(
        kind: kind ?? this.kind,
        label: label ?? this.label,
        url: url ?? this.url,
      );

  @override
  bool operator ==(Object other) =>
      other is GateAsset &&
      other.kind == kind &&
      other.label == label &&
      other.url == url;

  @override
  int get hashCode => Object.hash(kind, label, url);

  @override
  String toString() => 'GateAsset($kind, "$label", $url)';
}

/// Reads a year cell into the files it names, in kind order.
///
/// Tolerates everything the student app tolerates, because this has to be able
/// to re-open a cell typed by hand in the sheet: a bare URL (the shape the
/// column held before it became JSON), loose key spelling, and a kind given as
/// one URL, a list of URLs, a list of `{label, url}` objects, or a
/// `{"Session 1": url}` map. Anything it cannot make a URL of is dropped.
List<GateAsset> parseGateAssets(String cell) {
  final decoded = _decode(cell);
  final assets = <GateAsset>[];

  if (decoded is Map) {
    for (final kind in GateAssetKind.values) {
      for (final entry in decoded.entries) {
        if (_kindOf(entry.key.toString()) != kind) continue;
        assets.addAll(_assetsOf(entry.value, kind));
      }
    }
  } else if (decoded != null) {
    assets.addAll(_assetsOf(decoded, GateAssetKind.paper));
  }

  return assets;
}

/// The cell text for [assets] — pretty-printed, because a person opens this
/// column in a spreadsheet and in the form's text box, and a single long line is
/// unreadable in both.
///
/// Empty in, empty out: an empty string clears the column rather than storing
/// `{}`, which the student app would read as a year with nothing in it anyway
/// but which looks like data to whoever opens the sheet next.
String encodeGateAssets(List<GateAsset> assets) {
  final body = <String, Object>{};

  for (final kind in GateAssetKind.values) {
    final ofKind = [
      for (final asset in assets)
        if (asset.kind == kind && asset.url.trim().isNotEmpty) asset,
    ];
    if (ofKind.isEmpty) continue;

    // One unlabelled file is written as a bare URL: the shortest thing that
    // still round-trips, and the shape a year with a single paper had before
    // sessions existed.
    if (ofKind.length == 1 && ofKind.first.label.trim().isEmpty) {
      body[kind.jsonKey] = ofKind.first.url.trim();
      continue;
    }

    body[kind.jsonKey] = [
      for (final asset in ofKind)
        {
          if (asset.label.trim().isNotEmpty) 'label': asset.label.trim(),
          'url': asset.url.trim(),
        },
    ];
  }

  if (body.isEmpty) return '';
  return const JsonEncoder.withIndent('  ').convert(body);
}

/// Which kind a file in the bucket most likely is, from its name.
///
/// A guess the person can change with two taps, so it errs towards the common
/// case: most of what sits in a GATE folder is the question paper itself, and
/// nothing is tagged as an answer key unless it says so.
GateAssetKind guessGateAssetKind(String fileName) {
  final text = _words(fileName);
  // Checked before the answer key: "solved solutions with answer key" is a
  // solved paper, and a file named that way should not land under the key.
  if (text.contains('solved') ||
      text.contains('solution') ||
      text.contains('explained')) {
    return GateAssetKind.solvedPaper;
  }
  if (text.contains('answer') ||
      text.contains('key') ||
      text.contains(' ans ')) {
    return GateAssetKind.answerKey;
  }
  return GateAssetKind.paper;
}

/// The session a file belongs to, from its name — `Session 1`, or empty when the
/// name does not say.
///
/// Empty is a real answer and the common one: a branch with a single sitting has
/// nothing to label, and the student app only numbers entries once a kind has
/// more than one of them.
String guessGateSessionLabel(String fileName) {
  final text = _words(fileName);

  // Forenoon / afternoon is how GATE itself writes the two sittings on the
  // paper, and how half the files in the bucket are named.
  if (RegExp(r'\b(forenoon|fn)\b').hasMatch(text)) return 'Session 1';
  if (RegExp(r'\b(afternoon|an)\b').hasMatch(text)) return 'Session 2';

  final match =
      RegExp(r'\b(?:session|shift|sitting|slot|set|s)\s*([1-9])\b').firstMatch(text);
  return match == null ? '' : 'Session ${match.group(1)}';
}

/// The four-digit year named in [text], or null. Used to keep the 2023 files out
/// of the list while the 2024 column is being filled in.
int? gateYearIn(String text) {
  final match = RegExp(r'(?:19|20)\d{2}').firstMatch(text);
  return match == null ? null : int.parse(match.group(0)!);
}

/// The folder names the bucket uses for each kind, directly under the branch:
/// `vtu/gatepyqs/AE_Aeronautical_Engineering/answer_key/`.
///
/// Note the asymmetry — `answer_key` singular, the other two plural. That is how
/// the folders are named, and a key is matched against it literally, so it is
/// not something to tidy up.
const _kindFolders = <String, GateAssetKind>{
  'answer_key': GateAssetKind.answerKey,
  'papers': GateAssetKind.paper,
  'solved_papers': GateAssetKind.solvedPaper,
};

/// The kind a file's *folder* puts it in — `…/answer_key/2014.pdf` is an answer
/// key — or null when the key does not sit under one of those folders.
///
/// Worth preferring over [guessGateAssetKind] wherever it answers: the folder is
/// a deliberate choice someone made when uploading, whereas the file name is a
/// guess from whatever the file happened to be called. A file named
/// "GATE 2014 paper with answer key.pdf" dropped into `answer_key/` is an answer
/// key, and only the path says so.
///
/// There is no year level in these paths — the folders are the three kinds
/// directly under the branch — so this reads the kind and [gateYearFromKey]
/// finds nothing and the year comes from the file name.
GateAssetKind? gateKindFromKey(String key) {
  final segments = key.split('/');
  if (segments.length < 2) return null;
  // Only the folder directly above the file counts. Matching any segment would
  // let a branch or a stray parent folder named 'papers' decide it.
  final parent = segments[segments.length - 2].trim().toLowerCase();
  return _kindFolders[parent];
}

/// The year a file's path puts it in, from a `…/<year>/…` segment, or null when
/// no segment is a plausible GATE year.
///
/// Reads whole segments rather than searching the string, so a year inside a
/// branch or file name cannot be mistaken for the folder it is filed under.
///
/// **Null is the expected answer for every GATE file in the bucket**, because the
/// paths are `<branch>/<kind>/<file>` with no year folder — the year is in the
/// file name, and callers fall back to [gateYearIn]. Kept because it is the right
/// answer if a year folder ever appears again, and because returning null is
/// cheaper than making every caller test for a shape that mostly does not exist.
int? gateYearFromKey(String key) {
  final segments = key.split('/');
  final yearOnly = RegExp(r'^(?:19|20)\d{2}$');
  // Right to left, so the deepest year wins over one further up the path.
  for (var i = segments.length - 1; i >= 0; i--) {
    final segment = segments[i].trim();
    if (yearOnly.hasMatch(segment)) return int.parse(segment);
  }
  return null;
}

/// Lower-case, with every separator turned into a space, so `GATE_2024-S1.pdf`
/// and `gate 2024 s1.pdf` read the same and `\b` can be relied on.
String _words(String raw) =>
    ' ${raw.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim()} ';

/// A cell into a Map, List or String — null for anything empty or unparseable.
Object? _decode(String cell) {
  final text = cell.trim();
  if (text.isEmpty) return null;
  if (!text.startsWith('{') && !text.startsWith('[')) return text;
  try {
    return jsonDecode(text);
  } catch (_) {
    return null;
  }
}

/// Maps a JSON key onto a kind, ignoring case, punctuation and plurals, so a
/// cell typed as `answer_key` or `Answer Keys` still opens here.
GateAssetKind? _kindOf(String rawKey) {
  var key = rawKey.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
  if (key.endsWith('s')) key = key.substring(0, key.length - 1);
  return switch (key) {
    'paper' || 'questionpaper' || 'qp' || 'question' => GateAssetKind.paper,
    'answerkey' || 'key' || 'answer' => GateAssetKind.answerKey,
    'solvedpaper' || 'solved' || 'solution' || 'solvedsolution' =>
      GateAssetKind.solvedPaper,
    _ => null,
  };
}

List<GateAsset> _assetsOf(Object? value, GateAssetKind kind) {
  final assets = <GateAsset>[];

  void addOne(Object? item, {String label = ''}) {
    if (item == null) return;
    if (item is Map) {
      final url = _firstString(item, const ['url', 'link', 'href', 'file']);
      if (!looksLikeUrl(url)) return;
      final name = label.isNotEmpty
          ? label
          : _firstString(item, const ['label', 'name', 'title', 'session']);
      assets.add(GateAsset(kind: kind, label: name, url: url));
      return;
    }
    final url = item.toString().trim();
    if (!looksLikeUrl(url)) return;
    assets.add(GateAsset(kind: kind, label: label.trim(), url: url));
  }

  if (value is List) {
    for (final item in value) {
      addOne(item);
    }
  } else if (value is Map) {
    for (final entry in value.entries) {
      addOne(entry.value, label: entry.key.toString());
    }
  } else {
    addOne(value);
  }

  return assets;
}

/// Whether a value is something the student app's viewer could open.
///
/// Without this a note left in the cell ("waiting for the key") would save as a
/// live button that opens a blank page, and the app's PDF indexer would queue it
/// for download. Same rule as `GatePaperSet._looksLikeUrl` in the student app.
bool looksLikeUrl(String value) {
  final text = value.trim();
  if (text.isEmpty || text.contains(RegExp(r'\s'))) return false;
  final lower = text.toLowerCase();
  if (lower.startsWith('http://') || lower.startsWith('https://')) return true;
  return RegExp(r'^[\w-]+(\.[\w-]+)+/').hasMatch(text);
}

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