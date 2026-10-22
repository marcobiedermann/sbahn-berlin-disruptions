#!/usr/bin/env bash
# Builds an iCalendar feed of S-Bahn Berlin consequences for the given lines.
#
# Usage: build-calendar.sh --input <api-response.json> --output <feed.ics> --line <S9> [--line <S85> ...]
set -euo pipefail

die() {
  echo "error: $*" >&2
  exit 1
}

input=""
output=""
lines=()
stations=()

while [ $# -gt 0 ]; do
  case "$1" in
    --input) input="${2:?--input needs a value}"; shift 2 ;;
    --output) output="${2:?--output needs a value}"; shift 2 ;;
    --line) lines+=("${2:?--line needs a value}"); shift 2 ;;
    --station) stations+=("${2:?--station needs a value}"); shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done

command -v jq >/dev/null || die "jq is required"
[ -n "$input" ] || die "--input is required"
[ -n "$output" ] || die "--output is required"
[ "$((${#lines[@]} + ${#stations[@]}))" -gt 0 ] || die "at least one --station or --line is required"
[ -f "$input" ] || die "input file not found: $input"

jq -e '.data.consequences | type == "array"' "$input" >/dev/null 2>&1 ||
  die "input is not a valid API response (missing data.consequences)"

to_json_array() {
  if [ $# -eq 0 ]; then echo '[]'; else printf '%s\n' "$@" | jq -R . | jq -s -c .; fi
}

wanted="$(to_json_array ${lines[@]+"${lines[@]}"})"
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

tmp="$(mktemp "$(dirname "$output")/.feed.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

TZ=Europe/Berlin jq -j --argjson wanted "$wanted" --argjson stationIds "$station_ids" '
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

  def utc: gsub("[-:]"; "") | sub("\\+0000$"; "Z");

  # Berlin wall-clock time of an API timestamp, as seconds since epoch read as if UTC.
  # Plain arithmetic on it adds calendar days without DST jumps. Needs TZ=Europe/Berlin.
  def wallclock: sub("\\+00:00$"; "Z") | fromdateiso8601 | localtime | mktime;
  def local: gmtime | strftime("%Y%m%dT%H%M%S");

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
  | [ $d.stations[] | select(.id as $i | $stationIds | any(. == $i)) | .consequences[].id ] as $stationConsequenceIds
  | [ $d.consequences[]
      | . as $c
      | select(
          (([.lines[].title] | map(select(. as $t | $wanted | any(. == $t)))) | length > 0)
          or ($stationConsequenceIds | any(. == $c.id)))
      | .periods[]
      | {c: $c, p: .}
      | occurrences ]
  | sort_by([.start, (.c.id | tonumber), (.p.id | tonumber)])
  | map(
      .c as $c | .p as $p
      | ($c.lines | map(.title)) as $lineTitles
      | [$d.stations[] | select(.consequences | any(.id == $c.id)) | .title] as $stations
      | ($c.updated | utc) as $updated
      | (.start | local) as $start
      | ($c.title | gsub("<>"; "⇄") | gsub(">"; "→")) as $title
      | [
          "BEGIN:VEVENT",
          "UID:\($c.id)-\($p.id)-\($start[0:8])@sbahn-berlin-disruptions",
          "DTSTAMP:\($updated)",
          "DTSTART;TZID=Europe/Berlin:\($start)",
          "DTEND;TZID=Europe/Berlin:\(.end | local)",
          "SUMMARY:\(($lineTitles | join("/")) + " · " + $title + " · " + (effects[$c.effect] // $c.effect) | esc)",
          "DESCRIPTION:\(
            ([ "Zeitraum: \($p.title)",
               "Linien: \($lineTitles | join(", "))" ]
             + (if ($stations | length) > 0 then ["Bahnhöfe: \($stations | join(", "))"] else [] end)
             + [ "Mehr: \($c.lines | map(.link) | join(", "))",
                 "Stand: \($updated | sub("^(?<d>[0-9]{4})(?<m>[0-9]{2})(?<day>[0-9]{2})T(?<h>[0-9]{2})(?<mi>[0-9]{2})(?<s>[0-9]{2})Z$"; "\(.d)-\(.m)-\(.day)T\(.h):\(.mi):\(.s)Z"))" ]
            ) | join("\n") | esc)",
          "TRANSP:TRANSPARENT",
          "END:VEVENT"
        ]
    ) as $events
  | ([ "BEGIN:VCALENDAR",
       "VERSION:2.0",
       "PRODID:-//sbahn-berlin-disruptions//DE",
       "CALSCALE:GREGORIAN",
       "METHOD:PUBLISH",
       "X-WR-CALNAME:S-Bahn Berlin Störungen" ]
     + timezone
     + ($events | add // [])
     + [ "END:VCALENDAR" ])
  | .[] | fold + "\r\n"
' "$input" >"$tmp"

mv "$tmp" "$output"
trap - EXIT
