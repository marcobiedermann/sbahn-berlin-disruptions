# S-Bahn Berlin Disruptions

A personal, statically hosted calendar feed of S-Bahn Berlin disruptions that affect chosen stations and lines, subscribed to from Google Calendar.

## Language

**Consequence**:
A single disruption announcement published by S-Bahn Berlin, with an effect, affected lines, and one or more periods.
_Avoid_: Disruption (as a data term), incident, alert

**Effect**:
What a consequence does to service, e.g. no service, replacement bus, changed timetable.
_Avoid_: Impact, status

**Period**:
A span of time during which a consequence applies; either one continuous span or a daily repeating window across a date range.
_Avoid_: Interval, timeframe

**Daily window**:
The recurring time-of-day range of a repeating period (e.g. 08:00 - 16:00), occurring on each day of its date range. If the end time of day is not later than the start, the window ends the next day; the last window ends at the period's `dateEnd`.
_Avoid_: Recurrence

**Occurrence**:
One concrete calendar event: a continuous period, or a single day of a daily window.
_Avoid_: Instance, entry

**Station**:
An S-Bahn stop, identified by the user via its name (e.g. "Schöneweide"), not an internal ID. Resolved by exact match on the title without its `S `/`S+U `/`U ` prefix; zero or several matches is an error.
_Avoid_: Stop, Bahnhof

**Line**:
An S-Bahn route, identified by its label (e.g. "S9").
_Avoid_: Route

**Watchlist**:
The configured set of stations and lines the user cares about; a consequence is relevant if it touches any of them. Set once in the `STATIONS`, `LINES` and `DAYS` env vars of `.github/workflows/update-calendar.yml`, passed to the script as `--station`, `--line` and `--days`.
_Avoid_: Filter, subscription

**Horizon**:
The forward-looking window (14 days from run time, `--days`) within which occurrences are published. An occurrence overlapping the horizon is kept in full.
_Avoid_: Range

**Feed**:
The single calendar file consumed by Google Calendar, always mirroring the current relevant consequences within the horizon. Lives at `calendar.ics`, written only by the workflow.
_Avoid_: Calendar export, ICS dump
