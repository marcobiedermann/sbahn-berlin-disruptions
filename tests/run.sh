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
  local name="$1"
  shift
  local out="$tmp/$name.ics"
  if ! "$script" --input "$fixture" --output "$out" "$@" >/dev/null 2>&1; then
    fail "$name: script exited non-zero"
    return
  fi
  if diff <(unfold "$out") "$golden/$name.ics" >"$tmp/$name.diff"; then
    pass "$name: matches golden"
  else
    fail "$name: differs from golden"
    cat "$tmp/$name.diff"
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

test_golden line-s9 --line S9
test_golden lines-s9-s26 --line S9 --line S26

# Identical input yields byte-identical output.
"$script" --input "$fixture" --output "$tmp/a.ics" --line S9 >/dev/null 2>&1
"$script" --input "$fixture" --output "$tmp/b.ics" --line S9 >/dev/null 2>&1
if cmp -s "$tmp/a.ics" "$tmp/b.ics"; then pass "deterministic output"; else fail "deterministic output"; fi

# Unknown line: non-zero exit, known lines listed, existing output untouched.
echo "previous feed" >"$tmp/keep.ics"
err="$("$script" --input "$fixture" --output "$tmp/keep.ics" --line S99 2>&1 >/dev/null)"
status=$?
if [ "$status" -ne 0 ]; then pass "unknown line exits non-zero"; else fail "unknown line exits non-zero"; fi
case "$err" in *S9*S26*) pass "unknown line lists known lines" ;; *) fail "unknown line lists known lines: $err" ;; esac
if [ "$(cat "$tmp/keep.ics")" = "previous feed" ]; then pass "output untouched on error"; else fail "output untouched on error"; fi

if [ "$failures" -ne 0 ]; then
  echo "$failures failure(s)"
  exit 1
fi
echo "all tests passed"
