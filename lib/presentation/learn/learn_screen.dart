import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/providers.dart';
import '../widgets/hand_skeleton.dart';

/// One character the classifier knows, with a real example of its handshape.
@immutable
class NslSign {
  const NslSign({
    required this.label,
    required this.index,
    required this.landmarks,
  });

  final String label;

  /// Model output index for this character. Shown because the index-to-character
  /// mapping is a string sort of folder names rather than anything intuitive.
  final int index;

  /// 21 `[x, y, z]` landmarks from a genuine training sample, or null if the
  /// fixture has no row for this character.
  final List<List<double>>? landmarks;
}

/// Builds the sign list by joining `meta.json`'s label order to the landmark
/// rows in `assets/parity.json`. Both files are already bundled, and because the
/// skeletons come from real training samples they show what the model expects.
final nslSignsProvider = FutureProvider<List<NslSign>>((ref) async {
  final model = await ref.watch(nslModelProvider.future);

  final byLabel = <String, List<List<double>>>{};
  try {
    final p = jsonDecode(await rootBundle.loadString('assets/parity.json'))
        as Map<String, dynamic>;
    final lms = p['landmarks'] as List;
    final truth = p['true'] as List;
    for (var i = 0; i < lms.length && i < truth.length; i++) {
      final label = truth[i] as String;
      // First sample wins; the fixture holds one row per class anyway.
      byLabel.putIfAbsent(
        label,
        () => [
          for (final pt in lms[i] as List)
            [
              (pt[0] as num).toDouble(),
              (pt[1] as num).toDouble(),
              (pt[2] as num).toDouble(),
            ],
        ],
      );
    }
  } catch (e) {
    debugPrint('[NSL] learn: could not load example landmarks: $e');
  }

  return [
    for (var i = 0; i < model.labels.length; i++)
      NslSign(
        label: model.labels[i],
        index: i,
        landmarks: byLabel[model.labels[i]],
      ),
  ];
});

/// Reference chart of every character the model can recognise.
class LearnScreen extends ConsumerWidget {
  const LearnScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final signs = ref.watch(nslSignsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Learn')),
      body: signs.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('Could not load the character set.\n$e',
                textAlign: TextAlign.center,
                style: TextStyle(color: theme.colorScheme.error)),
          ),
        ),
        data: (list) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(
                '${list.length} Devanagari characters. Each handshape is drawn '
                'from a real training sample, so it shows what the recogniser '
                'expects to see.',
                style: theme.textTheme.bodySmall,
              ),
            ),
            Expanded(
              child: GridView.builder(
                padding: const EdgeInsets.all(12),
                gridDelegate:
                    const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  childAspectRatio: 0.82,
                  crossAxisSpacing: 10,
                  mainAxisSpacing: 10,
                ),
                itemCount: list.length,
                itemBuilder: (_, i) => _SignTile(
                  sign: list[i],
                  onTap: () => _openDetail(context, list, i),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _openDetail(BuildContext context, List<NslSign> all, int index) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _SignDetailScreen(all: all, initialIndex: index),
      ),
    );
  }
}

class _SignTile extends StatelessWidget {
  const _SignTile({required this.sign, required this.onTap});

  final NslSign sign;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            children: [
              Expanded(
                child: sign.landmarks == null
                    ? Center(
                        child: Icon(Icons.help_outline_rounded,
                            color: theme.colorScheme.outlineVariant),
                      )
                    : HandSkeleton(landmarks: sign.landmarks!),
              ),
              const SizedBox(height: 4),
              Text(
                sign.label,
                style: theme.textTheme.headlineSmall
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Full-size view, swipeable through the whole character set.
class _SignDetailScreen extends StatefulWidget {
  const _SignDetailScreen({required this.all, required this.initialIndex});

  final List<NslSign> all;
  final int initialIndex;

  @override
  State<_SignDetailScreen> createState() => _SignDetailScreenState();
}

class _SignDetailScreenState extends State<_SignDetailScreen> {
  late final PageController _controller =
      PageController(initialPage: widget.initialIndex);
  late int _current = widget.initialIndex;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text('${_current + 1} of ${widget.all.length}'),
      ),
      body: PageView.builder(
        controller: _controller,
        itemCount: widget.all.length,
        onPageChanged: (i) => setState(() => _current = i),
        itemBuilder: (_, i) {
          final sign = widget.all[i];
          return Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                Text(sign.label,
                    style: theme.textTheme.displayLarge
                        ?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                Text('Model output index ${sign.index}',
                    style: theme.textTheme.bodySmall),
                const SizedBox(height: 16),
                Expanded(
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: sign.landmarks == null
                          ? Center(
                              child: Text('No example available',
                                  style: theme.textTheme.bodyMedium),
                            )
                          : HandSkeleton(
                              landmarks: sign.landmarks!,
                              strokeWidth: 4,
                              pointRadius: 5,
                            ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Swipe to browse. The skeleton is a real training sample, '
                  'viewed from the camera side.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
