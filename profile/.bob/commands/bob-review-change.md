---
description: Produce an evidence-backed change review.
argument-hint: <work-packet-path>
---
# /bob-review-change

## Input

- Work-packet path: `$1`.

## Preconditions

- Parse the canonical JSON object in `$1` and validate it with `team-bob/config/work-packet.schema.json`.

## Context

- Inspect only targeted Allowed Files and linked requirement evidence.

## Output

- Write only `team-bob-work/<Task>/drafts/code-review.md` from the template and review rubric.

## Stop Conditions

- Stop without output on missing evidence, diff evidence, or traceability evidence.
