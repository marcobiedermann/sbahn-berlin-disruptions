# Coding standards

## Stack

Bash, curl and jq are the only code. Each Operator has one adapter in `scripts/lib/`; shared helpers live in `scripts/lib/common.sh`. Adapter interface: arguments in, events JSON array on stdout, `die` on any failure.

## Checks

`.github/workflows/test.yml` runs both; run both before pushing:

```
shellcheck scripts/build-calendar.sh scripts/lib/*.sh tests/run.sh tests/regen-golden.sh
tests/run.sh
```

`tests/run.sh` needs `python3` (local BVG server) and diffs script output against `tests/golden/*.ics`.

## Adding a test case

1. Put the fixture in `tests/fixtures/` (reuse an existing one when it fits).
2. Add a `test_golden` (or `test_fails`) call in `tests/run.sh`.
3. Generate the golden with `tests/regen-golden.sh <name> <script args>`, then review the diff by hand before committing.
