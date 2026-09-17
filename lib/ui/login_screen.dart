import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../core/admin_session.dart';
import 'widgets/state_views.dart';

/// How many digits an authenticator app shows.
const _codeLength = 6;

/// Email + password sign-in. Google sign-in is deliberately absent: the account
/// this app needs is the one with a `web_admins` row, and a password is the only
/// credential that cannot be granted to a random student by accident.
///
/// The password is only the first step — see [MfaCodeScreen].
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _obscure = true;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final session = context.read<AdminSession>();
    // False means the password itself was refused. Anything else — a code still
    // to enter, an account with no `web_admins` row — is a screen of its own.
    final ok = await session.signIn(_email.text, _password.text);
    if (!mounted) return;
    if (!ok) {
      showToast(context, session.error ?? 'Could not sign in', isError: true);
    }
  }

  Future<void> _resetPassword() async {
    final email = _email.text.trim();
    if (email.isEmpty) {
      showToast(context, 'Type your email address first', isError: true);
      return;
    }
    final session = context.read<AdminSession>();
    final sent = await session.sendPasswordReset(email);
    if (!mounted) return;
    showToast(
      context,
      sent
          ? 'Link sent to $email. Open it, set a password, then come back here.'
          : session.error ?? 'Could not send the link',
      isError: !sent,
    );
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<AdminSession>();
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Icon(Icons.shield_outlined,
                          color: theme.colorScheme.primary),
                    ),
                    const SizedBox(height: 22),
                    Text('One VTU Admin', style: theme.textTheme.headlineSmall),
                    const SizedBox(height: 8),
                    Text(
                      'Edits here change the live app immediately.',
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(height: 28),
                    TextFormField(
                      controller: _email,
                      keyboardType: TextInputType.emailAddress,
                      autocorrect: false,
                      autofillHints: const [AutofillHints.email],
                      decoration: const InputDecoration(labelText: 'Admin email'),
                      validator: (value) =>
                          (value == null || !value.contains('@'))
                              ? 'Enter your email address'
                              : null,
                    ),
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: _password,
                      obscureText: _obscure,
                      autofillHints: const [AutofillHints.password],
                      decoration: InputDecoration(
                        labelText: 'Password',
                        suffixIcon: IconButton(
                          icon: Icon(_obscure
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined),
                          onPressed: () => setState(() => _obscure = !_obscure),
                        ),
                      ),
                      onFieldSubmitted: (_) => _submit(),
                      validator: (value) => (value == null || value.isEmpty)
                          ? 'Enter your password'
                          : null,
                    ),
                    const SizedBox(height: 22),
                    FilledButton(
                      onPressed: session.busy ? null : _submit,
                      child: session.busy
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2.2),
                            )
                          : const Text('Sign in'),
                    ),
                    const SizedBox(height: 6),
                    TextButton(
                      onPressed: session.busy ? null : _resetPassword,
                      child: const Text('Set or reset my password'),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'If this account was only ever used with Google sign-in it '
                      'has no password yet — send yourself a link first.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Colors.white.withValues(alpha: 0.45),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The second step of signing in: the six digits from the authenticator app.
///
/// Not a formality this app could skip. `is_web_admin()` refuses a session that
/// only ever had a password whenever the account has an authenticator set up, so
/// without this screen the app would look signed in and answer every save with
/// "permission denied". Setting an authenticator *up* still happens on the
/// website — this only asks for the code.
class MfaCodeScreen extends StatefulWidget {
  const MfaCodeScreen({super.key});

  @override
  State<MfaCodeScreen> createState() => _MfaCodeScreenState();
}

class _MfaCodeScreenState extends State<MfaCodeScreen> {
  final _code = TextEditingController();
  String? _factorId;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _submit(AdminSession session, String factorId) async {
    if (session.busy || factorId.isEmpty) return;
    if (_code.text.length < _codeLength) {
      showToast(context, 'Type all six digits', isError: true);
      return;
    }
    final ok = await session.submitCode(factorId: factorId, code: _code.text);
    // On success the gate has already swapped this screen out.
    if (!mounted || ok) return;
    _code.clear();
    showToast(context, session.error ?? 'That code did not work', isError: true);
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<AdminSession>();
    final theme = Theme.of(context);
    final factors = session.factors;
    final selected =
        _factorId ?? (factors.isEmpty ? '' : factors.first.id);

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Icon(Icons.verified_user_outlined,
                        color: theme.colorScheme.primary),
                  ),
                  const SizedBox(height: 22),
                  Text('Enter your code', style: theme.textTheme.headlineSmall),
                  const SizedBox(height: 8),
                  Text(
                    'Open your authenticator app and type the six digits it '
                    'shows for One VTU.',
                    style: theme.textTheme.bodySmall,
                  ),
                  // Two apps mean two different codes, so the right one has to be
                  // named rather than guessed at.
                  if (factors.length > 1) ...[
                    const SizedBox(height: 20),
                    Text('Which app are you using?',
                        style: theme.textTheme.bodySmall),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final factor in factors)
                          ChoiceChip(
                            label: Text(factor.friendlyName ?? 'Authenticator'),
                            selected: selected == factor.id,
                            onSelected: session.busy
                                ? null
                                : (_) => setState(() => _factorId = factor.id),
                          ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 22),
                  TextField(
                    controller: _code,
                    autofocus: true,
                    enabled: !session.busy,
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.center,
                    maxLength: _codeLength,
                    autofillHints: const [AutofillHints.oneTimeCode],
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    style: theme.textTheme.headlineSmall
                        ?.copyWith(letterSpacing: 10),
                    decoration: const InputDecoration(
                      labelText: 'Six-digit code',
                      counterText: '',
                      hintText: '000000',
                    ),
                    onChanged: (value) {
                      setState(() {});
                      // A six-digit field is done when it is full; making them
                      // reach for a button as well is a wasted tap.
                      if (value.length == _codeLength) {
                        _submit(session, selected);
                      }
                    },
                    onSubmitted: (_) => _submit(session, selected),
                  ),
                  const SizedBox(height: 22),
                  FilledButton(
                    onPressed:
                        session.busy || _code.text.length < _codeLength
                            ? null
                            : () => _submit(session, selected),
                    child: session.busy
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2.2),
                          )
                        : const Text('Sign in'),
                  ),
                  const SizedBox(height: 6),
                  TextButton(
                    onPressed:
                        session.busy ? null : () => session.signOut(),
                    child: const Text('Use a different account'),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Lost the app? Sign in at onevtu.in/admin and add a new '
                    'authenticator from Account.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: Colors.white.withValues(alpha: 0.45),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Signed in, but the account is not an admin — so every write would be refused
/// by RLS. Says exactly what is missing rather than letting saves fail later.
class NotAnAdminScreen extends StatelessWidget {
  const NotAnAdminScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final session = context.watch<AdminSession>();
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.lock_outline,
                    size: 40, color: Theme.of(context).colorScheme.error),
                const SizedBox(height: 16),
                Text('Not an admin account',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 10),
                Text(
                  '${session.email ?? 'This account'} is signed in but has no '
                  'row in web_admins, so the database will refuse every change. '
                  'Sign in with the admin account instead.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 24),
                OutlinedButton(
                  onPressed: () => context.read<AdminSession>().signOut(),
                  child: const Text('Sign out'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The check itself did not happen — the server did not answer, or the stored
/// session cannot be read.
///
/// Deliberately not folded into [NotAnAdminScreen]: that screen says the account
/// has no `web_admins` row, which is a statement about the person. This is a
/// statement about the network, and it is the screen that replaced an app which
/// sat on "Checking your sign-in…" for ever with nothing to tap.
class CouldNotCheckScreen extends StatelessWidget {
  const CouldNotCheckScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final session = context.watch<AdminSession>();
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.cloud_off_outlined,
                    size: 40, color: Theme.of(context).colorScheme.error),
                const SizedBox(height: 16),
                Text('Could not check your sign-in',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 10),
                Text(
                  // Supabase's or the platform's own words, which is the only
                  // thing that tells a dropped connection from a bad key.
                  session.error ?? 'Something went wrong.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: session.busy
                      ? null
                      : () => context.read<AdminSession>().retry(),
                  icon: const Icon(Icons.refresh),
                  label: const Text('Try again'),
                ),
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: () => context.read<AdminSession>().signOut(),
                  child: const Text('Sign out'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
