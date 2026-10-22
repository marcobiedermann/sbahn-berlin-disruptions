## Repo map

- Code: `scripts/build-calendar.sh` (orchestrator, section index at its top) plus one adapter per Operator in `scripts/lib/` (`sbahn-berlin.sh`, `bvg.sh`) and shared helpers in `scripts/lib/common.sh`. Read `docs/adr/` and `docs/agents/api-notes.md` (S-Bahn Berlin and BVG endpoints and shapes) before changing it.
- Conventions: read `CODING_STANDARDS.md` before writing or changing code or tests, and before pushing (lint and test commands, golden workflow).
- `calendar.ics` and the watchlist (`STATIONS`, `LINES`, `DAYS`) belong to `.github/workflows/update-calendar.yml`; leave them to that workflow.

## Agent skills

Issues live in GitHub Issues (`gh` CLI): `docs/agents/issue-tracker.md`. Labels: `docs/agents/triage-labels.md`. Domain language: `GLOSSARY.md` + `docs/adr/`, see `docs/agents/domain.md`.
