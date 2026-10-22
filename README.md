# sbahn-berlin-disruptions

Builds an iCalendar feed of S-Bahn Berlin disruptions (consequences) for the lines you care about, so you can subscribe to it in Google Calendar. See `GLOSSARY.md` for terminology.

## Data source

Disruptions come from the GraphQL API behind the [S-Bahn Berlin](https://sbahn.berlin/) website (`https://api.sbahn.berlin/construction-api/query`). It is an unofficial, undocumented API discovered via the browser's network tab, so it may change without notice.

> Work in progress: so far the script reads a saved API response. The live API fetch and the scheduled workflow are tracked in the open issues.

## Requirements

`bash`, `jq` and `perl` (tests only). Nothing else.

## Usage

```bash
scripts/build-calendar.sh --input <api-response.json> --output <feed.ics> [--station <name> ...] [--line <label> ...] [--days <n>] [--now <timestamp>]
```

| Flag        | Description                                                                    | Example                                    |
| ----------- | ------------------------------------------------------------------------------ | ------------------------------------------ |
| `--input`   | Saved response of the S-Bahn Berlin GraphQL API (JSON, required)               | `--input tests/fixtures/api-response.json` |
| `--output`  | Path of the `.ics` feed to write (required)                                    | `--output calendar.ics`                    |
| `--station` | Station name; repeatable. At least one `--station` or `--line` is required     | `--station Schöneweide --station Westkreuz` |
| `--line`    | Line label; repeatable                                                         | `--line S9 --line S85`                     |
| `--days`    | Horizon length in days from now (default `14`)                                 | `--days 7`                                 |
| `--now`     | UTC timestamp to use as "now" (default: current time), for reproducible runs   | `--now 2026-10-22T12:00:00Z`               |

A consequence is included if it affects any given station or any given line (union, each consequence appears once). Pass several stations or lines by repeating the flag.

Stations are resolved by name, so you never need internal IDs. Matching ignores case and the `S `/`S+U `/`U ` prefix: `Schöneweide` matches `S Schöneweide` but not `S Schöneweide Betriebsbahnhof`. Lines match exactly. Only events overlapping the horizon (`--now` up to `--now` + `--days`) are written; an event that overlaps is kept in full, everything else is dropped. Unknown or ambiguous stations, unknown lines, invalid arguments, malformed input and API error responses make the script exit non-zero with a message (suggestions or the list of known lines where useful); the existing output file is never overwritten on failure.

Example using the bundled fixture:

```bash
scripts/build-calendar.sh --input tests/fixtures/api-response.json --output /tmp/feed.ics --station Schöneweide --line S9
```

## Events

- A continuous period becomes one event; a daily repeating period (e.g. "täglich 08:00 - 16:00") becomes one event per day. Overnight windows (22:00 - 01:30) end on the following day.
- Times are Europe/Berlin local time (`TZID`), so daily windows keep their wall-clock time across the daylight saving change. The script sets `TZ` itself; your machine's time zone doesn't matter.
- Summary: `S9 · Schöneweide ⇄ Flughafen BER · Ersatzverkehr`. The description has the period, lines, affected stations, line links and the last update. Events are marked as free.

## Tests

```bash
tests/run.sh
```

The tests call the script through its command line with `tests/fixtures/api-response.json` and compare the output to the files in `tests/golden/` (after undoing line folding), and also check line length, CRLF endings, deterministic output and error handling.
