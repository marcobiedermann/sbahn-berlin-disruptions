#!/usr/bin/env bash
# Writes tests/golden/<name>.ics from the script run on the test fixtures.
# Usage: tests/regen-golden.sh <name> [script args...]   e.g. tests/regen-golden.sh tram-m10 --line "Tram M10"
# Uses the same defaults as tests/run.sh (fixed --now, --days 14); later args override them.
# Review the diff by hand before committing.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
name="${1:?usage: regen-golden.sh <name> [script args...]}"
shift
out="$(mktemp)"
trap 'rm -f "$out"' EXIT

"$root/scripts/build-calendar.sh" \
  --input-sbahn-berlin "$root/tests/fixtures/api-response.json" \
  --input-bvg "$root/tests/fixtures/bvg-response.json" \
  --now 2026-10-22T12:00:00Z --days 14 --output "$out" "$@"
perl -0pe 's/\r\n //g; s/\r//g' "$out" >"$root/tests/golden/$name.ics"
