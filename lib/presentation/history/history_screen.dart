import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/history/sentence_history_store.dart';
import '../providers/providers.dart';

/// Durable record of every sentence the app has spoken. Separate from the
/// 5-entry LLM-context window in `SentencePipelineState.history`, which Clear
/// wipes: this survives restarts.
class HistoryScreen extends ConsumerWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final entries = ref.watch(sentenceHistoryProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('History'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_sweep_rounded),
            tooltip: 'Clear all history',
            onPressed: entries.valueOrNull?.isEmpty ?? true
                ? null
                : () => _confirmClear(context, ref),
          ),
        ],
      ),
      body: entries.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Could not read history.\n$e')),
        data: (list) {
          if (list.isEmpty) return const _EmptyHistory();
          // Newest first: the thing just said is the thing most likely wanted.
          final ordered = list.reversed.toList();
          return ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: ordered.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (_, i) {
              final entry = ordered[i];
              // Map back to storage order for removal.
              final storageIndex = list.length - 1 - i;
              return _HistoryTile(
                entry: entry,
                onSpeak: () => ref.read(ttsServiceProvider).speak(entry.sentence),
                onCopy: () {
                  Clipboard.setData(ClipboardData(text: entry.sentence));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Copied'),
                      duration: Duration(seconds: 1),
                    ),
                  );
                },
                onDelete: () async {
                  await ref.read(sentenceHistoryStoreProvider).remove(storageIndex);
                  ref.invalidate(sentenceHistoryProvider);
                },
              );
            },
          );
        },
      ),
      floatingActionButton: entries.valueOrNull == null
          ? null
          : FloatingActionButton.small(
              tooltip: 'Refresh',
              onPressed: () => ref.invalidate(sentenceHistoryProvider),
              child: const Icon(Icons.refresh_rounded),
            ),
      backgroundColor: theme.colorScheme.surface,
    );
  }

  Future<void> _confirmClear(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear history?'),
        content: const Text(
            'This permanently removes every saved sentence. It cannot be '
            'undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Clear')),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(sentenceHistoryStoreProvider).clear();
    ref.invalidate(sentenceHistoryProvider);
  }
}

class _HistoryTile extends StatelessWidget {
  const _HistoryTile({
    required this.entry,
    required this.onSpeak,
    required this.onCopy,
    required this.onDelete,
  });

  final HistoryEntry entry;
  final VoidCallback onSpeak, onCopy;
  final Future<void> Function() onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Dismissible(
      key: ValueKey('${entry.at.millisecondsSinceEpoch}-${entry.sentence}'),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        decoration: BoxDecoration(
          color: theme.colorScheme.errorContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(Icons.delete_rounded,
            color: theme.colorScheme.onErrorContainer),
      ),
      onDismissed: (_) => onDelete(),
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(entry.sentence,
                        style: theme.textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text(_formatWhen(entry.at),
                        style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.volume_up_rounded),
                tooltip: 'Speak',
                onPressed: onSpeak,
              ),
              IconButton(
                icon: const Icon(Icons.copy_rounded),
                tooltip: 'Copy',
                onPressed: onCopy,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Relative for recent entries, absolute once that stops being useful.
  static String _formatWhen(DateTime at) {
    final d = DateTime.now().difference(at);
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes} min ago';
    if (d.inHours < 24) return '${d.inHours} h ago';
    if (d.inDays < 7) return '${d.inDays} d ago';
    String two(int n) => n.toString().padLeft(2, '0');
    return '${at.year}-${two(at.month)}-${two(at.day)} '
        '${two(at.hour)}:${two(at.minute)}';
  }
}

class _EmptyHistory extends StatelessWidget {
  const _EmptyHistory();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.history_rounded,
                size: 56, color: theme.colorScheme.outlineVariant),
            const SizedBox(height: 12),
            Text('No sentences yet', style: theme.textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              'Sentences you build on the Live tab are saved here '
              'automatically, and stay after you close the app.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
