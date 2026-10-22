# sbahn-berlin-disruptions

Builds an iCalendar feed of S-Bahn Berlin disruptions (consequences) for the lines you care about, so you can subscribe to it in Google Calendar. See `GLOSSARY.md` for terminology.

## Data source

Disruptions come from the GraphQL API behind the [S-Bahn Berlin](https://sbahn.berlin/) website (`https://api.sbahn.berlin/construction-api/query`). It is an unofficial, undocumented API discovered via the browser's network tab, so it may change without notice.

> Work in progress: so far the script reads a saved API response and supports lines and continuous periods only. Stations, daily repeating periods, the horizon, the live API fetch and the scheduled workflow are tracked in the open issues.

## Requirements

`bash`, `jq` and `perl` (tests only). Nothing else.

## Usage

```bash
scripts/build-calendar.sh --input <api-response.json> --output <feed.ics> --line S9 [--line S85 ...]
```

| Flag       | Description                                                      | Example                                    |
| ---------- | ---------------------------------------------------------------- | ------------------------------------------ |
| `--input`  | Saved response of the S-Bahn Berlin GraphQL API (JSON, required) | `--input tests/fixtures/api-response.json` |
| `--output` | Path of the `.ics` feed to write (required)                      | `--output calendar.ics`                    |
| `--line`   | Line label; repeatable, at least one required                    | `--line S9 --line S85`                     |

A consequence is included if it affects any given line. You can pass multiple lines by repeating `--line`; multiple stations will work the same way with `--station` once it lands (#3), matching consequences for any station or any line. Unknown lines make the script exit non-zero and list the known lines; the existing output file is never overwritten on failure.

Example using the bundled fixture:

```bash
scripts/build-calendar.sh --input tests/fixtures/api-response.json --output /tmp/feed.ics --line S9
```

## Tests

```bash
tests/run.sh
```

The tests call the script through its command line with `tests/fixtures/api-response.json` and compare the output to the files in `tests/golden/` (after undoing line folding), and also check line length, CRLF endings, deterministic output and error handling.
