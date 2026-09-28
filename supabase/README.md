# App Fit V1 on Supabase

The linked Supabase Cloud project is `shape` (`bvyohalmpwfijfhoxnxc`). Android signs in with Supabase Auth, reads Health Connect on the device, and writes directly to two tables in the exposed `api` schema through the Data API. There is no sync RPC or Hermes integration in V1.

## Active data model

| Table | Purpose | Upsert key |
| --- | --- | --- |
| `api.daily_metrics` | One daily value or `no_data` marker per metric | `(user_id, local_date, metric)` |
| `api.activities` | Exercise activities read from Health Connect | `(user_id, origin_package, hc_record_id)` |

`user_id` defaults to `auth.uid()`. Android can omit it when inserting, but every row is still checked by RLS. Both tables have RLS enabled and forced. Policies allow `authenticated` to access only rows with `user_id = auth.uid()`. `authenticated` can select, insert, and update both tables, and delete activities. `anon` has no table access. Android uses the publishable key and the user's access token; administrative keys do not belong in the app.

Daily metrics use `availability = 'available'` with a nonnegative finite value, or `availability = 'no_data'` with a null value. The supported metric names and units are constrained in the migration. Activities require `origin_package`, `hc_record_id`, `exercise_type`, `start_at`, `end_at`, and `local_date`. The unique keys above make repeated uploads update the same row.

## Migration history

The older health, coach, and integration migrations remain in `supabase/migrations` because they were already applied. `20260928122524_simplify_personal_health_data.sql` replaced those schemas with a smaller model. `20260928144251_align_app_fit_v1_two_tables.sql` removed the Hermes and insight objects, old executor roles, and the extra required activity field. The active V1 contract is the two tables above.

Do not edit or delete an applied migration: its version is recorded in the remote ledger. Make future schema changes in a new migration. Local Auth test sessions and scripts live in ignored `supabase/.temp/`; never commit a session file.

## Deployment

Review pending SQL, then run `supabase db push --linked --skip-vault --dry-run` and `supabase db push --linked --skip-vault`. Keep the project reference and migration history aligned before pushing. The `api` schema must remain exposed through the Data API.

## Validation still pending

The current two-table schema, RLS, grants, and anonymous denial were checked after the cleanup migration. Repeat the authenticated insert, read, upsert, and update flow through the Android app when its Auth and sync screens are ready. Verify cross-user isolation before public distribution.
