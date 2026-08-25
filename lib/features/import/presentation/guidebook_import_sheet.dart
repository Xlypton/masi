import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app/theme.dart';
import '../../../core/db/database_provider.dart';
import '../../../core/grades/grade_system.dart';
import '../../../shared/presentation/bottom_safe_inset.dart';
import '../data/guidebook_import_applier.dart';
import '../data/guidebook_import_codec.dart';
import '../domain/guidebook_import.dart';
import '../domain/guidebook_import_prompt.dart';

/// Import a photographed guidebook page onto the topo the user is editing.
///
/// Opened from the canvas's draw-mode action row, so [wallId] and [photoId] are
/// already settled — there is no target picker, and no question about which
/// photo the model's coordinates belong to.
///
/// Returns the applied result, or null if the user backed out.
Future<ImportApplyResult?> showGuidebookImportSheet(
  BuildContext context, {
  required String wallId,
  required String photoId,
}) {
  return showModalBottomSheet<ImportApplyResult>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _GuidebookImportSheet(wallId: wallId, photoId: photoId),
  );
}

enum _Step { brief, review }

class _GuidebookImportSheet extends ConsumerStatefulWidget {
  const _GuidebookImportSheet({required this.wallId, required this.photoId});

  final String wallId;
  final String photoId;

  @override
  ConsumerState<_GuidebookImportSheet> createState() =>
      _GuidebookImportSheetState();
}

class _GuidebookImportSheetState extends ConsumerState<_GuidebookImportSheet> {
  final TextEditingController _paste = TextEditingController();

  _Step _step = _Step.brief;
  GuidebookImport? _import;

  /// The ladder the routes will actually be written against.
  ///
  /// Seeded from the payload but independently editable, because the model
  /// naming the wrong system — or none — is the single most likely thing to go
  /// wrong on a page of otherwise-correct route names.
  GradeSystem? _system;

  /// Why the last paste could not be read, shown inline under the field.
  String? _rejected;

  bool _busy = false;

  @override
  void dispose() {
    _paste.dispose();
    super.dispose();
  }

  Future<void> _copyPrompt() async {
    await Clipboard.setData(const ClipboardData(text: kGuidebookImportPrompt));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        key: Key('import-prompt-copied'),
        content: Text('Prompt copied. Paste it in your chat app with both photos.'),
      ),
    );
  }

  /// Opens the chat app.
  ///
  /// Deliberately does NOT try to pre-fill the prompt via `?q=`. Neither app
  /// can be handed an attached image that way, so the user has to attach both
  /// photos by hand regardless — and a pre-filled URL carrying a 2KB prompt
  /// buys nothing while risking a truncated one. Copy to clipboard, then open:
  /// one paste, two attachments, no surprises.
  Future<void> _openChatApp(String url) async {
    final launched = await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
    if (!launched && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Couldn't open that app.")),
      );
    }
  }

  void _read() {
    final result = decodeGuidebookImportJson(_paste.text);
    switch (result) {
      case ImportRejected(:final message):
        setState(() => _rejected = message);
      case ImportDecoded(:final import):
        setState(() {
          _import = import;
          _system = import.gradeSystem;
          _rejected = null;
          _step = _Step.review;
        });
    }
  }

  Future<void> _apply() async {
    final import = _import;
    if (import == null || _busy) return;
    setState(() => _busy = true);

    try {
      final result = await GuidebookImportApplier(
        ref.read(routeRepositoryProvider),
      ).apply(
        import: import,
        wallId: widget.wallId,
        photoId: widget.photoId,
        system: _system,
      );
      if (!mounted) return;
      Navigator.of(context).pop(result);
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          key: Key('import-apply-failed'),
          content: Text("Couldn't add those routes. Nothing was changed."),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = MasiColors.of(context);

    return Container(
      key: const Key('guidebook-import-sheet'),
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.9,
      ),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius:
            const BorderRadius.vertical(top: Radius.circular(MasiRadii.large)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: MasiSpacing.sm),
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: colors.ink3,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                MasiSpacing.lg,
                MasiSpacing.md,
                MasiSpacing.lg,
                MasiSpacing.lg + masiBottomInset(context, ref),
              ),
              child: _step == _Step.brief ? _buildBrief() : _buildReview(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBrief() {
    final colors = MasiColors.of(context);
    final text = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Import from guidebook', style: text.titleLarge),
        const SizedBox(height: MasiSpacing.sm),
        Text(
          'Your chat app reads the route names and grades off a guidebook page, '
          'and places the lines on your own photo as best it can. You correct '
          'them here afterwards.',
          style: text.bodyMedium?.copyWith(color: colors.ink2),
        ),
        const SizedBox(height: MasiSpacing.lg),
        _numbered(1, 'Copy the prompt.'),
        _numbered(2, 'Open ChatGPT or Claude, paste it, and attach two photos: '
            'the guidebook page, and your photo of this boulder.'),
        _numbered(3, 'Copy its reply and paste it below.'),
        const SizedBox(height: MasiSpacing.lg),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            key: const Key('import-copy-prompt'),
            onPressed: _copyPrompt,
            icon: const Icon(Icons.copy_all_outlined, size: 18),
            label: const Text('Copy the prompt'),
          ),
        ),
        const SizedBox(height: MasiSpacing.sm),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                key: const Key('import-open-claude'),
                onPressed: () => _openChatApp('https://claude.ai/new'),
                child: const Text('Open Claude'),
              ),
            ),
            const SizedBox(width: MasiSpacing.sm),
            Expanded(
              child: OutlinedButton(
                key: const Key('import-open-chatgpt'),
                onPressed: () => _openChatApp('https://chatgpt.com/'),
                child: const Text('Open ChatGPT'),
              ),
            ),
          ],
        ),
        const SizedBox(height: MasiSpacing.lg),
        TextField(
          key: const Key('import-paste-field'),
          controller: _paste,
          maxLines: 5,
          minLines: 3,
          style: text.bodySmall,
          decoration: InputDecoration(
            labelText: "Paste the chat app's reply",
            hintText: '{ "v": 1, ... }',
            errorText: _rejected,
            errorMaxLines: 4,
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: MasiSpacing.md),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            key: const Key('import-read'),
            onPressed: _read,
            child: const Text('Read it'),
          ),
        ),
      ],
    );
  }

  Widget _numbered(int n, String body) {
    final colors = MasiColors.of(context);
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: MasiSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 20,
            child: Text('$n.',
                style: text.bodyMedium?.copyWith(color: colors.accent)),
          ),
          Expanded(
            child: Text(body,
                style: text.bodyMedium?.copyWith(color: colors.ink2)),
          ),
        ],
      ),
    );
  }

  Widget _buildReview() {
    final import = _import!;
    final colors = MasiColors.of(context);
    final text = Theme.of(context).textTheme;
    final problems = import.problems.toList();
    final unplaced = import.unplacedRoutes.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(import.boulder ?? 'Imported routes', style: text.titleLarge),
        const SizedBox(height: MasiSpacing.xs),
        Text(
          '${import.routes.length} routes'
          '${unplaced > 0 ? ' · $unplaced to draw' : ''}',
          style: text.bodySmall?.copyWith(color: colors.ink2),
        ),
        const SizedBox(height: MasiSpacing.lg),

        // The single control most likely to be wrong, so it sits above the
        // list rather than buried under it: one dropdown re-reads every grade
        // on the page.
        Row(
          children: [
            Text('Grades', style: text.bodyMedium),
            const SizedBox(width: MasiSpacing.md),
            Expanded(
              child: DropdownButtonFormField<GradeSystem?>(
                key: const Key('import-grade-system'),
                initialValue: _system,
                isDense: true,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: MasiSpacing.md,
                    vertical: MasiSpacing.sm,
                  ),
                ),
                items: [
                  const DropdownMenuItem(value: null, child: Text('No grades')),
                  for (final system in GradeSystem.values)
                    DropdownMenuItem(
                      value: system,
                      child: Text(switch (system) {
                        GradeSystem.french => 'French / Font',
                        GradeSystem.uiaa => 'UIAA',
                      }),
                    ),
                ],
                onChanged: (v) => setState(() => _system = v),
              ),
            ),
          ],
        ),
        const SizedBox(height: MasiSpacing.lg),

        for (final route in import.routes) _routeRow(route),

        if (problems.isNotEmpty) ...[
          const SizedBox(height: MasiSpacing.lg),
          Container(
            key: const Key('import-problems'),
            padding: const EdgeInsets.all(MasiSpacing.md),
            decoration: BoxDecoration(
              color: colors.surface2,
              borderRadius: BorderRadius.circular(MasiRadii.card),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  problems.length == 1
                      ? '1 thing to check'
                      : '${problems.length} things to check',
                  style: text.bodyMedium?.copyWith(color: colors.gradeHard),
                ),
                const SizedBox(height: MasiSpacing.xs),
                for (final w in problems)
                  Padding(
                    padding: const EdgeInsets.only(top: MasiSpacing.xs),
                    child: Text(
                      w.routeNumber == null
                          ? w.detail
                          : '#${w.routeNumber}: ${w.detail}',
                      style: text.bodySmall?.copyWith(color: colors.ink2),
                    ),
                  ),
              ],
            ),
          ),
        ],

        const SizedBox(height: MasiSpacing.lg),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                key: const Key('import-back'),
                onPressed: _busy ? null : () => setState(() => _step = _Step.brief),
                child: const Text('Back'),
              ),
            ),
            const SizedBox(width: MasiSpacing.sm),
            Expanded(
              flex: 2,
              child: FilledButton(
                key: const Key('import-apply'),
                onPressed: _busy ? null : _apply,
                child: Text(
                  _busy
                      ? 'Adding…'
                      : 'Add ${import.routes.length} route'
                          '${import.routes.length == 1 ? '' : 's'}',
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _routeRow(ImportedRoute route) {
    final colors = MasiColors.of(context);
    final text = Theme.of(context).textTheme;
    final grade = route.resolvedGradeRaw(_system);

    // An unresolved token is shown struck through rather than hidden: the user
    // needs to see that the page HAD a grade there which this ladder cannot
    // read, since that is usually the signal that the dropdown is wrong.
    final unread = grade == null && route.gradeRaw != null;

    return Padding(
      key: Key('import-route-${route.number}'),
      padding: const EdgeInsets.only(bottom: MasiSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 24,
            child: Text('${route.number}',
                style: text.bodySmall?.copyWith(color: colors.ink3)),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(route.name ?? 'Unnamed', style: text.bodyMedium),
                if (route.positionHint != null)
                  Text(
                    route.positionHint!,
                    style: text.bodySmall?.copyWith(color: colors.ink3),
                  ),
              ],
            ),
          ),
          if (!route.isPlaced)
            Padding(
              padding: const EdgeInsets.only(right: MasiSpacing.sm),
              child: Text('to draw',
                  style: text.bodySmall?.copyWith(color: colors.ink3)),
            ),
          if (route.stars != null && route.stars! > 0)
            Padding(
              padding: const EdgeInsets.only(right: MasiSpacing.sm),
              child: Text('★' * route.stars!,
                  style: text.bodySmall?.copyWith(color: colors.ink3)),
            ),
          SizedBox(
            width: 52,
            child: Text(
              grade ?? route.gradeRaw ?? '—',
              textAlign: TextAlign.end,
              style: text.bodyMedium?.copyWith(
                color: unread ? colors.gradeHard : colors.ink,
                decoration: unread ? TextDecoration.lineThrough : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
