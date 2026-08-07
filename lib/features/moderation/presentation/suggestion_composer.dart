import 'package:flutter/material.dart';

import '../../../shared/presentation/masi_dialogs.dart';
import '../domain/edit_suggestion.dart';

/// What [showSuggestionComposer] resolved to.
class SuggestionDraft {
  const SuggestionDraft({
    required this.kind,
    required this.patch,
    this.note,
    this.routeId,
  });

  final SuggestionKind kind;
  final Map<String, Object?> patch;
  final String? note;
  final String? routeId;
}

/// Lets anyone signed in propose a metadata fix to a published topo
/// (community editing phase 7a / C-5).
///
/// Returns `null` if they backed out.
///
/// One field at a time, deliberately. A form offering every field at once
/// produces suggestions that mix a good correction with two casual ones, and
/// the owner then has to accept or reject the lot — the patch model has no
/// notion of partial acceptance, and adding one would mean building a merge
/// UI for what is usually a typo fix.
///
/// The sheet says plainly that the owner decides. That is the honest framing
/// of C-5 — an owner's approval is final, there is no admin re-review — and
/// getting it wrong in the friendlier direction ("suggest a fix!") sets an
/// expectation the system cannot keep.
Future<SuggestionDraft?> showSuggestionComposer(
  BuildContext context, {
  required String targetLabel,
  required SuggestionKind kind,
  String? routeId,
}) async {
  final fields = kind.fields;
  final picked = await showMasiActionSheet<String>(
    context,
    sheetKey: const Key('suggestion-field-sheet'),
    title: 'Suggest a fix — $targetLabel',
    message: 'The owner decides whether to apply it. You are credited.',
    actions: [
      for (final field in fields)
        MasiSheetAction(
          key: Key('suggestion-field-${field.name}'),
          label: field.label,
          value: field.name,
        ),
    ],
  );
  if (picked == null || !context.mounted) return null;

  // `picked` came from this sheet's own values, so a miss cannot happen —
  // but `orElse` beats a `firstWhere` that would throw a StateError into a
  // dialog callback if it ever did.
  final field = fields.firstWhere(
    (f) => f.name == picked,
    orElse: () => fields.first,
  );

  final value = await showMasiTextPrompt(
    context,
    title: 'What should ${field.label.toLowerCase()} be?',
    submitLabel: 'Suggest',
    placeholder: field.isNumeric ? 'e.g. 47.6512' : 'The corrected value',
    fieldKey: const Key('suggestion-value-field'),
    submitKey: const Key('suggestion-value-submit'),
  );
  if (value == null || !context.mounted) return null;

  final trimmed = value.trim();
  // An empty value is refused for everything EXCEPT description, where
  // "remove this wrong text" is a real and useful suggestion.
  if (trimmed.isEmpty && field != SuggestableField.description) return null;

  Object? parsed = trimmed;
  if (field.isNumeric) {
    final number = double.tryParse(trimmed);
    // Bail rather than sending a string the server will store and the owner
    // will later fail to apply. Coordinates are the one field here where a
    // typo is silent — a wrong name is obvious, a wrong latitude is a hillside
    // twenty kilometres away.
    if (number == null) return null;
    parsed = number;
  }

  final note = await showMasiTextPrompt(
    context,
    title: 'Why?',
    submitLabel: 'Send',
    placeholder: 'Optional — but it is what gets a fix accepted',
    fieldKey: const Key('suggestion-note-field'),
    submitKey: const Key('suggestion-note-submit'),
  );
  // `null` means the prompt was dismissed, which abandons the whole thing. An
  // empty string means they submitted without typing, which is allowed.
  if (note == null) return null;

  return SuggestionDraft(
    kind: kind,
    patch: {field.wire: parsed},
    note: note.trim().isEmpty ? null : note.trim(),
    routeId: routeId,
  );
}
