# App Fit

The V1 plan pairs Android Health Connect reads with direct Supabase sync. HOM-27 implements the read layer; sync follows in HOM-28. Supabase Auth and row level security isolate each user's data. The database contract and deployment notes are in [supabase/README.md](supabase/README.md). The detailed documents in `docs/` record earlier HOM-25 planning; their RPC, lease, writer, and Hermes designs are not the V1 implementation.

## Android app

The Android scaffold in `app/` uses Kotlin, Jetpack Compose, and Health Connect client 1.1.0. Open the repository in Android Studio with Android SDK 36 installed. Health Connect must be available on the device; on Android 13 and earlier, install or update its provider.

The HOM-27 layer requests read access to steps, sleep sessions, resting heart rate, active calories, total calories, distance, and weight. History and background permissions are optional and requested separately when supported. The app rechecks provider availability and grants on resume, and both Health Connect privacy entry points open the dedicated policy.

`HealthConnectRepository` maps each metric and local date range to explicit availability states and canonical units. `AndroidHealthConnectDataSource` handles aggregate reads and paginated records. Cumulative metrics use Health Connect aggregation; sleep sessions, resting heart rate, and weight use a selected origin. A newly discovered origin is a local candidate. The future sync flow must establish a durable origin policy before upload under the active V1 contract.

Sleep reads have an open start, consume every page, and assign full sessions to the date on which they end. Health Connect client 1.1.0 does not expose the first grant timestamp. The app persists bounds between installation and the first observed data permission outside backup and device transfer. An uncertain history boundary returns an incomplete `read_error` rather than an empty replacement.

This branch implements Health Connect reads and consent; it does not yet invoke the Supabase sync flow. Run `gradlew.bat build` on Windows (or `./gradlew build`) for builds, unit tests, and lint. Regression coverage and the review matrix are in [HOM-27 review fixes](docs/hom-27-review-fixes.md). Real device verification is still required before claiming the seven metrics work with the installed provider and producers.
