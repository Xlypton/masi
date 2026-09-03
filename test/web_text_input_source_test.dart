import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Pins the two `web/index.html` rules that make text input WORK on the PWA,
/// both of which were regressions caused by canvas-protection code that was
/// correct in intent and too broad in scope.
///
/// Why a source test and not a widget test: neither property is observable
/// from Dart. Flutter web does not edit text on the canvas — it positions a
/// real DOM `<input>`/`<textarea>` (class `flt-text-editing`) over the painted
/// field, inside `<flt-text-editing-host>`, which the engine appends to
/// `<flutter-view>` in the LIGHT DOM rather than into the `<flt-glass-pane>`
/// shadow root (see `DomManager`'s tree diagram in the engine sources). Light
/// DOM means it INHERITS `<body>`'s CSS, and the engine's own stylesheet
/// (`applyGlobalCssRulesToSheet`) resets only `::selection` colour,
/// `caret-color` and `::placeholder` — never `user-select` or
/// `-webkit-touch-callout`. So `<body>`'s canvas-protection rules reach the
/// input, and no Flutter-side test can see it happen.
///
/// The three bugs that produced, all reported as "the text fields are buggy":
///   - `-webkit-touch-callout: none` suppresses the iOS long-press callout,
///     which is the only way to paste on iOS. The guidebook-import sheet is a
///     paste target by definition, so that feature was unusable.
///   - `user-select: none` makes WebKit treat the input's text as
///     unselectable, so the iOS space-bar-hold cursor-positioning gesture has
///     no selection to drive and drag-select does nothing.
///   - The blanket `contextmenu` `preventDefault()` removed Cut/Copy/Paste
///     from every field on desktop web too.
String _read(String relativePath) {
  final file = File(p.join(Directory.current.path, relativePath));
  expect(file.existsSync(), isTrue, reason: 'expected $relativePath to exist');
  return file.readAsStringSync();
}

void main() {
  group('web/index.html keeps text input usable', () {
    test('re-enables selection inside the text-editing host', () {
      final source = _read('web/index.html');

      // The canvas protection itself must STAY — this test guards the scope of
      // the fix, not its removal. A future edit that drops the body rules
      // entirely would make canvas drags select text again.
      expect(
        source,
        contains('-webkit-touch-callout: none;'),
        reason: 'the <body> canvas protection should still be there',
      );

      expect(
        source,
        contains('flutter-view flt-text-editing-host'),
        reason:
            'the text-editing host must be exempted from <body>\'s '
            'user-select/touch-callout rules, or paste and iOS cursor '
            'positioning break inside every text field',
      );
      expect(source, contains('-webkit-user-select: text;'));
      expect(source, contains('-webkit-touch-callout: default;'));
    });

    test('does not suppress the context menu over a text field', () {
      final source = _read('web/index.html');

      expect(
        source,
        contains('contextmenu'),
        reason: 'the canvas still needs its context-menu suppression',
      );
      // The guard, not the suppression, is what this pins: an unconditional
      // `preventDefault()` is what removed Paste from every input.
      expect(
        source,
        contains('flt-text-editing-host, input, textarea, '
            '[contenteditable="true"]'),
        reason:
            'the contextmenu handler must bail out over an editable target '
            'so the browser still offers Paste',
      );
    });
  });
}
