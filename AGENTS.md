## Repo map

- Code: `scripts/build-calendar.sh` (bash + curl + jq, the only code; a section index sits at the top of the file). Read `docs/adr/` and `docs/agents/api-notes.md` (S-Bahn Berlin and BVG endpoints and shapes) before changing it.
- Tests: `tests/run.sh` (needs `python3` for the local BVG server) diffs script output against `tests/golden/*.ics`. Add a case with a fixture in `tests/fixtures/` and generate its golden with `tests/regen-golden.sh <name> <script args>`, then review the diff.
- Checks: `.github/workflows/test.yml` runs `shellcheck scripts/build-calendar.sh tests/run.sh tests/regen-golden.sh` and `tests/run.sh`. Run both before pushing.
- `calendar.ics` and the watchlist (`STATIONS`, `LINES`, `DAYS`) belong to `.github/workflows/update-calendar.yml`; never edit `calendar.ics` by hand.

## Agent skills

Issues live in GitHub Issues (`gh` CLI): `docs/agents/issue-tracker.md`. Labels: `docs/agents/triage-labels.md`. Domain language: `GLOSSARY.md` + `docs/adr/`, see `docs/agents/domain.md`.
