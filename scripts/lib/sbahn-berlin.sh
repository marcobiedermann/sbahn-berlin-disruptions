#!/usr/bin/env bash
# shellcheck disable=SC2154 # jq_common comes from lib/common.sh
# S-Bahn Berlin adapter. Source it after lib/common.sh, do not run it.
#
# build_sbahn_events <api-url> <saved-response|""> <now> <days> <lines-json> <stations-json>
#   Prints the events JSON array on stdout; exits non-zero via die on any failure.
#   An empty saved-response means: query the GraphQL API at <api-url>.
#   <lines-json> and <stations-json> are JSON arrays of line labels and station names.
#   Call it inside $(...): it removes its temp file in the subshell's EXIT trap.

# Station titles and queries are compared case-insensitively without the "S "/"S+U "/"U " prefix.
norm_def='def norm: gsub("Ä"; "ä") | gsub("Ö"; "ö") | gsub("Ü"; "ü") | ascii_downcase | sub("^(s\\+u|s|u) +"; "");'

fetch_sbahn() {
  local api_url="$1" out="$2" graphql_query request
  command -v curl >/dev/null || die "curl is required"
  # shellcheck disable=SC2016 # $language is a GraphQL variable, not a shell one
  graphql_query='query Consequences($language: Language!) {
    consequences(language: $language) {
      id effect title updated
      task { id }
      periods { id title type dateStart dateEnd }
      lines { id title link }
    }
    lines { id title }
    stations { id title consequences { id } }
  }'
  request="$(jq -n -c --arg query "$graphql_query" '{query: $query, variables: {language: "GERMAN"}}')"
  curl --silent --show-error --fail --location --max-time 30 --retry 2 --retry-delay 5 \
    --request POST "$api_url" \
    --header 'content-type: application/json' \
    --header 'accept: application/json' \
    --header 'origin: https://sbahn.berlin' \
    --header 'referer: https://sbahn.berlin/' \
    --header 'user-agent: Mozilla/5.0 (compatible; sbahn-berlin-disruptions)' \
    --data "$request" \
    --output "$out" || die "could not fetch $api_url"
}

build_sbahn_events() {
  local api_url="$1" input="$2" now="$3" days="$4" wanted="$5" queries="$6"
  local fetched unknown known station_errors station_ids api_error

  if [ -z "$input" ]; then
    fetched="$(mktemp)"
    trap 'rm -f "$fetched"' EXIT
    fetch_sbahn "$api_url" "$fetched"
    input="$fetched"
  fi
  if ! jq -e '((.errors // []) | length == 0) and (.data.consequences | type == "array")' "$input" >/dev/null 2>&1; then
    api_error="$(jq -r '.errors[0].message? // empty' "$input" 2>/dev/null || true)"
    die "input is not a valid API response${api_error:+: $api_error}"
  fi

  unknown="$(jq -r --argjson wanted "$wanted" '(.data.lines | map(.title)) as $known | ($wanted - $known)[]' "$input")"
  if [ -n "$unknown" ]; then
    known="$(jq -r '.data.lines | map(.title) | join(", ")' "$input")"
    die "unknown line(s): $(echo "$unknown" | paste -sd, -). Known lines: $known"
  fi

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

  # The API also links a station to consequences that only mention it in the alternative-route text,
  # so a station counts as affected only if it is a whole stop name in the consequence title.
  TZ=Europe/Berlin jq -c --argjson wanted "$wanted" --argjson stationIds "$station_ids" --arg now "$now" --argjson days "$days" "$jq_common$norm_def"'
    def namedIn($title):
      ($title | split("<>") | map(split(">")[]) | map(split("/")[]) | map(gsub("^ +| +$"; "") | norm)) as $stops
      | (.title | norm) as $n | $stops | any(. == $n);
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
    | [ $d.consequences[]
        | . as $c
        | [$d.stations[] | select(.consequences | any(.id == $c.id)) | select(namedIn($c.title))] as $namedStations
        | select(
            (([.lines[].title] | map(select(. as $t | $wanted | any(. == $t)))) | length > 0)
            or ($namedStations | any(.id as $i | $stationIds | any(. == $i))))
        | .periods[]
        | {c: $c, p: .}
        | occurrences
        | select(.end > $horizonStart and .start < $horizonEnd) ]
    | map(
        .c as $c | .p as $p
        | ($c.lines | map(.title)) as $lineTitles
        | [$d.stations[] | select(.consequences | any(.id == $c.id)) | select(namedIn($c.title)) | .title] as $stations
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
               + (if $c.task.id then ["Details: https://sbahn.berlin/fahren/bauen-stoerung/bauen/\($c.task.id)/auswirkung/\($c.id)/"] else [] end)
               + [ "Mehr: \($c.lines | map(.link) | join(", "))",
                   "Stand: \($updated | sub("^(?<d>[0-9]{4})(?<m>[0-9]{2})(?<day>[0-9]{2})T(?<h>[0-9]{2})(?<mi>[0-9]{2})(?<s>[0-9]{2})Z$"; "\(.d)-\(.m)-\(.day)T\(.h):\(.mi):\(.s)Z"))" ]
              ) | join("\n"),
            order: [0, ($c.id | tonumber), ($p.id | tonumber)]
          }
      )
  ' "$input"
}
