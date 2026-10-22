#!/usr/bin/env bash
# shellcheck disable=SC2154 # jq_common comes from lib/common.sh
# BVG adapter (U-Bahn, Tram, Bus). Source it after lib/common.sh, do not run it.
#
# build_bvg_events <api-url> <saved-response|""> <now> <days> <wanted-labels-json>
#   Prints the events JSON array on stdout; exits non-zero via die on any failure.
#   An empty saved-response means: fetch every page from <api-url>.
#   Labels look like "U2", "Tram M10", "Bus 160" (already canonical).
#   Call it inside $(...): it removes its temp files in the subshell's EXIT trap.

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

# Fetches every page of the BVG disruption list into <out> as one merged response.
# <page> and <acc> are scratch files owned by the caller: live data exceeds the argument-size limit.
fetch_bvg() {
  local api_url="$1" out="$2" file="$3" acc="$4" page=1 pages=1
  command -v curl >/dev/null || die "curl is required"
  : >"$acc"
  while [ "$page" -le "$pages" ]; do
    curl --silent --show-error --fail --location --max-time 30 --retry 2 --retry-delay 5 \
      --header 'accept: application/json' \
      --header 'user-agent: Mozilla/5.0 (compatible; sbahn-berlin-disruptions)' \
      --output "$file" \
      "$api_url?type=TRAFFIC&timeFrame=FORTNIGHT&page=$page" || die "could not fetch $api_url"
    jq -e '(.elements | type == "array") and ((.numPages // 1) | type == "number")' "$file" >/dev/null 2>&1 || die "input is not a valid BVG API response"
    pages="$(jq -r '.numPages // 1' "$file")"
    jq -c '{elements}' "$file" >>"$acc"
    page=$((page + 1))
  done
  jq -s -c '{elements: (map(.elements) | add // [])}' "$acc" >"$out"
}

build_bvg_events() {
  local api_url="$1" saved="$2" now="$3" days="$4" wanted="$5" input page acc
  input="$(mktemp)"
  page="$(mktemp)"
  acc="$(mktemp)"
  trap 'rm -f "$input" "$page" "$acc"' EXIT
  if [ -n "$saved" ]; then
    jq -e '.elements | type == "array"' "$saved" >/dev/null 2>&1 || die "input is not a valid BVG API response"
    cp "$saved" "$input"
  else
    fetch_bvg "$api_url" "$input" "$page" "$acc"
  fi
  TZ=Europe/Berlin jq -c --argjson wanted "$wanted" --arg now "$now" --argjson days "$days" "$jq_common$jq_bvg" "$input"
}
