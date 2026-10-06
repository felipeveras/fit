# App Fit — Flutter foundation

Implementation of the foundation in [GitHub #19](https://github.com/felipeveras/fit/issues/19).
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
  database `app_fit.db` for future app-owned records. No health data replication.
- `features/settings`: Telegram configuration, Health Connect settings, credits.

App ID: `com.homefelipev.healthcoach.flutter`, deliberately separate to install
alongside Kotlin. Grants and preferences are independent. No automatic import or
autosend in Flutter yet. Coach, workouts and habits belong to separate issues.
No upstream GymMane/Streak code or assets are included.

Full contract, provenance and device checklist: [migration notes](../docs/flutter-migration.md).
CI runs format, analyze, Flutter tests, APK build, native tests and lint.
