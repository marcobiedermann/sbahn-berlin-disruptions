#!/usr/bin/env bash
# Builds an iCalendar feed of consequences for stations and lines.
#
# Usage: build-calendar.sh --output <feed.ics> [--station <name> ...] [--line <label> ...]
#                          [--days <n>] [--now <timestamp>]
#                          [--input-sbahn-berlin <api-response.json>] [--input-bvg <api-response.json>]
# Lines: S9 (S-Bahn Berlin); U2, "Tram M10", "Bus 160" (BVG). Stations are S-Bahn Berlin only.
# Without --input-sbahn-berlin the S-Bahn Berlin GraphQL API is queried
# (--api-url-sbahn-berlin and --api-url-bvg override the endpoints). --days accepts 1 to 14.
#
# Sections, in file order (this file is the orchestrator; Operator adapters live in lib/):
#   argument parsing and validation  -> then "Route each line" (label -> operator)
#   jq_render    events -> ICS text
#   orchestration: call each needed adapter, merge their events, render the feed
# Sourced modules:
#   lib/common.sh         die, jq_common (timestamps: epoch, wallclock; ICS escaping and folding)
#   lib/sbahn-berlin.sh   build_sbahn_events (GraphQL fetch, stations, periods)
#   lib/bvg.sh            build_bvg_events (paging, HTML-to-text, open-ended items)
# Adapter interface: arguments in, events JSON array on stdout, die on any failure.
# shellcheck disable=SC2154 # jq_common comes from lib/common.sh
set -euo pipefail

lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
# shellcheck source=/dev/null # the lib files are linted on their own
source "$lib/common.sh"
# shellcheck source=/dev/null # the lib files are linted on their own
source "$lib/sbahn-berlin.sh"
# shellcheck source=/dev/null # the lib files are linted on their own
source "$lib/bvg.sh"

input=""
input_bvg=""
output=""
lines=()
stations=()
days=14
now=""
api_url_sbahn="https://api.sbahn.berlin/construction-api/query"
api_url_bvg="https://www.bvg.de/disruption-reports-service/disruptions/v1/de"
tmp=""
trap 'rm -f "$tmp"' EXIT

while [ $# -gt 0 ]; do
  case "$1" in
    --input-sbahn-berlin) input="${2:?--input-sbahn-berlin needs a value}"; shift 2 ;;
    --input-bvg) input_bvg="${2:?--input-bvg needs a value}"; shift 2 ;;
    --output) output="${2:?--output needs a value}"; shift 2 ;;
    --line) lines+=("${2:?--line needs a value}"); shift 2 ;;
    --station) stations+=("${2:?--station needs a value}"); shift 2 ;;
    --days) days="${2:?--days needs a value}"; shift 2 ;;
    --now) now="${2:?--now needs a value}"; shift 2 ;;
    --api-url-sbahn-berlin) api_url_sbahn="${2:?--api-url-sbahn-berlin needs a value}"; shift 2 ;;
    --api-url-bvg) api_url_bvg="${2:?--api-url-bvg needs a value}"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

command -v jq >/dev/null || die "jq is required"
[ -n "$output" ] || die "--output is required"
[ "$((${#lines[@]} + ${#stations[@]}))" -gt 0 ] || die "at least one --station or --line is required"
[ -z "$input" ] || [ -f "$input" ] || die "input file not found: $input"
[ -z "$input_bvg" ] || [ -f "$input_bvg" ] || die "input file not found: $input_bvg"
[[ "$days" =~ ^[1-9][0-9]*$ ]] && [ "$days" -le 14 ] || die "--days must be an integer from 1 to 14, got: $days"
[ -n "$now" ] || now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
[[ "$now" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || die "--now must be a UTC timestamp like 2026-10-22T12:00:00Z, got: $now"

# Route each line to its operator by label. BVG labels are canonicalised ("bus 160" -> "Bus 160").
sbahn_lines=()
bvg_lines=()
for label in ${lines[@]+"${lines[@]}"}; do
  if [[ "$label" =~ ^[Uu]([0-9]+)$ ]]; then
    bvg_lines+=("U${BASH_REMATCH[1]}")
  elif [[ "$label" =~ ^([Bb][Uu][Ss]|[Tt][Rr][Aa][Mm])\ +([^[:space:]]+)$ ]]; then
    mode="$(echo "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')"
    mode="$(echo "${mode:0:1}" | tr '[:lower:]' '[:upper:]')${mode:1}"
    bvg_lines+=("$mode ${BASH_REMATCH[2]}")
  elif [[ "$label" =~ ^[Ss][0-9]+$ ]]; then
    sbahn_lines+=("$(echo "$label" | tr '[:lower:]' '[:upper:]')")
  else
    die "invalid line \"$label\". Use S9 (S-Bahn), U2 (U-Bahn), \"Tram M10\" or \"Bus 160\""
  fi
done

to_json_array() {
  if [ $# -eq 0 ]; then echo '[]'; else printf '%s\n' "$@" | jq -R . | jq -s -c .; fi
}

read -r -d '' jq_render <<'JQ' || true
  def stamp: if .allDay
    then "DTSTART;VALUE=DATE:\(.start | local | .[0:8])", "DTEND;VALUE=DATE:\(.end | local | .[0:8])"
    else "DTSTART;TZID=Europe/Berlin:\(.start | local)", "DTEND;TZID=Europe/Berlin:\(.end | local)"
    end;

  sort_by([.start, .order])
  | map([
      "BEGIN:VEVENT",
      "UID:\(.uid)",
      "DTSTAMP:\(.dtstamp)",
      stamp,
      "SUMMARY:\(.summary | esc)",
      "DESCRIPTION:\(.description | esc)",
      "TRANSP:TRANSPARENT",
      "END:VEVENT"
    ]) as $events
  | ([ "BEGIN:VCALENDAR",
       "VERSION:2.0",
       "PRODID:-//sbahn-berlin-disruptions//DE",
       "CALSCALE:GREGORIAN",
       "METHOD:PUBLISH",
       "X-WR-CALNAME:Berlin ÖPNV Störungen" ]
     + timezone
     + ($events | add // [])
     + [ "END:VCALENDAR" ])
  | .[] | fold + "\r\n"
JQ

# Operators are only queried when the watchlist needs them.
sbahn_events='[]'
if [ "$((${#sbahn_lines[@]} + ${#stations[@]}))" -gt 0 ]; then
  sbahn_events="$(build_sbahn_events "$api_url_sbahn" "$input" "$now" "$days" \
    "$(to_json_array ${sbahn_lines[@]+"${sbahn_lines[@]}"})" \
    "$(to_json_array ${stations[@]+"${stations[@]}"})")"
fi

bvg_events='[]'
if [ "${#bvg_lines[@]}" -gt 0 ]; then
  bvg_events="$(build_bvg_events "$api_url_bvg" "$input_bvg" "$now" "$days" "$(to_json_array "${bvg_lines[@]}")")"
fi

tmp="$(mktemp "$(dirname "$output")/.feed.XXXXXX")"
TZ=Europe/Berlin jq -n -j --slurpfile sbahn <(printf '%s' "$sbahn_events") --slurpfile bvg <(printf '%s' "$bvg_events") "$jq_common"'($sbahn[0] + $bvg[0]) | '"$jq_render" >"$tmp"

mv "$tmp" "$output"
