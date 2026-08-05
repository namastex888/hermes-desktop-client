# v2026.7.30 backfill-or-skip decision (2026-08-05)

## Decision: SKIP — deliberately not backfilled.

## Why v2026.7.30 was never published

Upstream tagged v2026.7.30 at 2026-07-30T23:45:37Z — **after** our daily
cron had already run that morning (06:00 UTC). That run resolved the latest
release to v2026.7.20 (already published) and took the `needed=false` no-op
path. The next scheduled run, 2026-07-31T09:12:50Z, was the first to see
v2026.7.30 — and it was the first of the six consecutive failures caused by
the `python` substring gate false positive on `python-B5eWn6H5.js`.

So v2026.7.30 was stranded by timing (tagged after the cron window) and by
the gate bug (every subsequent run failed). Nobody ever received a
v2026.7.30 build, because none was ever produced.

## Why skip rather than backfill

1. **No user is waiting on it.** v2026.7.30 was never published, so no
   install path or package manager ever referenced it. Every consumer of
   install.sh / apt resolves the *latest* release, which is now v2026.8.3 —
   strictly newer. A backfill would serve exactly zero installed users.
2. **Publishing order would be wrong.** A backfill would publish v2026.7.30
   *after* v2026.8.3. Release listings and scripts that iterate releases by
   date would see an out-of-order history, and the cron's own `resolve` step
   treats existing releases as `needed=false` — it would never re-pick
   v2026.7.30 anyway, so the backfill could only ever be a manual one-off.
3. **The `verify` job is already exercised.** The green end-to-end dispatch
   (run 31052575908) on `wish/daily-release-pipeline-repair` ran `verify`
   against the real extracted `.deb` and gated `publish` on it; every future
   release will do the same. Backfilling a superseded tag just to exercise
   `verify` once more costs a full three-platform matrix build for no user
   value.
4. **The gap is a documented incident artifact, not a product gap.**
   Release history reads v2026.7.20 → v2026.8.3; the missing tag is the
   visible trace of the six-day outage, recorded here and in
   `gate-matches.txt` / `notification-diagnosis.md`.

## What happens instead

The pipeline cadence resumes as designed: the next upstream tag after
v2026.8.3 will be picked up by the daily cron (or a dispatch) and will be
the first release built with the merged gate + `verify` topology on `main`.
