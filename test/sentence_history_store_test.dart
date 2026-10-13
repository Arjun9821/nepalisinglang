import 'package:flutter_test/flutter_test.dart';
import 'package:nsl_fyp/services/history/sentence_history_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SentenceHistoryStore store;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    store = SentenceHistoryStore();
  });

  test('starts empty', () async {
    expect(await store.load(), isEmpty);
  });

  test('appends newest last and round-trips through storage', () async {
    await store.add('नमस्ते।');
    await store.add('म काठमाडौं जान्छु।');

    final entries = await store.load();
    expect(entries.map((e) => e.sentence),
        ['नमस्ते।', 'म काठमाडौं जान्छु।']);
    // A fresh instance reads the same data: this is persistence, not a cache.
    expect((await SentenceHistoryStore().load()).length, 2);
  });

  test('collapses consecutive duplicates', () async {
    await store.add('नमस्ते।');
    await store.add('नमस्ते।');
    expect((await store.load()).length, 1);

    // Non-consecutive repeats are legitimate -- the user really did say it
    // again -- so those are kept.
    await store.add('धन्यवाद।');
    await store.add('नमस्ते।');
    expect((await store.load()).length, 3);
  });

  test('ignores empty and whitespace-only sentences', () async {
    await store.add('');
    await store.add('   ');
    expect(await store.load(), isEmpty);
  });

  test('trims stored sentences', () async {
    await store.add('  नमस्ते।  ');
    expect((await store.load()).single.sentence, 'नमस्ते।');
  });

  test('caps at maxEntries, dropping oldest first', () async {
    for (var i = 0; i < SentenceHistoryStore.maxEntries + 10; i++) {
      await store.add('sentence $i');
    }
    final entries = await store.load();
    expect(entries.length, SentenceHistoryStore.maxEntries);
    expect(entries.first.sentence, 'sentence 10');
    expect(entries.last.sentence,
        'sentence ${SentenceHistoryStore.maxEntries + 9}');
  });

  test('remove drops the entry at that index', () async {
    await store.add('one');
    await store.add('two');
    await store.add('three');

    await store.remove(1);
    expect((await store.load()).map((e) => e.sentence), ['one', 'three']);
  });

  test('remove ignores an out-of-range index', () async {
    await store.add('one');
    await store.remove(5);
    await store.remove(-1);
    expect((await store.load()).length, 1);
  });

  test('clear empties everything', () async {
    await store.add('one');
    await store.clear();
    expect(await store.load(), isEmpty);
  });

  test('survives a corrupt stored value rather than throwing', () async {
    SharedPreferences.setMockInitialValues(
        {'nsl.sentence_history.v1': 'not json at all'});
    // A history screen that cannot parse its file must show an empty list, not
    // take down the app.
    expect(await SentenceHistoryStore().load(), isEmpty);
  });

  test('skips malformed entries but keeps well-formed ones', () async {
    SharedPreferences.setMockInitialValues({
      'nsl.sentence_history.v1':
          '[{"s":"ok","t":1000},{"s":"","t":2000},{"nope":1},{"s":"also ok"}]',
    });
    final entries = await SentenceHistoryStore().load();
    expect(entries.map((e) => e.sentence), ['ok']);
  });
}
