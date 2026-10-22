# Tests

Run `shellcheck` (args in `.github/workflows/test.yml`) and `tests/run.sh` before pushing. `tests/run.sh` needs `python3` for its local BVG server.

## Adding a case

1. Reuse a fixture in `tests/fixtures/` when one fits, else add one.
2. Add a `test_golden` (or `test_fails`) call in `tests/run.sh`.
3. Generate the golden with `tests/regen-golden.sh <name> <script args>`, then review its diff by hand before committing.
