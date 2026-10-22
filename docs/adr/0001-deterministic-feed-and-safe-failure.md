# Deterministic feed, wall-clock expansion, safe failure

The **Feed** is committed by a cron workflow, so three choices keep it stable and trustworthy.

## Deterministic output

Unchanged data yields a byte-identical file, so the workflow commits only real changes.

- `DTSTAMP` is the **Consequence**'s `updated` value, never the run time.
- `UID` is `<consequenceId>-<periodId>-<localdate>@sbahn-berlin-disruptions`, so Google updates events instead of duplicating them.
- Events that vanish from the API vanish from the **Feed**; it mirrors the current state.

## Wall-clock expansion

A **Daily window** is expanded in Berlin wall-clock seconds (`TZ=Europe/Berlin`, `localtime | mktime`, helper `wallclock` in the jq program). Adding whole days to wall-clock time never meets a DST jump, so windows keep their local time across 25 Oct.

## Safe failure

Any API error, missing `data.consequences`, malformed JSON, unknown **Line** or unresolvable **Station** exits non-zero. The output is built in a temp file and moved into place at the end, so a good **Feed** is never replaced by an empty or partial one.
