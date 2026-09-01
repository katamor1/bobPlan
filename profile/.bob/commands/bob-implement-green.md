---
description: Run the constrained Green legacy C/C++ edit and local build loop.
argument-hint: <work-packet-path>
---
# /bob-implement-green

## Input

- Work-packet path: `$1`.

## Preconditions

- Parse the canonical JSON object in `$1` and validate it with `team-bob/config/work-packet.schema.json`.
- Require Green risk, empty Open QA, YES impact-clear fields, YES Clean Working Copy, both approvers, and both explicit YES approvals.

## Context

- Read only targeted source and build-profile context named by the packet.
- Work Packet Allowed Files is mandatory. Edit only allowed `.c`, `.cc`, `.cpp`, `.cxx`, `.h`, `.hh`, `.hpp`, `.hxx`, or `.inl` files; never edit `.rc`, `.dsp`, `.dsw`, `.def`, `.idl`, `.mak`, or any file outside Allowed Files.

## Output

- Write only allowed legacy source/header edits and `team-bob-work/<Task>/results/build-result.md`.

## Green Workflow

1. Edit only the approved legacy source/header files and preserve CP932, no BOM, and CRLF.
2. Make with the approved local build profile.
3. At most two evidence-based repairs may follow a retryable code failure.
4. Final Rebuild and integrity verification are required.

Emit `READY_FOR_HUMAN_REVIEW` only after success and integrity verification. Never run Bazaar mutation commands, commit, merge, tag, attach a debugger, or access actual machines, control networks, mainline, or secrets.

## Stop Conditions

- Stop on missing evidence, forbidden impact, environment failure, timeout, integrity failure, or non-retryable code failure.
