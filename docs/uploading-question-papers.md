# Uploading VTU question papers

How to fill the Previous Year Papers feature. Written 2026-09-17, when the
feature was measured as **empty**: 55 rows in `py_qp`, 20 exam sessions each
(1,100 cells), and **zero usable papers**.

## Where things stand

| | State |
|---|---|
| `py_qp` rows | 55 — one per subject, not one per paper |
| Exam-session columns | 20 (`Dec/Jan 2018` … `Jun/Jul 2027`) |
| Cells filled | **1**, and it is a **404** |
| Papers in R2 | **none** |

**Fix the one bad cell first.** Row `id = 107` (`CV`, semester 1, scheme `1`)
holds:

```
https://pub-195182fb36a34f84a8ac88b9369aaa3a.r2.dev/question-papers/3.-simple-language-1-.pdf
```

That key does not exist, and it sits on a `question-papers/` prefix that is not
part of the bucket's tree. It looks like leftover test data, and the filename
has nothing to do with `1BMATC101`. Clear that cell before anything else — a
student opening CV Semester 1 today gets a 404 rather than a paper.

## Where a paper file goes

One canonical tree, decided entirely by `lib/r2/bucket_layout.dart`. Never
compose a path by hand.

```
vtu/
  scheme-2025/
    1st_year/                          semesters 1, 2 and "1 & 2"
      py_qp/
        1BMATC101 Calculus/
          <the paper>.pdf
    CS_Computer_Science_&_Engineering/ semester 3 onwards, one per branch
      3rd_sem/
        py_qp/
          1BCS301 Data Structures/
            <the paper>.pdf
  scheme-2022/   scheme-2018/          same shape
  gatepyqs/                             already populated, do not touch
```

Two rules decide the middle of that path:

- **Scheme folder** comes from the scheme *name*, not its code: `'2025 CBCS'` →
  `scheme-2025`. Writing `scheme-1` (the code in `py_qp.scheme_code`) would
  create a folder nobody can interpret later.
- **Level folder** is `1st_year` for semesters 1, 2 and "1 & 2", and
  `3rd_sem` … `8th_sem` from semester 3 up. `1st_year` is also where a cycle
  subject goes, since it has no semester.

## Do not "tidy" the branch folder names

This is the trap that costs a redo. `branchFolderName()` keeps `&` and
parentheses, so the real spellings are:

```
CS_Computer_Science_&_Engineering
CD_CSE_(Data_Science)
VL_Electronics_Engineering_(VLSI_Design_and_Technology)
```

**24 of the 50 branches contain `&` or parentheses.** A friendlier-looking
`_and_` / no-parens version silently points at a *different* folder, and the
admin app will then create its own second folder beside the tidy one. Both
look half-empty afterwards.

If you are ever unsure, copy the folder name from the admin app's bucket screen
rather than typing it.

## How to upload

The admin app already has the whole editor — there is no code to write.

1. Open **Previous question papers** (`py_qp`) in the admin app.
2. Filter by **Scheme** and **Branch**.
3. Find the row for the subject.
4. Tap the session column you have a paper for, and upload the PDF.

Each session column is a file-upload field (`FieldType.fileUrl`, folder
`BucketFolder.questionPaper`). The upload writes the file to the tree above and
records the URL in the cell in one step.

## The 20 session columns

Every row has one column per session. The admin app labels them like this:

| Column | Label | Column | Label |
|---|---|---|---|
| `dec_jan_2018` | Dec/Jan 2018 | `june_july_2023` | Jun/Jul 2023 |
| `june_july_2018` | Jun/Jul 2018 | `dec_jan_2024` | Dec/Jan 2024 |
| `dec_jan_2019` | Dec/Jan 2019 | `june_july_2024` | Jun/Jul 2024 |
| `june_july_2019` | Jun/Jul 2019 | `dec_jan_2025` | Dec/Jan 2025 |
| `dec_jan_2020` | Dec/Jan 2020 | `june_july_2025` | Jun/Jul 2025 |
| `june_july_2020` | Jun/Jul 2020 | `dec_jan_2026` | Dec/Jan 2026 |
| `dec_jan_2021` | Dec/Jan 2021 | `june_july_2026` | Jun/Jul 2026 |
| `june_july_2021` | Jun/Jul 2021 | `dec_jan_2027` | Dec/Jan 2027 |
| `dec_jan_2022` | Dec/Jan 2022 | `june_july_2027` | Jun/Jul 2027 |
| `june_july_2022` | Jun/Jul 2022 | | |

**These are real columns, not rows.** Adding 2028 means an `ALTER TABLE`. The
`gatepyqs` table avoids this by storing JSON in a text cell, which also lets one
session hold several papers (a regular paper plus each re-sit).

## Two things to decide before bulk work starts

**Is 55 rows the right number?** That is roughly one row per first-year subject
plus a scattering of others — `CV` alone appears at semesters 1 and 2 across
three schemes, while most branches appear once. A full catalogue would be one
row per subject per branch per scheme, which is far more than 55. Worth
settling before uploading, because papers for a subject with no row have
nowhere to go.

**Only 2025 has a real scheme document.** `schemes.scheme_pdf` is a dummy
`1abc123def456` for 2022 and null for 2018 and 2017, so the scheme folders for
those years exist but the scheme itself cannot be downloaded. Fill those before
or alongside the papers, or first-year students on 2022 will hit the same dead
end the CV paper currently gives.

## Sanity check when you are done

The public host answers directly, so any uploaded file can be checked without
the app:

```
curl -sI "https://pub-195182fb36a34f84a8ac88b9369aaa3a.r2.dev/vtu/scheme-2025/1st_year/py_qp/1BMATC101%20Calculus/<file>.pdf"
```

A `200` with `content-type: application/pdf` means the file is where the
database says it is. A `404` means the recorded URL and the uploaded file
disagree — which is exactly the state row 107 is in today.
