# One feed for all operators, failing whole on any operator error

The calendar combines S-Bahn Berlin and BVG (bus, tram, U-Bahn) disruptions in a single feed ("Berlin ÖPNV Störungen"), so subscribers add one URL. Following ADR 0001, if any queried operator fails the whole run fails and the previous feed is kept, rather than publishing a feed silently missing one operator's disruptions. Operators are only queried when the watchlist needs them.

BVG items without an end date become an all-day event on their start day instead of being dropped or stretched to the horizon, and BVG text is not parsed for daily windows.
