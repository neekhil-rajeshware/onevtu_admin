import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/admin_repository.dart';
import 'widgets/state_views.dart';

/// Who is using the app, and how much of the library is actually filled in.
///
/// Two questions the console could not answer before. The table lists show what
/// exists; neither of them says that 46 of 205 subjects have a question paper, or
/// that a third of the profiles are missing a college.
///
/// Every number here is a bar rather than a table cell, because they are all the
/// same shape — *this many out of that many* — and the reading wanted is "which
/// of these is behind", which a column of digits does not give up quickly.
class AnalyticsScreen extends StatefulWidget {
  const AnalyticsScreen({super.key});

  @override
  State<AnalyticsScreen> createState() => _AnalyticsScreenState();
}

class _AnalyticsScreenState extends State<AnalyticsScreen> {
  Analytics? _data;
  String? _error;
  bool _loading = true;

  /// A college list can run to hundreds, and the long tail is one user each —
  /// past the first few the bars stop being a ranking and become a scroll.
  static const int _maxBars = 8;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await context.read<AdminRepository>().analytics();
      if (!mounted) return;
      setState(() {
        _data = data;
        _loading = false;
      });
    } on AdminWriteException catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.hint == null
            ? error.message
            : '${error.message}\n\n${error.hint}';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not read the counts: $error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Analytics'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _error != null
          ? ErrorView(message: _error!, onRetry: _load)
          : data == null
              ? const BusyView(label: 'Counting…')
              : RefreshIndicator(onRefresh: _load, child: _body(context, data)),
    );
  }

  Widget _body(BuildContext context, Analytics data) {
    final theme = Theme.of(context);
    final missing = data.users - data.completeProfiles;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        _Heading('Users', detail: '${data.users} signed in so far'),
        _Figures([
          ('Users', '${data.users}'),
          ('Complete profiles', '${data.completeProfiles}'),
          ('Missing something', '$missing'),
        ]),
        if (missing > 0)
          Padding(
            padding: const EdgeInsets.only(left: 4, top: 8),
            child: Text(
              'A profile counts as complete with a name, USN, branch, college, '
              'scheme and semester. The rest show up under "Missing something" '
              'above and are the ones worth chasing — the app filters subjects '
              'and papers by branch and scheme, so an empty one means those '
              'students see everything.',
              style: theme.textTheme.bodySmall,
            ),
          ),

        // Largest dimension first, and only the ones that exist: a scheme or a
        // cycle nobody has is a heading with no bars under it.
        for (final entry in _ordered(data.usersBy))
          if (entry.value.isNotEmpty) ...[
            const SizedBox(height: 20),
            _Heading(_dimensionLabel(entry.key), top: 0),
            for (final bar in _trim(entry.value)) _Bar(bar: bar),
          ],

        const SizedBox(height: 28),
        _Heading(
          'Links',
          detail: 'how much of the library is filled in',
          top: 0,
        ),
        for (final bar in data.links) _Bar(bar: bar),

        const SizedBox(height: 14),
        Text(
          'A question paper or a GATE paper counts as filled when that subject '
          'or branch has it for at least one exam session. The second bar of '
          'each pair counts the sessions themselves, so "46 of 205" and "69 of '
          '4100" are the same library seen two ways.',
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }

  /// The dimensions in the order the question is usually asked: where people
  /// are, then when, then which college.
  static const List<String> _dimensionOrder = [
    'branch', 'semester', 'scheme', 'cycle', 'college',
  ];

  static Iterable<MapEntry<String, List<StatBar>>> _ordered(
    Map<String, List<StatBar>> bars,
  ) {
    return [
      for (final key in _dimensionOrder)
        if (bars.containsKey(key)) MapEntry(key, bars[key]!),
      // Anything the database grows later, rather than dropping it silently.
      for (final entry in bars.entries)
        if (!_dimensionOrder.contains(entry.key)) entry,
    ];
  }

  static List<StatBar> _trim(List<StatBar> bars) =>
      bars.length <= _maxBars ? bars : bars.sublist(0, _maxBars);

  static String _dimensionLabel(String dimension) => switch (dimension) {
        'branch' => 'By branch',
        'semester' => 'By semester',
        'scheme' => 'By scheme',
        'cycle' => 'By cycle',
        'college' => 'By college',
        _ => dimension,
      };
}

/// Three numbers side by side, for the figures that are not a bar.
class _Figures extends StatelessWidget {
  const _Figures(this.figures);

  final List<(String, String)> figures;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        for (final (label, value) in figures)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(right: 10),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(value, style: theme.textTheme.titleLarge),
                    const SizedBox(height: 2),
                    // Wraps rather than ellipsises: "Complete profiles" is two
                    // words on a narrow phone and neither of them is optional.
                    Text(label, style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// One bar: what it is, how full it is, and the proportion the fill works out to.
class _Bar extends StatelessWidget {
  const _Bar({required this.bar});

  final StatBar bar;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fraction = bar.cap <= 0 ? 0.0 : bar.value / bar.cap;

    // Red for "most of this is missing", amber for "getting there", the primary
    // colour once it is nearly done. The link rows are a to-do list, so the
    // colour is the answer to "which one do I work on".
    final color = bar.cap <= 0
        ? theme.disabledColor
        : fraction >= 0.9
            ? theme.colorScheme.primary
            : fraction >= 0.5
                ? theme.colorScheme.tertiary
                : theme.colorScheme.error;

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(bar.label, style: theme.textTheme.bodyMedium),
                    if (bar.detail.isNotEmpty)
                      Text(
                        bar.detail,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.hintColor),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                bar.cap <= 0
                    ? 'nothing yet'
                    : '${bar.value} / ${bar.cap}',
                style: theme.textTheme.bodySmall,
              ),
              if (bar.cap > 0) ...[
                const SizedBox(width: 8),
                SizedBox(
                  width: 38,
                  child: Text(
                    '${(fraction * 100).round()}%',
                    textAlign: TextAlign.right,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(fontWeight: FontWeight.w600, color: color),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 6),
          LinearProgressIndicator(
            value: fraction.clamp(0.0, 1.0),
            minHeight: 8,
            borderRadius: BorderRadius.circular(4),
            color: color,
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
          ),
        ],
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.title, {this.detail, this.top = 8});

  final String title;
  final String? detail;
  final double top;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(left: 4, bottom: 8, top: top),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title.toUpperCase(),
            style: theme.textTheme.labelSmall?.copyWith(
              letterSpacing: 1.1,
              color: Colors.white.withValues(alpha: 0.5),
            ),
          ),
          if (detail != null)
            Text(detail!, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}
