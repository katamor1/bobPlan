# Task 3 report: VC6 build wrapper and Bazaar evidence utilities

## Status

Implemented the configuration-only VC6 Make/Rebuild wrapper and read-only Bazaar evidence exporter. The tracked build-target catalog remains empty, the tracked example remains disabled, and all behavior tests use runtime-generated fake executables in isolated temporary installed repository copies and temporary `LOCALAPPDATA` trees.

## Files

- Added `profile/team-bob/tools/Invoke-Vc6Build.ps1`.
- Added `profile/team-bob/tools/Export-BazaarEvidence.ps1`.
- Added `profile/team-bob/tools/TeamBob-BuildCommon.ps1`.
- Added `tests/Test-BuildTools.ps1`.
- Extended `profile/team-bob/tools/Test-TeamBobProfile.ps1` to require the installed Task 3 utilities.
- Extended `tests/Test-Package.ps1` to include the Task 3 package files and behavior suite.
- Added this report.

## Implementation

### VC6 build wrapper

- Exposes only the approved `-WorkPacket`, `-Action Make|Rebuild`, and `-Attempt 0..2` interface.
- Parses the exact canonical work-packet JSON fields, enforces all Green/Open-QA/approval/impact/repair-budget gates, and resolves the exact `Build Profile ID` from the installed `vc6-build-targets.json`.
- Consumes the exact flat local registration fields, including `pcId`, and verifies profile/schema identity, current-machine identity, tool existence, and SHA-256 hashes.
- Requires a unique enabled profile whose five qualification booleans are true and whose PC/record metadata is complete and matches both the current machine and local registration.
- Validates relative project/artifact paths, a present `.dsw`/`.dsp`, target, positive timeout, expected artifacts, exclusions, and all qualified regexes.
- Rejects source/sandbox/log equality, containment, or nesting before creating an attempt directory. Each sandbox/log directory is new and GUID-qualified; the wrapper never recursively deletes one.
- Accepts only existing supported C/C++ Allowed Files within the Bazaar root; rejects forbidden/outside/duplicate/unsupported paths, reparse points, BOMs, invalid CP932, and non-CRLF newlines.
- Captures hashes, full source inventory excluding only `.bzr` and `team-bob-work`, `.bzr` inventory, Allowed File hashes, and normalized Bazaar status before and after the build.
- Allows only pre-existing short-status `M` changes whose normalized path is in Allowed Files. Added, removed, renamed, conflict, unknown, and out-of-scope entries fail integrity.
- Copies the working tree to a new external sandbox while excluding `.bzr`, `team-bob-work`, configured generated-output patterns, and expected artifact paths. The original working tree never receives VC6 output.
- Builds a fixed direct argument array for the selected `/MAKE` or `/REBUILD`, qualified target, and fixed `/OUT` log. `System.Diagnostics.Process` launches the registered executable directly without a shell or expression evaluation, drains stdout/stderr asynchronously, enforces the qualified timeout, and kills only its own retained process object when necessary.
- Stores stdout, stderr, configured build log, sandbox/log/result paths, command evidence, inventories, status, and hashes in a unique JSON result under the task `results` directory.
- Emits and persists exactly one fixed status mapping: `SUCCEEDED=0`, `CODE_FAILED_RETRYABLE=10`, `CODE_FAILED_STOP=11`, `ENVIRONMENT_FAILED=20`, `TIMED_OUT=21`, or `INTEGRITY_FAILED=30`.
- Treats compiler/linker evidence as retryable only when the matching line is attributable to an Allowed File/object and Attempt is below 2. Attempt 2 and unrelated/unclassifiable code failures stop.
- Requires both qualified success-log evidence and every expected sandbox artifact for success.

### Bazaar evidence exporter

- Exposes only `-WorkPacket`, resolves Bazaar solely from the fixed local environment, and verifies its registered hash before invocation.
- Runs exactly `status --short`, `diff`, `nick`, and `version-info --custom --template={revision_id}` in that order.
- Launches Bazaar directly, collects outputs in memory, refuses empty nick/revision evidence, and preserves a failed Bazaar command exit code as the script exit code.
- Fingerprints source and `.bzr` before and after all queries and publishes evidence only after non-mutation is proven.
- Writes BOM-free UTF-8 status, diff, nick, full revision-id, and manifest files under task `results`; the manifest records the exact full revision id, command list, and per-command exit codes.

## TDD RED

Tests and runtime fake MSDEV/Bazaar executable sources were added before production scripts.

Command:

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\tests\Test-Package.ps1
```

Exit code: `1`.

Observed output (the GUID temporary root is runtime-generated):

```text
PASS: 298 package contract assertions succeeded.
PASS: 391 total package and tool assertions succeeded.
ASSERTION FAILED: Build Make attempt 0 persists exactly one new JSON result (expected '1', got '0'). Invocation output:
powershell.exe : The argument '...\working-tree\team-bob\tools\Invoke-Vc6Build.ps1' to the -File parameter does not exist.
```

The failure was the expected missing-feature failure from the installed repository copy. Existing package/tool behavior, fake executable compilation, temporary installation, and isolated registration setup completed before the missing build entrypoint was invoked.

## Focused GREEN and compatibility iteration

Windows PowerShell 5.1:

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\tests\Test-BuildTools.ps1
```

```text
PASS: 156 total package, tool, build, and evidence assertions succeeded.
```

Exit code: `0`.

PowerShell 7:

```powershell
pwsh.exe -NoLogo -NoProfile -NonInteractive -File .\tests\Test-BuildTools.ps1
```

```text
PASS: 156 total package, tool, build, and evidence assertions succeeded.
```

Exit code: `0`.

PowerShell 7 initially exposed two engine differences. Its `Add-Type` cannot emit a console EXE, so the test now generates its fake EXEs through a temporary Windows PowerShell 5.1 compiler script. Its `ConvertFrom-Json` projects JSON integers as `Int64` rather than Windows PowerShell 5.1's `Int32`, so the production schema consumer accepts all CLR integer types while still rejecting fractional/string values. Both changes were rechecked in both engines.

## Status-case and behavior coverage

- `SUCCEEDED / 0`: Make and Rebuild, exact requested switch, success log evidence, expected artifact.
- `CODE_FAILED_RETRYABLE / 10`: attributable compile failure at Attempt 0 and link failure after Rebuild at Attempt 1.
- `CODE_FAILED_STOP / 11`: attributable compile failure at Attempt 2 and unrelated compiler failure.
- `ENVIRONMENT_FAILED / 20`: configured environment pattern, missing artifact, missing success evidence, missing project target, mismatched qualification PC, and mismatched MSDEV hash.
- `TIMED_OUT / 21`: bounded fake MSDEV delay with retained spawned PID evidence.
- `INTEGRITY_FAILED / 30`: BOM/lone-LF, invalid CP932, out-of-Allowed-Files modification, added/renamed/unknown/conflict status, source/sandbox overlap, and an attempted original-source mutation during the sandbox build.
- Sandbox exclusions: `.bzr`, `team-bob-work`, configured `*.pdb`, recursive `**/*.obj`, and stale expected artifacts.
- Original-tree stability: Allowed File hash, complete `.bzr` fingerprint, pre/post status, and absence of original-tree artifact.
- Bazaar evidence: exact four-command allowlist/order, exact status/diff/full-revision content, BOM-free UTF-8 files, manifest command/exit records, source/`.bzr` stability, Bazaar exit-code propagation, and pre-invocation hash refusal.

## Self-review

- Re-read the Task 3 brief line by line against the implemented entrypoints and shared helper.
- Confirmed the build wrapper parameter block contains only `WorkPacket`, `Action`, and `Attempt`; the evidence exporter contains only `WorkPacket`.
- Confirmed no `Invoke-Expression`, shell launcher, command-script execution, caller-provided tool/project/target/timeout/root/log parameter, or recursive production deletion exists.
- Confirmed the process executable is separate from its safely quoted direct argument array, stdout/stderr are drained concurrently, timeout uses the retained process object, and no process-name/PID lookup can kill an unrelated process.
- Confirmed build-time Bazaar use is exactly two `status --short` reads, while evidence use is exactly the four approved read-only queries. No production file contains a Bazaar mutation argument set.
- Confirmed the tracked `vc6-build-targets.json` still has zero profiles and the tracked example profile remains disabled.
- Confirmed temporary test cleanup first canonicalizes the GUID fixture beneath the system temp root. Tests restore every modified environment variable and never read/write real `LOCALAPPDATA`.
- Confirmed all repository edits were made through `apply_patch`; runtime fixture writers target only verified temporary roots.
- Confirmed every new/changed PowerShell file parses under Windows PowerShell 5.1 and `git diff --check` reports no whitespace errors.

## Concerns

- Actual `MSDEV.COM` switch/log/artifact semantics remain qualification-gated and intentionally unverified because no real VC6 installation is available. No real profile is enabled.
- PowerShell 5.1 lacks `ProcessStartInfo.ArgumentList`; the wrapper therefore derives the Windows command line from a fixed argument array using Windows quoting rules, while keeping the executable separate and `UseShellExecute=false`. It never invokes a shell or evaluates a command string.
- Per-attempt sandboxes and logs are retained by design for evidence and diagnosis; cleanup is deliberately outside the wrapper so it cannot recursively delete a user path.

## Final full-suite verification

Windows PowerShell 5.1:

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\tests\Test-Package.ps1
```

```text
PASS: 301 package contract assertions succeeded.
PASS: 394 total package and tool assertions succeeded.
PASS: 550 total package, tool, build, and evidence assertions succeeded.
```

Exit code: `0`.

PowerShell 7:

```powershell
pwsh.exe -NoLogo -NoProfile -NonInteractive -File .\tests\Test-Package.ps1
```

```text
PASS: 301 package contract assertions succeeded.
PASS: 394 total package and tool assertions succeeded.
PASS: 550 total package, tool, build, and evidence assertions succeeded.
```

Exit code: `0`.
