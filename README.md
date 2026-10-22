# S-Bahn Berlin Disruptions Calendar

Builds an iCalendar feed of S-Bahn Berlin disruptions (consequences) for the lines you care about, so you can subscribe to it in Google Calendar. See `GLOSSARY.md` for terminology.

## Data source

Disruptions come from the GraphQL API behind the [S-Bahn Berlin](https://sbahn.berlin/) website (`https://api.sbahn.berlin/construction-api/query`). It is an unofficial, undocumented API discovered via the browser's network tab, so it may change without notice.

Without `--input-sbahn-berlin` the script queries the live API (`--api-url-sbahn-berlin` overrides the endpoint). `--input-sbahn-berlin <file>` reads a saved response instead, which the tests use. BVG lines (bus, tram, U-Bahn) work the same way with `--api-url-bvg` and `--input-bvg`. An operator is only queried if the watchlist needs it; if any queried operator fails, the whole run fails and the existing feed is kept.

## Subscribing in Google Calendar

The workflow [`update-calendar.yml`](.github/workflows/update-calendar.yml) runs every 30 minutes (and on manual dispatch), rebuilds `calendar.ics` and commits it only when it changed. The watchlist lives in the workflow's `STATIONS`, `LINES` and `DAYS` env vars (comma-separated lists).

In Google Calendar choose *Other calendars → From URL* and paste:

```
https://raw.githubusercontent.com/marcobiedermann/sbahn-berlin-disruptions/main/calendar.ics
```

The repository must be public for this URL to work. Google refreshes subscribed calendars only every several hours, so updates are not instant.

## Requirements

`bash`, `curl` and `jq` to run the script. `perl` and [`shellcheck`](https://www.shellcheck.net/) (e.g. `brew install shellcheck`) for the tests and the pre-commit hook. Nothing else.

## Usage

```bash
scripts/build-calendar.sh --output <feed.ics> [--station <name> ...] [--line <label> ...] [--days <n>] [--now <timestamp>] [--input-sbahn-berlin <api-response.json>] [--input-bvg <bvg-response.json>] [--api-url-sbahn-berlin <url>] [--api-url-bvg <url>]
```

| Flag        | Description                                                                    | Example                                    |
| ----------- | ------------------------------------------------------------------------------ | ------------------------------------------ |
| `--input-sbahn-berlin`| Saved API response (JSON); if omitted, the live API is queried                 | `--input-sbahn-berlin tests/fixtures/api-response.json` |
| `--api-url-sbahn-berlin`| GraphQL endpoint to query when `--input-sbahn-berlin` is absent                             | `--api-url-sbahn-berlin https://api.sbahn.berlin/construction-api/query` |
| `--output`  | Path of the `.ics` feed to write (required)                                    | `--output calendar.ics`                    |
| `--station` | Station name; repeatable. At least one `--station` or `--line` is required     | `--station Schöneweide --station Westkreuz` |
| `--input-bvg` | Saved BVG response (JSON); if omitted, the live BVG API is queried | `--input-bvg tests/fixtures/bvg-response.json` |
| `--api-url-bvg` | BVG endpoint to query when `--input-bvg` is absent | `--api-url-bvg https://www.bvg.de/disruption-reports-service/disruptions/v1/de` |
| `--line`    | Line label, case-insensitive; repeatable. `S9` (S-Bahn), `U2` (U-Bahn), `"Tram M10"`, `"Bus 160"` | `--line S9 --line "Bus 160" --line "Bus 163"` |
| `--days`    | Horizon length in days from now (1 to 14, default `14`)                                 | `--days 7`                                 |
| `--now`     | UTC timestamp to use as "now" (default: current time), for reproducible runs   | `--now 2026-10-22T12:00:00Z`               |

A consequence is included if it affects any given station or any given line (union, each consequence appears once). Pass several stations or lines by repeating the flag.

Stations are resolved by name, so you never need internal IDs. Matching ignores case and the `S `/`S+U `/`U ` prefix: `Schöneweide` matches `S Schöneweide` but not `S Schöneweide Betriebsbahnhof`. Lines match exactly. Only events overlapping the horizon (`--now` up to `--now` + `--days`) are written; an event that overlaps is kept in full, everything else is dropped. Unknown or ambiguous stations, unknown lines, invalid arguments, malformed input and API error responses make the script exit non-zero with a message (suggestions or the list of known lines where useful); the existing output file is never overwritten on failure.

Example using the bundled fixture:

```bash
scripts/build-calendar.sh --input-sbahn-berlin tests/fixtures/api-response.json --output /tmp/feed.ics --station Schöneweide --line S9
```

## Events

- A continuous period becomes one event; a daily repeating period (e.g. "täglich 08:00 - 16:00") becomes one event per day. Overnight windows (22:00 - 01:30) end on the following day.
- Times are Europe/Berlin local time (`TZID`), so daily windows keep their wall-clock time across the daylight saving change. The script sets `TZ` itself; your machine's time zone doesn't matter.
- Summary: `S9 · Schöneweide ⇄ Flughafen BER · Ersatzverkehr`. The description has the period, lines, affected stations, line links and the last update. Events are marked as free.

## Tests

```bash
tests/run.sh
```

To run it automatically before every commit (shellcheck + tests), enable the bundled hook once: `git config core.hooksPath .githooks`. CI runs the same checks on pull requests.

The tests call the script through its command line with `tests/fixtures/api-response.json` and compare the output to the files in `tests/golden/` (after undoing line folding), and also check line length, CRLF endings, deterministic output and error handling.


BVG disruptions without an end date become an all-day event on their start day. Only the BVG type `TRAFFIC` is used (elevator messages are ignored). Stations are S-Bahn only.
