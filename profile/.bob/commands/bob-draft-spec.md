---
description: Draft an evidence-backed external specification.
argument-hint: <work-packet-path>
---
# /bob-draft-spec

## Input

- Work-packet path: `$1`.

## Preconditions

- Parse the canonical JSON object in `$1` and validate it with `team-bob/config/work-packet.schema.json`.

## Context

- Read only targeted ReqIDs and linked ledger evidence from the packet.

## Output

- Write only `team-bob-work/<Task>/drafts/external-spec.md` from the template.

## Stop Conditions

- Stop without output on missing evidence, baseline, or required human approval.
