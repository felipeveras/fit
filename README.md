# App Fit

## Flutter migration (#19)

The migration foundation lives in [`app_flutter/`](app_flutter/README.md):
Flutter dashboard → versioned Kotlin bridge → existing Health Connect reader.
It includes today's metrics, daily snapshots for 7/30/90 days, permission handling,
manual Telegram sending in Dart, local preferences and one SQLite database for
future app-owned records. No AI configuration or backend is needed.

The native app remains the functional reference until real-device parity is
validated. Flutter installs alongside it with a separate application ID; daily
autosend remains in Kotlin during this phase. See the [inventory, bridge contract,
storage strategy and cutover checklist](docs/flutter-migration.md).

```powershell
cd app_flutter
flutter pub get
flutter analyze
flutter test
flutter build apk --debug
flutter run
```

Personal Android app that reads health metrics from Health Connect and sends a daily summary directly to a private Telegram chat.

Current Kotlin reference:

```
Garmin → Health Sync → Health Connect → App Fit (Android/Kotlin) → Telegram Bot API → private chat/topic
```

## Android app (Kotlin reference)

The Android scaffold in `app/` uses Kotlin, Jetpack Compose, and Health Connect client 1.1.0. Open the repository in Android Studio with Android SDK 36 installed. Health Connect must be available on the device; on Android 13 and earlier, install or update its provider.

The app requests read access to steps, sleep sessions, resting heart rate, active calories, total calories, distance, and weight. History and background permissions are optional and requested separately when supported. The app rechecks provider availability and grants on resume, and both Health Connect privacy entry points open the dedicated policy.

`HealthConnectRepository` maps each metric and local date to explicit availability states and canonical units. `AndroidHealthConnectDataSource` handles aggregate reads and paginated records. Cumulative metrics use Health Connect aggregation; sleep sessions, resting heart rate, and weight use a selected origin. A metric with several producers is reported as `source_ambiguous` instead of guessing.

Sleep reads have an open start, consume every page, and assign full sessions to the date on which they end. Health Connect client 1.1.0 does not expose the first grant timestamp. The app persists bounds between installation and the first observed data permission outside backup and device transfer. An uncertain history boundary returns an incomplete `read_error` rather than an empty replacement.

`HealthReadViewModel` reads the seven metrics for the last seven local days and lists the snapshots on the main screen. There is no account, no login screen, and no remote database.

## Telegram

A manual `Enviar para Telegram` action reads today's metrics through the same Health Connect layer and sends a compact summary straight to the Telegram Bot API (`sendMessage`), with no backend or proxy in between. Only metrics that are actually available are included; missing or failed reads are never turned into zero.

Set `telegramBotToken` and `telegramChatId` (and optionally `telegramThreadId` for a forum topic) in your user Gradle properties (`~/.gradle/gradle.properties`) or the equivalent `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`, and `TELEGRAM_THREAD_ID` environment variables. The bot token is compiled into the personal build by design.

## Legacy

`supabase/` (config, migrations, and README) and the documents in `docs/` are retained as historical artifacts from the earlier HOM-25/HOM-26/HOM-28 design. They are not part of the Android runtime and are not referenced by the app.

## Build

Run `gradlew.bat build` on Windows (or `./gradlew build`) for builds, unit tests, and lint. `local.properties` holds the local SDK path and is ignored by Git. Regression coverage for the read layer is in [HOM-27 review fixes](docs/hom-27-review-fixes.md). A real-device test with a configured bot, installed Health Connect provider, and actual producer data is still needed to verify the complete send flow.

## Run on emulator

Run `run-app.bat` from the repository root (double-click on Windows, or `powershell -File scripts\run-app.ps1` from a terminal). One run does everything: start the AVD if nothing is connected, wait for boot, run `installDebug`, grant health permissions (with the flag below), open the main screen, and check that Health Connect is present.

```powershell
run-app.bat                              # emulator -> build -> install -> open app
run-app.bat -GrantPermissions            # + grants the 9 health permissions over adb (fastest path to validate UI)
run-app.bat -SkipBuild                   # skips compilation; reuse what is already installed
run-app.bat -Avd OutraAvd                # use another AVD (default: DiarioAmarApi36, API 36)
```

Every step prints its cumulative time (`[t=Ns]`), so the slow step is always visible. Measured on this machine:

| Run | Total | Notes |
| --- | --- | --- |
| Warm (emulator already open) | ~15s | build `installDebug` ≈ 8s |
| Cold (emulator off) | ~95s | boot ≈ 11s, install right after boot ≈ 70s (device dexopt) |
| First build of the project | up to ~3min | Gradle downloads dependencies and starts its daemon |

Rules that keep it fast:

- **Leave the emulator open** between validations; the warm run is 6x faster than a cold one.
- **Never run two builds at the same time.** Gradle silently waits for the lock held by the other run, which looks like a hung terminal with no output.
- Use `-SkipBuild` while only checking UI changes you already installed.
- Without `-GrantPermissions`, the app opens Health Connect consent screens and you have to click through them.

`local.properties` (created by the script if missing) holds the local SDK path and is ignored by Git. The emulator/SDK live outside the repository; the script resolves them from `local.properties`, `ANDROID_HOME`, or `%LOCALAPPDATA%\Android\Sdk`.
