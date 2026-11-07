import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/utils/playback_seek_preview.dart';
import 'package:mornye/widgets/app_search_field.dart';
import 'package:mornye/widgets/app_text_field.dart';
import 'package:mornye/widgets/playback_seek_slider.dart';

void main() {
  testWidgets('Cupertino seek previews movement and commits a single target', (
    tester,
  ) async {
    final preview = PlaybackSeekPreview();
    addTearDown(preview.dispose);
    final seeks = <Duration>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlaybackSeekSlider(
            position: const Duration(seconds: 10),
            duration: const Duration(seconds: 100),
            preview: preview,
            onSeek: (target) async {
              seeks.add(target);
            },
          ),
        ),
      ),
    );
    final bounds = tester.getRect(find.byType(CupertinoSlider));
    final gesture = await tester.startGesture(
      Offset(bounds.left + bounds.width * .1, bounds.center.dy),
    );
    await gesture.moveBy(Offset(bounds.width * .4, 0));
    await tester.pump();
    expect(preview.value, isNotNull);
    final target = preview.value;
    expect(seeks, isEmpty);
    await gesture.up();
    await tester.pump();
    expect(seeks, [target]);
    expect(preview.value, isNull);
  }, variant: const TargetPlatformVariant({TargetPlatform.iOS}));

  testWidgets('Cupertino search uses the same submit and clear actions', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final submissions = <String>[];
    var cleared = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppSearchField(
            controller: controller,
            hintText: 'Search music',
            clearTooltip: 'Clear search',
            onClear: () => cleared++,
            onSubmitted: submissions.add,
          ),
        ),
      ),
    );
    await tester.enterText(find.byType(CupertinoTextField), 'blue');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    expect(submissions, ['blue']);
    await tester.tap(find.byTooltip('Clear search'));
    await tester.pump();
    expect(controller.text, isEmpty);
    expect(cleared, 1);
  }, variant: const TargetPlatformVariant({TargetPlatform.iOS}));

  testWidgets('Cupertino editing retains Flutter form validation', (
    tester,
  ) async {
    final form = GlobalKey<FormState>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Form(
            key: form,
            child: AppTextField(
              label: 'Name',
              validator: (value) =>
                  (value ?? '').isEmpty ? 'Name required' : null,
            ),
          ),
        ),
      ),
    );
    expect(form.currentState!.validate(), isFalse);
    await tester.pump();
    expect(find.text('Name required'), findsOneWidget);
    await tester.enterText(find.byType(CupertinoTextField), 'Mornye');
    expect(form.currentState!.validate(), isTrue);
    await tester.pump();
    expect(find.text('Name required'), findsNothing);
    await tester.pump(const Duration(seconds: 1));
  }, variant: const TargetPlatformVariant({TargetPlatform.iOS}));
}
