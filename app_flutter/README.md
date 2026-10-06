# App Fit — Flutter foundation, workouts and habits

Implementation of the foundation in [GitHub #19](https://github.com/felipeveras/fit/issues/19),
workouts in [#20](https://github.com/felipeveras/fit/issues/20), and habits in
[#21](https://github.com/felipeveras/fit/issues/21).
The Kotlin reference remains untouched in `../app`. No cutover until real-device
Health Connect and manual Telegram parity are verified.

## Requirements and commands

Flutter stable **3.47.6**, Dart **3.13.5**, JDK 17 or 21, Android SDK 36.
The host pins AGP 8.13.2 / Gradle 8.14.3 / Kotlin 2.2.20 and Health Connect 1.1.0.
Install the Android NDK requested by Flutter if it is not already present.
Run from this directory:

```powershell
flutter pub get
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
flutter build apk --debug
flutter run -d emulator-5554
```

APK: `build/app/outputs/flutter-apk/app-debug.apk`.
After building, native regression tests and lint on Windows:

```powershell
.\tool\lint-android.ps1
cd android
.\gradlew.bat :app:testDebugUnitTest
```

Do not run Gradle/Flutter APK builds concurrently. SDK paths in
`android/local.properties` are generated locally and must not be committed.
The lint helper escapes Windows drive letters in that generated file and
refreshes the lint report, without disabling any lint checks. On Linux use
`bash ./gradlew` from `android/` with `:app:testDebugUnitTest :app:lintDebug`.
Flutter dashboard is the initial route. Configure Telegram token, chat and
optional positive topic ID under **Configurações**; secrets are not in Git.
Preferences survive restart. HTTP sends only on the explicit manual action;
the bridge collects today's data again even when viewing a historical period.

## Architecture

- `core/health`: typed DTOs and HealthRepository; only the MethodChannel adapter
  knows Flutter platform channels.
- Android host: the existing paginated/normalized Health Connect implementation,
  with version 1 bridge, consent bounds and native permission launcher.
- `features/dashboard`: reads on entry/resume and manual refresh; absent values
  remain absent. Historical periods display daily readings, never a misleading
  sum of weight or heart rate.
- `features/telegram`: direct Dart HTTP and daily summary formatter.
- `core/persistence`: SharedPreferences for simple settings, one versioned SQLite
  database `app_fit.db` at schema version 5 for app-owned records. It preserves
  metadata and workout migrations v1–v4 before adding habits in v5. Workouts
  include the exercise library, routines, live sessions, timers and progress
  records; habits use the same database.
- `features/habits`: manual and quantitative tracking, schedules, focus,
  reminders, private notes and aggregate summaries. A durable workout consumer
  connects at bootstrap and retries pending completions without duplicating
  logs. Step and exercise imports use per-day Health Connect coverage; exercise
  imports use one selected producer origin and independent permission.
- Android habit adapters: system photo picker and persisted reminders, including
  snooze, boot recovery, eligible-day goals and checklist-safe notification actions.
- `features/settings`: Telegram configuration, Health Connect settings, optional
  exercise permission and credits.

App ID: `com.homefelipev.healthcoach.flutter`, deliberately separate to install
alongside Kotlin. Grants and preferences are independent. No automatic import or
autosend in Flutter yet. Workouts and habits are integrated; the Coach service
remains a separate issue, with aggregate habit APIs ready for its consumers.
No upstream GymMane/Streak code or assets are included.

Full contract, provenance and device checklist: [migration notes](../docs/flutter-migration.md).
CI is configured to run format, analyze, Flutter tests, APK build, native tests
and lint. Results for this integrated delivery must be recorded against its
final commit; this document does not certify a completed validation run.

Real-device Health Connect/Telegram parity and the release cutover remain
pending for #19. See the [device checklist](../docs/flutter-device-validation.md)
and [habit integration contract](../docs/habit-tracker-flutter.md).
