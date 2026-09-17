import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../ui/widgets/state_views.dart';
import 'archive.dart';
import 'bucket_layout.dart';
import 'r2_client.dart';

/// Content types worth getting right: R2 stores what we send and the public host
/// replays it, so a PDF sent as `application/octet-stream` downloads instead of
/// opening, and an image never renders in the app.
const Map<String, String> _contentTypes = {
  'pdf': 'application/pdf',
  'png': 'image/png',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'webp': 'image/webp',
  'gif': 'image/gif',
  'svg': 'image/svg+xml',
  'json': 'application/json',
  'txt': 'text/plain; charset=utf-8',
  'csv': 'text/csv; charset=utf-8',
  'md': 'text/markdown; charset=utf-8',
  'zip': 'application/zip',
  'mp4': 'video/mp4',
  'webm': 'video/webm',
  'mp3': 'audio/mpeg',
  'doc': 'application/msword',
  'docx':
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'ppt': 'application/vnd.ms-powerpoint',
  'pptx':
      'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  'xls': 'application/vnd.ms-excel',
  'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
};

String contentTypeFor(String filename) {
  final dot = filename.lastIndexOf('.');
  if (dot == -1) return 'application/octet-stream';
  final ext = filename.substring(dot + 1).toLowerCase();
  return _contentTypes[ext] ?? 'application/octet-stream';
}

/// Object keys travel inside URLs that end up in the database and in the app, so
/// what would break one is taken out — and nothing else.
///
/// Case and spaces survive: `AE_Aeronautical_Engineering` and `1BAE305
/// Introduction to UAV Systems` are this bucket's convention, not an accident,
/// and flattening them would file new uploads away from the existing files.
String sanitizeKeySegment(String name) {
  final cleaned = bucketSafeName(name);
  return cleaned.isEmpty ? 'file' : cleaned;
}

/// The result of an upload: both halves, because the caller usually wants the
/// URL but the bucket screen wants the key.
class R2Upload {
  const R2Upload(this.key, this.url);

  final String key;
  final String url;
}

/// Where a file that has been superseded goes instead of being destroyed: see
/// `archive.dart`, which holds the rule and the order that makes it safe.
///
/// Pick a local file, confirm the key, upload it. Returns null on any cancel.
///
/// Shared by the bucket browser and by every `fileUrl` field, so "upload a
/// syllabus" behaves identically whether it starts from the file manager screen
/// or from the subject being edited.
///
/// [currentUrl] is what the column holds today. Passing it turns the upload into
/// a replacement: the file it points at is archived rather than overwritten, and
/// the key it already uses is what the new file is offered.
///
/// [prefix] and [suggestedName] are where the row says this file belongs — see
/// `bucket_layout.dart`. They decide the offered key for a *new* file only: a
/// replacement always keeps the key it is replacing, because the link is already
/// out in the world.
Future<R2Upload?> pickAndUploadToR2(
  BuildContext context, {
  required R2Client client,
  String prefix = '',
  String? suggestedKey,
  String? suggestedName,
  String currentUrl = '',
}) async {
  final file = await FilePicker.pickFile();
  if (file == null) return null;

  final bytes = await _bytesOf(file);
  if (bytes == null) {
    if (context.mounted) {
      showToast(context, 'That file could not be read', isError: true);
    }
    return null;
  }

  if (!context.mounted) return null;
  // The key behind the current link, when the link is one of ours. An external
  // one (a Drive URL, say) has nothing to archive and no name to reuse.
  final superseded = currentUrl.trim().isEmpty
      ? null
      : client.credentials.keyForPublicUrl(currentUrl.trim());

  // A replacement is offered the key it is replacing — first, ahead of anything
  // the caller suggests — so the link already in the database, and every copy of
  // it handed out since, keeps working. Otherwise the row's own scheme, semester
  // and subject name the folder and the file, which beats whatever the phone
  // called the download. Either way the key stays editable.
  final suggested = superseded ??
      suggestedKey ??
      '${_normalizedPrefix(prefix)}${_fileNameFor(file.name, suggestedName)}';
  final key = await _askForKey(
    context,
    suggested: suggested,
    bytes: bytes.length,
    replacing: superseded,
  );
  if (key == null || key.isEmpty) return null;
  if (!context.mounted) return null;

  return uploadBytesToR2(
    context,
    client: client,
    key: key,
    bytes: bytes,
    contentType: contentTypeFor(file.name),
    replacing: superseded,
  );
}

/// Uploads bytes that are already in hand, archiving whatever it displaces, with
/// the confirmation and the progress barrier. Returns null if the person backed
/// out or it failed.
Future<R2Upload?> uploadBytesToR2(
  BuildContext context, {
  required R2Client client,
  required String key,
  required Uint8List bytes,
  required String contentType,
  String? replacing,
}) async {
  final superseded = (replacing ?? '').trim();
  final List<String> inTheWay;
  try {
    // R2 has no conditional PUT, so what is about to be displaced has to be
    // looked up — the write itself will not mention it.
    inTheWay = [
      for (final candidate in <String>{
        if (superseded.isNotEmpty) superseded,
        key,
      })
        if (await client.exists(candidate)) candidate,
    ];
  } on R2Exception catch (error) {
    if (context.mounted) showToast(context, '$error', isError: true);
    return null;
  }

  if (inTheWay.isNotEmpty) {
    if (!context.mounted) return null;
    final renamed = superseded.isNotEmpty && superseded != key;
    final confirmed = await confirmDestructive(
      context,
      title: superseded.isEmpty
          ? 'Replace the existing file?'
          : 'Replace the file this row uses?',
      message: [
        '$key will hold the file you picked.',
        inTheWay.length == 1
            ? 'The file there now is moved into $archiveFolderName/ first, so '
                'nothing is destroyed.'
            : 'Both files it displaces are moved into $archiveFolderName/ first, so '
                'nothing is destroyed.',
        if (renamed)
          'The link changes, so it is written into this row straight away — the '
              'old link stops working.',
        if (superseded.isEmpty)
          'Every row already pointing at that link will show the new file.',
      ].join('\n\n'),
      confirmLabel: 'Replace',
    );
    if (!confirmed) return null;
  }

  if (!context.mounted) return null;
  final barrier = showProgressBarrier(
    context,
    inTheWay.isEmpty ? 'Uploading…' : 'Replacing…',
  );
  final List<String> archived;
  try {
    archived = await writeWithArchive(
      client,
      key: key,
      bytes: bytes,
      contentType: contentType,
      replacing: superseded,
    );
  } catch (error) {
    barrier.dismiss();
    if (context.mounted) {
      showToast(context, _describe(error), isError: true);
    }
    return null;
  }
  barrier.dismiss();

  final url = client.credentials.publicUrlFor(key);
  if (context.mounted) {
    showToast(
      context,
      archived.isEmpty
          ? 'Uploaded $key'
          : 'Uploaded $key — the old file is in $archiveFolderName/',
    );
  }
  return R2Upload(key, url);
}

Future<Uint8List?> _bytesOf(PlatformFile file) async {
  // The whole object is signed and PUT in one request, so the bytes have to be
  // in hand either way. `readAsBytes` covers a `content://` pick as well as a
  // real path, which a raw File read would not.
  try {
    return await file.readAsBytes();
  } catch (_) {
    return null;
  }
}

String _normalizedPrefix(String prefix) {
  if (prefix.isEmpty) return '';
  return prefix.endsWith('/') ? prefix : '$prefix/';
}

/// The name the row implies plus the picked file's own extension, or the picked
/// name when the row implies nothing. `Document(2).pdf` off a phone is never what
/// the bucket should end up calling a syllabus.
String _fileNameFor(String pickedName, String? canonicalBase) {
  if (canonicalBase == null || canonicalBase.trim().isEmpty) {
    return sanitizeKeySegment(pickedName);
  }
  final dot = pickedName.lastIndexOf('.');
  final extension = dot == -1 ? '' : pickedName.substring(dot).toLowerCase();
  return '${sanitizeKeySegment(canonicalBase)}$extension';
}

Future<String?> _askForKey(
  BuildContext context, {
  required String suggested,
  required int bytes,
  String? replacing,
}) {
  final controller = TextEditingController(text: suggested);
  final size = bytes < 1024 * 1024
      ? '${(bytes / 1024).toStringAsFixed(0)} KB'
      : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  final isReplacement = replacing != null && replacing.isNotEmpty;

  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(isReplacement ? 'Replace this file' : 'File name in the bucket'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: controller,
            autofocus: true,
            decoration: InputDecoration(
              labelText: 'Object key',
              // Leaving a replacement's key alone is the safe path and worth
              // saying so: it keeps the link that is already in the database.
              helperText: isReplacement
                  ? 'Keep this name and the current link keeps working. '
                      'Change it and the row is re-pointed at the new one.'
                  : 'Slashes make folders. This one follows the bucket layout — '
                      'vtu/scheme-2025/1st_year/…',
              helperMaxLines: 3,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            isReplacement
                ? '$size will be uploaded. The file there now is kept in '
                    '$archiveFolderName/.'
                : '$size will be uploaded',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, controller.text.trim()),
          child: const Text('Upload'),
        ),
      ],
    ),
  );
}

String _describe(Object error) =>
    error is R2Exception ? '$error' : 'Upload failed: $error';
