import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One synthesized sentence, with when it was produced.
@immutable
class HistoryEntry {
  const HistoryEntry({required this.sentence, required this.at});

  final String sentence;
  final DateTime at;

  Map<String, dynamic> toJson() =>
      {'s': sentence, 't': at.millisecondsSinceEpoch};

  static HistoryEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final s = raw['s'];
    final t = raw['t'];
    if (s is! String || s.isEmpty || t is! int) return null;
    return HistoryEntry(
      sentence: s,
      at: DateTime.fromMillisecondsSinceEpoch(t),
    );
  }
}

/// Persists synthesized sentences across app restarts.
///
/// Distinct from `SentencePipelineState.history`, the short in-memory window
/// used as LLM context and cleared by `clearAll()`: this is the user-facing
/// record, longer and durable. Every method swallows storage failures -- a
/// history screen that cannot read its file must not break recognition.
class SentenceHistoryStore {
  static const String _key = 'nsl.sentence_history.v1';

  /// Kept bounded so the preference value cannot grow without limit. Oldest
  /// entries are dropped first.
  static const int maxEntries = 100;

  Future<List<HistoryEntry>> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null || raw.isEmpty) return const [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .map(HistoryEntry.fromJson)
          .whereType<HistoryEntry>()
          .toList();
    } catch (e) {
      debugPrint('[NSL] history load failed: $e');
      return const [];
    }
  }

  /// Appends [sentence] as the newest entry.
  /// Appends [sentence] as the newest entry. Consecutive duplicates are
  /// collapsed, so pressing Done twice does not fill the list with repeats.
  Future<void> add(String sentence) async {
    final trimmed = sentence.trim();
    if (trimmed.isEmpty) return;
    try {
      final entries = List<HistoryEntry>.from(await load());
      if (entries.isNotEmpty && entries.last.sentence == trimmed) return;
      entries.add(HistoryEntry(sentence: trimmed, at: DateTime.now()));
      while (entries.length > maxEntries) {
        entries.removeAt(0);
      }
      await _write(entries);
    } catch (e) {
      debugPrint('[NSL] history add failed: $e');
    }
  }

  Future<void> remove(int index) async {
    try {
      final entries = List<HistoryEntry>.from(await load());
      if (index < 0 || index >= entries.length) return;
      entries.removeAt(index);
      await _write(entries);
    } catch (e) {
      debugPrint('[NSL] history remove failed: $e');
    }
  }

  Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_key);
    } catch (e) {
      debugPrint('[NSL] history clear failed: $e');
    }
  }

  Future<void> _write(List<HistoryEntry> entries) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode([for (final e in entries) e.toJson()]),
    );
  }
}
