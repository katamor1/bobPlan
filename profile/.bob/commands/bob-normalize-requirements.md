---
description: Normalize immutable requirement evidence into a ledger.
argument-hint: <work-packet-path>
---
# /bob-normalize-requirements

## Input

- Work-packet path: `$1`.

## Preconditions

- Parse the canonical JSON object in `$1` and validate it with `team-bob/config/work-packet.schema.json`.

## Context

- Read only targeted baseline and source evidence named by the packet.

## Output

- Write only `team-bob-work/<Task>/drafts/requirement-ledger.csv` from the template.

## Stop Conditions

- Stop without output on missing evidence, baseline, or required human approval.
