import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'config.dart';
import 'core/admin_push.dart';
import 'core/admin_session.dart';
import 'data/admin_repository.dart';
import 'data/lookup_cache.dart';
import 'data/push_sender.dart';
import 'data/store_notifier.dart';
import 'r2/r2_credentials.dart';
import 'schema/catalog.dart';
import 'schema/table_spec.dart';
import 'theme.dart';
import 'ui/collection_screen.dart';
import 'ui/dashboard_screen.dart';
import 'ui/login_screen.dart';
import 'ui/widgets/moderation_action.dart';
import 'ui/widgets/state_views.dart';

/// A tapped notification has no `BuildContext` of its own — it arrives from the
/// notifications plugin, outside the widget tree — so the one navigator is
/// reached by key instead.
final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

/// Where a tapped queue notice goes. Looked up by table name rather than by
/// index, so reordering the catalog cannot quietly open a different table.
final TableSpec _storeSpec = specForTable('store')!;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Supabase.initialize(
    url: AdminConfig.supabaseUrl,
    // The anon key goes in as the publishable key: same value, and `anonKey` is
    // deprecated in supabase_flutter 2.17.
    publishableKey: AdminConfig.supabaseAnonKey,
  );

  // R2 keys come out of Keystore-backed storage before the first frame, so the
  // dashboard already knows whether the bucket is reachable.
  final r2Store = R2CredentialStore();
  await r2Store.load();

  runApp(AdminApp(r2Store: r2Store));
}

class AdminApp extends StatelessWidget {
  const AdminApp({super.key, required this.r2Store});

  final R2CredentialStore r2Store;

  @override
  Widget build(BuildContext context) {
    final client = Supabase.instance.client;
    final repository = AdminRepository(client);

    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AdminSession(client)),
        ChangeNotifierProvider.value(value: r2Store),
        Provider<AdminRepository>.value(value: repository),
        Provider<LookupCache>(create: (_) => LookupCache(repository)),
        Provider<PushSender>(create: (_) => PushSender(client)),
        Provider<StoreNotifier>(create: (_) => StoreNotifier(client)),
      ],
      child: _PushBinding(
        child: MaterialApp(
          title: 'One VTU Admin',
          debugShowCheckedModeBanner: false,
          navigatorKey: _navigatorKey,
          theme: buildAdminTheme(),
          home: const _AuthGate(),
        ),
      ),
    );
  }
}

/// Keeps the push subscription in step with who is signed in, and turns a tapped
/// notice into the review queue.
///
/// Wraps the app rather than living on a screen, because neither of those things
/// belongs to a screen: a notice can land while the app is on any of them, and the
/// subscription has to outlive every one of them being rebuilt. It draws nothing.
class _PushBinding extends StatefulWidget {
  const _PushBinding({required this.child});

  final Widget child;

  @override
  State<_PushBinding> createState() => _PushBindingState();
}

class _PushBindingState extends State<_PushBinding> {
  late final AdminPush _push = AdminPush(onOpenReviewQueue: _requestQueue);
  late final AdminSession _session;

  /// A tap waiting for somewhere to go. A cold start from a notification lands on
  /// the sign-in screen, and the queue is not reachable from there — so the tap is
  /// held rather than dropped, and spent when the session becomes an admin one.
  bool _queueWanted = false;

  /// So a second tap does not stack a second copy of the same screen.
  bool _queueOpen = false;

  @override
  void initState() {
    super.initState();
    // `read` in initState is the one place provider allows it, and this listener
    // is why: the subscription follows auth, not the build.
    _session = context.read<AdminSession>();
    _session.addListener(_onSessionChanged);
    _start();
  }

  @override
  void dispose() {
    _session.removeListener(_onSessionChanged);
    super.dispose();
  }

  Future<void> _start() async {
    await _push.start();
    if (!mounted) return;
    // Only after `start`, which registers the plugin the launch tap is read out
    // of, and only once — a tap that launched the app is collected, not delivered.
    await _push.consumeLaunchTap();
    if (!mounted) return;
    // The session may already have settled while the above was in flight, in
    // which case its listener has nothing left to fire.
    _onSessionChanged();
  }

  void _onSessionChanged() {
    final isAdmin = _session.state == AdminAuthState.ready;
    _push.syncSubscription(isAdmin: isAdmin);
    _openQueueIfPossible();
  }

  void _requestQueue(String listingId) {
    // Logged because the alternative diagnosis for "the notification opened
    // nothing" is guesswork: this line says the tap arrived and which row it named.
    debugPrint('AdminPush: notice tapped for listing "$listingId"');
    _queueWanted = true;
    _openQueueIfPossible();
  }

  void _openQueueIfPossible() {
    if (!_queueWanted) return;
    // Sign-in, and the second factor, come first: the queue reads rows only an
    // admin session is allowed to see.
    if (_session.state != AdminAuthState.ready) return;
    final navigator = _navigatorKey.currentState;
    if (navigator == null) return;

    _queueWanted = false;
    if (_queueOpen) return;
    _queueOpen = true;
    navigator
        .push(MaterialPageRoute(
          builder: (_) => CollectionScreen(
            spec: _storeSpec,
            // The whole point of the notice: what is waiting, not everything ever
            // listed. Shown as a filter chip the admin can clear.
            initialFilters: const {'status': ListingStatus.pending},
          ),
        ))
        .whenComplete(() => _queueOpen = false);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Decides which of the screens the app can be on. Writes are refused by RLS for
/// anyone without a `web_admins` row and a second factor, so this gate is a
/// courtesy, not the security boundary.
class _AuthGate extends StatelessWidget {
  const _AuthGate();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AdminSession>().state;
    return switch (state) {
      AdminAuthState.checking =>
        const Scaffold(body: BusyView(label: 'Checking your sign-in…')),
      AdminAuthState.signedOut => const LoginScreen(),
      AdminAuthState.needsCode => const MfaCodeScreen(),
      AdminAuthState.notAnAdmin => const NotAnAdminScreen(),
      AdminAuthState.failed => const CouldNotCheckScreen(),
      AdminAuthState.ready => const DashboardScreen(),
    };
  }
}
