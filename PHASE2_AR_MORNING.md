# AR Phase 2 — morning device-test guide

**You asked for two placement engines (Vision + OpenCV) built + tested in sim, then parked for you to device-test and pick one.** It grew into a **4-way runtime A/B** because a second session of yours was independently building the same thing — see "Concurrent session" below. Everything is on branch **`phase2-ar-placement-engines`** in the worktree **`/Users/kerip/Projects/masi-phase2`** (NOT on `main`).

---

## 0. Device test results (2026-07-28) — READ THIS FIRST

Installed on PetiTeló and tested with live `AR_DBG` logs. Verdict per engine:

| Engine | On-device | Verdict |
|---|---|---|
| `arkit` | **works** — routes stick | the pragmatic keep; the old "it's unstable" premise didn't hold up here |
| `opencv` | **works, corners correct** (matched ARKit placement, conf 0.6–0.95) — but was slow/hot/flickery | **the one to pursue** — fixed in commit `6df4147` (see below), needs a re-test |
| `vision` | **0 matches ever** (923 no-match) | dead end — Apple's registration can't align a stored photo to a live wall. Don't use. |
| `orb` | almost no matches (`too_few_good_matches count=0`) | weak — needs the same downscale fix `opencv` got; left as-is (bonus engine) |

**The `opencv` fix (`6df4147`, installed):** the matcher was running the full 24-megapixel-reference ORB **on the UI thread** every frame (→ ~3 fps, heat, freeze) and blanking the overlay on every missed frame (→ flicker). Now: matching runs **off-main** (single-flight + every-2nd-frame), on a **~1000px downscale** (≈10× faster, more matches), and **holds the last good position** through misses (up to ~45 frames, fading) so it stays stuck instead of blinking. **Re-test `opencv` specifically** — it should be smooth, cool, and sticky now.

**Bottom line:** it's `arkit` (works today) vs `opencv` (correct placement, now made fast + stable — verify). `vision`/`orb` are out.

---

## 1. What this is

Replaces the unstable ARKit "pin-once" image-anchor tracking (routes float mid-air / drift at angle) with **continuous per-frame reference→live homography registration**, behind one `RockRegistrationEngine` protocol. You can switch engines at runtime and compare them on the same wall.

Four selectable engines (lightweight ↔ reliable spectrum):

| Engine | What it is | Sim-test result | Notes |
|---|---|---|---|
| `arkit` | the CURRENT baseline (pin-once) | — | the unstable one you're replacing; keep for reference |
| `vision` | Apple `VNHomographicImageRegistrationRequest` | **device-only** (sim returns no observation) | zero binary weight, fast; best at modest angle, degrades wide-baseline |
| `orb` | pure-Swift ORB (reused from your other session's `RockFeatureMatcher`) | matching works (141 good matches) but **RANSAC doesn't converge** | zero-dependency; needs RANSAC/tuning work to be usable |
| `opencv` | OpenCV ORB + RANSAC | **✅ recovers a ~10° rot+translation+perspective warp, <15px error** | heaviest binary (see §5); the most battle-tested matcher |

**Bottom line from sim:** `opencv` is proven to work; `vision` needs your eyes on the device; `orb` is close but its RANSAC needs more work; `arkit` is the baseline.

---

## 2. Build + install on device (IN PLACE — never uninstall)

```bash
export PATH="/opt/homebrew/bin:$PATH" && cd /Users/kerip/Projects/masi-phase2 && \
flutter build ios --release -t lib/main.dart && \
xcrun devicectl device install app --device 00008140-0011585936EB001C build/ios/iphoneos/Runner.app
```
- Run the `devicectl install` with `dangerouslyDisableSandbox: true` and the **phone unlocked** (Apple's DDI mount needs both).
- NEVER `flutter install` and NEVER uninstall — it wipes your Supabase login session. `devicectl install` updates in place and preserves it.
- The OpenCV framework is already vendored in this worktree (`ios/Frameworks/`), so the build has what it needs. (If you ever get a fresh checkout, re-fetch it — see §5.)

## 3. How to A/B

1. Open a topo → tap into **AR**.
2. Tap the **`sync` FAB** (`ar-engine-toggle`) to cycle `arkit → vision → orb → opencv`. Each tap **restarts tracking** with that engine.
3. The **active engine name shows in the top-left status pill** ("Engine: …").
4. For each engine, judge: do the routes **land on the wall and stay** (vs float mid-air)? How does it hold when you **move to an oblique angle** / different lighting? Try it on your own topo and a friend's published one.
5. The **manual-align** mode (mode-toggle FAB) is still the fallback for any engine when it can't lock.

Native diagnostics stream over `AR_DBG` (see project CLAUDE.md for `devicectl … --console`); each engine logs `AR_DBG engine <name> …` with its confidence.

## 4. Concurrent session (please read)

While I built this, a **second live Claude session of yours (`677624b4`)** was independently building the same Phase 2 on `main` (uncommitted): its own `ios/Runner/AR/RockFeatureMatcher.swift` (pure-Swift ORB) + `docs/superpowers/specs/2026-07-27-ar-placement-design.md` + interleaved edits to `ArPlatformView.swift`/`project.pbxproj`. To avoid clobbering it I:
- Isolated my work in this **worktree/branch** (from clean commit `a238659`), leaving `main`'s uncommitted work untouched.
- **Reused its `RockFeatureMatcher` as the `orb` engine** — so its approach survives and you can compare all four.
- Saved a backup of both sessions' files at `<scratchpad>/other-session-backup/`.

`main` still holds that session's uncommitted work (`git -C /Users/kerip/Projects/masi status`). Reconcile as you like — nothing of mine is on `main`.

## 5. ⚠️ Disk + OpenCV weight

- **Your Mac's data volume is ~100% full — only ~1.5GB free** (`df -h /System/Volumes/Data`). This is not from this work (my build caches are ~1–2GB); something else is using ~423GB. It started causing `ENOSPC` build failures mid-session. **Worth clearing space before heavy rebuilds.**
- The OpenCV engine uses a **vendored static xcframework at `ios/Frameworks/opencv2.xcframework` (~743MB, git-ignored, NOT committed)**. It's present in this worktree now. To reclaim space you can delete it and re-fetch later:
  ```bash
  curl -L -o /tmp/opencv2.zip https://github.com/yeatse/opencv-spm/releases/download/5.0.0/opencv2.xcframework.zip
  mkdir -p ios/Frameworks && (cd ios/Frameworks && unzip -q /tmp/opencv2.zip)
  ```
  (The remote SPM package `yeatse/opencv-spm` 5.0.0 was the intended path but its `-resolvePackageDependencies` hung in this environment, so it's vendored instead. If you keep `opencv`, a slimmed custom OpenCV build — only core/imgproc/features2d/calib3d/geometry — would cut the size a lot.)

## 6. What was verified vs not

- **Verified in sim:** `flutter analyze` 0 · `flutter test` **1589 green** · arm64 iOS-sim **build + link** (OpenCV symbols confirmed via `nm`) · independent adversarial review PASS · `RockEngineMath` geometry unit tests · **`opencv` recovers a real perspective warp** · ORB descriptor matching works on a real YUV frame.
- **NOT verified (device-only):** live camera behaviour of all engines; `vision` (sim can't run `VNHomographicImageRegistrationRequest`); whether `opencv`/`vision` hold routes on a real wall at real angles. **That's this morning's job.**

## 7. Known minor items (non-blocking)

- `orb`'s pure-Swift RANSAC doesn't converge on the synthetic test (141 matches → no homography). Needs RANSAC iteration/threshold tuning to be usable; matching + the YUV frame fix are done.
- `rescan` FAB is a no-op while a non-ARKit engine is active (those engines don't pin, so there's nothing to rescan).
- `RockRegistrationEngine.reset()` is implemented but never called (startSession always makes a fresh engine — harmless).
- Per-frame `AR_DBG` logging on `orb` no-match can be chatty on the device console — fine for a tester build, trim before wider rollout.
- Engine-path view mapping uses `ARFrame.displayTransform` for orientation; the existing ARKit path was orientation-immune (3D projectPoint). **Do a quick landscape check** if you rotate the phone.

## 8. Commits on this branch

```
aa85512 fix(ar): orb reads ARKit YUV Y-plane (was BGRA-only); device-realistic CV tests
2f3452f test(ar): sim XCTest — RockEngineMath + synthetic homography recovery
c7734c8 feat(ar): OpenCV ORB+RANSAC registration engine
345fcca feat(ar): runtime 4-way engine selector + numeric confidence
0dee49b feat(ar): pluggable RockRegistrationEngine seam + Vision & ORB engines
a238659 docs(ar): Phase 2 placement-engines spec + plan   (branch point)
```

## 9. To keep one engine / merge

- The engine is a runtime toggle. To lock a default, change `ArEngineController.build()` in `lib/features/ar/application/ar_controller.dart` (currently `arkit`).
- To bring the winner to `main`: reconcile with the other session's main-tree work first, then cherry-pick/merge the relevant commits. If you keep `opencv`, decide SPM-remote vs vendored (and consider a slimmed build).
- Spec: `docs/superpowers/specs/2026-07-27-ar-placement-engines-design.md`; plan: `docs/superpowers/plans/2026-07-28-ar-placement-engines.md`.
