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
- Select this shipped custom mode only after a human has qualified and enabled the requested PC-matched build profile. The mode is present; the shipped build catalog is empty and disabled.

## Context

- Read only targeted source and build-profile context named by the packet.
- Work Packet Allowed Files is mandatory. Edit only allowed `.c`, `.cc`, `.cpp`, `.cxx`, `.h`, `.hh`, `.hpp`, `.hxx`, or `.inl` files; never edit `.rc`, `.dsp`, `.dsw`, `.def`, `.idl`, `.mak`, or any file outside Allowed Files.

## Output

- Write only allowed legacy source/header edits and `team-bob-work/<Task>/results/build-result.md`.

## Green Workflow

1. Edit only the approved legacy source/header files and preserve CP932, no BOM, and CRLF. Set the shared repair-budget counter `N = 0`.
2. Run Make `N` with this installed-tool invocation:

   ```powershell
   powershell.exe -NoLogo -NoProfile -NonInteractive -File "<Bazaar-root>\team-bob\tools\Invoke-Vc6Build.ps1" -WorkPacket "$1" -Action Make -Attempt N
   ```

   On `SUCCEEDED`, immediately run Rebuild with the same `N`:

   ```powershell
   powershell.exe -NoLogo -NoProfile -NonInteractive -File "<Bazaar-root>\team-bob\tools\Invoke-Vc6Build.ps1" -WorkPacket "$1" -Action Rebuild -Attempt N
   ```

3. Make and Rebuild use one shared repair budget. If either action returns `CODE_FAILED_RETRYABLE` and `N < 2`, inspect its generated evidence, make exactly one evidence-based repair within Allowed Files, increment N, and return to Make N. Do not retry Rebuild directly.
4. If either action returns `CODE_FAILED_RETRYABLE` when `N = 2`, handle it as `CODE_FAILED_STOP` and stop. `CODE_FAILED_STOP`, `ENVIRONMENT_FAILED`, `TIMED_OUT`, and `INTEGRITY_FAILED` always stop immediately and preserve evidence.
5. Only a successful final Rebuild plus its integrity verification permits `READY_FOR_HUMAN_REVIEW`. A successful Make alone is not final success.

Never run Bazaar mutation commands, commit, merge, tag, attach a debugger, or access actual machines, control networks, mainline, or secrets.

## Stop Conditions

- Stop on missing evidence, forbidden impact, environment failure, timeout, integrity failure, or non-retryable code failure.
