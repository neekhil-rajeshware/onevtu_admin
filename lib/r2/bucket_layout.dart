/// Where everything in `vtu-resources` lives. One bucket, one tree, forever.
///
/// The student app holds no R2 credentials and cannot list anything: it only
/// follows links already in the database. So the tree is not for the software —
/// it is for whoever has to find the 2022 third-semester papers a year from now,
/// and that only survives if uploads land in the same places by themselves. This
/// file, not the person uploading, decides the folder.
///
/// ```
/// vtu/
///   branches/                                   branch-wise, no semester
///     AE_Aeronautical_Engineering/
///       study_materials/
///       deleted_old_files/2026-08-31_143205/
///   scheme-2025/                                one per scheme year
///     1st_year/                                 semesters 1, 2 and "1 & 2"
///       py_qp/1BMATC101 Subject Name/
///         june_july_2025.pdf                    one paper for the sitting
///         dec_jan_2025 Paper A.pdf              up to three for one sitting
///         dec_jan_2025 Paper B.pdf
///         dec_jan_2025 Solved.pdf
///         DEC JAN 2026/                         or a folder per sitting, which
///           1BMATC101.pdf                       is how a lot of it was uploaded
///       notes/
///       deleted_old_files/2026-08-31_143205/
///     AE_Aeronautical_Engineering/              from semester 3, one per branch
///       3rd_sem/
///         py_qp/1BAE305 Subject Name/
///         notes/                                every subject's notes, flat
///         1BAE305 Introduction to UAV Systems.pdf
///         deleted_old_files/2026-08-31_143205/
///   scheme-2022/  scheme-2018/                  same shape
///   gatepyqs/
///     AE_Aeronautical_Engineering/
///       answer_key/  papers/  solved_papers/     the year is in the file name
/// ```
///
/// A subject's `py_qp/` folder holds **every sitting that subject has papers
/// for**, so what says which one a paper belongs to is the file name *or* a
/// folder of its own — and both shapes are in the bucket today:
///
/// ```
/// 1BBEE105 Basics of Electrical Engineering/
///   1BBEE205 - June-2026.pdf        sitting inside the file name
///   DEC JAN 2026/                   sitting as a folder
///     1BCEDS103.pdf
/// ```
///
/// Nothing here creates the second shape — `bucketBaseNameFor` seeds a new
/// upload's name with the session column (`dec_jan_2026.pdf`) — but people do
/// make session folders by hand, so `pyqpSessionMatches` reads the path below the
/// subject folder rather than the name alone. VTU sets up to three papers for one
/// sitting (Paper A, Paper B, Paper C) plus a solved paper, and those are named
/// onto the end of that stem by whoever uploads them.
///
/// Note where the three document columns land: a **lab manual** goes straight
/// into the semester folder, beside `py_qp/` rather than inside it, and is named
/// after its subject — a semester folder holds one of them, so the name is what
/// tells it from the papers. **Notes** go in the semester's `notes/`, one folder
/// for every subject of that semester. **Study materials** belong to a branch
/// and are filed under `vtu/branches/`, since a `branches` row names no scheme.
///
/// Two consequences worth stating, because both are load-bearing:
///
/// - **Names keep their capitals and their spaces.** `AE_Aeronautical_Engineering`
///   and `1BAE305 Introduction to UAV Systems` are the convention, and the 65
///   syllabus links already in the database are spelt that way. Flattening a name
///   to `ae-aeronautical-engineering` would file the next upload somewhere the
///   existing files are not.
/// - **Every level keeps its own `deleted_old_files/`.** A replaced third-semester
///   paper stays next to its semester rather than travelling to a bin at the root,
///   so the folder still reads as one thing after a year of edits.
library;

import 'package:flutter/foundation.dart';

/// Everything academic hangs off this. Nothing is written to the bucket root.
const String bucketRoot = 'vtu';

/// GATE papers are branch-wise but scheme-less, so they sit beside the schemes.
///
/// **A branch folder holds exactly three sub-folders — the three kinds — and no
/// year level.**
///
/// ```
/// vtu/gatepyqs/AE_Aeronautical_Engineering/
///   answer_key/      2014.pdf
///   papers/          2014 Session 1.pdf
///   solved_papers/
/// ```
///
/// The year is not a folder: it lives in the file name, which
/// [bucketBaseNameFor] sets from the `gatepyqs` column being filled in
/// (`2014` → `2014.pdf`). That is why [gateYearFromKey] and [gateKindFromKey]
/// behave asymmetrically on these keys — the kind is readable from the path, the
/// year is not.
///
/// **This shape took two revisions to arrive at.** A `<year>/<kind>/` tree
/// (2007–2026) was created on 2026-09-15 and removed the next day; for a few
/// minutes the branch held no sub-folder at all. The current three-folder form
/// was then asked for explicitly. Do not add a year level back.
const String gateRoot = '$bucketRoot/gatepyqs';

/// What a GATE branch folder holds — the three kinds, matched literally by
/// `gateKindFromKey` in `schema/gate_assets.dart`.
///
/// The plural is asymmetric on purpose: `answer_key` singular, the other two
/// plural, which is how the folders in the bucket are named. A key is matched
/// against these strings literally, so tidying the spelling here would stop the
/// kind being read off the path.
const List<String> gateKindFolders = ['answer_key', 'papers', 'solved_papers'];

/// Question papers, inside the semester they were set in.
const String questionPaperFolder = 'py_qp';

/// A subject's notes, inside the semester the subject is taught in:
/// `…/3rd_sem/notes/`.
///
/// **One `notes/` per semester, not one per subject** — the folder holds every
/// subject's notes flat, so the file name is what says which subject a file
/// belongs to. That is why [bucketBaseNameFor] leaves these files called whatever
/// the person picking them called them, and why the upload offers the key for
/// editing: `1BAE305 Module 1.pdf` files itself, `Module 1.pdf` does not.
const String notesFolder = 'notes';

/// Branch-wise study materials hang off `vtu/branches/` rather than being filed
/// under a scheme.
///
/// A `branches` row is the row being edited and it names no scheme and no
/// semester, so there is nowhere inside a scheme to put its files that would not
/// file the same PDF once per scheme — or file it under whichever scheme came
/// first and hide it from every student on the other two.
const String branchesRoot = '$bucketRoot/branches';

/// The folder each branch under [branchesRoot] holds, and the only reason that
/// branch folder exists.
const String studyMaterialsFolder = 'study_materials';

/// The recycle bin's name. There is one of these per level — see
/// [archiveFolderFor].
const String archiveFolderName = 'deleted_old_files';

/// Semesters 1 and 2 share a folder, the way VTU teaches them.
const String firstYearFolder = '1st_year';

/// Which tree a `fileUrl` or `documentList` column belongs in.
///
/// [flat] is for the columns that are not academic content — a job's attachment
/// has no scheme or semester to file it under — and keeps using
/// `FieldSpec.uploadPrefix`.
enum BucketFolder {
  flat,
  syllabus,

  /// `subjects.notes_link`: `…/<sem>/notes/`.
  notes,

  /// `subjects.lab_manual_link`: the semester folder itself, `…/<sem>/`.
  labManual,

  questionPaper,
  gatePaper,
  schemeDocument,

  /// `branches.study_materials`: `vtu/branches/<branch>/study_materials/`.
  studyMaterials,
}

/// The code → name maps the tree needs, because a row holds `scheme_code: '1'`
/// and `branch: 'AE'` while the folders are named `scheme-2025` and
/// `AE_Aeronautical_Engineering`.
///
/// Empty maps are legitimate: a lookup that could not be read leaves the folder
/// unresolved, and an unresolved folder asks instead of guessing.
@immutable
class BucketNames {
  const BucketNames({this.schemes = const {}, this.branches = const {}});

  /// `scheme_code` → `scheme_name`, e.g. `'1'` → `'2025 CBCS'`.
  final Map<String, String> schemes;

  /// Branch code → branch name, e.g. `'AE'` → `'Aeronautical Engineering'`.
  final Map<String, String> branches;
}

/// A name that can be a folder or a file in this bucket and still survive being
/// put in a URL. Case and spaces are kept on purpose — see the library note.
///
/// Only what would actually break is removed: `/` would invent a folder level,
/// and `%`, `#` and `?` change where a URL ends or double-encode on the way back.
String bucketSafeName(String raw) {
  final cleaned = raw
      // 'Calculus: ME Stream' → 'Calculus_ ME Stream', which is how the syllabus
      // files already in the bucket are spelt.
      .replaceAll(':', '_')
      .replaceAll(RegExp(r'[\\/%#?"<>|*\x00-\x1f]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return cleaned;
}

/// `'2025 CBCS'` → `scheme-2025`. Null when the name carries no year, because
/// `scheme-1` (the code) would be a folder nobody could interpret later.
String? schemeFolderName(String schemeName) {
  final year = RegExp(r'(?:19|20)\d{2}').firstMatch(schemeName)?.group(0);
  return year == null ? null : 'scheme-$year';
}

/// `('AE', 'Aeronautical Engineering')` → `AE_Aeronautical_Engineering`.
String branchFolderName(String code, String name) {
  final cleanCode = bucketSafeName(code).replaceAll(' ', '_');
  final cleanName = bucketSafeName(name).replaceAll(' ', '_');
  if (cleanName.isEmpty) return cleanCode;
  return '${cleanCode}_$cleanName';
}

/// The year-or-semester folder a subject belongs to.
///
/// `'1'`, `'2'`, `'1 & 2'` and empty all mean the first year: the last because a
/// cycle subject (`cycle: 'C'`, no semester) is first-year by definition, and the
/// 26 such rows in the database are filed there. `'3'` upwards get their own
/// `3rd_sem` … `8th_sem`.
String? levelFolderName(String? semester) {
  final numbers = RegExp(r'\d+')
      .allMatches(semester ?? '')
      .map((match) => int.parse(match.group(0)!))
      .toList();
  if (numbers.isEmpty) return firstYearFolder;
  // '1 & 2' is one folder, and the highest number is the one that places it.
  final level = numbers.reduce((a, b) => a > b ? a : b);
  if (level <= 2) return firstYearFolder;
  if (level > 8) return null; // not a VTU semester; ask rather than invent
  return '$level${_ordinal(level)}_sem';
}

String _ordinal(int n) => switch (n % 10) {
      1 when n % 100 != 11 => 'st',
      2 when n % 100 != 12 => 'nd',
      3 when n % 100 != 13 => 'rd',
      _ => 'th',
    };

/// `1BAE305 Introduction to UAV Systems and Technologies` — the code first so the
/// folders sort the way a scheme document does, the name so it can be read.
String subjectFolderName(String code, String name) {
  final cleanCode = bucketSafeName(code);
  final cleanName = bucketSafeName(name);
  if (cleanCode.isEmpty) return cleanName;
  if (cleanName.isEmpty) return cleanCode;
  return '$cleanCode $cleanName';
}

/// The folder a file for this row belongs in, ending in `/`.
///
/// Null means the row does not say enough to place the file — no scheme, or a
/// third-semester subject with no branch. The upload then asks for a key with no
/// folder filled in, which is the honest outcome: a guessed folder is a folder
/// somebody has to find and clean up later.
///
/// [subjectName] is only needed for [BucketFolder.questionPaper], whose row
/// carries the subject *code* but not its name.
String? bucketFolderFor(
  BucketFolder kind,
  Map<String, String> row, {
  BucketNames names = const BucketNames(),
  String subjectName = '',
}) {
  String value(String column) => (row[column] ?? '').trim();

  switch (kind) {
    case BucketFolder.flat:
      return null;

    case BucketFolder.schemeDocument:
      // The row *is* the scheme, so its own name places it.
      final folder = schemeFolderName(value('scheme_name'));
      return folder == null ? null : '$bucketRoot/$folder/';

    case BucketFolder.gatePaper:
      return _branchPath(gateRoot, row, names);

    case BucketFolder.studyMaterials:
      final branch = _branchPath(branchesRoot, row, names);
      return branch == null ? null : '$branch$studyMaterialsFolder/';

    case BucketFolder.syllabus:
    case BucketFolder.labManual:
      // Both are one document for the whole subject, so both go straight into
      // the semester folder. A lab manual is told from the papers by its name —
      // see [bucketBaseNameFor], which names it after the subject.
      return _semesterPath(row, names);

    case BucketFolder.notes:
    case BucketFolder.questionPaper:
      // **A `py_qp` row's own `scheme_code`, `semester` and `branch_code` do not
      // place it, and the caller must overwrite them before calling this.**
      // Every row in that table is a first-year subject of the 2025 scheme,
      // while those three columns hold group numbers (a `semester` of 1–8) and
      // stray values — `1BCEDS103` is filed under `AG_Aeronautical_Engineering/
      // 4th_sem/` if they are believed, and no such folder exists, so the picker
      // lists nothing. `RecordEditorScreen._plannedDestination` replaces them
      // with the subject's own, which is what this file expects: for every
      // `py_qp` row today, `scheme-2025/1st_year/`.
      final semesterFolder = _semesterPath(row, names);
      if (semesterFolder == null) return null;
      // `notes/` holds every subject's notes and has no subject level, unlike
      // `py_qp/`, so a note's file name is what says which subject it is.
      if (kind == BucketFolder.notes) return '$semesterFolder$notesFolder/';
      final subject = subjectFolderName(
        value('sem_1_sub_code').isNotEmpty
            ? value('sem_1_sub_code')
            : value('sem_2_sub_code'),
        // A question paper's row is a `py_qp` row, which carries the subject
        // code but not its name.
        subjectName,
      );
      if (subject.isEmpty) return '$semesterFolder$questionPaperFolder/';
      return '$semesterFolder$questionPaperFolder/$subject/';
  }
}

/// The subject folder under [folders] that is really this one's, or null when
/// none of them is.
///
/// **The folder name is not derivable.** `subjectFolderName` builds
/// `<code> <name>`, which is right for anything this app filed — but most of
/// `py_qp/` was named by hand before it existed, and the names are not that
/// shape: `1BAIA103`'s is `1BAIA103  1BAIA103_203_ BETC105x_205x Introduction
/// to AI and Applications` where the layout builds `1BAIA103 Introduction to AI
/// and Applications`. Listing it then returns nothing, which reads as an empty
/// folder. So the bucket is asked, and only the code is matched — it is the one
/// part of the name nobody gets wrong.
///
/// [folders] is the `CommonPrefixes` of the level above. Null is the ordinary
/// answer for a subject nothing has been filed under yet, and the caller falls
/// back to [subjectFolderName] to create it.
String? subjectFolderIn(Iterable<String> folders, String code) {
  final wanted = code.trim().toLowerCase();
  if (wanted.isEmpty) return null;
  // The code has to be the whole first word: `1BAIA1031` is a different subject.
  final starts = RegExp('^${RegExp.escape(wanted)}(?![a-z0-9])');
  for (final folder in folders) {
    final leaf = folder.endsWith('/')
        ? folder.substring(0, folder.length - 1)
        : folder;
    final slash = leaf.lastIndexOf('/');
    final name = (slash == -1 ? leaf : leaf.substring(slash + 1)).trim();
    if (starts.hasMatch(name.toLowerCase())) return folder;
  }
  // ponytail: the first match, when a subject has somehow been filed twice. The
  // picker shows what it found, so a wrong one is visible rather than silent.
  return null;
}

/// `<root>/<BRANCH_Code_Name>/` for a row that *is* a branch — a `gatepyqs` row
/// or a `branches` row.
///
/// `code` is a branch code; one the lookup has not heard of still files under
/// the code itself, which is inside the right tree and self-explanatory. That is
/// the common case on a row being created, where the name is not in the database
/// yet.
String? _branchPath(String root, Map<String, String> row, BucketNames names) {
  final code = (row['code'] ?? '').trim();
  if (code.isEmpty) return null;
  return '$root/${branchFolderName(code, names.branches[code] ?? '')}/';
}

/// `vtu/scheme-2025/1st_year/` or `vtu/scheme-2025/AE_…/3rd_sem/`.
String? _semesterPath(Map<String, String> row, BucketNames names) {
  final schemeCode = (row['scheme_code'] ?? '').trim();
  if (schemeCode.isEmpty) return null;
  final scheme = schemeFolderName(names.schemes[schemeCode] ?? '');
  if (scheme == null) return null;

  final level = levelFolderName(row['semester']);
  if (level == null) return null;
  // First year is taught before a student has a branch, so it sits directly
  // under the scheme — even for the rows that do name a branch.
  if (level == firstYearFolder) return '$bucketRoot/$scheme/$level/';

  final branchCode =
      ((row['branch'] ?? '').trim().isNotEmpty ? row['branch'] : row['branch_code'])
              ?.trim() ??
          '';
  final branchName = names.branches[branchCode] ?? '';
  if (branchCode.isEmpty || branchName.isEmpty) return null;
  return '$bucketRoot/$scheme/${branchFolderName(branchCode, branchName)}/$level/';
}

/// What the file itself should be called, without an extension — the picked
/// file's own extension is kept.
///
/// Null falls back to the name the phone gave the download, which is only ever
/// right by accident (`Document(2).pdf`).
String? bucketBaseNameFor(
  BucketFolder kind,
  Map<String, String> row, {
  required String column,
  String subjectName = '',
}) {
  String value(String name) => (row[name] ?? '').trim();

  switch (kind) {
    case BucketFolder.flat:
      return null;

    // 'june_july_2025' and '2014' are the column names, and inside a subject
    // folder that is the whole story a filename has to tell.
    case BucketFolder.questionPaper:
    case BucketFolder.gatePaper:
      return bucketSafeName(column);

    case BucketFolder.schemeDocument:
      final name = bucketSafeName(value('scheme_name'));
      return name.isEmpty ? null : name;

    // A semester's `notes/` holds every subject's notes, and a branch's
    // `study_materials/` holds everything that branch publishes. Nothing the
    // folder or the column knows can tell one file from another, so the file
    // keeps the name the person picking it gave it — and they are the only one
    // who can. The name *students* see is set separately, in the picker.
    //
    // This is the one place the picked file's own name is trusted, which is why
    // the upload still offers the key for editing before it goes anywhere.
    case BucketFolder.notes:
    case BucketFolder.studyMaterials:
      return null;

    case BucketFolder.syllabus:
    case BucketFolder.labManual:
      final code = value('sem_1_sub_code').isNotEmpty
          ? value('sem_1_sub_code')
          : value('sem_2_sub_code');
      final name = subjectFolderName(code, value('sub_name'));
      return name.isEmpty ? null : name;
  }
}

/// The `deleted_old_files/` that belongs to [key] — the one at its own level.
///
/// A replaced third-semester paper goes to
/// `vtu/scheme-2025/AE_…/3rd_sem/deleted_old_files/`, not to a bin at the bucket
/// root: a folder that keeps its own history stays readable, and a single shared
/// bin turns into thousands of files nobody dares touch.
///
/// The level is the deepest `1st_year`/`Nth_sem` ancestor. Below that the path is
/// kept as-is, so `py_qp/<subject>/june_july_2025.pdf` archives to
/// `…/3rd_sem/deleted_old_files/<stamp>/py_qp/<subject>/june_july_2025.pdf` and
/// still says what it was. Anything outside a semester — a GATE paper, a job
/// attachment — is binned in its own folder.
String archiveFolderFor(String key) {
  final segments = key.split('/')..removeLast(); // the file itself
  final level = segments.lastIndexWhere(_isLevelFolder);
  final base = level == -1 ? segments : segments.sublist(0, level + 1);
  return [...base, archiveFolderName].join('/');
}

/// The part of [key] kept below the timestamp: everything under its level.
String _pathBelowLevel(String key) {
  final segments = key.split('/');
  final level = segments.sublist(0, segments.length - 1).lastIndexWhere(_isLevelFolder);
  return level == -1 ? segments.last : segments.sublist(level + 1).join('/');
}

bool _isLevelFolder(String segment) =>
    segment == firstYearFolder ||
    RegExp(r'^[1-8](?:st|nd|rd|th)_sem$').hasMatch(segment);

/// True when [key] is already inside a `deleted_old_files/` anywhere in the tree.
/// Those are deleted outright rather than archived again — otherwise the bin
/// could never be emptied.
bool isInArchive(String key) =>
    key.split('/').any((segment) => segment == archiveFolderName);

/// `…/deleted_old_files/2026-08-31_143205/py_qp/…` — the moment it stopped being
/// current, then the path it had below its level.
///
/// The stamp means replacing the same file twice keeps both versions and nothing
/// already in the archive is overwritten in turn. One stamp for a whole
/// operation, so a deleted folder lands in the bin as the tree it was.
String archiveKeyFor(String key, DateTime when) {
  String two(int value) => value.toString().padLeft(2, '0');
  final at = when.toLocal();
  final stamp = '${at.year}-${two(at.month)}-${two(at.day)}'
      '_${two(at.hour)}${two(at.minute)}${two(at.second)}';
  return '${archiveFolderFor(key)}/$stamp/${_pathBelowLevel(key)}';
}

/// The folders a new one cannot do without: every semester has its papers folder
/// and its own bin, so making a semester makes all three; every GATE branch has
/// its three kind folders; every branch under `vtu/branches/` exists to hold its
/// study materials, so making it makes those. Everything else the layout knows
/// about is only offered — see [standardChildrenOf].
List<String> requiredChildrenOf(String prefix) {
  final segments = prefix.split('/').where((s) => s.isNotEmpty).toList();
  if (segments.isEmpty) return const [];
  // A GATE branch comes with its three kind folders for the same reason a
  // semester comes with py_qp: a branch folder without them is a folder uploads
  // have nowhere to go into, and the person making it would have to know the
  // three spellings and make each one by hand.
  if (segments.length == 3 &&
      segments.first == bucketRoot &&
      segments[1] == 'gatepyqs') {
    return gateKindFolders;
  }
  // A branch under `vtu/branches/` is a study-materials folder and nothing
  // else, so making it without one would leave a branch that can never be
  // uploaded into.
  if (segments.length == 3 &&
      segments.first == bucketRoot &&
      segments[1] == 'branches') {
    return const [studyMaterialsFolder];
  }
  if (!_isLevelFolder(segments.last)) return const [];
  return const [questionPaperFolder, archiveFolderName];
}

/// The folders that belong inside [prefix], so making one is a tap instead of
/// typing a name that has to match the convention exactly.
///
/// [schemeNames] and [branches] come from the database, so a scheme or branch
/// added last week is offered here without touching this file.
List<String> standardChildrenOf(
  String prefix, {
  Iterable<String> schemeNames = const [],
  Map<String, String> branches = const {},
}) {
  final segments = prefix.split('/').where((s) => s.isNotEmpty).toList();
  final branchFolders = [
    for (final entry in branches.entries) branchFolderName(entry.key, entry.value),
  ]..sort();
  final schemeFolders = [
    for (final name in schemeNames)
      ?schemeFolderName(name),
  ]..sort();

  // The bucket root: only `vtu/` belongs here, and the scheme-less branch tree
  // and the two scheme trees one level in.
  if (segments.isEmpty) return const [bucketRoot];
  if (segments.length == 1 && segments.first == bucketRoot) {
    return ['branches', 'gatepyqs', ...schemeFolders];
  }
  if (segments.length == 2 && segments.first == bucketRoot) {
    // `branches/` and `gatepyqs/` are each one folder per branch and nothing
    // else.
    if (segments[1] == 'branches' || segments[1] == 'gatepyqs') {
      return branchFolders;
    }
    if (segments[1].startsWith('scheme-')) {
      return [firstYearFolder, ...branchFolders];
    }
    return const [];
  }
  // A branch under `vtu/branches/` exists to hold its study materials and its
  // bin — see [requiredChildrenOf], which makes the first of those with it.
  if (segments.length == 3 &&
      segments.first == bucketRoot &&
      segments[1] == 'branches') {
    return const [studyMaterialsFolder, archiveFolderName];
  }
  // Inside that study_materials folder: files sit flat, so the bin is all there
  // is left to make.
  if (segments.length == 4 &&
      segments.first == bucketRoot &&
      segments[1] == 'branches' &&
      segments[3] == studyMaterialsFolder) {
    return const [archiveFolderName];
  }
  // Inside a GATE branch: the three kinds, and nothing else. No year level —
  // the year is in the file name. These are also the folders that cannot be
  // done without, so a branch created from here comes out ready to upload into
  // rather than needing three more taps.
  if (segments.length >= 3 && segments.first == bucketRoot && segments[1] == 'gatepyqs') {
    return segments.length == 3 ? gateKindFolders : const [];
  }
  // Inside a branch: the semesters it teaches.
  if (segments.length == 3 &&
      segments.first == bucketRoot &&
      segments[1].startsWith('scheme-') &&
      !_isLevelFolder(segments[2])) {
    return [for (var sem = 3; sem <= 8; sem++) '$sem${_ordinal(sem)}_sem'];
  }
  // Inside a semester: what every semester holds, plus `notes/` — which is only
  // offered, since a semester with no notes is a semester nobody has uploaded
  // for yet, not a broken one. There is no lab-manual folder: a lab manual goes
  // straight in here, named after its subject.
  if (_isLevelFolder(segments.last)) {
    return const [questionPaperFolder, notesFolder, archiveFolderName];
  }
  return const [];
}
