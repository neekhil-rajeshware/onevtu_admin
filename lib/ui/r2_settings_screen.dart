import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../config.dart';
import '../r2/r2_client.dart';
import '../r2/r2_credentials.dart';
import 'widgets/state_views.dart';

/// Where the R2 keys are typed in. Nothing here ships with the app: the account
/// id, key id and secret are entered once on the device and kept in
/// Keystore-backed storage, so the APK carries no credentials at all.
class R2SettingsScreen extends StatefulWidget {
  const R2SettingsScreen({super.key});

  @override
  State<R2SettingsScreen> createState() => _R2SettingsScreenState();
}

class _R2SettingsScreenState extends State<R2SettingsScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _accountId;
  late final TextEditingController _accessKeyId;
  late final TextEditingController _secret;
  late final TextEditingController _bucket;
  late final TextEditingController _publicBase;

  bool _obscureSecret = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final current = context.read<R2CredentialStore>().credentials;
    _accountId = TextEditingController(text: current.accountId);
    _accessKeyId = TextEditingController(text: current.accessKeyId);
    _secret = TextEditingController(text: current.secretAccessKey);
    _bucket = TextEditingController(text: current.bucket);
    _publicBase = TextEditingController(text: current.publicBaseUrl);
  }

  @override
  void dispose() {
    _accountId.dispose();
    _accessKeyId.dispose();
    _secret.dispose();
    _bucket.dispose();
    _publicBase.dispose();
    super.dispose();
  }

  R2Credentials get _typed => R2Credentials(
        accountId: _accountId.text.trim(),
        accessKeyId: _accessKeyId.text.trim(),
        secretAccessKey: _secret.text.trim(),
        bucket: _bucket.text.trim(),
        publicBaseUrl: _publicBase.text.trim(),
      );

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _busy = true);

    final credentials = _typed;
    await context.read<R2CredentialStore>().save(credentials);

    // Saved first, then checked: if the check fails the values are still on the
    // device to be corrected rather than retyped from scratch.
    final client = R2Client(credentials);
    String? failure;
    try {
      await client.verify();
    } catch (error) {
      failure = error is R2Exception ? '$error' : 'Could not reach R2: $error';
    } finally {
      client.dispose();
    }

    if (!mounted) return;
    setState(() => _busy = false);
    if (failure == null) {
      showToast(context, 'Saved — the bucket answered');
      Navigator.of(context).maybePop();
    } else {
      showToast(context, failure, isError: true);
    }
  }

  Future<void> _clear() async {
    final confirmed = await confirmDestructive(
      context,
      title: 'Remove the R2 keys?',
      message: 'The keys are deleted from this phone. Files already in the '
          'bucket and links already saved in the database are untouched.',
      confirmLabel: 'Remove',
    );
    if (!confirmed || !mounted) return;
    await context.read<R2CredentialStore>().clear();
    if (!mounted) return;
    _accountId.clear();
    _accessKeyId.clear();
    _secret.clear();
    _bucket.text = AdminConfig.defaultBucket;
    _publicBase.text = AdminConfig.defaultPublicBaseUrl;
    showToast(context, 'Keys removed from this device');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final stored = context.watch<R2CredentialStore>().credentials;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Cloudflare R2 keys'),
        actions: [
          if (stored.isComplete)
            IconButton(
              tooltip: 'Remove keys',
              onPressed: _busy ? null : _clear,
              icon: const Icon(Icons.delete_outline),
            ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(Icons.lock_outline,
                      size: 18, color: theme.colorScheme.primary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'These stay on this phone, in encrypted storage. They are '
                      'not in the app bundle and are never uploaded anywhere.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            TextFormField(
              controller: _accountId,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Account ID *',
                helperText: 'The hex id in the S3 endpoint '
                    'https://<this>.r2.cloudflarestorage.com',
                helperMaxLines: 3,
              ),
              validator: _required,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _accessKeyId,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Access Key ID *',
                helperText: 'R2 → Manage API tokens → create a token with '
                    'Object Read & Write',
                helperMaxLines: 3,
              ),
              validator: _required,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _secret,
              autocorrect: false,
              obscureText: _obscureSecret,
              decoration: InputDecoration(
                labelText: 'Secret Access Key *',
                helperText: 'Cloudflare shows this once, when the token is made',
                helperMaxLines: 2,
                suffixIcon: IconButton(
                  icon: Icon(_obscureSecret
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined),
                  onPressed: () =>
                      setState(() => _obscureSecret = !_obscureSecret),
                ),
              ),
              validator: _required,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _bucket,
              autocorrect: false,
              decoration: const InputDecoration(labelText: 'Bucket *'),
              validator: _required,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _publicBase,
              autocorrect: false,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'Public base URL *',
                helperText: 'The origin readers hit — this is what gets written '
                    'into syllabus_link and the other link columns',
                helperMaxLines: 3,
              ),
              validator: (value) {
                final text = (value ?? '').trim();
                if (text.isEmpty) return 'Required';
                if (!text.startsWith('http')) {
                  return 'Should start with https://';
                }
                if (text.contains('r2.cloudflarestorage.com')) {
                  return 'That is the private S3 endpoint. Use the r2.dev URL '
                      'or your custom domain.';
                }
                return null;
              },
            ),
            const SizedBox(height: 26),
            FilledButton.icon(
              onPressed: _busy ? null : _save,
              icon: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2.2),
                    )
                  : const Icon(Icons.check, size: 18),
              label: Text(_busy ? 'Checking the bucket…' : 'Save and test'),
            ),
          ],
        ),
      ),
    );
  }

  static String? _required(String? value) =>
      (value == null || value.trim().isEmpty) ? 'Required' : null;
}
