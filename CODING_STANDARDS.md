# Coding standards

## Adapters

Bash, curl and jq are the only code. One adapter per Operator in `scripts/lib/`, shared helpers in `scripts/lib/common.sh`. An adapter takes arguments in, prints an events JSON array on stdout, and calls `die` on any failure.

Endpoints and response shapes: `docs/agents/api-notes.md`. Design decisions: `docs/adr/`.

## Tests

Run the `shellcheck` and `tests/run.sh` steps of `.github/workflows/test.yml` before pushing. `tests/run.sh` needs `python3` for its local BVG server.

Adding a case:

1. Reuse a fixture in `tests/fixtures/`, else add one.
2. Add a `test_golden` (or `test_fails`) call in `tests/run.sh`.
3. Generate the golden with `tests/regen-golden.sh <name> <script args>`, then review its diff by hand before committing.
