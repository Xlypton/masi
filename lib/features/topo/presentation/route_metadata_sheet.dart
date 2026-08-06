import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:masi/app/theme.dart';
import 'package:masi/core/grades/grade_system.dart';
import 'package:masi/core/routes/route_styles.dart';
import 'package:masi/features/topo/application/draw_controller.dart';
import 'package:masi/features/topo/domain/topo_route.dart';
import 'package:masi/shared/presentation/masi_icon.dart';

/// Free-form climbing style options offered by [RouteMetadataSheet], by
/// convention one of `'sport'`, `'trad'`, `'boulder'` (see
/// [TopoRoute.style]).
const List<(String value, String label)> _styleOptions = [
  ('sport', 'Sport'),
  ('trad', 'Trad'),
  ('boulder', 'Boulder'),
];

/// Maps a [GradeBand] to its MASI design-token color (see DESIGN.md's
/// "Grade bands" table, wired to [MasiColors]). Kept local to this sheet
/// (rather than added to `core/grades`, which is deliberately UI-free — see
/// that file's doc) — this is the only place in this sheet that needs a
/// [GradeBand] -> [Color] mapping.
Color gradeBandColor(MasiColors colors, GradeBand band) {
  switch (band) {
    case GradeBand.beginner:
      return colors.gradeBeginner;
    case GradeBand.intermediate:
      return colors.gradeIntermediate;
    case GradeBand.advanced:
      return colors.gradeAdvanced;
    case GradeBand.hard:
      return colors.gradeHard;
    case GradeBand.elite:
      return colors.gradeElite;
  }
}

/// Short display label for a [GradeBand], used in the grade-band feedback
/// badge next to the grade picker.
String gradeBandLabel(GradeBand band) {
  switch (band) {
    case GradeBand.beginner:
      return 'Beginner';
    case GradeBand.intermediate:
      return 'Intermediate';
    case GradeBand.advanced:
      return 'Advanced';
    case GradeBand.hard:
      return 'Hard';
    case GradeBand.elite:
      return 'Elite';
  }
}

/// A standalone, directly-testable form for editing a [TopoRoute]'s
/// free-form/grade metadata (name, grade system + grade, style,
/// description).
///
/// Deliberately built as a plain (non-modal-aware) widget rather than
/// something that reaches into `Navigator`/route-arguments machinery, so it
/// can be pumped directly inside a `ProviderScope`/`MaterialApp` in widget
/// tests — with [drawControllerProvider] seeded via a
/// [ProviderContainer]/[UncontrolledProviderScope] — without ever touching
/// the real image-decode/canvas path that only [TopoCanvasScreen] drives.
/// Callers that want it presented as a sheet (e.g. [TopoCanvasScreen]) wrap
/// it in `showModalBottomSheet` themselves; this widget only needs a
/// [Navigator] ancestor to pop itself on Save/Cancel.
class RouteMetadataSheet extends ConsumerStatefulWidget {
  const RouteMetadataSheet({
    super.key,
    required this.wallId,
    required this.routeId,
    this.initial,
  });

  /// FIX #6: family key for [drawControllerProvider] — see that provider's
  /// doc. Always the same wallId as the owning [TopoCanvasScreen].
  final String wallId;

  /// The id of the [TopoRoute] (in [DrawState.routes]) this sheet edits.
  final int routeId;

  /// The route's current metadata, used to pre-fill the form fields when
  /// editing an already-graded/named route. Null for a brand new route
  /// (all fields start empty/unset).
  final TopoRoute? initial;

  @override
  ConsumerState<RouteMetadataSheet> createState() =>
      _RouteMetadataSheetState();
}

class _RouteMetadataSheetState extends ConsumerState<RouteMetadataSheet> {
  late final TextEditingController _nameController;
  late final TextEditingController _descriptionController;
  late final TextEditingController _betaUrlController;
  late final TextEditingController _customTagController;
  late GradeSystem _gradeSystem;
  String? _grade;
  String? _style;
  late Set<String> _styleTags;
  int? _stars;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _nameController = TextEditingController(text: initial?.name ?? '');
    _descriptionController = TextEditingController(
      text: initial?.description ?? '',
    );
    _betaUrlController = TextEditingController(
      text: initial?.betaVideoUrl ?? '',
    );
    // Live-validate as the user types so the inline error (see
    // `_betaUrlInvalid`) tracks the field rather than only appearing after
    // a failed Save attempt.
    _betaUrlController.addListener(_handleBetaUrlChanged);
    _customTagController = TextEditingController();
    _gradeSystem = initial?.gradeSystem ?? GradeSystem.french;
    _grade = initial?.gradeRaw;
    _style = initial?.style;
    _styleTags = {...?initial?.styleTags};
    _stars = initial?.stars;
  }

  @override
  void dispose() {
    _betaUrlController.removeListener(_handleBetaUrlChanged);
    _nameController.dispose();
    _descriptionController.dispose();
    _betaUrlController.dispose();
    _customTagController.dispose();
    super.dispose();
  }

  void _handleBetaUrlChanged() {
    setState(() {});
  }

  /// #41 validation: an empty (after trim) URL clears the field (`null`);
  /// a non-empty one must be a valid `http`/`https` URL. Trims surrounding
  /// whitespace either way. Invalid-but-non-empty values are no longer
  /// silently dropped here -- [_betaUrlInvalid] blocks Save until the field
  /// is fixed or cleared, so by the time this runs the value is already
  /// known-good (or empty).
  String? _validatedBetaUrl() {
    final raw = _betaUrlController.text.trim();
    return raw.isEmpty ? null : raw;
  }

  /// True when the beta-URL field currently holds a non-empty value that
  /// isn't a valid `http`/`https` URL. Drives the inline error shown under
  /// the field and blocks [_save] until the field is fixed or cleared.
  bool get _betaUrlInvalid {
    final raw = _betaUrlController.text.trim();
    if (raw.isEmpty) return false;
    final uri = Uri.tryParse(raw);
    return uri == null ||
        !uri.isAbsolute ||
        !(uri.isScheme('http') || uri.isScheme('https'));
  }

  void _toggleStyleTag(String key) {
    setState(() {
      if (!_styleTags.remove(key)) _styleTags.add(key);
    });
  }

  void _addCustomTag() {
    final raw = _customTagController.text.trim();
    if (raw.isEmpty) return;
    setState(() {
      _styleTags.add(raw.toLowerCase());
      _customTagController.clear();
    });
  }

  /// Tapping the currently-set star clears the rating back to unrated
  /// (`null`); tapping any other star sets it to that value.
  void _onStarTapped(int value) {
    setState(() => _stars = _stars == value ? null : value);
  }

  /// Switches the active grading ladder. If the previously-selected grade
  /// isn't a member of the new ladder, the selection resets to unset
  /// (rather than silently keeping a token from the wrong system).
  void _onGradeSystemChanged(GradeSystem system) {
    if (_gradeSystem == system) return;
    setState(() {
      _gradeSystem = system;
      final grade = _grade;
      if (grade != null && !gradeOptions(system).contains(grade)) {
        _grade = null;
      }
    });
  }

  void _save() {
    if (_betaUrlInvalid) {
      // Surface the inline error (in case Save is tapped before the field
      // has ever fired a change event, e.g. a pasted value via autofill)
      // and refuse to save/pop until it's fixed or cleared.
      setState(() {});
      return;
    }
    ref
        .read(drawControllerProvider(widget.wallId).notifier)
        .setRouteMetadata(
          widget.routeId,
          name: _nameController.text.trim().isEmpty
              ? null
              : _nameController.text.trim(),
          gradeSystem: _grade == null ? null : _gradeSystem,
          gradeRaw: _grade,
          style: _style,
          description: _descriptionController.text.trim().isEmpty
              ? null
              : _descriptionController.text.trim(),
          betaVideoUrl: _validatedBetaUrl(),
          styleTags: _styleTags.toList(),
          stars: _stars,
        );
    _pop();
  }

  void _cancel() {
    _pop();
  }

  /// Pops this sheet off its enclosing [Navigator] if it's actually part of
  /// one that can pop (the real usage — pushed by `showModalBottomSheet`).
  /// Uses `maybePop` rather than a bare `pop()` so this widget stays
  /// pumpable as the sole route in a test `MaterialApp` (see class doc):
  /// a bare `pop()` there would try to pop the app's only route, which
  /// Flutter disallows.
  ///
  /// #20a keyboard-dismiss fix: unfocuses whatever field (name/description)
  /// currently holds focus BEFORE popping, so tapping Save or Cancel while
  /// mid-edit never leaves the on-screen keyboard stranded after the sheet
  /// closes underneath it. Both [_save] and [_cancel] route through here,
  /// so this single call site covers both.
  void _pop() {
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    final options = gradeOptions(_gradeSystem);
    final gradeValue = (_grade != null && options.contains(_grade))
        ? _grade
        : null;
    final band = gradeValue == null
        ? null
        : bandForSortKey(gradeSortKey(_gradeSystem, gradeValue));

    return ClipRRect(
      borderRadius: const BorderRadius.only(
        topLeft: Radius.circular(MasiRadii.large),
        topRight: Radius.circular(MasiRadii.large),
      ),
      child: Container(
        color: colors.surface,
        padding: EdgeInsets.only(
          left: MasiSpacing.lg,
          right: MasiSpacing.lg,
          top: MasiSpacing.sm,
          bottom: MediaQuery.of(context).viewInsets.bottom + MasiSpacing.lg,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: MasiSpacing.md),
                  decoration: BoxDecoration(
                    color: colors.separator,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Text(
                'Route metadata',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: MasiSpacing.lg),
              _FieldLabel('Name', colors),
              const SizedBox(height: MasiSpacing.xs),
              _MasiTextField(
                fieldKey: const Key('topo-meta-name'),
                controller: _nameController,
                hintText: 'e.g. Le Toit',
                colors: colors,
              ),
              const SizedBox(height: MasiSpacing.lg),
              _FieldLabel('Grade system', colors),
              const SizedBox(height: MasiSpacing.sm),
              CupertinoSlidingSegmentedControl<GradeSystem>(
                groupValue: _gradeSystem,
                backgroundColor: colors.surface2,
                thumbColor: colors.accent,
                children: {
                  GradeSystem.french: _SegmentLabel(
                    key: const Key('topo-meta-gradesystem-french'),
                    label: 'French',
                    selected: _gradeSystem == GradeSystem.french,
                    colors: colors,
                  ),
                  GradeSystem.uiaa: _SegmentLabel(
                    key: const Key('topo-meta-gradesystem-uiaa'),
                    label: 'UIAA',
                    selected: _gradeSystem == GradeSystem.uiaa,
                    colors: colors,
                  ),
                },
                onValueChanged: (system) {
                  if (system != null) _onGradeSystemChanged(system);
                },
              ),
              const SizedBox(height: MasiSpacing.lg),
              _FieldLabel('Grade', colors),
              const SizedBox(height: MasiSpacing.sm),
              Row(
                children: [
                  Expanded(
                    child: _GradeDropdown(
                      colors: colors,
                      value: gradeValue,
                      options: options,
                      onChanged: (value) => setState(() => _grade = value),
                    ),
                  ),
                  if (band != null) ...[
                    const SizedBox(width: MasiSpacing.sm),
                    _GradeBandBadge(band: band, colors: colors),
                  ],
                ],
              ),
              const SizedBox(height: MasiSpacing.lg),
              _FieldLabel('Style', colors),
              const SizedBox(height: MasiSpacing.sm),
              Row(
                children: [
                  for (final (value, label) in _styleOptions) ...[
                    Expanded(
                      child: _StyleChip(
                        key: Key('topo-meta-style-$value'),
                        label: label,
                        // The one place the chip is deliberately stretched:
                        // three equal `Expanded` segments across the row.
                        expands: true,
                        selected: _style == value,
                        // Re-tapping the already-selected style deselects it
                        // (toggles back to unset), matching how the
                        // multi-select style-tag chips below already behave
                        // -- otherwise the identical _StyleChip look reads
                        // as inconsistent between the two groups.
                        onPressed: () => setState(
                          () => _style = _style == value ? null : value,
                        ),
                      ),
                    ),
                    if (value != _styleOptions.last.$1)
                      const SizedBox(width: MasiSpacing.sm),
                  ],
                ],
              ),
              const SizedBox(height: MasiSpacing.lg),
              _FieldLabel('Description', colors),
              const SizedBox(height: MasiSpacing.xs),
              _MasiTextField(
                fieldKey: const Key('topo-meta-description'),
                controller: _descriptionController,
                hintText: 'Beta, crux notes, approach…',
                colors: colors,
                minLines: 2,
                maxLines: 4,
              ),
              const SizedBox(height: MasiSpacing.lg),
              _FieldLabel('Beta video URL', colors),
              const SizedBox(height: MasiSpacing.xs),
              _MasiTextField(
                fieldKey: const Key('topo-meta-beta-url'),
                controller: _betaUrlController,
                hintText: 'https://…',
                colors: colors,
                errorText: _betaUrlInvalid
                    ? 'Enter a valid https:// link'
                    : null,
              ),
              const SizedBox(height: MasiSpacing.lg),
              _FieldLabel('Style tags', colors),
              const SizedBox(height: MasiSpacing.sm),
              Wrap(
                spacing: MasiSpacing.sm,
                runSpacing: MasiSpacing.sm,
                children: [
                  for (final routeStyle in kCuratedRouteStyles)
                    _StyleChip(
                      key: Key('topo-meta-styletag-${routeStyle.key}'),
                      label: routeStyle.label,
                      selected: _styleTags.contains(routeStyle.key),
                      onPressed: () => _toggleStyleTag(routeStyle.key),
                    ),
                  for (final custom
                      in _styleTags.where(
                        (t) => curatedStyleForKey(t) == null,
                      ))
                    _StyleChip(
                      key: Key('topo-meta-styletag-$custom'),
                      label: custom,
                      selected: true,
                      onPressed: () => _toggleStyleTag(custom),
                    ),
                ],
              ),
              const SizedBox(height: MasiSpacing.sm),
              Row(
                children: [
                  Expanded(
                    child: _MasiTextField(
                      fieldKey: const Key('topo-meta-styletag-add-field'),
                      controller: _customTagController,
                      hintText: 'Add a custom tag',
                      colors: colors,
                    ),
                  ),
                  const SizedBox(width: MasiSpacing.sm),
                  SizedBox(
                    height: 44,
                    child: ElevatedButton(
                      key: const Key('topo-meta-styletag-add-button'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: colors.surface2,
                        foregroundColor: colors.accent,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(MasiRadii.control),
                        ),
                      ),
                      onPressed: _addCustomTag,
                      child: MasiIcon('add', size: 18, color: colors.accent),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: MasiSpacing.lg),
              _FieldLabel('Rating', colors),
              const SizedBox(height: MasiSpacing.sm),
              Row(
                children: [
                  for (var value = 1; value <= 3; value++) ...[
                    Semantics(
                      label: 'Rate $value stars',
                      button: true,
                      child: SizedBox(
                        width: 44,
                        height: 44,
                        child: Material(
                          color: Colors.transparent,
                          shape: const CircleBorder(),
                          child: InkWell(
                            key: Key('topo-meta-stars-$value'),
                            customBorder: const CircleBorder(),
                            onTap: () => _onStarTapped(value),
                            child: Center(
                              child: MasiIcon(
                                _stars != null && value <= _stars!
                                    ? 'star_fill'
                                    : 'star',
                                size: 28,
                                color: colors.accent,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (value != 3) const SizedBox(width: MasiSpacing.xs),
                  ],
                ],
              ),
              const SizedBox(height: MasiSpacing.xl),
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 50,
                      child: TextButton(
                        key: const Key('topo-meta-cancel'),
                        style: TextButton.styleFrom(
                          foregroundColor: colors.accent,
                          textStyle: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        onPressed: _cancel,
                        child: const Text('Cancel'),
                      ),
                    ),
                  ),
                  const SizedBox(width: MasiSpacing.sm),
                  Expanded(
                    child: SizedBox(
                      height: 50,
                      child: ElevatedButton(
                        key: const Key('topo-meta-save'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: colors.accent,
                          foregroundColor: colors.onAccent,
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(13),
                          ),
                          textStyle: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        onPressed: _save,
                        child: const Text('Save'),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A Subhead-styled field label placed above an input, per DESIGN.md's
/// type scale (15/w400, `ink2`).
class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.label, this.colors);

  final String label;
  final MasiColors colors;

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w400,
        color: colors.ink2,
      ),
    );
  }
}

/// A [TextField] filled with `surface2` and rounded to [MasiRadii.control],
/// matching the MASI form token set.
class _MasiTextField extends StatelessWidget {
  const _MasiTextField({
    required this.fieldKey,
    required this.controller,
    required this.hintText,
    required this.colors,
    this.minLines,
    this.maxLines = 1,
    this.errorText,
  });

  final Key fieldKey;
  final TextEditingController controller;
  final String hintText;
  final MasiColors colors;
  final int? minLines;
  final int maxLines;

  /// When non-null, shows an inline validation error below the field and
  /// switches its border to the `gradeHard` (red) token -- see
  /// `RouteMetadataSheet._betaUrlInvalid`.
  final String? errorText;

  @override
  Widget build(BuildContext context) {
    final errorColor = colors.gradeHard;
    return TextField(
      key: fieldKey,
      controller: controller,
      minLines: minLines,
      maxLines: maxLines,
      style: TextStyle(fontSize: 17, fontWeight: FontWeight.w400, color: colors.ink),
      decoration: InputDecoration(
        hintText: hintText,
        hintStyle: TextStyle(fontSize: 17, color: colors.ink3),
        errorText: errorText,
        errorStyle: TextStyle(fontSize: 13, color: errorColor),
        filled: true,
        fillColor: colors.surface2,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: MasiSpacing.md,
          vertical: MasiSpacing.md,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(MasiRadii.control),
          borderSide: BorderSide(color: colors.separator),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(MasiRadii.control),
          borderSide: BorderSide(color: colors.separator),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(MasiRadii.control),
          borderSide: BorderSide(color: colors.accent, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(MasiRadii.control),
          borderSide: BorderSide(color: errorColor, width: 1.5),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(MasiRadii.control),
          borderSide: BorderSide(color: errorColor, width: 1.5),
        ),
      ),
    );
  }
}

/// A label used inside [CupertinoSlidingSegmentedControl]'s `children` map
/// for the grade-system (French/UIAA) chooser. Carries the caller-supplied
/// [Key] so tests/callers can still target each segment directly (see
/// `RouteMetadataSheet`'s class doc on key stability).
class _SegmentLabel extends StatelessWidget {
  const _SegmentLabel({
    super.key,
    required this.label,
    required this.selected,
    required this.colors,
  });

  final String label;
  final bool selected;
  final MasiColors colors;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        vertical: MasiSpacing.xs,
        horizontal: MasiSpacing.sm,
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: selected ? colors.onAccent : colors.ink2,
        ),
      ),
    );
  }
}

/// The grade-value picker: a [DropdownButton] (validated against
/// [GradeSystem]'s ladder via [gradeOptions]/[isValidGrade]) dressed in a
/// MASI-token field box. Kept as a dropdown (rather than switched to a
/// Cupertino picker) so the existing tap-key-then-tap-option-text test flow
/// (see `RouteMetadataSheet`'s widget tests) keeps working unchanged.
class _GradeDropdown extends StatelessWidget {
  const _GradeDropdown({
    required this.colors,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final MasiColors colors;
  final String? value;
  final List<String> options;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: MasiSpacing.md),
      decoration: BoxDecoration(
        color: colors.surface2,
        borderRadius: BorderRadius.circular(MasiRadii.control),
        border: Border.all(color: colors.separator),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          key: const Key('topo-meta-grade'),
          isExpanded: true,
          value: value,
          hint: Text('Grade', style: TextStyle(fontSize: 17, color: colors.ink3)),
          dropdownColor: colors.surface,
          icon: MasiIcon('chevron_down', size: 16, color: colors.ink2),
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w400, color: colors.ink),
          items: [
            for (final option in options)
              DropdownMenuItem(value: option, child: Text(option)),
          ],
          onChanged: onChanged,
        ),
      ),
    );
  }
}

/// A colored pill showing the currently-selected grade's [GradeBand] — the
/// "grade-band feedback" called for by DESIGN.md, wired to
/// [gradeBandColor]/[gradeBandLabel] above.
class _GradeBandBadge extends StatelessWidget {
  const _GradeBandBadge({required this.band, required this.colors});

  final GradeBand band;
  final MasiColors colors;

  @override
  Widget build(BuildContext context) {
    final color = gradeBandColor(colors, band);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: MasiSpacing.sm,
        vertical: MasiSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: MasiSpacing.xs),
          Text(
            gradeBandLabel(band),
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.4,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

/// A selectable chip used for the style (Sport/Trad/Boulder) picker:
/// `accent`-tinted wash when selected, `surface2` otherwise, per DESIGN.md's
/// "Tinted" secondary button token.
class _StyleChip extends StatelessWidget {
  const _StyleChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onPressed,
    this.expands = false,
  });

  final String label;
  final bool selected;
  final VoidCallback onPressed;

  /// Whether this chip should FILL the width it is given (its label centred),
  /// or hug its own label.
  ///
  /// This distinction is the fix for a real bug, not a style preference. The
  /// chip's body used to be an unconditional [Center], which is an [Align]
  /// with a null `widthFactor` — i.e. it expands to the maximum width its
  /// constraints allow. That is exactly right in the Sport/Trad/Boulder
  /// [Row], where each chip sits in an [Expanded] and shares the width three
  /// ways. But a [Wrap] hands its children LOOSE constraints whose `maxWidth`
  /// is the whole row, so the same [Center] made every style tag a
  /// full-width bar and the 18-tag list rendered as 18 stacked rows instead
  /// of a compact wrapped cloud. Default `false`, so a chip hugs its label
  /// unless a call site explicitly asks to be stretched.
  final bool expands;

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);
    final label = Text(
      this.label,
      style: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w500,
        color: selected ? colors.accent : colors.ink2,
      ),
    );
    return Material(
      color: selected ? colors.accent.withValues(alpha: 0.16) : colors.surface2,
      borderRadius: BorderRadius.circular(MasiRadii.control),
      child: InkWell(
        borderRadius: BorderRadius.circular(MasiRadii.control),
        onTap: onPressed,
        child: Padding(
          // A hugging chip needs horizontal padding of its own (the stretched
          // one gets its breathing room from the width it is handed); the
          // vertical padding is tightened to `sm` to match `FilterChoiceChip`,
          // the same chip look used by every filter sheet.
          padding: expands
              ? const EdgeInsets.symmetric(vertical: MasiSpacing.md)
              : const EdgeInsets.symmetric(
                  horizontal: MasiSpacing.md,
                  vertical: MasiSpacing.sm,
                ),
          child: expands ? Center(child: label) : label,
        ),
      ),
    );
  }
}
