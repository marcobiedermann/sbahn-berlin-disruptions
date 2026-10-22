#!/usr/bin/env bash
# Black-box tests for scripts/build-calendar.sh, run through its command line only.
set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
script="$root/scripts/build-calendar.sh"
fixture="$root/tests/fixtures/api-response.json"
golden="$root/tests/golden"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

failures=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1"; failures=$((failures + 1)); }

# Undo RFC 5545 line folding and drop CR so output can be compared to readable goldens.
unfold() { perl -0pe 's/\r\n //g; s/\r//g' "$1"; }

# Longest physical line in octets, excluding CRLF.
max_line_octets() { LC_ALL=C awk '{ sub(/\r$/, ""); if (length($0) > m) m = length($0) } END { print m + 0 }' "$1"; }

test_golden() {
  local name="$1" golden_name="$2"
  shift 2
  local out="$tmp/case-$((++case_no)).ics"
  if ! "$script" --input "$fixture" --output "$out" "$@" >/dev/null 2>&1; then
    fail "$name: script exited non-zero"
    return
  fi
  if diff <(unfold "$out") "$golden/$golden_name.ics" >"$tmp/case.diff"; then
    pass "$name: matches golden"
  else
    fail "$name: differs from golden"
    cat "$tmp/case.diff"
  fi
  if [ "$(max_line_octets "$out")" -le 75 ]; then
    pass "$name: lines folded to 75 octets"
  else
    fail "$name: line longer than 75 octets"
  fi
  if [ "$(grep -c $'\r$' "$out")" -eq "$(wc -l <"$out")" ]; then
    pass "$name: CRLF line endings"
  else
    fail "$name: not CRLF line endings"
  fi
}

# Runs the script expecting failure: non-zero exit, stderr contains $2, existing output untouched.
test_fails() {
  local name="$1" expected="$2"
  shift 2
  echo "previous feed" >"$tmp/keep.ics"
  local err status=0
  err="$("$script" --input "$fixture" --output "$tmp/keep.ics" "$@" 2>&1 >/dev/null)" || status=$?
  if [ "$status" -ne 0 ]; then pass "$name: exits non-zero"; else fail "$name: exits non-zero"; fi
  case "$err" in *"$expected"*) pass "$name: message mentions '$expected'" ;; *) fail "$name: message mentions '$expected' (got: $err)" ;; esac
  if [ "$(cat "$tmp/keep.ics")" = "previous feed" ]; then pass "$name: output untouched"; else fail "$name: output untouched"; fi
}

case_no=0

test_golden "line S9" line-s9 --line S9
test_golden "lines S9 + S26" lines-s9-s26 --line S9 --line S26
test_golden "station by name" station-schoeneweide --station Schöneweide
test_golden "station with S prefix" station-schoeneweide --station "S Schöneweide"
test_golden "station case-insensitive" station-schoeneweide --station SCHÖNEWEIDE
test_golden "station OR line" lines-s9-s26 --station Schöneweide --line S26
test_golden "station and line match once" line-s9 --station Westkreuz --line S9
test_golden "multiple stations" lines-s9-s26 --station Schöneweide --station Westkreuz --line S26

# Identical input yields byte-identical output.
"$script" --input "$fixture" --output "$tmp/a.ics" --line S9 >/dev/null 2>&1
"$script" --input "$fixture" --output "$tmp/b.ics" --line S9 >/dev/null 2>&1
if cmp -s "$tmp/a.ics" "$tmp/b.ics"; then pass "deterministic output"; else fail "deterministic output"; fi

test_fails "unknown line" "Known lines: S9, S26" --line S99
test_fails "unknown station" "unknown station" --station Nirgendwo
test_fails "near-miss station suggests candidates" "S Schöneweide" --station Schöneweid
test_fails "ambiguous station" "U Ostkreuz" --station Ostkreuz
test_fails "no stations or lines" "--station or --line"

if [ "$failures" -ne 0 ]; then
  echo "$failures failure(s)"
  exit 1
fi
echo "all tests passed"
