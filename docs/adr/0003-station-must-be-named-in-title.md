# A station match requires the station in the consequence title

The S-Bahn API links a station to every consequence whose text mentions it, including the "Alternative Fahrtmöglichkeit" advice (e.g. the N60 night bus). "S9 Alexanderplatz <> Treptower Park" was therefore linked to Schöneweide although no train service at Schöneweide is affected.

A consequence now matches a station only if the station is one of the stops named in the consequence title (split on `<>`, `>` and `/`, compared with the same normalisation as station resolution). "Schöneweide" does not match "Schöneweide Betriebsbahnhof". Line matching is unchanged, and the "Bahnhöfe:" line of an event lists only the stations that passed this check.

Trade-off: a disruption that passes through a station without naming it in the title (e.g. "Grünau <> Ostkreuz") no longer matches that station. We accept this over calendar noise. Rejected: trusting the API links as they are (the bug above), and deriving stops between the title's endpoints (the API exposes no route topology).
