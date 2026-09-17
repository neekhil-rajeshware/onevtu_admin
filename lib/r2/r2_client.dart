import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import 'r2_credentials.dart';
import 'sigv4.dart';

/// One object in the bucket.
class R2Object {
  const R2Object({
    required this.key,
    required this.size,
    required this.lastModified,
    this.etag = '',
  });

  final String key;
  final int size;
  final DateTime? lastModified;
  final String etag;

  /// The trailing segment — what a person calls the file.
  String get name {
    final trimmed = key.endsWith('/') ? key.substring(0, key.length - 1) : key;
    final slash = trimmed.lastIndexOf('/');
    return slash == -1 ? trimmed : trimmed.substring(slash + 1);
  }

  String get readableSize => formatBytes(size);
}

/// KB and MB the way every file listing in the app says them, so a total and a
/// single file are never formatted two different ways.
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// One page of a ListObjectsV2 answer: the sub-"folders" and the files.
class R2Listing {
  const R2Listing({
    required this.prefixes,
    required this.objects,
    this.nextToken,
  });

  final List<String> prefixes;
  final List<R2Object> objects;
  final String? nextToken;

  bool get isEmpty => prefixes.isEmpty && objects.isEmpty;
}

/// An error R2 reported, unwrapped from its XML so the UI can show something
/// better than "403".
class R2Exception implements Exception {
  R2Exception(this.statusCode, this.code, this.message);

  final int statusCode;
  final String code;
  final String message;

  /// The two mistakes that actually happen in practice get a plain-English
  /// answer, because "SignatureDoesNotMatch" tells the owner nothing.
  @override
  String toString() {
    switch (code) {
      case 'SignatureDoesNotMatch':
        return 'R2 rejected the signature — check the secret access key '
            '(and that the phone clock is correct).';
      case 'InvalidAccessKeyId':
        return 'R2 does not know that access key id. Check the token in '
            'Cloudflare → R2 → Manage API tokens.';
      case 'NoSuchBucket':
        return 'That bucket does not exist in this account.';
      case 'AccessDenied':
        return 'The API token is valid but not allowed to do this. It needs '
            'Object Read & Write on the bucket.';
      default:
        return message.isEmpty
            ? 'R2 request failed (HTTP $statusCode)'
            : '$message (HTTP $statusCode)';
    }
  }
}

/// The S3 operations the console needs, signed for Cloudflare R2.
///
/// Path-style addressing throughout (`/<bucket>/<key>`), which is what R2
/// supports; virtual-host style would need a per-bucket DNS name.
class R2Client {
  R2Client(this.credentials, {http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  final R2Credentials credentials;
  final http.Client _http;

  SigV4Signer get _signer => SigV4Signer(
        accessKeyId: credentials.accessKeyId,
        secretAccessKey: credentials.secretAccessKey,
      );

  /// Encoded once and reused for both the signature and the URL, so the two can
  /// never disagree.
  String _canonicalPath(String? key) {
    final bucket = SigV4Signer.encode(credentials.bucket);
    if (key == null || key.isEmpty) return '/$bucket';
    final segments = key.split('/').map(SigV4Signer.encode).join('/');
    return '/$bucket/$segments';
  }

  Uri _uri(String canonicalPath, Map<String, String> query) {
    final qs = SigV4Signer.canonicalQuery(query);
    return Uri.parse(
      'https://${credentials.endpointHost}$canonicalPath${qs.isEmpty ? '' : '?$qs'}',
    );
  }

  /// Lists one page under [prefix]. With the default `/` delimiter the answer
  /// is folder-shaped, which is how [R2Listing] is meant to be browsed; pass an
  /// empty delimiter to walk every key underneath instead.
  ///
  /// [includeFolderMarkers] keeps the zero-byte `.../` placeholder objects that
  /// stand in for empty folders. Browsing hides them — they are not files — but a
  /// recursive delete has to see them, or the folder it emptied stays on screen.
  Future<R2Listing> list({
    String prefix = '',
    String delimiter = '/',
    String? continuationToken,
    int maxKeys = 200,
    bool includeFolderMarkers = false,
  }) async {
    final query = <String, String>{
      'list-type': '2',
      'max-keys': '$maxKeys',
      if (prefix.isNotEmpty) 'prefix': prefix,
      if (delimiter.isNotEmpty) 'delimiter': delimiter,
      'continuation-token': ?continuationToken,
    };
    final path = _canonicalPath(null);
    final headers = _signer.sign(
      method: 'GET',
      host: credentials.endpointHost,
      canonicalPath: path,
      query: query,
    );

    final response = await _http.get(_uri(path, query), headers: headers);
    _throwIfFailed(response);

    final root = XmlDocument.parse(response.body).rootElement;
    String? text(XmlElement parent, String name) =>
        parent.getElement(name)?.innerText;

    final prefixes = root
        .findElements('CommonPrefixes')
        .map((e) => text(e, 'Prefix') ?? '')
        .where((p) => p.isNotEmpty)
        .toList()
      ..sort();

    final objects = root
        .findElements('Contents')
        .map((e) {
          final key = text(e, 'Key') ?? '';
          final modified = text(e, 'LastModified');
          return R2Object(
            key: key,
            size: int.tryParse(text(e, 'Size') ?? '') ?? 0,
            lastModified:
                modified == null ? null : DateTime.tryParse(modified)?.toLocal(),
            etag: (text(e, 'ETag') ?? '').replaceAll('"', ''),
          );
        })
        // A key ending in `/` is a placeholder for an empty folder, not a file.
        .where((o) =>
            o.key.isNotEmpty && (includeFolderMarkers || !o.key.endsWith('/')))
        .toList();

    final truncated = text(root, 'IsTruncated') == 'true';
    return R2Listing(
      prefixes: prefixes,
      objects: objects,
      nextToken: truncated ? text(root, 'NextContinuationToken') : null,
    );
  }

  /// Everything under [prefix], recursively and to the last page, folder markers
  /// included — what a folder delete has to enumerate before it can say how much
  /// it is about to remove.
  ///
  /// Deliberately unbounded: deleting a folder without knowing what is in it is
  /// the mistake this exists to prevent.
  Future<List<R2Object>> objectsUnder(String prefix) async {
    final all = <R2Object>[];
    String? token;
    do {
      final page = await list(
        prefix: prefix,
        delimiter: '', // every key underneath, not one folder level
        continuationToken: token,
        maxKeys: 1000,
        includeFolderMarkers: true,
      );
      all.addAll(page.objects);
      token = page.nextToken;
    } while (token != null);
    return all;
  }

  /// Uploads (or replaces) one object. R2 has no "create if absent" mode, so
  /// callers that must not overwrite check with [exists] first.
  Future<void> put({
    required String key,
    required Uint8List bytes,
    String contentType = 'application/octet-stream',
  }) async {
    final path = _canonicalPath(key);
    final headers = _signer.sign(
      method: 'PUT',
      host: credentials.endpointHost,
      canonicalPath: path,
      headers: {'content-type': contentType},
      payloadSha256: SigV4Signer.sha256Hex(bytes),
    );

    final request = http.Request('PUT', _uri(path, const {}))
      ..headers.addAll(headers)
      ..bodyBytes = bytes;
    final response =
        await http.Response.fromStream(await _http.send(request));
    _throwIfFailed(response);
  }

  /// Copies one object to another key, server-side — no bytes travel through the
  /// phone. S3 has no rename and R2 has no versioning, so this is the only way to
  /// keep a file that is about to be overwritten: a move is this, then [delete].
  ///
  /// The stored content type comes across with it, which is why a copied PDF
  /// still opens instead of downloading.
  Future<void> copy({required String from, required String to}) async {
    final path = _canonicalPath(to);
    // `x-amz-copy-source` is `/<bucket>/<key>`, percent-encoded exactly like a
    // canonical path — so it is built by the same function, and the two can never
    // disagree about a space or a bracket.
    final headers = _signer.sign(
      method: 'PUT',
      host: credentials.endpointHost,
      canonicalPath: path,
      headers: {'x-amz-copy-source': _canonicalPath(from)},
    );

    final response = await _http.put(_uri(path, const {}), headers: headers);
    _throwIfFailed(response);
    // CopyObject is the one call that can fail inside a 200: the connection is
    // held open while the copy runs, so the error arrives in the body afterwards.
    // Treating that as success is how an archive silently becomes an empty folder.
    if (response.body.contains('<Error')) _throwFrom(response);
  }

  /// Creates an empty folder.
  ///
  /// There are no folders in S3 — a folder is only the `/` inside some key, which
  /// is why one appears the moment a file is uploaded into it and vanishes when
  /// the last file leaves. So a folder with nothing in it needs a stand-in: the
  /// zero-byte object ending in `/` that every S3 console writes, and that [list]
  /// hides again from the file listing.
  Future<void> createFolder(String prefix) {
    return put(
      key: prefix.endsWith('/') ? prefix : '$prefix/',
      bytes: Uint8List(0),
      // What the Cloudflare dashboard marks its own folders with.
      contentType: 'application/x-directory',
    );
  }

  Future<void> delete(String key) async {
    final path = _canonicalPath(key);
    final headers = _signer.sign(
      method: 'DELETE',
      host: credentials.endpointHost,
      canonicalPath: path,
    );
    final response = await _http.delete(_uri(path, const {}), headers: headers);
    _throwIfFailed(response);
  }

  /// True when an object with this key is already there.
  Future<bool> exists(String key) async {
    final path = _canonicalPath(key);
    final headers = _signer.sign(
      method: 'HEAD',
      host: credentials.endpointHost,
      canonicalPath: path,
    );
    final response = await _http.head(_uri(path, const {}), headers: headers);
    if (response.statusCode == 404) return false;
    _throwIfFailed(response);
    return true;
  }

  /// Cheapest possible credential check for the settings screen: list nothing.
  Future<void> verify() => list(maxKeys: 1);

  void dispose() => _http.close();

  void _throwIfFailed(http.Response response) {
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    _throwFrom(response);
  }

  /// Unwraps whatever R2 said into an [R2Exception], whatever shape it came in.
  Never _throwFrom(http.Response response) {
    var code = '';
    var message = '';
    // R2 answers errors in XML — except when it doesn't (proxy errors, HEAD).
    if (response.body.trimLeft().startsWith('<')) {
      try {
        final root = XmlDocument.parse(response.body).rootElement;
        code = root.getElement('Code')?.innerText ?? '';
        message = root.getElement('Message')?.innerText ?? '';
      } catch (_) {
        message = response.body;
      }
    } else if (response.body.isNotEmpty) {
      message = utf8.decode(response.bodyBytes, allowMalformed: true);
    }
    throw R2Exception(response.statusCode, code, message);
  }
}
