# One VTU Admin

An Android app for editing the One VTU content: every content table in Supabase,
and the files in the Cloudflare R2 bucket those tables link to.

It is a companion to the student app (`vtu_timetable`), not part of it. The two
share one Supabase project and one bucket; this app writes, the student app
reads.

## What it can do

- **Content tables** — create, edit, duplicate and delete rows in 17 tables:
  subjects, previous-year papers, schemes, branches, streams, colleges, zones,
  GATE papers, resources, projects, jobs, exam timetable, formulas,
  notifications, notification categories, store listings and app links.
- **The bucket** — browse folders, upload, replace and delete objects in
  `vtu-resources`, create and delete folders, and copy an object's public link.
  Deleting a file or a folder moves it to its level's `deleted_old_files/` rather
  than destroying it.
- **The join between them** — a link column (`subjects.syllabus_link`,
  `resources.resource_url`, the 20 session columns on `py_qp`, each GATE year)
  has an **Upload** button that puts the file in the bucket and writes the
  resulting public URL straight into the column, and a **Pick from bucket**
  button for a file that is already there. The folder and the filename come from
  the row being edited, so uploads land in the bucket's own tree without anybody
  typing a path — see below. Uploading over a link **archives the file it
  replaces**.
- **Push notifications** — an announcement has a **send** button, on the row and
  in its editor, which notifies the students it is addressed to. Same mechanism
  as onevtu.in/admin: see below.
- **The Store approval queue** — a student's listing is held until it is approved
  here, so nothing a student posts reaches the Store unreviewed. A new listing
  arrives as a notification on this phone, and the decision notifies the seller.
  Approve or turn down from the row itself: see below.

There are no per-table screens. One `TableSpec` per table in
`lib/schema/catalog.dart` drives the list, the search box, the filter chips and
the form. Adding a column is a line in that file.

## Setting it up

### 1. Be a web admin

Writes are allowed by RLS policies that call `is_web_admin()`, which checks for a
row in `public.web_admins` matching the signed-in user. Nothing about the app
grants access — the same account works at onevtu.in/admin and nowhere else.

Signing in takes two steps, the same two as the website:

1. **Email and password.** If the admin account was created through Google
   sign-in it has no password yet — tap **Set or reset my password**, then open
   the emailed link and set one.
2. **A six-digit code** from your authenticator app.

The second step is not optional and not decoration: `is_web_admin()` also
requires the session to be at `aal2` whenever the account has an authenticator
set up, so a password-only session can *read* everything and has every write
refused. Adding or replacing an authenticator still happens on the website
(**Account** at onevtu.in/admin); the app only asks for the code. An account with
no authenticator at all skips step 2 — the database allows `aal1` in that case.

Two things that look like the same problem and are not:

- **"Not an admin account"** after signing in — the password and code were fine,
  the `web_admins` row is missing.
- **Every save refused with a permission error** while the app looks signed in —
  that is the second step missing, which this app now asks for. If it ever
  reappears, sign out and back in.

### 2. R2 keys, once, on the device

In Cloudflare: **R2 → API → Manage API tokens → Create API token**.

- Permission: **Object Read & Write** (Read-only lets you browse and breaks
  every upload with `AccessDenied`).
- Scope it to the `vtu-resources` bucket.

The token page shows an **Access Key ID**, a **Secret Access Key** (once — copy
it now) and an S3 endpoint like
`https://<account-id>.r2.cloudflarestorage.com`. The account id is that first
label.

Then in the app: **Bucket → key icon**, and fill in

| Field | Value |
| --- | --- |
| Account ID | the subdomain of the S3 endpoint |
| Access Key ID | from the token page |
| Secret Access Key | from the token page |
| Bucket | `vtu-resources` |
| Public base URL | `https://pub-195182fb36a34f84a8ac88b9369aaa3a.r2.dev` |

Saving runs a real request against the bucket and reports what came back.

The public base URL is the host students' devices fetch from — the
`r2.dev` domain or a custom domain, **not** the `r2.cloudflarestorage.com`
endpoint, which is private and needs a signature. The default matches the links
already in the database, so leave it alone unless the bucket moves to a custom
domain.

These four values live in Android Keystore-backed storage on the one phone they
were typed into. They are not in the APK, not in this repository, and are never
sent anywhere but Cloudflare.

### 3. Nothing, for push

Neither sending nor receiving needs setup in this app. Both go through Edge
Functions that already hold the FCM credential as a Supabase secret, and both
authorize with the admin's own session — so there is no key to install here and
nothing new in the APK. `android/app/google-services.json` is the only Firebase
file, it holds no secret, and it is already committed.

Receiving does need the notification permission, which the app asks for the first
time a sign-in is confirmed as an admin — not at launch, because until then there
is nothing to explain. Refusing it costs the notifications and nothing else: the
queue is a screen, and the push is only the convenience of not having to go and
look at it.

If a send reports *"Sending is not set up yet"*, the Supabase project has no
`FCM_SERVICE_ACCOUNT` secret: add it under **Edge Functions → Secrets**, with the
JSON from Firebase Console → Project settings → Service accounts → **Generate new
private key**. That is a project-wide setting shared with the website, so it is
normally already there.

## Where files go in the bucket

One bucket, one tree, and the app puts things in it — nobody types a path.

```
vtu-resources/
  vtu/
    scheme-2025/                                  one folder per scheme year
      1st_year/                                   semesters 1, 2 and "1 & 2"
        1BMATC101 Differential Calculus….pdf      syllabus_link
        py_qp/
          1BMATC101 Differential Calculus…/
            june_july_2025.pdf                    one file per py_qp session column
        deleted_old_files/
          2026-08-31_143205/…
      AE_Aeronautical_Engineering/                from semester 3, one per branch
        3rd_sem/
          1BAE305 Introduction to UAV Systems….pdf
          py_qp/1BAE305 Introduction to UAV Systems…/
          deleted_old_files/
    scheme-2022/   scheme-2018/                   same shape
    gatepyqs/
      AE_Aeronautical_Engineering/
        2014.pdf …                                one file per year column
```

`lib/r2/bucket_layout.dart` is that tree in code, and it is the only thing that
decides a folder. Press **Upload** on a link column and the destination is worked
out from the row you are editing — its scheme, its semester, its branch, its
subject code and name — so the key comes up prefilled and correct. **Pick from
bucket** opens in the same folder, which is why picking a file is a short list
instead of the whole bucket.

Three rules the tree depends on, all of them visible in the paths above:

- **The first year is one folder.** Semesters 1, 2, `1 & 2` and a cycle subject
  with no semester at all are `1st_year`, and it sits directly under the scheme
  even for a row that names a branch — students have no branch yet. The branch
  folder starts where the branch does, at `3rd_sem`.
- **Names keep their capitals and their spaces.** `AE_Aeronautical_Engineering`
  and `1BAE305 Introduction to UAV Systems and Technologies` are the convention
  and the 65 syllabus links already in the database are spelt that way. Only what
  would break a key or a URL is touched: `/ % # ? " < > | *` become spaces, and a
  colon becomes `_` (`Calculus_ ME Stream.pdf`).
- **Every level keeps its own `deleted_old_files/`.** A replaced third-semester
  paper stays with its semester instead of travelling to one bin at the root, so
  a folder still reads as one thing after a year of edits.

Nothing is guessed. If the row cannot place the file — no scheme picked, or a
fifth-semester subject with no branch — the upload asks for a key with no folder
filled in, because a folder invented from half a row is one somebody has to find
and clean up later.

Four columns are outside this tree, because the tree says nothing about them:
`resources.resource_url`, `notifications`, `projects` and `jobs` keep their own
flat prefixes (`resources/`, `notices/`, `projects/`, `jobs/`).

## Replacing a file behind a link

Open the row, press **Upload** on the link column, pick the new file. To swap the
syllabus of *Differential Calculus and Linear Algebra: CV Stream* (`1BMATC101`):
Subjects → that row → **Syllabus** → **Upload**.

What happens in the bucket, in this order:

1. The file the column points at now is **copied** into its own level's
   `deleted_old_files/<date>_<time>/`, keeping the path it had below that level —
   so `py_qp/<subject>/june_july_2025.pdf` still says what it was, and the
   archive browses like the folder it came from.
2. The new file is uploaded.
3. If you changed the name, the old object is deleted (its copy is already in the
   archive) and the new link is written to the column **immediately**, without
   waiting for Save.

Nothing is deleted before its copy exists, so a failure at any step leaves the
old file exactly where the database still expects it.

The key is offered prefilled — with the one it is replacing if there is one, or
the one the layout says it should have — and **keeping it is the safe choice**:
the link in the database, in the app, and in any link a student has already
shared keeps working, and there is nothing to save afterwards. Changing it is
allowed and is why step 3 writes the column straight away — leaving the form
without saving would otherwise leave a link pointing at a file that has moved to
the archive.

**Pick from bucket** archives nothing. It only re-points the column at a file
that is already there; the file it stops pointing at is still in use elsewhere as
far as this app knows.

## Folders, and deleting

**New folder** is in the top bar of the bucket screen, and makes the folder
inside whatever you are looking at. It offers the folders the layout expects
there as chips — the schemes and `gatepyqs` inside `vtu/`, `1st_year` and the
branches inside a scheme, `3rd_sem`…`8th_sem` inside a branch — read from the
database, so a branch added last week is on the list. Tapping one is the way to
get a name that matches the convention exactly. There is a free-text field for
anything else: `2026/notes` makes both levels at once, and capitals and spaces
are kept, because the bucket uses them.

Making a semester makes `py_qp/` and `deleted_old_files/` inside it at the same
time, since every semester has both.

An empty folder in S3 is a fiction — there are only keys with slashes in them, so
a new folder is a zero-byte marker object ending in `/`, which is what the
Cloudflare dashboard writes too. The marker is hidden from the file list and
disappears by itself once the folder has something real in it.

Deleting is the **bin icon**, on a file row or a folder row, and it goes to that
level's `deleted_old_files/` rather than destroying anything:

- **A folder** is counted first — the confirmation says how many files, how much,
  and names the first few — and then goes over one file at a time, showing
  progress. Everything under it goes, however deep. If a request fails it stops
  there: what has been deleted is in the archive, and the rest is untouched.
- **A file** is copied to the archive and then removed, the same as a replace.
- **Inside a `deleted_old_files/` it is permanent.** Nothing is archived twice —
  otherwise the bin could never be emptied — so a delete in there is the real
  one. That is also how you empty one: delete the dated folders.

Nothing prunes the archive on its own, and it is public like the rest of the
bucket, so an archived file's URL still works for anyone who kept it. To restore,
open the archived file and upload it back over the current key.

## Sending an announcement

Writing and sending are two separate steps, deliberately.

1. Write the announcement and save it. It is saved as a **draft**: no student can
   see it, and no phone has buzzed.
2. Press **send** (the paper-plane, on the row in Announcements or in the top bar
   of its editor). The app first asks the function who the row would reach, then
   shows the audience, the FCM topic and whether it has been sent before, and
   waits for confirmation.
3. Confirming publishes it. The notification going out and the row becoming
   readable in the app are the same moment, so "sent" and "visible" cannot drift
   apart. What was sent is recorded on the row itself — **Push sent at**, **Push
   topic**, and **Push error** if anything went wrong.

That order means a typo is an edit, not a second notification to every student.

Three things worth knowing:

- **The audience comes from the saved row**, never from the form: `branch_code`,
  `scheme_code` and `semester`, read by the function itself. So the editor
  refuses to send while there are unsaved edits — otherwise the old wording would
  go out. Leave all three empty to reach everyone.
- **A branch has to match `profiles` exactly.** The topic is built from the
  string, so a branch spelt differently from the one students' profiles hold
  produces a topic nobody is subscribed to: the send succeeds and reaches no one.
  That is why **Branch** on an announcement is the full name — "Civil
  Engineering", the same string profiles store — and not the `CV` code used
  everywhere else in this app, and why it can only be picked from the list.
  The topic in the confirmation is still there to be read.
- **Turning "Allow sending to phones" off** removes the send button, for an
  announcement that should sit in the app quietly. Saving it is not enough to
  publish it — a new row is a draft whatever the form says — so switch **Visible
  in the app** on as well to publish without notifying anyone.

## Approving Store listings

Every listing a student posts arrives **pending** and is invisible to everyone but
its seller until it is approved here. **Store listings** is therefore a queue, not
a list — open it, tap the **pending** filter chip, and work down.

**You are told when something arrives.** A listing lands as a notification on this
phone, and tapping it opens the queue already filtered to *pending*. Notifications
only start once a sign-in has been confirmed as an admin, and stop when you sign
out — so a phone that is no longer on duty stops buzzing.

**The photo is on the row.** Half the reasons a listing gets turned down are
judgments about its picture, so it sits at the left of every row rather than two
taps inside the editor. Tap the photo — not the row — to open it full screen, where
you can pinch to zoom in on a price tag or a phone number written across a corner;
tap the row itself to open the listing as usual. A listing with no photo shows a
struck-through picture mark, which is a decision in itself. The editor shows the
same photo, fitted whole, under the **Image** link.

Each row carries the two decisions in its trailing slot, and the same pair sits in
the top bar of the editor if you want to read the whole listing first:

- **✓ Approve** — the listing goes on the Store immediately. Any previous refusal
  reason is cleared, because it is the reason for a refusal that no longer stands.
- **⃠ Not approved** — opens a short sheet for the reason. Six presets cover
  almost everything ("Not a study item", "Photo needed", "Price looks wrong",
  "Contact in the text", "Duplicate", "Not a real listing"); tapping one fills the
  box in, and you can then edit it. The reason is optional but it is what the
  seller reads on **My listings**, so a sentence saves them a guess.

On an already-approved listing the second button is worded **Take it down**, and it
does exactly that: back off the Store, with the reason shown to the seller. A
taken-down listing can be approved again later.

Four things worth knowing:

- **Either decision notifies the seller.** They get a push — "Your listing is
  live", or the refusal with your reason in it — and it opens My listings on their
  phone. If that notification could not be sent, the confirmation says so in the
  same breath: *"Approved — it is on the Store now. But the seller was not
  notified — …"*. The decision has already been saved by then; only the telling
  failed, so there is nothing to redo except letting them know.
- **Status, reason, reviewed-at and reviewed-by are read-only in the form.** The
  database stamps the last two off a *change of status*, so a form able to set one
  without the other could only ever produce a row whose stamp disagrees with its
  status. The two buttons are the only way to write them, which is why they exist
  rather than a Status dropdown.
- **"Visible in the app" is the seller's own sold switch, not approval.** A
  listing that is not approved stays hidden whatever that switch says.
- **A seller can post 3 listings a day**, counted by the database, on the
  Asia/Kolkata day. Deleting a listing does not give the slot back — the ledger
  counts listings *created*, or a spammer would just delete and repost. To change
  the number, change `store_daily_listing_limit()` in Supabase; nothing in either
  app hard-codes a 3, and no app release is needed.

## Running it

```
flutter pub get
flutter run                     # a connected Android device
flutter build apk --release     # or a sideloadable APK
flutter test
flutter analyze
```

Android only. There is no iOS, web or desktop target — it is an internal tool
for one phone.

The Supabase URL and publishable key are compiled in with working defaults, so
no `--dart-define` is needed. To point a throwaway build at another project:

```
flutter run --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...
```

## Things worth knowing before you edit data

- **This is the live database.** There is no staging project and no undo for a
  *row*: a delete is a delete. *Files* are the exception — replacing or deleting
  one keeps it in `deleted_old_files/`.
- **Only changed fields are sent.** Opening a row and saving without touching
  anything writes nothing.
- **A generated primary key can't be typed.** `subjects.id`, `resources.id` and
  `zones.id` are `GENERATED ALWAYS`; the app leaves them out on insert. The
  hand-keyed tables (`colleges.code`, `formulas.title`, `app_links.key`) do take
  a key you choose, but it can't be edited afterwards — delete and re-add
  instead, so nothing that references it is silently orphaned.
- **Store listings can be edited and removed, not created.** A listing needs a
  real seller behind it, so there is no INSERT policy for `store`.
- **Timestamps are local.** A `timestamptz` field shows and accepts your wall
  clock and is converted to UTC on save.
- **Replacing a file keeps its key by default**, so links already in the database
  keep working, and the file it replaces is archived rather than destroyed.
  Uploading a *new* file onto an existing key asks first.
- **A refused write shows a dialog, not a toast** — the hint in it is usually the
  whole answer (missing admin row, expired session, a `NOT NULL` column, a
  foreign key that doesn't exist yet).
- **Every dropdown opens on a tap** and its values come from the database, read
  once per session. A field whose list won't load says so on the tap ("Could not
  read branches…") and retries on the next one, rather than opening an empty
  sheet. Where a value outside the list is allowed, the sheet's search box takes
  it: type it and pick **Use "…"**.
- **Filtering Subjects by branch hides the first-year ones, and should.** Most
  first- and second-semester subjects carry no branch at all because every branch
  studies them; the column is only filled once a subject belongs to one branch.
  So **Branch: AE** means "AE's own subjects", not "everything an AE student
  sees". Clear the chip to get the common ones back.

## Layout

```
lib/
  config.dart              compiled-in defaults
  core/
    admin_session.dart      sign-in, the code step, and the is_web_admin() check
    admin_push.dart         receiving: the topic, the channel gate, one
                            notification per message, and where a tap goes
  data/
    admin_repository.dart   all PostgREST reads and writes; FieldCodec
    lookup_cache.dart       dropdown values, fetched once per session; a failure
                            is not cached, so the next tap retries
    push_sender.dart        the send-push Edge Function call, and its errors
    store_notifier.dart     the notify-store call that tells a seller the verdict
  r2/
    sigv4.dart              AWS SigV4, by hand
    r2_client.dart          list / copy / put / head / delete / folders, on R2
    r2_credentials.dart     the secure-storage model, and public-URL ↔ key
    bucket_layout.dart      the one tree: which folder each column's files go in,
                            what they are called, and where each level's archive
                            is — the file to edit when the bucket's shape changes
    archive.dart            the deleted_old_files rule: what is kept, under what
                            key, and the request order that makes a replace or a
                            delete recoverable
    upload_flow.dart        the one upload path, shared by every screen
  schema/
    field_spec.dart         how one column is edited
    table_spec.dart         how one table is listed and searched
    catalog.dart            all 17 tables — the file to edit
  ui/
    dashboard_screen.dart   the bucket, then the table groups
    collection_screen.dart  one list screen for every table
    record_editor_screen.dart  one form for every table
    bucket_screen.dart      R2 browser, also used as a file picker
    r2_settings_screen.dart the only place keys are entered
    login_screen.dart       password, then the six-digit code
    widgets/push_action.dart   the send button and its confirm-then-send flow
    widgets/moderation_action.dart  approve / turn down, and telling the seller
    widgets/row_thumbnail.dart  a row's photo, and the zoomable full-screen look
```

`test/` covers the parts that fail silently rather than loudly: the SigV4
signature, the R2 request/response shapes, the bucket layout's folder and file
names (including the first-year rule and the per-level archive), the exact order
of requests behind a replace and a delete (the only operations here that can lose
a file), the field codec's encoding of empty values and timestamps, the sign-in
and Edge Function error text a failed attempt has to surface, which push messages
this app draws and which it must leave alone, and a set of invariants over the
catalog.
