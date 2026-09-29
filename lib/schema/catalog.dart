import 'package:flutter/material.dart';

import '../r2/bucket_layout.dart';
import 'field_spec.dart';
import 'gate_assets.dart';
import 'table_spec.dart';

/// Option sources that recur across tables.
///
/// [schemeLookup] and [branchLookup] are public because the bucket layout needs
/// them too: a row holds `scheme_code: '1'` and `branch: 'AE'`, while the folders
/// are `scheme-2025` and `AE_Aeronautical_Engineering`, so an upload has to read
/// the same two tables the dropdowns do.
const schemeLookup = Lookup(
  table: 'schemes',
  valueColumn: 'scheme_code',
  labelColumn: 'scheme_name',
  orderBy: 'scheme_code',
);
const _streamLookup = Lookup(
  table: 'streams',
  valueColumn: 'code',
  labelColumn: 'name',
  orderBy: 'code',
);
const branchLookup = Lookup(
  table: 'branches',
  valueColumn: 'code',
  labelColumn: 'name',
  orderBy: 'code',
);

/// The branch **name**, for the one column that is not a code despite its name:
/// `notifications.branch_code`. The push topic is built from that string and has
/// to match `profiles.branch` character for character, and profiles hold full
/// names ("Civil Engineering"). Offering `branches.code` there would build a
/// topic nobody is subscribed to — the send succeeds and reaches no one. The
/// website's push editor reads the same column the same way.
const _branchNameLookup = Lookup(
  table: 'branches',
  valueColumn: 'name',
  orderBy: 'name',
);

/// The eight semesters, for audience filters where the column is an integer but
/// only ever holds 1–8. Typing it invites a 9.
const List<String> _semesterOptions = ['1', '2', '3', '4', '5', '6', '7', '8'];

/// The semesters a subject or a paper row is filed under, in the order VTU
/// numbers them — `1 & 2` is the whole of the first year, which is why those
/// subjects come second rather than last.
///
/// A list of strings, not a range: `1 & 2` is why `subjects.semester` and
/// `py_qp.semester` are text columns. Both tables use this one list so the two
/// screens offer the same choice.
const List<String> subjectSemesterOptions = [
  '1', '2', '1 & 2', '3', '4', '5', '6', '7', '8',
];
const _categoryKeyLookup = Lookup(
  table: 'notification_categories',
  valueColumn: 'key',
  labelColumn: 'label',
  orderBy: 'sort_order',
);

/// The twenty VTU exam sittings, one column each in `py_qp`, newest first:
/// `june_july_2027` down to `dec_jan_2018`.
///
/// Listing them once is what keeps the form's twenty session fields in step with
/// each other. The order is the form's order — it renders fields as they are
/// declared, and puts no sort of its own on them — and it is reversed on purpose:
/// the sitting being filled in is nearly always a recent one, and the last of
/// these is eight years and twenty fields down the screen.
const List<String> pyqpSessionColumns = [
  'june_july_2027', 'dec_jan_2027',
  'june_july_2026', 'dec_jan_2026',
  'june_july_2025', 'dec_jan_2025',
  'june_july_2024', 'dec_jan_2024',
  'june_july_2023', 'dec_jan_2023',
  'june_july_2022', 'dec_jan_2022',
  'june_july_2021', 'dec_jan_2021',
  'june_july_2020', 'dec_jan_2020',
  'june_july_2019', 'dec_jan_2019',
  'june_july_2018', 'dec_jan_2018',
];

/// Every table the console can edit.
///
/// Order matters only for display. Anything with an `is_web_admin()` write
/// policy can be added here; anything without one will read fine and fail on
/// save, which is why the list matches the policies exactly.
final List<TableSpec> adminCatalog = [
  // ───────────────────────────── Academic data ─────────────────────────────
  TableSpec(
    table: 'subjects',
    title: 'Subjects',
    description:
        'Subject names, codes and syllabus PDFs. This is what the app shows '
        'under a semester.',
    icon: Icons.menu_book_outlined,
    group: 'Academic data',
    primaryKey: 'id',
    orderBy: 'id',
    searchColumns: ['sub_name', 'sem_1_sub_code', 'sem_2_sub_code'],
    titleColumns: ['sub_name'],
    // `branch` last because most rows have none; where it is set it is the thing
    // that distinguishes the row, and an empty column prints nothing.
    subtitleColumns: ['sem_1_sub_code', 'sem_2_sub_code', 'semester', 'branch'],
    filters: [
      FilterSpec('scheme_code', 'Scheme', lookup: schemeLookup),
      FilterSpec('semester', 'Semester', options: subjectSemesterOptions),
      FilterSpec('stream', 'Stream', lookup: _streamLookup),
      // The column holds a branch *code* (`AE`), not a name — unlike
      // `notifications.branch_code` — so this is the plain code lookup.
      //
      // Most first-year rows have no branch at all, because those subjects are
      // common to every branch. Picking one therefore narrows to that branch's
      // own subjects and drops the common ones; that is the column's meaning,
      // not a filter that is missing rows.
      FilterSpec('branch', 'Branch', lookup: branchLookup),
    ],
    fields: [
      FieldSpec('id', 'Row id', readOnly: true, help: 'Assigned by the database.'),
      FieldSpec('sub_name', 'Subject name',
          type: FieldType.text, required: true, maxLines: 2),
      FieldSpec('sem_1_sub_code', 'Semester 1 code',
          help: 'Subject code as printed for semester 1, e.g. 1BMATC101. '
              'Leave empty if this subject is not offered in sem 1.'),
      FieldSpec('sem_2_sub_code', 'Semester 2 code',
          help: 'The sem-2 twin of the same subject, e.g. 1BMATC201.'),
      FieldSpec('syllabus_link', 'Syllabus PDF',
          type: FieldType.fileUrl,
          bucketFolder: BucketFolder.syllabus,
          help: 'Opened by the Syllabus screen. Either a vtu.ac.in link or a '
              'file uploaded to the bucket.'),
      // The three Resources categories each get their own document rather than
      // all three showing the syllabus. Both of the ones below are built by
      // ticking files in the subject's own folder under its semester — notes
      // under `…/3rd_sem/notes/`, flat, because a semester's notes belong to the
      // semester and the file names already say which subject they are — so the
      // upload files itself and the button cannot misspell the JSON.
      FieldSpec('notes_link', 'Notes',
          type: FieldType.documentList,
          maxLines: 8,
          bucketFolder: BucketFolder.notes,
          help: 'One or more sets of notes. Each file is listed on the Notes '
              'screen under the name you give it here.'),
      FieldSpec('lab_manual_link', 'Lab manual',
          type: FieldType.fileUrl,
          bucketFolder: BucketFolder.labManual,
          help: 'Shown under Lab Manuals in Resources.'),
      FieldSpec('scheme_code', 'Scheme',
          type: FieldType.select, lookup: schemeLookup),
      FieldSpec('semester', 'Semester',
          type: FieldType.select,
          options: subjectSemesterOptions,
          freeTextSelect: true,
          help: '"1 & 2" means the same subject runs in both first-year '
              'semesters — that is why this is text, not a number.'),
      FieldSpec('stream', 'Stream',
          type: FieldType.select,
          lookup: _streamLookup,
          freeTextSelect: true,
          help: 'ALL means every stream sees this subject.'),
      FieldSpec('branch', 'Branch',
          type: FieldType.select, lookup: branchLookup, freeTextSelect: true),
      FieldSpec('cycle', 'Cycle',
          type: FieldType.select,
          options: ['P', 'C'],
          help: 'P = Physics cycle, C = Chemistry cycle. Empty for subjects '
              'that are not cycle-specific.'),
      FieldSpec('sub_category', 'Category',
          type: FieldType.select,
          lookup: Lookup(
              table: 'subjects', valueColumn: 'sub_category', distinct: true),
          freeTextSelect: true,
          help: 'VTU course-basket name, e.g. "Programme Specific Courses (PSC)".'),
      FieldSpec('elective', 'Elective',
          type: FieldType.select,
          options: ['1'],
          help: 'Set to 1 for an elective. The app hides electives the student '
              'did not choose.'),
      FieldSpec('created_at', 'Created', type: FieldType.dateTime, readOnly: true),
      FieldSpec('updated_at', 'Updated', type: FieldType.dateTime, readOnly: true),
    ],
  ),

  TableSpec(
    table: 'py_qp',
    title: 'Previous question papers',
    description:
        'One row per subject; one column per exam session. A session holds that '
        'sitting\'s papers and solved papers — use "Build from bucket" to tick '
        'the files rather than typing the JSON.',
    icon: Icons.description_outlined,
    group: 'Academic data',
    primaryKey: 'id',
    orderBy: 'id',
    searchColumns: ['sem_1_sub_code', 'sem_2_sub_code'],
    titleColumns: ['sem_1_sub_code', 'sem_2_sub_code'],
    subtitleColumns: ['scheme_code', 'branch_code', 'semester'],
    // The row is a code and nothing else, so the list appends the subject's own
    // name after it. Matched through `subjects`, which holds the codes the app
    // itself places students by.
    subjectCodeColumns: ['sem_1_sub_code', 'sem_2_sub_code'],
    filters: [
      FilterSpec('scheme_code', 'Scheme', lookup: schemeLookup),
      FilterSpec('semester', 'Semester', options: subjectSemesterOptions),
      FilterSpec('stream', 'Stream', lookup: _streamLookup),
      FilterSpec('branch_code', 'Branch', lookup: branchLookup),
    ],
    fields: [
      FieldSpec('id', 'Row id', readOnly: true),
      FieldSpec('scheme_code', 'Scheme',
          type: FieldType.select, lookup: schemeLookup, required: true),
      FieldSpec('sem_1_sub_code', 'Semester 1 code'),
      FieldSpec('sem_2_sub_code', 'Semester 2 code'),
      // The placement column: this is what decides which students see the paper.
      // `branch_code` and `semester` below it are labels nothing reads.
      FieldSpec('stream', 'Stream',
          type: FieldType.select,
          lookup: _streamLookup,
          freeTextSelect: true,
          help: 'Which students sit this paper: CSE, CV, ECE, EEE, ME, or ALL '
              'for a paper every stream takes. This is the column that places '
              'the paper in the app. Leave it empty and the subject code decides '
              'instead.'),
      FieldSpec('branch_code', 'Branch',
          type: FieldType.select,
          lookup: branchLookup,
          freeTextSelect: true,
          help: 'A label, not a branch anyone studies. It holds one stray code '
              'per row and no student’s branch is ever this value — nothing '
              'filters on it. Set Stream above instead.'),
      FieldSpec('semester', 'Semester',
          type: FieldType.select,
          options: subjectSemesterOptions,
          freeTextSelect: true,
          help: '"1 & 2" means the paper covers both first-year semesters — '
              'that is why this is text, not a number. A label: the app places '
              'a paper by Stream, not by this.'),
      // The same JSON a `gatepyqs` year cell holds — one sitting's paper and
      // solved paper, each possibly several files, since VTU sets up to three
      // papers (A, B, C) for the same sitting. Edited by ticking files in the
      // subject's folder, and read back by the same parser.
      for (final column in pyqpSessionColumns)
        FieldSpec(column, pyqpSessionLabel(column),
            type: FieldType.gateAssets,
            bucketFolder: BucketFolder.questionPaper),
      FieldSpec('created_at', 'Created', type: FieldType.dateTime, readOnly: true),
      FieldSpec('updated_at', 'Updated', type: FieldType.dateTime, readOnly: true),
    ],
  ),

  TableSpec(
    table: 'schemes',
    title: 'Schemes',
    description: 'The VTU schemes students can pick, and each scheme document.',
    icon: Icons.account_tree_outlined,
    group: 'Academic data',
    primaryKey: 'id',
    orderBy: 'scheme_code',
    searchColumns: ['scheme_code', 'scheme_name'],
    titleColumns: ['scheme_name'],
    subtitleColumns: ['scheme_code'],
    fields: [
      FieldSpec('id', 'Row id', readOnly: true),
      FieldSpec('scheme_code', 'Scheme code',
          required: true,
          help: 'Short key stored on every subject and profile — changing it '
              'orphans existing rows.'),
      FieldSpec('scheme_name', 'Scheme name', required: true),
      FieldSpec('scheme_pdf', 'Scheme PDF',
          type: FieldType.fileUrl, bucketFolder: BucketFolder.schemeDocument),
      FieldSpec('created_at', 'Created', type: FieldType.dateTime, readOnly: true),
    ],
  ),

  TableSpec(
    table: 'branches',
    title: 'Branches',
    description: 'Engineering branches. The code is what other tables store.',
    icon: Icons.hub_outlined,
    group: 'Academic data',
    primaryKey: 'id',
    orderBy: 'code',
    searchColumns: ['code', 'name'],
    titleColumns: ['name'],
    subtitleColumns: ['code'],
    fields: [
      FieldSpec('id', 'Row id', readOnly: true),
      FieldSpec('code', 'Code', required: true, help: 'Unique, e.g. CSE.'),
      FieldSpec('name', 'Name', required: true, help: 'Unique.'),
      FieldSpec('stream_id', 'Stream id',
          type: FieldType.integer,
          required: true,
          help: 'Row id from Streams — not the stream code.'),
      // These belong to the branch rather than to any subject of it, which is
      // why they hang off this table: the Branch-wise Study Materials screen
      // shows a branch filter and these files, with no subject rows at all.
      //
      // They are also the one branch column with no semester, so they file
      // under `vtu/branches/<BRANCH>/study_materials/` rather than inside a
      // scheme — see `r2/bucket_layout.dart` for the tree.
      FieldSpec('study_materials', 'Study materials',
          type: FieldType.documentList,
          maxLines: 8,
          bucketFolder: BucketFolder.studyMaterials,
          help: 'Files students see under Branch-wise Study Materials. Tick them '
              'in the branch\'s own folder; each one is listed under the name '
              'you give it here.'),
    ],
  ),

  TableSpec(
    table: 'streams',
    title: 'Streams',
    description: 'First-year streams (CSE, ME, CV…) used to pick sem 1–2 subjects.',
    icon: Icons.alt_route_outlined,
    group: 'Academic data',
    primaryKey: 'id',
    orderBy: 'code',
    searchColumns: ['code', 'name'],
    titleColumns: ['name'],
    subtitleColumns: ['code'],
    fields: [
      FieldSpec('id', 'Row id', readOnly: true),
      FieldSpec('code', 'Code', required: true, help: 'Unique, e.g. CSE.'),
      FieldSpec('name', 'Name', required: true, help: 'Unique.'),
    ],
  ),

  TableSpec(
    table: 'colleges',
    title: 'Colleges',
    description:
        'College code → name. The code is the USN prefix, e.g. 1AB in 1AB21CS001.',
    icon: Icons.apartment_outlined,
    group: 'Academic data',
    primaryKey: 'code',
    primaryKeyIsGenerated: false,
    orderBy: 'code',
    searchColumns: ['code', 'name'],
    titleColumns: ['name'],
    subtitleColumns: ['code'],
    fields: [
      FieldSpec('code', 'College code',
          required: true,
          help: 'Cannot be changed later — delete and re-add instead.'),
      FieldSpec('name', 'College name', required: true, maxLines: 2),
    ],
  ),

  TableSpec(
    table: 'zones',
    title: 'Zones',
    description: 'VTU regional zones used by the exam timetable.',
    icon: Icons.map_outlined,
    group: 'Academic data',
    primaryKey: 'id',
    orderBy: 'zone_code',
    searchColumns: ['zone_name'],
    titleColumns: ['zone_name'],
    subtitleColumns: ['zone_code'],
    fields: [
      FieldSpec('id', 'Row id', readOnly: true),
      FieldSpec('zone_name', 'Zone name', required: true),
      FieldSpec('zone_code', 'Zone code',
          type: FieldType.integer, required: true, help: 'Unique number.'),
    ],
  ),

  TableSpec(
    table: 'exam_timetable',
    title: 'Exam timetable',
    description:
        'The exam dates every study plan is built backwards from. One row per '
        'subject per exam.',
    icon: Icons.event_outlined,
    group: 'Academic data',
    primaryKey: 'id',
    orderBy: 'exam_date',
    searchColumns: ['subject_code', 'subject_name'],
    titleColumns: ['subject_name'],
    subtitleColumns: ['subject_code', 'exam_date', 'semester'],
    filters: [
      FilterSpec('scheme', 'Scheme', lookup: schemeLookup),
      FilterSpec('branch', 'Branch', lookup: branchLookup),
      FilterSpec('exam_type', 'Type',
          options: ['Regular', 'Revaluation', 'Backlog', 'Supplementary']),
    ],
    fields: [
      FieldSpec('id', 'Row id', readOnly: true),
      FieldSpec('subject_name', 'Subject name', maxLines: 2),
      FieldSpec('subject_code', 'Subject code'),
      FieldSpec('exam_date', 'Exam date',
          type: FieldType.date,
          help: 'What the AI study timetable counts down to.'),
      FieldSpec('exam_day', 'Day',
          type: FieldType.select,
          options: [
            'Monday', 'Tuesday', 'Wednesday', 'Thursday',
            'Friday', 'Saturday', 'Sunday',
          ]),
      FieldSpec('exam_time', 'Time',
          help: 'Free text as printed on the timetable, e.g. "2:00 PM to 5:00 PM".'),
      FieldSpec('scheme', 'Scheme',
          type: FieldType.select, lookup: schemeLookup, freeTextSelect: true),
      FieldSpec('branch', 'Branch',
          type: FieldType.select, lookup: branchLookup, freeTextSelect: true),
      FieldSpec('semester', 'Semester', type: FieldType.integer),
      FieldSpec('exam_type', 'Exam type',
          type: FieldType.select,
          options: ['Regular', 'Revaluation', 'Backlog', 'Supplementary'],
          freeTextSelect: true),
    ],
  ),

  TableSpec(
    table: 'resources',
    title: 'Resources',
    description: 'Notes, videos and other study material shown per subject.',
    icon: Icons.folder_copy_outlined,
    group: 'Academic data',
    primaryKey: 'id',
    orderBy: 'id',
    ascending: false,
    searchColumns: ['title', 'subject_code', 'subject_name'],
    titleColumns: ['title'],
    subtitleColumns: ['resource_type', 'subject_code', 'semester'],
    filters: [
      FilterSpec('scheme_code', 'Scheme', lookup: schemeLookup),
      FilterSpec('resource_type', 'Type',
          lookup: Lookup(
              table: 'resources', valueColumn: 'resource_type', distinct: true)),
    ],
    fields: [
      FieldSpec('id', 'Row id', readOnly: true),
      FieldSpec('title', 'Title', required: true, maxLines: 2),
      FieldSpec('resource_url', 'Resource URL',
          type: FieldType.fileUrl,
          required: true,
          uploadPrefix: 'resources',
          help: 'The file itself, or a link to it.'),
      FieldSpec('description', 'Description',
          type: FieldType.multiline, maxLines: 5),
      FieldSpec('resource_type', 'Resource type',
          type: FieldType.select,
          lookup: Lookup(
              table: 'resources', valueColumn: 'resource_type', distinct: true),
          freeTextSelect: true),
      FieldSpec('subject_code', 'Subject code'),
      FieldSpec('subject_name', 'Subject name'),
      FieldSpec('scheme_code', 'Scheme',
          type: FieldType.select, lookup: schemeLookup, freeTextSelect: true),
      FieldSpec('stream', 'Stream',
          type: FieldType.select, lookup: _streamLookup, freeTextSelect: true),
      FieldSpec('branch', 'Branch',
          type: FieldType.select, lookup: branchLookup, freeTextSelect: true),
      FieldSpec('semester', 'Semester'),
      FieldSpec('cycle', 'Cycle', type: FieldType.select, options: ['P', 'C']),
      FieldSpec('uploaded_by', 'Uploaded by'),
      FieldSpec('is_active', 'Visible in the app', type: FieldType.boolean),
      FieldSpec('created_at', 'Created', type: FieldType.dateTime, readOnly: true),
      FieldSpec('updated_at', 'Updated', type: FieldType.dateTime, readOnly: true),
    ],
  ),

  TableSpec(
    table: 'gatepyqs',
    title: 'GATE papers',
    description: 'GATE previous papers by branch code, one column per year. '
        'Each year holds its paper, answer key and solved paper — use "Build '
        'from bucket" rather than typing the JSON.',
    icon: Icons.school_outlined,
    group: 'Academic data',
    primaryKey: 'id',
    orderBy: 'code',
    searchColumns: ['code'],
    titleColumns: ['code'],
    fields: [
      FieldSpec('id', 'Row id', readOnly: true),
      FieldSpec('code', 'Branch code',
          required: true,
          help: 'GATE paper code, e.g. CV, CH, CS. One row per branch — this is '
              'also what picks the bucket folder the papers come from.'),
      // Every GATE year since the app has papers for, whether or not anything is
      // in it yet: the column exists in the database, and a year that is not
      // here cannot be filled in from the phone at all.
      //
      // Each cell holds JSON naming that year's paper, answer key and solved
      // paper — see schema/gate_assets.dart. Use "Build from bucket": it ticks
      // files in vtu/gatepyqs/<CODE>_<Branch Name>/ and writes the JSON.
      for (var year = 2026; year >= 2014; year--)
        FieldSpec('$year', '$year',
            type: FieldType.gateAssets,
            maxLines: 8,
            bucketFolder: BucketFolder.gatePaper),
    ],
  ),

  TableSpec(
    table: 'formulas',
    title: 'Formulas',
    description:
        'The formula sheet and calculator. Title is the primary key, so it '
        'cannot be renamed.',
    icon: Icons.functions_outlined,
    group: 'Academic data',
    primaryKey: 'title',
    primaryKeyIsGenerated: false,
    orderBy: 'title',
    searchColumns: ['title', 'subject', 'subject_code', 'category'],
    titleColumns: ['title'],
    subtitleColumns: ['subject', 'module', 'category'],
    filters: [
      FilterSpec('branch_code', 'Branch', lookup: branchLookup),
      FilterSpec('difficulty', 'Difficulty',
          options: ['Beginner', 'Intermediate', 'Advanced']),
    ],
    fields: [
      FieldSpec('title', 'Title',
          required: true,
          help: 'Primary key — to rename a formula, add the new one and delete '
              'the old.'),
      FieldSpec('latex', 'LaTeX',
          type: FieldType.multiline,
          maxLines: 3,
          help: r'Rendered in the app, e.g. E = mc^2. No $ delimiters.'),
      FieldSpec('description', 'Description', type: FieldType.multiline, maxLines: 4),
      FieldSpec('calculator_formula', 'Calculator formula',
          help: 'Plain arithmetic over the variable names only: + - * / ^ and '
              'brackets. No functions and no leading minus — the in-app '
              'evaluator cannot parse those.'),
      FieldSpec('calculator_result_unit', 'Result unit'),
      FieldSpec('variables', 'Variables',
          type: FieldType.json,
          maxLines: 8,
          help: 'JSON. Order here is the order the calculator asks for them.'),
      FieldSpec('units', 'Units'),
      FieldSpec('subject', 'Subject'),
      FieldSpec('subject_code', 'Subject code'),
      FieldSpec('module', 'Module'),
      FieldSpec('category', 'Category'),
      FieldSpec('branch_code', 'Branch',
          type: FieldType.select, lookup: branchLookup, freeTextSelect: true),
      FieldSpec('semester', 'Semester', type: FieldType.integer),
      FieldSpec('difficulty', 'Difficulty',
          type: FieldType.select,
          options: ['Beginner', 'Intermediate', 'Advanced'],
          freeTextSelect: true),
      FieldSpec('importance', 'Importance'),
      FieldSpec('simple_explanation', 'Simple explanation',
          type: FieldType.multiline, maxLines: 6),
      FieldSpec('exam_explanation', 'Exam explanation',
          type: FieldType.multiline, maxLines: 6),
      FieldSpec('interview_explanation', 'Interview explanation',
          type: FieldType.multiline, maxLines: 6),
      FieldSpec('derivation', 'Derivation', type: FieldType.multiline, maxLines: 8),
      FieldSpec('example', 'Example', type: FieldType.multiline, maxLines: 5),
      FieldSpec('solved_question', 'Solved: question',
          type: FieldType.multiline, maxLines: 4),
      FieldSpec('solved_given', 'Solved: given', type: FieldType.multiline, maxLines: 3),
      FieldSpec('solved_formula_used', 'Solved: formula used'),
      FieldSpec('solved_substitution', 'Solved: substitution',
          type: FieldType.multiline, maxLines: 3),
      FieldSpec('solved_calculation', 'Solved: calculation',
          type: FieldType.multiline, maxLines: 3),
      FieldSpec('solved_answer', 'Solved: answer'),
      FieldSpec('solved_explanation', 'Solved: explanation',
          type: FieldType.multiline, maxLines: 5),
      FieldSpec('memory_mnemonic', 'Mnemonic'),
      FieldSpec('memory_notes', 'Memory notes', type: FieldType.multiline, maxLines: 4),
      FieldSpec('applications', 'Applications', type: FieldType.tags),
      FieldSpec('assumptions', 'Assumptions', type: FieldType.tags),
      FieldSpec('limitations', 'Limitations', type: FieldType.tags),
      FieldSpec('tags', 'Tags', type: FieldType.tags),
      FieldSpec('common_mistakes', 'Common mistakes', type: FieldType.json, maxLines: 6),
      FieldSpec('interpretations', 'Interpretations', type: FieldType.json, maxLines: 6),
      FieldSpec('external_url', 'External URL', type: FieldType.url),
      FieldSpec('is_active', 'Visible in the app', type: FieldType.boolean),
      FieldSpec('sort_order', 'Sort order', type: FieldType.integer),
    ],
  ),

  // ─────────────────────────────── Content ───────────────────────────────
  TableSpec(
    table: 'notifications',
    title: 'Announcements',
    description:
        'The Circulars screen. Saving publishes it there; the send button is '
        'what notifies phones.',
    icon: Icons.campaign_outlined,
    group: 'Content',
    primaryKey: 'id',
    orderBy: 'published_at',
    ascending: false,
    canSendPush: true,
    searchColumns: ['title', 'description'],
    titleColumns: ['title'],
    subtitleColumns: ['notif_type', 'published_at'],
    filters: [
      FilterSpec('notif_type', 'Category', lookup: _categoryKeyLookup),
      FilterSpec('branch_code', 'Branch', lookup: _branchNameLookup),
    ],
    fields: [
      FieldSpec('id', 'Row id', readOnly: true),
      FieldSpec('title', 'Title', required: true, maxLines: 2),
      FieldSpec('description', 'Body', type: FieldType.multiline, maxLines: 8),
      FieldSpec('notif_type', 'Category',
          type: FieldType.select,
          lookup: _categoryKeyLookup,
          required: true,
          help: 'Must match a key in Announcement categories — it picks the '
              'colour and the icon.'),
      FieldSpec('file_path', 'Attached file',
          type: FieldType.fileUrl,
          uploadPrefix: 'notifications',
          help: 'PDF or image shown with the announcement.'),
      FieldSpec('external_url', 'External link', type: FieldType.url),
      FieldSpec('branch_code', 'Branch',
          type: FieldType.select,
          lookup: _branchNameLookup,
          help: 'Audience filter. Clear it to reach every branch. These are the '
              'branch names as profiles store them — a hand-typed spelling '
              'reaches nobody, so pick from the list.'),
      FieldSpec('scheme_code', 'Scheme',
          type: FieldType.select, lookup: schemeLookup),
      FieldSpec('semester', 'Semester',
          type: FieldType.select,
          options: _semesterOptions,
          help: 'Clear it to reach every semester.'),
      FieldSpec('published_at', 'Publish at',
          type: FieldType.dateTime,
          help: 'A future time hides it from the app until then.'),
      FieldSpec('pinned', 'Pinned to the top', type: FieldType.boolean),
      FieldSpec('push_enabled', 'Allow sending to phones',
          type: FieldType.boolean,
          defaultValue: 'true',
          help: 'Turn this off for something that should sit in the app without '
              'a notification — the send button disappears. Nothing goes out '
              'until you press it.'),
      FieldSpec('push_sent_at', 'Push sent at',
          type: FieldType.dateTime, readOnly: true),
      FieldSpec('push_topic', 'Push topic', readOnly: true),
      FieldSpec('push_error', 'Push error', readOnly: true, maxLines: 3),
      FieldSpec('tags', 'Tags', type: FieldType.tags),
      FieldSpec('is_active', 'Visible in the app',
          type: FieldType.boolean, defaultValue: 'true'),
      FieldSpec('sort_order', 'Sort order', type: FieldType.integer),
      FieldSpec('created_at', 'Created', type: FieldType.dateTime, readOnly: true),
      FieldSpec('updated_at', 'Updated', type: FieldType.dateTime, readOnly: true),
    ],
  ),

  TableSpec(
    table: 'notification_categories',
    title: 'Announcement categories',
    description:
        'The categories announcements can use. The key is what an announcement '
        'stores.',
    icon: Icons.label_outline,
    group: 'Content',
    primaryKey: 'id',
    orderBy: 'sort_order',
    searchColumns: ['key', 'label'],
    titleColumns: ['label'],
    subtitleColumns: ['key', 'color'],
    fields: [
      FieldSpec('id', 'Row id', readOnly: true),
      FieldSpec('key', 'Key',
          required: true,
          help: 'Unique, upper case, e.g. RESULTS. Announcements store this '
              'string — renaming it strands the ones already using it.'),
      FieldSpec('label', 'Label', required: true),
      FieldSpec('color', 'Colour',
          required: true, help: 'Hex, e.g. #6B7280. Tints the card and the push.'),
      FieldSpec('sort_order', 'Sort order', type: FieldType.integer),
      FieldSpec('is_active', 'Selectable', type: FieldType.boolean),
      FieldSpec('created_at', 'Created', type: FieldType.dateTime, readOnly: true),
      FieldSpec('updated_at', 'Updated', type: FieldType.dateTime, readOnly: true),
    ],
  ),

  TableSpec(
    table: 'projects',
    title: 'Project ideas',
    description: 'The Project Ideas screen: mini, major, IEEE and AI ideas.',
    icon: Icons.lightbulb_outline,
    group: 'Content',
    primaryKey: 'id',
    orderBy: 'created_at',
    ascending: false,
    searchColumns: ['title', 'description', 'technology'],
    titleColumns: ['title'],
    subtitleColumns: ['project_type', 'difficulty', 'technology'],
    filters: [
      FilterSpec('project_type', 'Type',
          options: ['mini', 'major', 'ieee', 'ai_idea']),
      FilterSpec('difficulty', 'Difficulty',
          options: ['Beginner', 'Intermediate', 'Advanced']),
    ],
    fields: [
      FieldSpec('id', 'Row id', readOnly: true),
      FieldSpec('title', 'Title', required: true, maxLines: 2),
      FieldSpec('description', 'Description', type: FieldType.multiline, maxLines: 8),
      FieldSpec('project_type', 'Project type',
          type: FieldType.select,
          options: ['mini', 'major', 'ieee', 'ai_idea'],
          help: 'Which tab the idea appears under. Lower case, exactly as '
              'listed — the screen matches on this string.'),
      FieldSpec('technology', 'Technology'),
      FieldSpec('difficulty', 'Difficulty',
          type: FieldType.select,
          options: ['Beginner', 'Intermediate', 'Advanced'],
          freeTextSelect: true),
      FieldSpec('image_url', 'Thumbnail',
          type: FieldType.fileUrl, uploadPrefix: 'projects'),
      FieldSpec('repo_url', 'Repository URL', type: FieldType.url),
      FieldSpec('file_path', 'Attached file',
          type: FieldType.fileUrl, uploadPrefix: 'projects'),
      FieldSpec('external_url', 'External link', type: FieldType.url),
      FieldSpec('category', 'Category'),
      FieldSpec('branch_code', 'Branch',
          type: FieldType.select, lookup: branchLookup, freeTextSelect: true),
      FieldSpec('scheme_code', 'Scheme',
          type: FieldType.select, lookup: schemeLookup, freeTextSelect: true),
      FieldSpec('semester', 'Semester', type: FieldType.integer),
      FieldSpec('subject_code', 'Subject code'),
      FieldSpec('tags', 'Tags', type: FieldType.tags),
      FieldSpec('is_active', 'Visible in the app', type: FieldType.boolean),
      FieldSpec('sort_order', 'Sort order', type: FieldType.integer),
      FieldSpec('created_at', 'Created', type: FieldType.dateTime, readOnly: true),
      FieldSpec('updated_at', 'Updated', type: FieldType.dateTime, readOnly: true),
    ],
  ),

  TableSpec(
    table: 'jobs',
    title: 'Job updates',
    description: 'The Job Updates screen. Apply URL is the button students tap.',
    icon: Icons.work_outline,
    group: 'Content',
    primaryKey: 'id',
    orderBy: 'created_at',
    ascending: false,
    searchColumns: ['title', 'company', 'description'],
    titleColumns: ['title'],
    subtitleColumns: ['company', 'job_category', 'last_date'],
    filters: [
      FilterSpec('category', 'Category',
          options: ['it', 'core', 'govt', 'gate', 'internship']),
      FilterSpec('branch_code', 'Branch', lookup: branchLookup),
    ],
    fields: [
      FieldSpec('id', 'Row id', readOnly: true),
      FieldSpec('title', 'Title', required: true, maxLines: 2),
      FieldSpec('company', 'Company'),
      FieldSpec('description', 'Description', type: FieldType.multiline, maxLines: 8),
      FieldSpec('apply_url', 'Apply URL',
          type: FieldType.url, help: 'Where the Apply button goes.'),
      FieldSpec('category', 'Category',
          type: FieldType.select,
          options: ['it', 'core', 'govt', 'gate', 'internship'],
          help: 'Lower case — this drives the filter chips.'),
      FieldSpec('job_category', 'Job type',
          type: FieldType.select,
          options: ['Full-time', 'Internship', 'Government', 'PSU via GATE'],
          freeTextSelect: true,
          help: 'Shown on the card.'),
      FieldSpec('location', 'Location'),
      FieldSpec('last_date', 'Last date',
          help: 'Free text as printed in the notification.'),
      FieldSpec('branch_code', 'Branch',
          type: FieldType.select,
          lookup: branchLookup,
          freeTextSelect: true,
          help: 'Empty means every branch.'),
      FieldSpec('file_path', 'Attached file',
          type: FieldType.fileUrl, uploadPrefix: 'jobs'),
      FieldSpec('external_url', 'External link', type: FieldType.url),
      FieldSpec('tags', 'Tags', type: FieldType.tags),
      FieldSpec('is_active', 'Visible in the app', type: FieldType.boolean),
      FieldSpec('sort_order', 'Sort order', type: FieldType.integer),
      FieldSpec('created_at', 'Created', type: FieldType.dateTime, readOnly: true),
      FieldSpec('updated_at', 'Updated', type: FieldType.dateTime, readOnly: true),
    ],
  ),

  TableSpec(
    table: 'store',
    title: 'Store listings',
    description:
        'The approval queue. A student listing arrives "pending" and reaches the '
        'Store only once it is approved here.',
    icon: Icons.storefront_outlined,
    group: 'Content',
    primaryKey: 'id',
    orderBy: 'created_at',
    ascending: false,
    // No admin INSERT policy: a listing must keep a real seller behind it.
    canCreate: false,
    canModerate: true,
    searchColumns: ['title', 'description', 'seller_name'],
    titleColumns: ['title'],
    subtitleColumns: ['status', 'price', 'seller_name', 'created_at'],
    // The photo is most of the decision — half the refusal presets are judgments
    // about it — so it belongs on the row, not two taps inside the editor.
    thumbnailColumn: 'image_url',
    filters: [
      // First because it is the one filter tapped daily: `pending` is the queue.
      FilterSpec('status', 'Status',
          options: ['pending', 'approved', 'rejected']),
      FilterSpec('category', 'Category',
          lookup: Lookup(table: 'store', valueColumn: 'category', distinct: true)),
    ],
    fields: [
      FieldSpec('id', 'Row id', readOnly: true),
      // The four review columns are read-only here and written by the
      // Approve / Not approved buttons instead — the trigger stamps
      // `reviewed_at`/`reviewed_by` off a change of status, so a form that could
      // set one without the other would only produce disagreeing rows.
      FieldSpec('status', 'Status',
          readOnly: true,
          help: 'Only "approved" is on the Store. Use the Approve / Not approved '
              'buttons above — a student re-listing after an edit sends it back '
              'to pending by itself.'),
      FieldSpec('review_note', 'Reason sent to the seller',
          type: FieldType.multiline,
          maxLines: 4,
          readOnly: true,
          help: 'What the seller reads in My Listings. Written by the '
              'Not approved button.'),
      FieldSpec('reviewed_at', 'Reviewed',
          type: FieldType.dateTime, readOnly: true),
      FieldSpec('reviewed_by', 'Reviewed by', readOnly: true),
      FieldSpec('title', 'Title', required: true, maxLines: 2),
      FieldSpec('description', 'Description', type: FieldType.multiline, maxLines: 6),
      FieldSpec('price', 'Price', type: FieldType.decimal, required: true),
      FieldSpec('category', 'Category'),
      FieldSpec('condition', 'Condition'),
      FieldSpec('image_url', 'Image', type: FieldType.fileUrl, readOnly: true),
      FieldSpec('seller_name', 'Seller', readOnly: true),
      FieldSpec('seller_contact', 'Seller contact', readOnly: true),
      FieldSpec('seller_id', 'Seller id', readOnly: true),
      FieldSpec('is_active', 'Visible in the app',
          type: FieldType.boolean,
          help: 'Off means the seller marked it sold. A listing that is not '
              'approved is hidden whatever this says.'),
      FieldSpec('created_at', 'Created', type: FieldType.dateTime, readOnly: true),
      FieldSpec('updated_at', 'Updated', type: FieldType.dateTime, readOnly: true),
    ],
  ),

  // ───────────────────────────────── App ─────────────────────────────────
  TableSpec(
    table: 'profiles',
    title: 'Users',
    description:
        'Every account, in the profiles table. Read-only: a student owns their '
        'row, and the app treats an admin edit as that student editing it.',
    icon: Icons.people_outline,
    group: 'App',
    primaryKey: 'id',
    orderBy: 'updated_at',
    ascending: false,
    // Read-only in both directions. There is no admin INSERT policy on
    // `profiles`, and the only UPDATE policy is `id = auth.uid()` — so a save
    // from here would be refused by the database on every row but your own. The
    // columns are marked read-only rather than left to fail, because "Nothing
    // changed" is a better answer than a permission error.
    canCreate: false,
    canDelete: false,
    searchColumns: ['name', 'usn', 'email', 'college_name'],
    titleColumns: ['name'],
    subtitleColumns: ['usn', 'branch', 'current_semester', 'college_name'],
    filters: [
      // Branch *names*, not codes: `profiles.branch` holds "Civil Engineering",
      // the same string the push topics are built from. See `_branchNameLookup`.
      FilterSpec('branch', 'Branch', lookup: _branchNameLookup),
      FilterSpec('scheme', 'Scheme', lookup: schemeLookup),
      FilterSpec('current_semester', 'Semester', options: _semesterOptions),
      FilterSpec('cycle', 'Cycle', options: ['Physics Cycle', 'Chemistry Cycle']),
    ],
    fields: [
      FieldSpec('id', 'User id', readOnly: true),
      FieldSpec('name', 'Name', readOnly: true),
      FieldSpec('usn', 'USN', readOnly: true,
          help: 'The university seat number — what a college is read off.'),
      FieldSpec('branch', 'Branch', readOnly: true,
          type: FieldType.select, lookup: _branchNameLookup,
          help: 'The full name, as the push topics and the app use it.'),
      FieldSpec('college_name', 'College', readOnly: true),
      FieldSpec('current_semester', 'Semester',
          type: FieldType.integer, readOnly: true),
      FieldSpec('email', 'Email', readOnly: true),
      FieldSpec('scheme', 'Scheme',
          type: FieldType.select, lookup: schemeLookup, readOnly: true),
      FieldSpec('cycle', 'Cycle', readOnly: true),
      FieldSpec('is_admin', 'Admin flag', type: FieldType.boolean, readOnly: true,
          help: 'Not what makes an admin. The console is gated on the '
              'web_admins table — this flag is read by the app for its own '
              'screens.'),
      FieldSpec('updated_at', 'Updated', type: FieldType.dateTime, readOnly: true),
    ],
  ),

  TableSpec(
    table: 'app_links',
    title: 'App links',
    description:
        'Links the live app opens — Play Store, privacy policy, support. '
        'Editing one takes effect without an app release.',
    icon: Icons.link_outlined,
    group: 'App',
    primaryKey: 'key',
    primaryKeyIsGenerated: false,
    orderBy: 'key',
    searchColumns: ['key', 'label', 'url'],
    titleColumns: ['label'],
    subtitleColumns: ['key', 'url'],
    fields: [
      FieldSpec('key', 'Key',
          required: true,
          help: 'The app looks links up by this exact string — inventing a new '
              'one has no effect until the app is taught to read it.'),
      FieldSpec('url', 'URL', type: FieldType.url, required: true),
      FieldSpec('label', 'Label'),
      FieldSpec('is_active', 'Active',
          type: FieldType.boolean,
          help: 'Off hides whatever button opens this link.'),
      FieldSpec('updated_at', 'Updated', type: FieldType.dateTime, readOnly: true),
    ],
  ),
];

/// Dashboard sections, in display order.
const List<String> catalogGroups = ['Academic data', 'Content', 'App'];

TableSpec? specForTable(String table) {
  for (final spec in adminCatalog) {
    if (spec.table == table) return spec;
  }
  return null;
}
