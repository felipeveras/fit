# AGENTS.md

## What this is

Personal Android app (Kotlin, Jetpack Compose, Health Connect client 1.1.0) that reads health metrics and sends a daily summary to Telegram. Package `com.homefelipev.healthcoach`, launcher activity `.ui.MainActivity`. Gradle 8.13 + AGP 8.13.2 + JDK 17 target (JDK 21 works for running Gradle).

## Build and test

```powershell
.\gradlew.bat build        # build + unit tests + lint
.\gradlew.bat testDebugUnitTest
.\gradlew.bat installDebug
```

`local.properties` holds the local SDK path (gitignored). The script below creates it when missing. Do not commit `local.properties`.

## Run on the emulator (preferred validation flow)

```powershell
run-app.bat                            # emulator -> build -> install -> open main screen
run-app.bat -GrantPermissions          # + grants the 9 health permissions over adb
run-app.bat -SkipBuild                 # no compilation, reuse the installed APK
run-app.bat -Avd OutraAvd              # pick another AVD (default DiarioAmarApi36, API 36)
```

Implementation: `scripts/run-app.ps1`. It resolves the SDK (`local.properties` -> `ANDROID_HOME` -> `%LOCALAPPDATA%\Android\Sdk`), starts the emulator only when no device is connected, waits for `sys.boot_completed=1`, runs `installDebug`, grants permissions before opening the app (the app shows a stale state otherwise), force-stops and launches `MainActivity`, then checks that Health Connect is installed.

### Timing (measured)

| Run | Total | Breakdown |
| --- | --- | --- |
| Warm, emulator open | ~15s | `installDebug` ≈ 8s |
| Cold, emulator off | ~95s | boot ≈ 11s, install right after boot ≈ 70s (device dexopt) |
| First build ever | up to ~3min | dependency download + Gradle daemon start |

Each step prints `[t=Ns]`, so the slow step is visible in the output.

### Rules

- **Never run two Gradle builds concurrently.** Gradle blocks silently on the lock held by the other run; the terminal shows nothing and looks hung. This has already caused a false "script is stuck" report.
- Keep the emulator open between validations; a warm run is ~6x faster than a cold one.
- Use `-SkipBuild` when only checking UI of an already installed build.
- Emulator environment: WHPX acceleration, `hw.gpu.mode=host`, system image `system-images;android-36;google_apis;x86_64`.

## Health Connect notes

- The provider on API 36 images is `com.google.android.healthconnect.controller` (older docs/images use `com.google.android.apps.healthdata`). Accept either when checking availability.
- Grantable over adb: the 7 data permissions + `android.permission.health.READ_HEALTH_DATA_HISTORY` + `android.permission.health.READ_HEALTH_DATA_IN_BACKGROUND` (all in `-GrantPermissions`). The app needs a fresh start after granting, otherwise the background row shows a stale "não autorizado".
- The main screen is a single scrollable column: Health Connect status → `Dados do Health Connect` → `Telegram` → `Envio diário automático`. Seeing "Health Connect" as the title does not mean you are on a rationale screen.
- The emulator has no producer data (no Garmin/Health Sync), so metrics show unavailable/empty states. Real data needs a physical device.
