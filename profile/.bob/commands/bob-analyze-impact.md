---
description: Analyze targeted engineering and delivery impacts.
argument-hint: <work-packet-path>
---
# /bob-analyze-impact

## Input

- Work-packet path: `$1`.

## Preconditions

- Parse the canonical JSON object in `$1` and validate it with `team-bob/config/work-packet.schema.json`.

## Context

- Inspect only targeted files, branch metadata, and requirement evidence named by the packet.

## Output

- Write only `team-bob-work/<Task>/drafts/impact-analysis.md` from the template.

## Stop Conditions

- Stop without output on missing evidence or an impact that cannot be classified.
