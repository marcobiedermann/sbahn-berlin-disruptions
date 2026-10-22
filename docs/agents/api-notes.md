# S-Bahn Berlin API notes

Unofficial, undocumented GraphQL endpoint: `POST https://api.sbahn.berlin/construction-api/query`. Verified live in October 2026.

- Send `origin: https://sbahn.berlin`, `referer: https://sbahn.berlin/` and a user-agent, as the website does.
- Variables: `{"language":"GERMAN"}`. The query the script sends is in `scripts/build-calendar.sh`.
- Errors arrive as HTTP 200 with a top-level `errors` array; the script treats them as failure.
- A **Station** has `id` and `t3Id`. Schöneweide is `id` 66 / `t3Id` 150; `id` 150 is "S Sundgauer Straße". The script resolves stations by title, never by ID.
- Station titles carry a prefix (`S `, `S+U `, `U `). "Schöneweide Betriebsbahnhof" is a different station.
- Period `type` is `DEFAULT` (continuous) or `REPEATING_DAILY`. For daily periods `dateStart`/`dateEnd` give the date range plus the **Daily window** as time of day; `dateEnd` is the end of the last window (an overnight window ends on the next calendar day).
- Timestamps are UTC (`+00:00`).
- `tests/fixtures/api-response.json` is a trimmed response with the same shape; extend it when you need a new case.

# BVG API notes

Unofficial JSON endpoint: `GET https://www.bvg.de/disruption-reports-service/disruptions/v1/de?type=TRAFFIC&timeFrame=FORTNIGHT&page=N`. Verified live in October 2026; no cookies needed.

- Pages are 1-based. The response is `{elements, numFound, numPages, page}`; the script follows `numPages` and merges `elements`.
- `type=TRAFFIC` excludes elevator messages; `timeFrame=FORTNIGHT` is the widest window that covers `--days` 14. Lines are filtered locally.
- `lines` is an array of mode groups (`bus`, `tram`, `subway`), each with `[{name, slug, lineType, isExternal}]`. Subway names are bare (`U2`). Metro lines such as M1 exist as both tram and bus, and tram 12 differs from bus 12, so the script matches on mode plus name. An item can span several modes.
- `startDate`, `endDate` (often absent) and `modDate` are offset timestamps, some with fractional seconds. No `endDate` means open-ended.
- `content[].headline` and `.content` are HTML (including `bds-signet-*` tags); `disruptionTypes[].displayName`, `stationOne`/`stationTwo.displayName` give extra context.
- `tests/fixtures/bvg-response.json` is a trimmed response with the same shape.
