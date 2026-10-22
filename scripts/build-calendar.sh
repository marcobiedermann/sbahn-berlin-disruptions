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
# Sections, in file order:
#   argument parsing and validation  -> then "Route each line" (label -> operator)
#   jq_common    shared jq defs: timestamps (epoch, wallclock), ICS escaping and folding
#   jq_render    events -> ICS text
#   build_sbahn_events()  S-Bahn Berlin fetch + jq builder (GraphQL, periods, stations)
#   jq_bvg       BVG builder (HTML-to-text, lines per mode, open-ended items)
#   fetch_bvg()  BVG paging; orchestration at the bottom merges both operators' events
set -euo pipefail

die() {
  echo "error: $*" >&2
  exit 1
}

input=""
input_bvg=""
output=""
lines=()
stations=()
days=14
now=""
api_url_sbahn="https://api.sbahn.berlin/construction-api/query"
api_url_bvg="https://www.bvg.de/disruption-reports-service/disruptions/v1/de"
fetched=""
tmp=""
tmp_bvg=""
tmp_page=""
trap 'rm -f "$fetched" "$tmp" "$tmp_bvg" "$tmp_page"' EXIT

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
use_sbahn=false
[ "$((${#sbahn_lines[@]} + ${#stations[@]}))" -eq 0 ] || use_sbahn=true
use_bvg=false
[ "${#bvg_lines[@]}" -eq 0 ] || use_bvg=true

# jq definitions shared by the event builders and the renderer. Needs TZ=Europe/Berlin.
# Builders emit events {start, end, allDay, uid, dtstamp, summary, description, order};
# start/end are Berlin wall-clock seconds (see wallclock).
read -r -d '' jq_common <<'JQ' || true
  def esc: gsub("\\\\"; "\\\\") | gsub(";"; "\\;") | gsub(","; "\\,") | gsub("\n"; "\\n");

  # Folds a content line at 75 octets (RFC 5545), counting UTF-8 bytes.
  def fold:
    [explode[] | . as $c | [$c, ([$c] | implode | utf8bytelength)]]
    | reduce .[] as [$c, $b] ({out: [], cur: [], len: 0, limit: 75};
        if .len + $b > .limit
        then .out += [.cur | implode] | .cur = [$c] | .len = $b | .limit = 74
        else .cur += [$c] | .len += $b
        end)
    | (.out + [.cur | implode]) | join("\r\n ");

  # UTC epoch of an offset timestamp like 2026-08-21T20:39:00+02:00 (fractions ignored). Both operators send offsets, e.g. +00:00 or +02:00.
  def epoch:
    capture("^(?<dt>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(\\.[0-9]+)?(?<z>Z|[+-][0-9]{2}:[0-9]{2})$") as $m
    | ($m.dt + "Z" | fromdateiso8601)
      - (if $m.z == "Z" then 0
         else (if $m.z[0:1] == "-" then -1 else 1 end) * (($m.z[1:3] | tonumber) * 3600 + ($m.z[4:6] | tonumber) * 60)
         end);

  def utc: epoch | todate | gsub("[-:]"; "");

  # Berlin wall-clock time of an API timestamp, as seconds since epoch read as if UTC.
  # Plain arithmetic on it adds calendar days without DST jumps. Needs TZ=Europe/Berlin.
  def wallclock: epoch | localtime | mktime;
  def wallclockAt($epoch): $epoch | localtime | mktime;
  def local: gmtime | strftime("%Y%m%dT%H%M%S");

  def timezone: [
    "BEGIN:VTIMEZONE",
    "TZID:Europe/Berlin",
    "BEGIN:DAYLIGHT",
    "TZOFFSETFROM:+0100",
    "TZOFFSETTO:+0200",
    "TZNAME:CEST",
    "DTSTART:19700329T020000",
    "RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=-1SU",
    "END:DAYLIGHT",
    "BEGIN:STANDARD",
    "TZOFFSETFROM:+0200",
    "TZOFFSETTO:+0100",
    "TZNAME:CET",
    "DTSTART:19701025T030000",
    "RRULE:FREQ=YEARLY;BYMONTH=10;BYDAY=-1SU",
    "END:STANDARD",
    "END:VTIMEZONE"
  ];
JQ

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


build_sbahn_events() {
if [ -z "$input" ]; then
  command -v curl >/dev/null || die "curl is required"
  # shellcheck disable=SC2016 # $language is a GraphQL variable, not a shell one
  graphql_query='query Consequences($language: Language!) {
    consequences(language: $language) {
      id effect title updated
      periods { id title type dateStart dateEnd }
      lines { id title link }
    }
    lines { id title }
    stations { id title consequences { id } }
  }'
  request="$(jq -n -c --arg query "$graphql_query" '{query: $query, variables: {language: "GERMAN"}}')"
  fetched="$(mktemp)"
  trap 'rm -f "$fetched"' EXIT # runs in the subshell of build_sbahn_events
  curl --silent --show-error --fail --location --max-time 30 --retry 2 --retry-delay 5 \
    --request POST "$api_url_sbahn" \
    --header 'content-type: application/json' \
    --header 'accept: application/json' \
    --header 'origin: https://sbahn.berlin' \
    --header 'referer: https://sbahn.berlin/' \
    --header 'user-agent: Mozilla/5.0 (compatible; sbahn-berlin-disruptions)' \
    --data "$request" \
    --output "$fetched" || die "could not fetch $api_url_sbahn"
  input="$fetched"
fi
if ! jq -e '((.errors // []) | length == 0) and (.data.consequences | type == "array")' "$input" >/dev/null 2>&1; then
  api_error="$(jq -r '.errors[0].message? // empty' "$input" 2>/dev/null || true)"
  die "input is not a valid API response${api_error:+: $api_error}"
fi

to_json_array() {
  if [ $# -eq 0 ]; then echo '[]'; else printf '%s\n' "$@" | jq -R . | jq -s -c .; fi
}

wanted="$(to_json_array ${sbahn_lines[@]+"${sbahn_lines[@]}"})"
queries="$(to_json_array ${stations[@]+"${stations[@]}"})"

unknown="$(jq -r --argjson wanted "$wanted" '(.data.lines | map(.title)) as $known | ($wanted - $known)[]' "$input")"
if [ -n "$unknown" ]; then
  known="$(jq -r '.data.lines | map(.title) | join(", ")' "$input")"
  die "unknown line(s): $(echo "$unknown" | paste -sd, -). Known lines: $known"
fi

# Station titles and queries are compared case-insensitively without the "S "/"S+U "/"U " prefix.
norm_def='def norm: gsub("Ä"; "ä") | gsub("Ö"; "ö") | gsub("Ü"; "ü") | ascii_downcase | sub("^(s\\+u|s|u) +"; "");'

station_errors="$(jq -r --argjson queries "$queries" "$norm_def"'
  .data.stations as $all
  | $queries[]
  | . as $q | ($q | norm) as $n
  | [$all[] | select(.title | norm == $n)] as $exact
  | if ($exact | length) == 1 then empty
    elif ($exact | length) > 1 then
      "ambiguous station \"\($q)\" matches: \($exact | map(.title) | join(", "))"
    else
      ([$all[] | select(.title | norm | contains($n)) | .title]) as $near
      | "unknown station \"\($q)\"" + (if ($near | length) > 0 then ". Did you mean: \($near | join(", "))" else "" end)
    end
' "$input")"
[ -z "$station_errors" ] || die "$station_errors"

station_ids="$(jq -c --argjson queries "$queries" "$norm_def"'
  [$queries[] | norm] as $names
  | [.data.stations[] | select(.title | norm | . as $t | $names | any(. == $t)) | .id]
' "$input")"

TZ=Europe/Berlin jq -c --argjson wanted "$wanted" --argjson stationIds "$station_ids" --arg now "$now" --argjson days "$days" "$jq_common"'
  # One occurrence per day for a daily window: the window is the time of day of the period
  # start and end, and the last window ends at the period end.
  def occurrences:
    if .p.type == "REPEATING_DAILY" then
      (.p.dateStart | wallclock) as $s
      | (.p.dateEnd | wallclock) as $e
      | ($s % 86400) as $from
      | ($e % 86400) as $to
      | (if $to <= $from then 86400 else 0 end) as $wrap
      | ($s - $from) as $firstDay
      | (($e - $e % 86400 - $wrap - $firstDay) / 86400 | floor + 1) as $days
      | if $days < 1 then {c, p, start: $s, end: $e}
        else range(0; $days) as $k
          | {c, p, start: ($firstDay + $k * 86400 + $from), end: ($firstDay + $k * 86400 + $to + $wrap)}
        end
    else
      {c, p, start: (.p.dateStart | wallclock), end: (.p.dateEnd | wallclock)}
    end;


  def effects: {
    NO_SERVICE: "Kein Zugverkehr",
    NO_STOP: "Halt entfällt",
    REPLACEMENT: "Ersatzverkehr",
    SHUTTLE_SERVICE: "Pendelverkehr",
    SPECIAL: "Besonderheit",
    TACT_CHANGE: "Taktänderung",
    TRAIN_SERVICE_CHANGED: "Zugangebot geändert"
  };

  .data as $d
  | ($now | fromdateiso8601) as $nowEpoch
  | wallclockAt($nowEpoch) as $horizonStart
  | wallclockAt($nowEpoch + $days * 86400) as $horizonEnd
  | [ $d.stations[] | select(.id as $i | $stationIds | any(. == $i)) | .consequences[].id ] as $stationConsequenceIds
  | [ $d.consequences[]
      | . as $c
      | select(
          (([.lines[].title] | map(select(. as $t | $wanted | any(. == $t)))) | length > 0)
          or ($stationConsequenceIds | any(. == $c.id)))
      | .periods[]
      | {c: $c, p: .}
      | occurrences
      | select(.end > $horizonStart and .start < $horizonEnd) ]
  | map(
      .c as $c | .p as $p
      | ($c.lines | map(.title)) as $lineTitles
      | [$d.stations[] | select(.consequences | any(.id == $c.id)) | .title] as $stations
      | ($c.updated | utc) as $updated
      | (.start | local) as $start
      | ($c.title | gsub("<>"; "⇄") | gsub(">"; "→")) as $title
      | {
          start: .start, end: .end,
          allDay: false,
          uid: "\($c.id)-\($p.id)-\($start[0:8])@sbahn-berlin-disruptions",
          dtstamp: $updated,
          summary: (($lineTitles | join("/")) + " · " + $title + " · " + (effects[$c.effect] // $c.effect)),
          description:
            ([ "Zeitraum: \($p.title)",
               "Linien: \($lineTitles | join(", "))" ]
             + (if ($stations | length) > 0 then ["Bahnhöfe: \($stations | join(", "))"] else [] end)
             + [ "Mehr: \($c.lines | map(.link) | join(", "))",
                 "Stand: \($updated | sub("^(?<d>[0-9]{4})(?<m>[0-9]{2})(?<day>[0-9]{2})T(?<h>[0-9]{2})(?<mi>[0-9]{2})(?<s>[0-9]{2})Z$"; "\(.d)-\(.m)-\(.day)T\(.h):\(.mi):\(.s)Z"))" ]
            ) | join("\n"),
          order: [0, ($c.id | tonumber), ($p.id | tonumber)]
        }
    )
' "$input"
}

# BVG items carry offset timestamps, HTML bodies and often no end date.
read -r -d '' jq_bvg <<'JQ' || true
  def entities:
    gsub("&(?<n>[a-zA-Z]+);"; ({nbsp: " ", auml: "ä", ouml: "ö", uuml: "ü", Auml: "Ä", Ouml: "Ö", Uuml: "Ü",
        szlig: "ß", ndash: "–", mdash: "—", quot: "\"", apos: "'", lt: "<", gt: ">", amp: "&"}[.n] // "&\(.n);"))
    | gsub("&#(?<d>[0-9]+);"; [.d | tonumber] | implode);

  # HTML body to plain text. Signet components carry their text in attributes.
  def plain:
    gsub("<br ?/?>"; "\n")
    | gsub("</(p|li|ul|ol|h[1-6])>"; "\n")
    | gsub("<li[^>]*>"; "- ")
    | gsub("<bds-signet-transport(?:[^>']|'[^']*')*?aria-label='(?<l>[^']*)'(?:[^>']|'[^']*')*>"; .l)
    | gsub("<bds-signet-line(?:[^>']|'[^']*')*?line-id='(?<l>[^']*)'(?:[^>']|'[^']*')*>"; .l)
    | gsub("<bds-icon(?:[^>']|'[^']*')*?alt='(?<l>[^']*)'(?:[^>']|'[^']*')*>"; .l)
    | gsub("<(?:[^>'\"]|'[^']*'|\"[^\"]*\")+>"; "")
    | entities
    | gsub("[ \t]+"; " ")
    | gsub(" ?\n ?"; "\n")
    | gsub("\n{3,}"; "\n\n")
    | sub("^\\s+"; "") | sub("\\s+$"; "");

  # One group per mode: {mode, names}. Labels are "Bus 160", "Tram M10", "U2".
  def groups: [.lines[]? | to_entries[] | {mode: .key, names: (.value | map(.name))}];
  def prefix: if .mode == "bus" then "Bus " elif .mode == "tram" then "Tram " else "" end;
  def labels: [groups[] | prefix as $p | .names[] | $p + .];
  def groupLabels: [groups[] | prefix + (.names | join("/"))];
  def clock: gmtime | strftime("%d.%m.%Y %H:%M");

  ($now | fromdateiso8601) as $nowEpoch
  | wallclockAt($nowEpoch) as $horizonStart
  | wallclockAt($nowEpoch + $days * 86400) as $horizonEnd
  | ($wanted | map(ascii_upcase)) as $wantedUp
  | [ .elements[]
      | select(.messageType == "TRAFFIC")
      | select(labels | any(ascii_upcase | . as $l | $wantedUp | any(. == $l)))
      | (.startDate | epoch | wallclockAt(.)) as $s
      | (if .endDate then (.endDate | epoch | wallclockAt(.)) else null end) as $e
      | select(if $e then $e > $horizonStart and $s < $horizonEnd else $s < $horizonEnd end)
      | (if $e then {start: $s, end: $e, allDay: false}
         else ($s - $s % 86400) as $day | {start: $day, end: ($day + 86400), allDay: true} end) as $span
      | ((.modDate // .startDate) | epoch | todate | utc) as $updated
      | ([.content[]?.headline // empty] | first // "") as $headline
      | ([.disruptionTypes[]?.displayName] | map(select(. as $t | $headline | contains($t) | not))) as $types
      | ([.content[]?.content // empty | plain] | map(select(. != "")) | join("\n\n")) as $body
      | ([.stationOne.displayName?, .stationTwo.displayName?] | map(select(. != null and . != ""))) as $stations
      | $span + {
          uid: "\(.id)-\($span.start | local | .[0:8])@sbahn-berlin-disruptions",
          dtstamp: $updated,
          summary: ([groupLabels | join(", "), $headline] + (if ($types | length) > 0 then [$types | join(", ")] else [] end) | map(select(. != "")) | join(" · ")),
          description:
            ([ $body,
               "Zeitraum: \($s | clock) – \(if $e then $e | clock else "unbefristet" end)",
               "Linien: \(labels | join(", "))" ]
             + (if ($stations | length) > 0 then ["Haltestelle: \($stations | join(", "))"] else [] end)
             + [ "Mehr: https://www.bvg.de/de/verbindungen/stoerungsmeldungen",
                 "Stand: \($updated | sub("^(?<d>[0-9]{4})(?<m>[0-9]{2})(?<day>[0-9]{2})T(?<h>[0-9]{2})(?<mi>[0-9]{2})(?<s>[0-9]{2})Z$"; "\(.d)-\(.m)-\(.day)T\(.h):\(.mi):\(.s)Z"))" ]
            | map(select(. != "")) | join("\n")),
          order: [1, .id]
        } ]
JQ

sbahn_events='[]'
if $use_sbahn; then sbahn_events="$(build_sbahn_events)"; fi

# Fetches every page of the BVG disruption list and merges the elements.
fetch_bvg() {
  command -v curl >/dev/null || die "curl is required"
  local page=1 pages=1 file
  file="$(mktemp)"
  tmp_page="$file"
  local merged='[]'
  while [ "$page" -le "$pages" ]; do
    curl --silent --show-error --fail --location --max-time 30 --retry 2 --retry-delay 5 \
      --header 'accept: application/json' \
      --header 'user-agent: Mozilla/5.0 (compatible; sbahn-berlin-disruptions)' \
      --output "$file" \
      "$api_url_bvg?type=TRAFFIC&timeFrame=FORTNIGHT&page=$page" || die "could not fetch $api_url_bvg"
    jq -e '(.elements | type == "array") and ((.numPages // 1) | type == "number")' "$file" >/dev/null 2>&1 || die "input is not a valid BVG API response"
    pages="$(jq -r '.numPages // 1' "$file")"
    merged="$(jq -c -n --argjson acc "$merged" --slurpfile page "$file" '$acc + $page[0].elements')"
    page=$((page + 1))
  done
  jq -c -n --argjson elements "$merged" '{elements: $elements}'
}

bvg_events='[]'
if $use_bvg; then
  bvg_input="$(mktemp)"
  tmp_bvg="$bvg_input"
  if [ -n "$input_bvg" ]; then
    jq -e '.elements | type == "array"' "$input_bvg" >/dev/null 2>&1 || die "input is not a valid BVG API response"
    cp "$input_bvg" "$bvg_input"
  else
    fetch_bvg >"$bvg_input"
  fi
  bvg_wanted="$(printf '%s\n' "${bvg_lines[@]}" | jq -R . | jq -s -c .)"
  bvg_events="$(TZ=Europe/Berlin jq -c --argjson wanted "$bvg_wanted" --arg now "$now" --argjson days "$days" "$jq_common$jq_bvg" "$bvg_input")"
fi

tmp="$(mktemp "$(dirname "$output")/.feed.XXXXXX")"
TZ=Europe/Berlin jq -n -j --argjson sbahn "$sbahn_events" --argjson bvg "$bvg_events" "$jq_common"'($sbahn + $bvg) | '"$jq_render" >"$tmp"

mv "$tmp" "$output"
