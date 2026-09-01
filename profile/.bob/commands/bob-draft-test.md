---
description: Draft a traceable test specification.
argument-hint: <work-packet-path>
---
# /bob-draft-test

## Input

- Work-packet path: `$1`.

## Preconditions

- Parse the canonical JSON object in `$1` and validate it with `team-bob/config/work-packet.schema.json`.

## Context

- Use only targeted requirement, impact, and design evidence.

## Output

- Write only `team-bob-work/<Task>/drafts/test-spec.md` from the template.

## Stop Conditions

- Stop without output on missing evidence, acceptance criteria, impact evidence, or approvals.
