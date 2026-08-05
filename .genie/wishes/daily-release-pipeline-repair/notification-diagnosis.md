# Notification gap diagnosis — daily release pipeline repair (2026-08-05)

## Did the six failed scheduled runs notify?

YES — the mechanism fires. GitHub's documented behavior for scheduled workflows
("Notifications for workflow runs", GitHub Docs) is:

> Notifications for scheduled workflows are sent to the user who initially
> created the workflow. If a different user updates the cron syntax, in the
> schedule event in the workflow file, subsequent notifications will be sent
> to that user instead.

So a failure email for the `build-and-publish` scheduled run is generated and
sent to the account that created the workflow / last modified its cron line.

## To whom?

The recipient is `namastex888 <genie@namastex.io>` — the **Genie agent
identity**, not a human.

Evidence:
- `release.yml` was created in commit e45215b (`2026-07-25`, author
  `namastex888 <genie@namastex.io>`).
- Every subsequent commit to the file — including the keepalive commit
  dbd4989 and the hicolor commit 2020262, which is the last one — is authored
  by `namastex888 <genie@namastex.io>`.
- Repository-wide commit history: 7 commits by `genie@namastex.io`, 2 by
  `felipe@namastex.io` (the human). Neither human commit touches
  `.github/workflows/release.yml`.
- The human (`felipe@namastex.ai` / `felipe@namastex.io`) has never been the
  workflow creator or cron-syntax modifier, so no human has ever been the
  recipient of the scheduled-run failure notification.

The six failures (all `event=schedule`, all `conclusion=failure`):
```
2026-07-31T09:12:50Z  https://github.com/namastex888/hermes-desktop-client/actions/runs/30619096222
2026-08-01T08:31:11Z  https://github.com/namastex888/hermes-desktop-client/actions/runs/30691922394
2026-08-02T08:33:39Z  https://github.com/namastex888/hermes-desktop-client/actions/runs/30740012930
2026-08-03T10:01:01Z  https://github.com/namastex888/hermes-desktop-client/actions/runs/30803827237
2026-08-04T08:50:13Z  https://github.com/namastex888/hermes-desktop-client/actions/runs/30893647808
2026-08-05T08:47:22Z  https://github.com/namastex888/hermes-desktop-client/actions/runs/30990474526
```

## Was delivery to a human plausible?

NO. The notification email terminates at the agent identity's mailbox
(`genie@namastex.io`), which is not a human attention channel. Nothing in the
recipient path is a person: the workflow's creator and its only committer is
the bot. Six consecutive days of unattended failure corroborate that the
signal never reached anyone who could act.

## Finding

The defect is **routing / recipient**, not absence of notification. GitHub's
built-in scheduled-failure notification exists and fires; it is simply
addressed to the wrong entity. The failure class is: the workflow's creator
and cron owner is an automation identity, so GitHub's native failure email
never lands in a human inbox.

Per Decision 6 of the wish: an auto-filed issue would be a second channel
that no human is guaranteed to read either — the fix is to put a human in the
recipient path, not to build a parallel notifier.

## Remedy (recorded, not built)

1. Make a human the recipient of GitHub's built-in notification: have a human
   account make the next commit that touches the `schedule`/cron syntax of
   `release.yml` (per the docs, notifications then route to that user), and
   confirm that account has Actions email notifications enabled in GitHub
   settings.
2. Alternatively, subscribe the human account to the `build-and-publish`
   workflow's failure notifications via GitHub's native workflow
   notification settings.
3. No `notify` job is added to `release.yml`. The diagnosis (this file) is
   the declared decision point; if a future release fails and no human is
   still being reached after the routing fix, revisit with a `notifier-required`
   decision.

DECISION: no-notifier
