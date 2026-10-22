# Adapters

Bash, curl and jq are the only code. Each Operator has one adapter in `scripts/lib/`; shared helpers live in `scripts/lib/common.sh`.

Adapter interface: arguments in, events JSON array on stdout, `die` on any failure.

Endpoints and response shapes: `api-notes.md`. Design decisions: `docs/adr/`.
