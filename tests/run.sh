#!/usr/bin/env bash
# Black-box tests for scripts/build-calendar.sh, run through its command line only.
set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
script="$root/scripts/build-calendar.sh"
fixture="$root/tests/fixtures/api-response.json"
bvg_fixture="$root/tests/fixtures/bvg-response.json"
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
  # A fixed clock and the maximum horizon keep fixtures valid; cases override --now/--days where they test them.
  if ! "$script" --input-sbahn-berlin "$fixture" --input-bvg "$bvg_fixture" --output "$out" --now "$default_now" --days 14 "$@" >/dev/null 2>&1; then
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
# Uses $failing_input instead of the main fixture when set.
test_fails() {
  local name="$1" expected="$2"
  shift 2
  echo "previous feed" >"$tmp/keep.ics"
  local err status=0
  err="$("$script" --input-sbahn-berlin "${failing_input:-$fixture}" --output "$tmp/keep.ics" "$@" 2>&1 >/dev/null)" || status=$?
  if [ "$status" -ne 0 ]; then pass "$name: exits non-zero"; else fail "$name: exits non-zero"; fi
  case "$err" in *"$expected"*) pass "$name: message mentions '$expected'" ;; *) fail "$name: message mentions '$expected' (got: $err)" ;; esac
  if [ "$(cat "$tmp/keep.ics")" = "previous feed" ]; then pass "$name: output untouched"; else fail "$name: output untouched"; fi
}

case_no=0
default_now="2026-10-22T12:00:00Z"

test_golden "line S9" line-s9 --line S9
test_golden "S-Bahn label is case-insensitive" line-s9 --line s9
test_golden "lines S9 + S26" lines-s9-s26 --line S9 --line S26 --now 2026-10-28T12:00:00Z
test_golden "daily windows, overnight end, DST change" line-s85-daily --line S85
# The live API now sends +02:00 offsets; the same instants must give the same feed.
offset_fixture="$root/tests/fixtures/api-response-offset.json"
test_golden "S-Bahn timestamps with +02:00 offsets" line-s9 --line S9 --input-sbahn-berlin "$offset_fixture"
test_golden "S-Bahn daily windows with +02:00 offsets" line-s85-daily --line S85 --input-sbahn-berlin "$offset_fixture"
test_golden "station by name" station-schoeneweide --station Schöneweide
test_golden "station with S prefix" station-schoeneweide --station "S Schöneweide"
test_golden "station case-insensitive" station-schoeneweide --station SCHÖNEWEIDE
test_golden "station OR line" lines-s9-s26 --station Schöneweide --line S26 --now 2026-10-28T12:00:00Z
test_golden "station and line match once" line-s9 --station Westkreuz --line S9
test_golden "multiple stations" lines-s9-s26 --station Schöneweide --station Westkreuz --line S26 --now 2026-10-28T12:00:00Z
# The API also links a station to consequences that only mention it in the alternative-route text; only titles naming the stop count.
test_golden "station named in title only" station-title-match --station Schöneweide --input-sbahn-berlin "$root/tests/fixtures/api-response-station-alternative.json" --now 2026-10-26T12:00:00Z

# BVG: lines are routed to the operator by label, items without a watched line or of another type are ignored.
test_golden "BVG bus 160" bvg-bus-160 --line "Bus 160"
test_golden "BVG bus 160 + 163 is one event for the shared item" bvg-bus-160-163 --line "Bus 160" --line "Bus 163"
test_golden "BVG label is case-insensitive" bvg-bus-160 --line "bus 160"
test_golden "S-Bahn and BVG in one feed" mixed-s9-bus-160 --line S9 --line "Bus 160"
test_golden "BVG tram line" tram-m10 --line "Tram M10"
test_golden "BVG U-Bahn line incl. replacement bus notice" ubahn-u2 --line U2
test_golden "BVG U-Bahn label is case-insensitive" ubahn-u2 --line u2
test_golden "tram 12 does not match bus 12" tram-12 --line "Tram 12"
test_golden "bus 12 does not match tram 12" bus-12 --line "Bus 12"
test_golden "tram M1 and bus M1 are different lines" tram-m1 --line "Tram M1"
test_golden "BVG open-ended item is an all-day event on its start day" bvg-open-ended --line "Bus 160" --now 2026-10-22T12:00:00Z --days 1
test_golden "BVG horizon drops items beyond it" bvg-bus-160-days-3 --line "Bus 160" --days 3

# Horizon: occurrences overlapping [now, now + days] are kept in full, the rest are dropped.
test_golden "--days 7 drops later occurrences" line-s85-days-7 --line S85 --days 7
test_golden "past occurrences dropped, running one kept in full" line-s85-from-26-oct --line S85 --now 2026-10-26T12:00:00Z --days 14

# Without --days the horizon is 14 days: the S26 outage on 10 Nov is out of range on 22 Oct.
"$script" --input-sbahn-berlin "$fixture" --output "$tmp/default.ics" --line S9 --line S26 --now "$default_now" >/dev/null 2>&1
if diff <(unfold "$tmp/default.ics") "$golden/line-s9.ics" >/dev/null; then pass "default horizon is 14 days"; else fail "default horizon is 14 days"; fi

# Identical input yields byte-identical output.
"$script" --input-sbahn-berlin "$fixture" --output "$tmp/a.ics" --line S9 >/dev/null 2>&1
"$script" --input-sbahn-berlin "$fixture" --output "$tmp/b.ics" --line S9 >/dev/null 2>&1
if cmp -s "$tmp/a.ics" "$tmp/b.ics"; then pass "deterministic output"; else fail "deterministic output"; fi

test_fails "unknown line" "Known lines: S9, S26" --line S99
test_fails "unknown station" "unknown station" --station Nirgendwo
test_fails "near-miss station suggests candidates" "S Schöneweide" --station Schöneweid
test_fails "ambiguous station" "U Ostkreuz" --station Ostkreuz
test_fails "no stations or lines" "--station or --line"

failing_input="$root/tests/fixtures/malformed.json" test_fails "malformed JSON" "not a valid API response" --line S9
failing_input="$root/tests/fixtures/graphql-errors.json" test_fails "GraphQL error response" "Internal server error" --line S9
failing_input="$root/tests/fixtures/graphql-partial-errors.json" test_fails "GraphQL partial data with errors" "Station lookup failed" --station Schöneweide
test_fails "invalid --days" "--days must be an integer from 1 to 14" --line S9 --days 0
test_fails "--days above 14" "--days must be an integer from 1 to 14" --line S9 --days 15
test_fails "old --input flag is gone" "unknown argument: --input" --line S9 --input "$fixture"
test_fails "old --api-url flag is gone" "unknown argument: --api-url" --line S9 --api-url "file://$fixture"
test_fails "bare BVG line number" "invalid line" --line 160
test_fails "unknown mode prefix" "invalid line" --line "Ferry F1"
failing_bvg_input="$root/tests/fixtures/malformed.json"
err="$("$script" --input-bvg "$failing_bvg_input" --input-sbahn-berlin "$fixture" --output "$tmp/keep.ics" --line "Bus 160" 2>&1 >/dev/null)" && status=0 || status=$?
if [ "$status" -ne 0 ]; then pass "malformed BVG input: exits non-zero"; else fail "malformed BVG input: exits non-zero"; fi
case "$err" in *"not a valid BVG API response"*) pass "malformed BVG input: explains itself" ;; *) fail "malformed BVG input: explains itself (got: $err)" ;; esac
test_fails "invalid --now" "--now must be" --line S9 --now yesterday

# Without --input the script fetches the API; a file:// URL stands in for the endpoint.
"$script" --output "$tmp/fetched.ics" --api-url-sbahn-berlin "file://$fixture" --now "$default_now" --days 14 --line S9 >/dev/null 2>&1
if diff <(unfold "$tmp/fetched.ics") "$golden/line-s9.ics" >/dev/null; then pass "fetches API when --input is absent"; else fail "fetches API when --input is absent"; fi

echo "previous feed" >"$tmp/keep.ics"
err="$("$script" --output "$tmp/keep.ics" --api-url-sbahn-berlin "file://$tmp/missing.json" --line S9 2>&1 >/dev/null)" && status=0 || status=$?
if [ "$status" -ne 0 ]; then pass "failed fetch exits non-zero"; else fail "failed fetch exits non-zero"; fi
case "$err" in *"could not fetch"*) pass "failed fetch explains itself" ;; *) fail "failed fetch explains itself (got: $err)" ;; esac
if [ "$(cat "$tmp/keep.ics")" = "previous feed" ]; then pass "failed fetch leaves output untouched"; else fail "failed fetch leaves output untouched"; fi

# Live BVG fetch against a local server that serves two pages and records every request.
serve="$tmp/serve"; mkdir -p "$serve"
jq -c '{elements: .elements[:5], numFound: 9, numPages: 2, page: 1}' "$root/tests/fixtures/bvg-response.json" >"$serve/page1.json"
jq -c '{elements: .elements[5:], numFound: 9, numPages: 2, page: 2}' "$root/tests/fixtures/bvg-response.json" >"$serve/page2.json"
# Live responses are far larger than the shell's per-argument limit (128 KiB on Linux).
jq -c '[.elements[] | select(.id == "HIM_FREETEXT_400001")] as $t | {elements: [range(1500) as $i | $t[0] | .id = "BIG_\($i)"], numPages: 2, page: 1}' "$root/tests/fixtures/bvg-response.json" >"$serve/bigpage1.json"
jq -c '.page = 2 | .elements = []' "$serve/bigpage1.json" >"$serve/bigpage2.json"
cat >"$tmp/server.py" <<'PY'
import http.server, sys, urllib.parse
root, log = sys.argv[1], sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        with open(log, "a") as f: f.write(self.path + "\n")
        q = urllib.parse.parse_qs(u.query)
        if u.path == "/fail": self.send_error(500); return
        prefix = "big" if u.path.startswith("/big/") else ""
        body = open(f"{root}/{prefix}page{q.get('page', ['1'])[0]}.json", "rb").read()
        self.send_response(200); self.send_header("content-type", "application/json"); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
srv = http.server.HTTPServer(("127.0.0.1", 0), H)
print(srv.server_port, flush=True)
srv.serve_forever()
PY
python3 "$tmp/server.py" "$serve" "$tmp/requests.log" >"$tmp/port" &
server_pid=$!; disown
trap 'kill "$server_pid" 2>/dev/null || true; rm -rf "$tmp"' EXIT
while [ ! -s "$tmp/port" ]; do sleep 0.1; done
port="$(cat "$tmp/port")"
bvg_url="http://127.0.0.1:$port/v1/de"

"$script" --output "$tmp/live-bvg.ics" --api-url-bvg "$bvg_url" --now "$default_now" --days 14 --line "Bus 160" --line "Bus 163" >/dev/null 2>&1
if diff <(unfold "$tmp/live-bvg.ics") "$golden/bvg-bus-160-163.ics" >/dev/null; then pass "live BVG fetch merges all pages"; else fail "live BVG fetch merges all pages"; fi
if grep -q 'type=TRAFFIC&timeFrame=FORTNIGHT&page=1' "$tmp/requests.log" && grep -q 'page=2' "$tmp/requests.log"; then pass "live BVG fetch requests traffic, fortnight, every page"; else fail "live BVG fetch requests traffic, fortnight, every page"; fi

: >"$tmp/requests.log"
"$script" --output "$tmp/sbahn-only.ics" --input-sbahn-berlin "$fixture" --api-url-bvg "$bvg_url" --now "$default_now" --days 14 --line S9 >/dev/null 2>&1
if [ ! -s "$tmp/requests.log" ]; then pass "S-Bahn-only watchlist makes no BVG call"; else fail "S-Bahn-only watchlist makes no BVG call"; fi

if "$script" --output "$tmp/big.ics" --api-url-bvg "http://127.0.0.1:$port/big/v1/de" --now "$default_now" --days 14 --line "Bus 160" >/dev/null 2>&1 && [ "$(grep -c '^BEGIN:VEVENT' "$tmp/big.ics")" -eq 1500 ]; then pass "live BVG response larger than the argument limit"; else fail "live BVG response larger than the argument limit"; fi

echo "previous feed" >"$tmp/keep.ics"
err="$("$script" --output "$tmp/keep.ics" --api-url-bvg "http://127.0.0.1:$port/fail" --line "Bus 160" 2>&1 >/dev/null)" && status=0 || status=$?
if [ "$status" -ne 0 ]; then pass "failed BVG fetch exits non-zero"; else fail "failed BVG fetch exits non-zero"; fi
case "$err" in *"could not fetch"*) pass "failed BVG fetch explains itself" ;; *) fail "failed BVG fetch explains itself (got: $err)" ;; esac
if [ "$(cat "$tmp/keep.ics")" = "previous feed" ]; then pass "failed BVG fetch leaves output untouched"; else fail "failed BVG fetch leaves output untouched"; fi

# A BVG failure fails the whole run even when S-Bahn data is fine.
"$script" --output "$tmp/keep.ics" --input-sbahn-berlin "$fixture" --api-url-bvg "http://127.0.0.1:$port/fail" --line S9 --line "Bus 160" >/dev/null 2>&1 && status=0 || status=$?
if [ "$status" -ne 0 ] && [ "$(cat "$tmp/keep.ics")" = "previous feed" ]; then pass "BVG failure fails the whole mixed run"; else fail "BVG failure fails the whole mixed run"; fi

: >"$tmp/requests.log"
if "$script" --output "$tmp/bvg-only.ics" --api-url-sbahn-berlin "file://$tmp/missing.json" --api-url-bvg "$bvg_url" --now "$default_now" --days 14 --line "Bus 160" >/dev/null 2>&1; then pass "BVG-only watchlist makes no S-Bahn call"; else fail "BVG-only watchlist makes no S-Bahn call"; fi

if [ "$failures" -ne 0 ]; then
  echo "$failures failure(s)"
  exit 1
fi
echo "all tests passed"
