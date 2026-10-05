# App Fit

Personal Android app that reads health metrics from Health Connect and sends a daily summary directly to a private Telegram chat.

Target architecture:

```
Garmin → Health Sync → Health Connect → App Fit (Android/Kotlin) → Telegram Bot API → private chat/topic
```

## Android app

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
