# Integrated validation — issues #19, #20 and #21

Date: 2026-10-06. Integration branch: `integrate/flutter-19-21`.

## Automated validation

At code snapshot `6085969`:

- Dart format: 40 files checked, no changes.
- Flutter analyze: no issues found.
- Flutter tests: 61 passed, including database v4 → v5, workout event retry/restart/deduplication, independent Health Connect permissions, quantitative editor and timer regressions.
- Debug APK: built and installed successfully.
- Native Android tests: 52 passed, zero failures/errors.
- Android lint: zero errors; 36 warnings (dependency updates, obsolete SDK checks, unused resource, KTX and native rationale text localization).
- GitHub push and pull-request workflows passed (runs 37547415732 and 37547416235).

The subsequent presentation fix replaces two corrupted separators in the workout prescription. Final-head validation is tracked on PR #22; the results above describe the preceding code snapshot accurately.

## API 36 emulator smoke test

Device: `emulator-5554`, AVD DiarioAmarApi36. Initial System UI/app unresponsive dialogs occurred under host memory pressure. Validation proceeded after a cold emulator start with 1536 MB, completion of the build checks and a fresh app launch. The emulator screen was kept awake for inspection.

Observed through UI interaction:

1. Dashboard and habits navigation opened; absent health metrics remained empty.
2. Created positive daily habit `Treino auditoria` with source **Treino concluído**.
3. Created routine `Auditoria integrada` with a barbell squat.
4. Started session and registered one completed set: 20 kg × 8 reps.
5. Force-stopped and reopened the app: active session, set and rest timer survived; **Retomar treino** opened the saved session.
6. Completed session: one set, 160 kg volume, 20 kg top load, 25.3 kg estimated 1RM, personal records shown.
7. Returned/reopened the app: the workout habit showed 1/1 completions, 1/1 opportunities and 100% adherence, without manual completion.

Screenshots: [dashboard](../migration/integration-home.png), [automatic workout habit](../migration/integration-workout-habit.png).

This smoke test does not establish real Garmin/Health Sync ingestion, physical notification delivery, image selection, or real Telegram delivery. Repository and native tests cover the underlying rules; physical validation remains separate.

## Closure and remaining work

The acceptance core of #20 and #21 is integrated: local persistence, user flows, workout progress, flexible habit engine, durable Workout → Habit, Health Connect automation and regression checks. Widgets and future Coach/Baseline/experiment screens are deferred features; public aggregate/link APIs exist and notes/photos are excluded from summaries.

#19 remains open. The user confirmed that the Flutter APK has not been validated on a real phone. Remaining migration gates: real Garmin/Health Sync data parity and permissions, authorized manual Telegram delivery, daily scheduling/background parity, and the final application ID/signing/preferences/launcher cutover decision. The Kotlin application remains available alongside the Flutter package.

All source worktrees and the earlier Kotlin habit stash were preserved. Ignored generated builds were moved to E: to recover disk space; no source worktree was deleted.
