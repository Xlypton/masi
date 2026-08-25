/**
 * The grade ladders, mirrored from `lib/core/grades/grade_system.dart`.
 *
 * ## This file is a DUPLICATE, and that is dangerous
 *
 * `gradeSortKey` is what every difficulty sort, filter and grade band in the
 * app reads. A wrong value is invisible on screen — the grade still displays
 * correctly — so a silent divergence between this file and the Dart original
 * would corrupt sorting everywhere with nothing to reveal it.
 *
 * It is duplicated anyway because `update_route` has to write a sort key, and
 * writing `null` would quietly demote a graded route to unsorted.
 *
 * **The divergence is guarded by a real test**, not by this comment:
 * `test/mcp/grade_ladder_parity_test.dart` reads THIS file, extracts both
 * arrays and all four anchors, and asserts they match `gradeOptions()` and
 * `gradeSortKey()` exactly. Change the Dart ladder without changing this one
 * and the Dart suite goes red.
 *
 * Keep the array literals on their own lines and in this shape — the parity
 * test parses them.
 */

export const FRENCH_LADDER: string[] = [
  "3",
  "4a", "4b", "4c",
  "5a", "5b", "5c",
  "6a", "6a+", "6b", "6b+", "6c", "6c+",
  "7a", "7a+", "7b", "7b+", "7c", "7c+",
  "8a", "8a+", "8b", "8b+", "8c", "8c+",
  "9a", "9a+", "9b", "9b+", "9c",
];

export const UIAA_LADDER: string[] = [
  "III",
  "IV-", "IV", "IV+",
  "V-", "V", "V+",
  "VI-", "VI", "VI+",
  "VII-", "VII", "VII+",
  "VIII-", "VIII", "VIII+",
  "IX-", "IX", "IX+",
  "X-", "X", "X+",
  "XI-", "XI", "XI+",
];

/** Anchors mapping the UIAA ladder onto the French/shared axis. */
export const ANCHOR_FRENCH_LOW = 7; // '6a'
export const ANCHOR_UIAA_LOW = 9; // 'VI+'
export const ANCHOR_FRENCH_HIGH = 13; // '7a'
export const ANCHOR_UIAA_HIGH = 13; // 'VIII-'

const UIAA_SLOPE =
  (ANCHOR_FRENCH_HIGH - ANCHOR_FRENCH_LOW) /
  (ANCHOR_UIAA_HIGH - ANCHOR_UIAA_LOW);

export type GradeSystem = "french" | "uiaa";

function ladderFor(system: GradeSystem): string[] {
  return system === "french" ? FRENCH_LADDER : UIAA_LADDER;
}

/** Trims and cases [raw] the way the Dart `normalizeGrade` does. */
export function normalizeGrade(system: GradeSystem, raw: string): string {
  const trimmed = raw.trim();
  return system === "french" ? trimmed.toLowerCase() : trimmed.toUpperCase();
}

/** Whether [raw], normalized, is a member of [system]'s ladder. */
export function isValidGrade(system: GradeSystem, raw: string): boolean {
  return ladderFor(system).includes(normalizeGrade(system, raw));
}

/**
 * The shared-scale sort key, or null when [raw] is not on [system]'s ladder.
 *
 * Returns null rather than throwing (the Dart version throws) because the
 * caller here is a tool handling model output, where an unknown token is an
 * expected input rather than a programming error.
 */
export function gradeSortKey(system: GradeSystem, raw: string): number | null {
  const index = ladderFor(system).indexOf(normalizeGrade(system, raw));
  if (index === -1) return null;
  if (system === "french") return index;
  return ANCHOR_FRENCH_LOW + UIAA_SLOPE * (index - ANCHOR_UIAA_LOW);
}
