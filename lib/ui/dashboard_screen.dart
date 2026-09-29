import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/admin_session.dart';
import '../data/admin_repository.dart';
import '../r2/r2_credentials.dart';
import '../schema/catalog.dart';
import '../schema/table_spec.dart';
import 'analytics_screen.dart';
import 'bucket_screen.dart';
import 'collection_screen.dart';
import 'r2_settings_screen.dart';

/// Home: every table in the catalog, plus the bucket.
///
/// Cards are full width and size themselves around their text — no fixed aspect
/// ratio, so a long description never clips.
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final Map<String, int?> _counts = {};
  bool _countsLoaded = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadCounts());
  }

  /// Row counts are decoration, so they load after the screen is up and a
  /// failure just leaves the number off.
  Future<void> _loadCounts() async {
    final repository = context.read<AdminRepository>();
    await Future.wait(
      adminCatalog.map((spec) async {
        final count = await repository.count(spec);
        if (mounted) _counts[spec.table] = count;
      }),
    );
    if (mounted) setState(() => _countsLoaded = true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final session = context.watch<AdminSession>();
    final r2 = context.watch<R2CredentialStore>().credentials;

    return Scaffold(
      appBar: AppBar(
        title: const Text('One VTU Admin'),
        actions: [
          IconButton(
            tooltip: 'Refresh counts',
            onPressed: _loadCounts,
            icon: const Icon(Icons.refresh),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: (value) {
              switch (value) {
                case 'r2':
                  Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => const R2SettingsScreen()));
                case 'signout':
                  context.read<AdminSession>().signOut();
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'r2', child: Text('Cloudflare R2 keys')),
              const PopupMenuItem(value: 'signout', child: Text('Sign out')),
            ],
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 32),
        children: [
          Text(
            session.email ?? 'Signed in',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 4),
          Text(
            'Every save here changes the live app.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.error.withValues(alpha: 0.9)),
          ),
          const SizedBox(height: 18),

          // The bucket comes first: it is where the files behind every link
          // column live, and the link columns are the reason this app exists.
          _NavCard(
            icon: Icons.cloud_outlined,
            title: 'Files in Cloudflare R2',
            subtitle: r2.isComplete
                ? '${r2.bucket} — upload, replace or delete the PDFs and images '
                    'the links point at'
                : 'Add your R2 keys to manage files from here',
            trailing: Icon(
                r2.isComplete ? Icons.chevron_right : Icons.key_outlined,
                size: 18),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => r2.isComplete
                    ? const BucketScreen()
                    : const R2SettingsScreen(),
              ),
            ),
          ),

          const SizedBox(height: 8),
          _NavCard(
            icon: Icons.insights_outlined,
            title: 'Analytics',
            subtitle: 'How many users, and how much of the library is filled in',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const AnalyticsScreen()),
            ),
          ),

          for (final group in catalogGroups) ...[
            const SizedBox(height: 22),
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 8),
              child: Text(
                group.toUpperCase(),
                style: theme.textTheme.labelSmall?.copyWith(
                  letterSpacing: 1.1,
                  color: Colors.white.withValues(alpha: 0.5),
                ),
              ),
            ),
            for (final spec in adminCatalog.where((s) => s.group == group))
              _TableCard(
                spec: spec,
                count: _counts[spec.table],
                countsLoaded: _countsLoaded,
                onTap: () => Navigator.of(context)
                    .push(MaterialPageRoute(
                      builder: (_) => CollectionScreen(spec: spec),
                    ))
                    .then((_) => _loadCounts()),
              ),
          ],
        ],
      ),
    );
  }
}

class _TableCard extends StatelessWidget {
  const _TableCard({
    required this.spec,
    required this.count,
    required this.countsLoaded,
    required this.onTap,
  });

  final TableSpec spec;
  final int? count;
  final bool countsLoaded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(spec.icon, size: 19, color: theme.colorScheme.primary),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(spec.title,
                              style: theme.textTheme.titleSmall),
                        ),
                        if (count != null)
                          Text('$count', style: theme.textTheme.bodySmall)
                        else if (countsLoaded)
                          const SizedBox.shrink()
                        else
                          const SizedBox(
                            width: 11,
                            height: 11,
                            child: CircularProgressIndicator(strokeWidth: 1.6),
                          ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(spec.description, style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              const Icon(Icons.chevron_right, size: 18),
            ],
          ),
        ),
      ),
    );
  }
}

/// A tappable card above the table list — the bucket, the analytics screen.
class _NavCard extends StatelessWidget {
  const _NavCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.trailing = const Icon(Icons.chevron_right, size: 18),
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(icon, color: theme.colorScheme.primary),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: theme.textTheme.titleSmall),
                    const SizedBox(height: 3),
                    Text(subtitle, style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              trailing,
            ],
          ),
        ),
      ),
    );
  }
}
