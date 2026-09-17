import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../config.dart';

/// Everything needed to reach one R2 bucket. Typed once on the device; the two
/// secrets are kept in Keystore-backed storage so they are never in the APK,
/// never in git, and survive a reinstall no better than they should.
@immutable
class R2Credentials {
  const R2Credentials({
    this.accountId = '',
    this.accessKeyId = '',
    this.secretAccessKey = '',
    this.bucket = AdminConfig.defaultBucket,
    this.publicBaseUrl = AdminConfig.defaultPublicBaseUrl,
  });

  /// Cloudflare account id — the host is `<accountId>.r2.cloudflarestorage.com`.
  final String accountId;
  final String accessKeyId;
  final String secretAccessKey;
  final String bucket;

  /// Where the world reads these objects from: the bucket's r2.dev host or a
  /// custom domain. This is what gets written into `syllabus_link` and friends,
  /// so it must be the *public* origin, not the S3 endpoint.
  final String publicBaseUrl;

  bool get isComplete =>
      accountId.isNotEmpty &&
      accessKeyId.isNotEmpty &&
      secretAccessKey.isNotEmpty &&
      bucket.isNotEmpty;

  String get endpointHost => '$accountId.r2.cloudflarestorage.com';

  /// The public URL for [key], e.g.
  /// `https://pub-….r2.dev/vtu/scheme-2025/1st_year/1BMATC101%20Calculus.pdf`.
  ///
  /// Each segment is percent-encoded, because the keys in this bucket have spaces
  /// in them by convention and a raw space is not a URL — this string goes
  /// straight into `syllabus_link` and out to every phone.
  String publicUrlFor(String key) {
    final path = key.startsWith('/') ? key.substring(1) : key;
    final encoded =
        path.split('/').map(Uri.encodeComponent).join('/');
    return '$_base/$encoded';
  }

  /// The object key a public URL points at, or null when the URL belongs to
  /// some other host. Used to show "this row's file lives in the bucket".
  ///
  /// Decoding is the half that matters: the link in the database holds `%20`, and
  /// a key still carrying `%20` would be encoded again on the wire (`%2520`), so
  /// a replace would look for a file that does not exist and archive nothing.
  String? keyForPublicUrl(String url) {
    if (_base.isEmpty || !url.startsWith('$_base/')) return null;
    final path = url.substring(_base.length + 1);
    try {
      return path.split('/').map(Uri.decodeComponent).join('/');
    } on ArgumentError {
      return path; // a stray '%' that is not an escape: take it literally
    }
  }

  String get _base => publicBaseUrl.endsWith('/')
      ? publicBaseUrl.substring(0, publicBaseUrl.length - 1)
      : publicBaseUrl;

  R2Credentials copyWith({
    String? accountId,
    String? accessKeyId,
    String? secretAccessKey,
    String? bucket,
    String? publicBaseUrl,
  }) {
    return R2Credentials(
      accountId: accountId ?? this.accountId,
      accessKeyId: accessKeyId ?? this.accessKeyId,
      secretAccessKey: secretAccessKey ?? this.secretAccessKey,
      bucket: bucket ?? this.bucket,
      publicBaseUrl: publicBaseUrl ?? this.publicBaseUrl,
    );
  }
}

/// Loads and saves [R2Credentials], and tells the UI when they change.
class R2CredentialStore extends ChangeNotifier {
  R2CredentialStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            // The bare default is the strong one: AES-GCM data encryption under
            // an RSA-OAEP key wrapped by the Android Keystore. The old
            // `encryptedSharedPreferences` flag is deprecated and ignored, so
            // there is nothing to turn on. `resetOnError` (on by default) wipes
            // the values if the keystore entry ever goes bad, which for these is
            // right: they can be typed again, and the alternative is a screen
            // that cannot be opened.
            const FlutterSecureStorage(aOptions: AndroidOptions());

  static const _accountId = 'r2_account_id';
  static const _accessKeyId = 'r2_access_key_id';
  static const _secret = 'r2_secret_access_key';
  static const _bucket = 'r2_bucket';
  static const _publicBase = 'r2_public_base_url';

  final FlutterSecureStorage _storage;

  R2Credentials _credentials = const R2Credentials();
  R2Credentials get credentials => _credentials;

  bool _loaded = false;
  bool get isLoaded => _loaded;

  Future<void> load() async {
    try {
      final values = await _storage.readAll();
      _credentials = R2Credentials(
        accountId: values[_accountId] ?? '',
        accessKeyId: values[_accessKeyId] ?? '',
        secretAccessKey: values[_secret] ?? '',
        bucket: values[_bucket]?.isNotEmpty == true
            ? values[_bucket]!
            : AdminConfig.defaultBucket,
        publicBaseUrl: values[_publicBase]?.isNotEmpty == true
            ? values[_publicBase]!
            : AdminConfig.defaultPublicBaseUrl,
      );
    } catch (error) {
      // A corrupt keystore entry must not brick the app: the Supabase half of
      // the console still works without R2.
      debugPrint('R2 credentials could not be read: $error');
      _credentials = const R2Credentials();
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> save(R2Credentials value) async {
    _credentials = value;
    notifyListeners();
    await _storage.write(key: _accountId, value: value.accountId);
    await _storage.write(key: _accessKeyId, value: value.accessKeyId);
    await _storage.write(key: _secret, value: value.secretAccessKey);
    await _storage.write(key: _bucket, value: value.bucket);
    await _storage.write(key: _publicBase, value: value.publicBaseUrl);
  }

  Future<void> clear() async {
    _credentials = const R2Credentials();
    notifyListeners();
    for (final key in [_accountId, _accessKeyId, _secret, _bucket, _publicBase]) {
      await _storage.delete(key: key);
    }
  }
}
