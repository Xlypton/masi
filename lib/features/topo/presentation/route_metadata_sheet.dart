import 'dart:async';

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

/// How long after the LAST keystroke a text field's save-through write
/// fires.
///
/// Save-through exists so dismissing this sheet (swipe-down, scrim tap,
/// system back — none of which run [_RouteMetadataSheetState._save]) does not
/// throw away what was typed. Writing per keystroke would do that, but each
/// write is a full route upsert, so typing a name would queue a dozen of them.
/// Discrete controls (grade, style, tags, stars) are single taps and write
/// immediately; only the free text is debounced, and a pop inside the window
/// still flushes (see `topo-meta-pop-guard`), so the delay can never cost the
/// climber an edit.
///
/// Every save-through write is LOCAL-ONLY (`markDirty: false` — see
/// [DrawController.setRouteMetadata]). Save-through means the climber's typing
/// is not LOST; it must not mean it is PUBLISHED. The write used to flag the
/// row dirty, which put a half-typed route name on the server ~2.6s after a
/// pause via the sync orchestrator's debounced push — visible to every other
/// climber on the next pull of a shared topo. Only the explicit Save (and the
/// other writers on this route: draw/commit/delete) marks the row pushable.
const Duration kRouteMetadataDraftDebounce = Duration(milliseconds: 600);

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

  /// The pending debounced text write — see [kRouteMetadataDraftDebounce].
  /// Always cancelled in [dispose] (an un-cancelled `Timer` outliving the
  /// widget tree fails every widget test that types in this sheet).
  Timer? _draftTimer;

  /// Whether an edit made in this sheet has NOT reached [DrawController] yet
  /// — i.e. the debounce window is still open. Drives the pop flush, and is
  /// what keeps Save/Cancel from writing twice.
  bool _draftPending = false;

  /// Whether save-through has written at least once — i.e. whether [_cancel]
  /// has anything to undo. Nothing was written, nothing gets reverted.
  bool _draftWritten = false;

  /// The route's metadata as it stood when this sheet opened: [_cancel]'s
  /// revert target, so an explicit Cancel still means "discard my edits" even
  /// though save-through has been writing them along the way.
  ///
  /// Taken from [RouteMetadataSheet.initial] when given (the production call
  /// site always passes the route it opened for — see
  /// `TopoCanvasScreen._openMetadataSheet`), else read straight off
  /// [DrawState.routes], so a caller that omitted `initial` still gets a
  /// correct revert rather than a wipe.
  TopoRoute? _openedWith;

  /// The last beta-video URL this sheet considered VALID (`null` = "no link").
  ///
  /// Seeded from the route as the sheet opened, and re-read off the field on
  /// every change that leaves it valid. It is what a save-through write
  /// persists while [_betaUrlInvalid] holds, so a mid-typing `htp://` never
  /// reaches the route AND never blocks the other fields from being kept —
  /// see [_betaUrlForWrite].
  String? _lastValidBetaUrl;

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
    // Save-through for the two plain text fields (the beta URL rides along on
    // `_handleBetaUrlChanged`, which also has to re-run validation).
    _nameController.addListener(_scheduleDraftWrite);
    _descriptionController.addListener(_scheduleDraftWrite);
    _customTagController = TextEditingController();
    _gradeSystem = initial?.gradeSystem ?? GradeSystem.french;
    _grade = initial?.gradeRaw;
    _style = initial?.style;
    _styleTags = {...?initial?.styleTags};
    _stars = initial?.stars;
    _openedWith = initial ?? _routeInState();
    _lastValidBetaUrl = _openedWith?.betaVideoUrl;
  }

  @override
  void dispose() {
    _draftTimer?.cancel();
    _betaUrlController.removeListener(_handleBetaUrlChanged);
    _nameController.removeListener(_scheduleDraftWrite);
    _descriptionController.removeListener(_scheduleDraftWrite);
    _nameController.dispose();
    _descriptionController.dispose();
    _betaUrlController.dispose();
    _customTagController.dispose();
    super.dispose();
  }

  void _handleBetaUrlChanged() {
    // Remember the field's value whenever it is in a state the sheet would
    // accept, so [_betaUrlForWrite] has a known-good fallback to carry through
    // a write made while the field is mid-typing and invalid.
    if (!_betaUrlInvalid) _lastValidBetaUrl = _validatedBetaUrl();
    setState(() {});
    _scheduleDraftWrite();
  }

  /// This sheet's route as [DrawController] currently holds it, or `null` if
  /// it isn't there (a sheet pumped standalone in a test, or a route removed
  /// underneath an open sheet).
  TopoRoute? _routeInState() {
    for (final route in ref.read(drawControllerProvider(widget.wallId)).routes) {
      if (route.id == widget.routeId) return route;
    }
    return null;
  }

  /// Queues the debounced save-through write for a free-text edit, restarting
  /// the window on every keystroke so only the settled value is written.
  void _scheduleDraftWrite() {
    _draftPending = true;
    _draftTimer?.cancel();
    _draftTimer = Timer(kRouteMetadataDraftDebounce, _writeDraft);
  }

  /// Save-through: writes the form's CURRENT state to [DrawController]
  /// LOCALLY (`markDirty: false`), without closing the sheet and without
  /// making the draft pushable — see [kRouteMetadataDraftDebounce].
  ///
  /// Called immediately for discrete controls (grade system, grade, style,
  /// style tags, stars — one tap each, no spam to debounce), and on the
  /// debounce for the text fields.
  ///
  /// Never refuses. It used to bail out whole while [_betaUrlInvalid] held,
  /// which silently threw the OTHER fields away on the way out: the pop flush
  /// (`topo-meta-pop-guard`) calls this same method, so typing a bad URL and
  /// then a route name and swiping the sheet away lost the name with no
  /// warning — the "written as soon as the URL is fixed" promise only ever
  /// held if the climber came back and fixed it, and a dismissal never does.
  /// An invalid URL is still never persisted; [_betaUrlForWrite] substitutes
  /// the last valid one instead of failing the whole write.
  void _writeDraft() {
    _draftTimer?.cancel();
    _draftTimer = null;
    if (!mounted) return;
    _draftPending = false;
    _draftWritten = true;
    _writeMetadata(markDirty: false);
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

  /// The beta-video URL a write should persist: the field's own value when it
  /// is valid (the [_save] case always, since Save refuses otherwise), and
  /// otherwise [_lastValidBetaUrl] — the link the route already had.
  ///
  /// This is the whole of the "an invalid URL is never persisted" rule under
  /// save-through: the URL field alone falls back, every other field on the
  /// form is written as typed.
  String? _betaUrlForWrite() =>
      _betaUrlInvalid ? _lastValidBetaUrl : _validatedBetaUrl();

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
    _writeDraft();
  }

  void _addCustomTag() {
    final raw = _customTagController.text.trim();
    if (raw.isEmpty) return;
    setState(() {
      _styleTags.add(raw.toLowerCase());
      _customTagController.clear();
    });
    _writeDraft();
  }

  /// Tapping the currently-set star clears the rating back to unrated
  /// (`null`); tapping any other star sets it to that value.
  void _onStarTapped(int value) {
    setState(() => _stars = _stars == value ? null : value);
    _writeDraft();
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
    _writeDraft();
  }

  /// Pushes the form's current state onto the route through
  /// [DrawController.setRouteMetadata], which is an AUTHORITATIVE full
  /// replacement (see its doc) — which is exactly why save-through is safe to
  /// repeat: every call sends every field, so writing the same form twice is
  /// idempotent and can never leave a half-built row behind.
  ///
  /// [markDirty] decides whether the row becomes PUSHABLE. `false` for the
  /// save-through/revert paths (a draft is the climber's alone until they
  /// commit it), `true` — the default, and what [_save] passes — for an
  /// explicit Save.
  void _writeMetadata({bool markDirty = true}) {
    ref
        .read(drawControllerProvider(widget.wallId).notifier)
        .setRouteMetadata(
          widget.routeId,
          markDirty: markDirty,
          name: _nameController.text.trim().isEmpty
              ? null
              : _nameController.text.trim(),
          gradeSystem: _grade == null ? null : _gradeSystem,
          gradeRaw: _grade,
          style: _style,
          description: _descriptionController.text.trim().isEmpty
              ? null
              : _descriptionController.text.trim(),
          betaVideoUrl: _betaUrlForWrite(),
          styleTags: _styleTags.toList(),
          stars: _stars,
        );
  }

  void _save() {
    if (_betaUrlInvalid) {
      // Surface the inline error (in case Save is tapped before the field
      // has ever fired a change event, e.g. a pasted value via autofill)
      // and refuse to save/pop until it's fixed or cleared.
      setState(() {});
      return;
    }
    _draftTimer?.cancel();
    _draftTimer = null;
    // Nothing left outstanding, so the pop guard below stays quiet rather
    // than writing the same form a second time.
    _draftPending = false;
    // The one write that MARKS THE ROW DIRTY, i.e. the one that makes the
    // metadata pushable. Save is the climber saying "this is finished"; every
    // save-through write before it was a draft (see [_writeDraft]).
    _writeMetadata(markDirty: true);
    _pop();
  }

  /// Cancel still means DISCARD, despite save-through.
  ///
  /// Save-through protects the climber from losing work to an ACCIDENTAL
  /// dismissal (swipe-down, scrim tap, back); Cancel is the opposite — an
  /// explicit "throw my edits away" — and it has to keep meaning that. So
  /// anything save-through already wrote is put back to [_openedWith], the
  /// route exactly as this sheet found it. [DrawController.setRouteMetadata]
  /// being a full replacement makes that a single authoritative write rather
  /// than a field-by-field undo.
  ///
  /// If save-through never fired, nothing is written at all — a Cancel with
  /// no edits behind it stays a pure no-op, as it always was.
  ///
  /// The revert is `markDirty: false` for the same reason save-through is: it
  /// restores values the server already has, so flagging the row would push a
  /// no-change row — and worse, would overwrite (last-writer-wins, see
  /// `shouldPushLww`) a genuine remote edit made while this sheet sat open.
  void _cancel() {
    _draftTimer?.cancel();
    _draftTimer = null;
    _draftPending = false;
    if (_draftWritten) {
      _draftWritten = false;
      final opened = _openedWith;
      ref
          .read(drawControllerProvider(widget.wallId).notifier)
          .setRouteMetadata(
            widget.routeId,
            name: opened?.name,
            gradeSystem: opened?.gradeRaw == null ? null : opened?.gradeSystem,
            gradeRaw: opened?.gradeRaw,
            style: opened?.style,
            description: opened?.description,
            betaVideoUrl: opened?.betaVideoUrl,
            styleTags: opened?.styleTags.toList() ?? const [],
            stars: opened?.stars,
            markDirty: false,
          );
    }
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

    // `final sheet = …` rather than a direct `return`, purely so the whole
    // form below keeps its original indentation under the `PopScope` wrapper
    // at the end of this method (documented there) — no line of it changed.
    final sheet = ClipRRect(
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
                      onChanged: (value) {
                        setState(() => _grade = value);
                        _writeDraft();
                      },
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
                        onPressed: () {
                          setState(
                            () => _style = _style == value ? null : value,
                          );
                          _writeDraft();
                        },
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

    // Pop flush. The debounce window (see [kRouteMetadataDraftDebounce]) is
    // the one gap where a dismissal could still lose a keystroke: type a name
    // and swipe the sheet away inside 600ms and the timer never fires. This
    // catches every Flutter-level dismissal — swipe-down and scrim tap both
    // pop the sheet's route through the Navigator — and it runs while this
    // widget is still mounted, so the write goes out with a live `ref` rather
    // than needing a flush from `dispose`.
    //
    // `canPop` stays `true`: this guard never blocks a dismissal, it only
    // writes on the way out. And `_draftPending` is already false after both
    // Save (it just wrote the form) and Cancel (it deliberately discarded),
    // so neither of those paths can write twice through here.
    //
    // The write it makes is [_writeDraft]'s — LOCAL, not dirty-flagged. A
    // dismissal is not a submission: it keeps the draft for when the climber
    // reopens the sheet, it does not publish it.
    return PopScope(
      key: const Key('topo-meta-pop-guard'),
      canPop: true,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop && _draftPending) _writeDraft();
      },
      child: sheet,
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
