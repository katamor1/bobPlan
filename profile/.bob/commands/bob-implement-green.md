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
2. Run `Invoke-Vc6Build.ps1 -WorkPacket $1 -Action Make -Attempt 0`. On `SUCCEEDED`, retain evidence and proceed to final Rebuild. On `CODE_FAILED_RETRYABLE`, inspect only generated evidence; `CODE_FAILED_STOP`, `ENVIRONMENT_FAILED`, `TIMED_OUT`, or `INTEGRITY_FAILED` stops the task.
3. At most two evidence-based repairs are allowed. If and only if attempt 0 is `CODE_FAILED_RETRYABLE`, make one evidence-based repair, then run `Invoke-Vc6Build.ps1 -WorkPacket $1 -Action Make -Attempt 1`. Apply the same status handling. This is repair cycle 1.
4. If and only if attempt 1 is `CODE_FAILED_RETRYABLE`, make the second and final evidence-based repair, then run `Invoke-Vc6Build.ps1 -WorkPacket $1 -Action Make -Attempt 2`. `CODE_FAILED_RETRYABLE` is now `CODE_FAILED_STOP`; every other non-success status also stops. This is repair cycle 2: no further edits or Make attempts.
5. Final Rebuild: after a successful Make (attempt 0, 1, or 2), run `Invoke-Vc6Build.ps1 -WorkPacket $1 -Action Rebuild -Attempt 2`. Require `SUCCEEDED`; `CODE_FAILED_RETRYABLE`, `CODE_FAILED_STOP`, `ENVIRONMENT_FAILED`, `TIMED_OUT`, and `INTEGRITY_FAILED` all stop the task.

Emit `READY_FOR_HUMAN_REVIEW` only after success and integrity verification. Never run Bazaar mutation commands, commit, merge, tag, attach a debugger, or access actual machines, control networks, mainline, or secrets.

## Stop Conditions

- Stop on missing evidence, forbidden impact, environment failure, timeout, integrity failure, or non-retryable code failure.
