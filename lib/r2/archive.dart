import 'dart:typed_data';

import 'bucket_layout.dart';
import 'r2_client.dart';

/// The order in which a replace and a delete touch the bucket. Where the files
/// go is `bucket_layout.dart`'s business — [archiveKeyFor] and [isInArchive] —
/// and what makes either operation survivable is here.
///
/// R2 has no object versioning, so a PUT over an existing key is unrecoverable
/// and a DELETE is final — and by then the link is in the database and on
/// students' phones. Everything this app replaces or deletes is copied into the
/// `deleted_old_files/` of its own level first, so a mistake is a copy back
/// rather than a hunt for the original PDF.

/// A folder marker — the zero-byte object that stands in for a folder with
/// nothing in it. There is no content to keep, so these are never archived.
bool isFolderMarker(String key) => key.endsWith('/');

/// The bucket half of a replace, in the order that makes it safe: archive
/// everything about to be lost, upload, and only then drop the key that has been
/// superseded. Nothing is deleted until its copy has been made, so a failure at
/// any step leaves the old file exactly where the database still expects it.
///
/// [replacing] is the key the row points at now, when that is a file of ours.
/// Two keys can be in the way and both are kept: the one being superseded, and —
/// when the new file is uploaded under a different name — whatever is already
/// sitting at that name.
///
/// Returns the archive keys written, in the order they were written.
Future<List<String>> writeWithArchive(
  R2Client client, {
  required String key,
  required Uint8List bytes,
  required String contentType,
  String? replacing,
  DateTime? at,
}) async {
  final stamp = at ?? DateTime.now();
  final archived = <String>[];

  // A set, because replacing a file in place is the ordinary case and the same
  // object must not be archived twice.
  for (final doomed in <String>{
    if (replacing != null && replacing.isNotEmpty) replacing,
    key,
  }) {
    if (!await client.exists(doomed)) continue;
    final archiveKey = archiveKeyFor(doomed, stamp);
    await client.copy(from: doomed, to: archiveKey);
    archived.add(archiveKey);
  }

  await client.put(key: key, bytes: bytes, contentType: contentType);

  // Renamed on the way in: the old object is now a duplicate of an archived copy,
  // and leaving it live would leave a second working URL for a replaced file.
  if (replacing != null && replacing.isNotEmpty && replacing != key) {
    await client.delete(replacing);
  }
  return archived;
}

/// Moves [keys] into the archive and then deletes them — one file, or every file
/// under a folder. Returns how many keys were dealt with.
///
/// Per key: copy first, delete second, so an interrupted run has lost nothing.
/// One key at a time and in order, so a failure stops the whole operation with
/// everything after it still there, rather than scattering half a folder.
///
/// A folder marker is deleted without a copy (there is no content in one), and so
/// is anything already in an archive — that is how the archive gets emptied.
Future<int> archiveAndDelete(
  R2Client client, {
  required List<String> keys,
  DateTime? at,
  void Function(int done, int total)? onProgress,
}) async {
  final stamp = at ?? DateTime.now();
  var done = 0;
  for (final key in keys) {
    if (!isFolderMarker(key) && !isInArchive(key)) {
      await client.copy(from: key, to: archiveKeyFor(key, stamp));
    }
    await client.delete(key);
    // Counted outside the callback: `onProgress?.call(++done, …)` would never
    // increment at all when nobody is listening.
    done++;
    onProgress?.call(done, keys.length);
  }
  return done;
}
