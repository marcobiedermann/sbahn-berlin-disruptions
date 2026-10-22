#!/usr/bin/env bash
# Shared by the orchestrator and the Operator adapters. Source it, do not run it.
# shellcheck disable=SC2034 # jq_common is read by the files that source this one

die() {
  echo "error: $*" >&2
  exit 1
}

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
