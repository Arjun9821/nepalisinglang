import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nsl_fyp/main.dart';
import 'package:nsl_fyp/nsl/sentence_pipeline_controller.dart';
import 'package:nsl_fyp/presentation/widgets/sentence_card.dart';

void main() {
  testWidgets('App launches and shows Home screen', (WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(child: NepaliSignLanguageApp()),
    );

    // Home screen should show the app title.
    expect(find.text('Nepali Sign Language Recognition'), findsOneWidget);
  });

  testWidgets('Done and Undo disable when only flushed letters are displayed',
      (WidgetTester tester) async {
    var actionTriggered = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SentenceCard(
            state: const SentencePipelineState(letters: 'ABC'),
            backendLabel: 'On-device join',
            hasBufferedLetters: false,
            onDone: () => actionTriggered = true,
            onClear: () {},
            onUndo: () => actionTriggered = true,
            onSpeak: () {},
          ),
        ),
      ),
    );

    await tester.tap(find.text('Done'));
    await tester.pump();
    await tester.tap(find.text('Undo letter'));
    await tester.pump();

    expect(actionTriggered, isFalse);
  });
}