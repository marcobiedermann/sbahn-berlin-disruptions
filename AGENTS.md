## Repo map

- Code: `scripts/build-calendar.sh` (bash + curl + jq, the only code). Read `docs/adr/` and `docs/agents/api-notes.md` before changing it.
- Tests: `tests/run.sh` diffs script output against `tests/golden/*.ics`. Add a case with a fixture in `tests/fixtures/` and a golden file.
- Checks: `.githooks/pre-commit` (shellcheck + tests; enable with `git config core.hooksPath .githooks`), mirrored by `.github/workflows/test.yml`.
- `calendar.ics` and the watchlist (`STATIONS`, `LINES`, `DAYS`) belong to `.github/workflows/update-calendar.yml`; never edit `calendar.ics` by hand.

## Agent skills

### Issue tracker

Issues live in GitHub Issues (`gh` CLI). See `docs/agents/issue-tracker.md`.

### Triage labels

Default five-label vocabulary (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `GLOSSARY.md` + `docs/adr/` at the repo root. See `docs/agents/domain.md`.
