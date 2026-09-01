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

## Fix round 1/5: security and integrity hardening

Implementation commit: `264760f fix: harden VC6 build and Bazaar evidence`.

### Files changed

- `profile/team-bob/tools/TeamBob-BuildCommon.ps1`
- `profile/team-bob/tools/Invoke-Vc6Build.ps1`
- `profile/team-bob/tools/Export-BazaarEvidence.ps1`
- `tests/Test-BuildTools.ps1`
- This report

### Implementation

- Added handle-based Windows final-path resolution and per-component reparse-point refusal for the existing source, sandbox, and log roots. Pairwise containment is checked on physical paths before the wrapper creates a result, task, attempt, sandbox, or log directory. A runtime junction-alias test covers the boundary when junction creation is permitted by the host policy.
- Reworked process waiting so normal completion, timeout, tree termination, parent grace, and redirected-output collection are all bounded. Timeout directly invokes the fixed System32 `taskkill.exe /PID <ownedPid> /T /F` path without a shell or name search, records `terminationComplete`, and never performs an unbounded wait or task result read.
- Takes the protected source, Allowed File, and `.bzr` baseline before the first Bazaar query. Build postflight now executes from `finally`, proves integrity before and after postflight queries, and converts deletion, unreadability, query failure, or any inability to prove non-mutation to `INTEGRITY_FAILED / 30`.
- Queries and compares `status --short`, `nick`, and `version-info --custom --template={revision_id}` before and after a build. The exact branch nick and full revision ID must match the canonical Work Packet and remain unchanged.
- Evidence export now has a Bazaar-only environment-validation path, always performs its non-mutation proof even after a native Bazaar failure, and propagates the native failure exit code only when integrity remains proven. `bzr diff` accepts exit `0` or `1`, and the manifest records the actual accepted exit code.
- Reads the raw VC6 `/OUT` log with strict CP932 decoding, leaves the original bytes untouched as evidence, configures redirected standard output/error for CP932 when supported, and fails undecodable logs safely.
- Makes retryable compiler/linker attribution require an exact normalized relative source/object path, or a bare source/object name that is globally unique across the protected source inventory. Duplicate-basename and exact-object-path behavior tests prevent ambiguous retry classification.
- Strictly validates every Forbidden Areas entry as a nonempty relative path/token with no rooted form, `.`/`..` segment, or control character, then enforces it against Allowed Files.
- Verifies the qualified project file and every Allowed File exists in the new sandbox and has the same SHA-256 as its source before MSDEV starts.
- Makes result JSON durability part of the success invariant. A result-write failure emits `INTEGRITY_FAILED` and exits `30`; it can no longer claim `SUCCEEDED` without durable evidence.
- The tracked build-target catalog remains empty and the tracked example remains disabled. No real VC6 or Bazaar executable was invoked, and tests continued to use runtime fakes, temporary installed repository copies, temporary `LOCALAPPDATA`, and CP932/BOM-free/CRLF fixtures.

### TDD RED

The review regressions and enhanced runtime fakes were added before the production hardening. The first focused run failed on the newly required Bazaar identity query sequence:

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\tests\Test-BuildTools.ps1
```

Exit code: `1`.

```text
ASSERTION FAILED: Build proves pre/post status, branch, and full revision using read-only queries (expected 'status --short|nick|version-info --custom --template={revision_id}|status --short|nick|version-info --custom --template={revision_id}', got 'status --short|status --short')
```

Final self-review exposed a missing control-character variant, so that regression was also added before its validator fix. The same focused command exited `1` with:

```text
ASSERTION FAILED: Forbidden Areas control-character entry uses the fixed process exit code; result message: Exception calling "IsPathRooted" with "1" argument(s): "Illegal characters in path." (expected '30', got '20')
```

This demonstrated that the tab control character reached a Windows path API and was incorrectly mapped to an environment failure. Production now rejects all `U+0000..U+001F` and `U+007F` controls before path parsing.

### Focused GREEN

Windows PowerShell 5.1:

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\tests\Test-BuildTools.ps1
```

```text
PASS: 229 total package, tool, build, and evidence assertions succeeded.
```

Exit code: `0`.

PowerShell 7:

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -File .\tests\Test-BuildTools.ps1
```

```text
PASS: 229 total package, tool, build, and evidence assertions succeeded.
```

Exit code: `0`.

### Final full-suite GREEN

Windows PowerShell 5.1:

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\tests\Test-Package.ps1
```

```text
PASS: 301 package contract assertions succeeded.
PASS: 394 total package and tool assertions succeeded.
PASS: 623 total package, tool, build, and evidence assertions succeeded.
```

Exit code: `0`.

PowerShell 7:

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -File .\tests\Test-Package.ps1
```

```text
PASS: 301 package contract assertions succeeded.
PASS: 394 total package and tool assertions succeeded.
PASS: 623 total package, tool, build, and evidence assertions succeeded.
```

Exit code: `0`.

### Status-case and finding coverage

- `SUCCEEDED / 0`: still requires durable result JSON, exact Bazaar identity/status, strict postflight proof, qualified success evidence, and all expected artifacts.
- `CODE_FAILED_RETRYABLE / 10`: exact relative source/object path or globally unique bare name, including a CP932 Japanese Allowed File path.
- `CODE_FAILED_STOP / 11`: duplicate/ambiguous bare basename and unrelated compiler failures.
- `ENVIRONMENT_FAILED / 20`: undecodable CP932 log and existing qualified environment/build failures; raw log bytes remain intact.
- `TIMED_OUT / 21`: a fake MSDEV child inherits redirected handles; the owned process tree is terminated and output collection returns within the test bound.
- `INTEGRITY_FAILED / 30`: physical junction alias, first-query mutation, pre/post Bazaar identity mismatch, postflight query failure, source mutation/deletion, unsafe/control Forbidden Areas, sandbox exclusion of an Allowed File, and result persistence failure.
- Evidence: works with MSDEV absent, accepts and records diff exit `1`, rejects Work Packet/Bazaar identity mismatch, propagates an intact native exit `47`, and overrides it with `30` when the same failing query mutates protected state.

### Self-review

- Re-read each Critical/Important/Minor finding and controller-confirmed gap against the final diff and its behavior case.
- Confirmed final physical paths are resolved through directory handles, every existing component is checked for a reparse point, and all pairwise comparisons happen before any wrapper-owned directory creation.
- Confirmed every process wait is finite; async text tasks are read only after bounded completion; termination targets only the retained owned PID and its tree; no process-name lookup exists.
- Confirmed protected snapshots precede every wrapper Bazaar query set and finally-style postflight cannot be bypassed by MSDEV failure, Bazaar failure, deletion, or unreadability.
- Confirmed the only Bazaar commands remain the approved read-only sets and the local evidence path does not validate MSDEV existence/hash.
- Confirmed the wrapper has no caller-supplied executable, project, target, timeout, root, or log parameter; no `Invoke-Expression`, shell, command-script execution, Bazaar mutation, recursive production deletion, or enabled tracked profile exists.
- Confirmed all changed PowerShell files parse in both Windows PowerShell 5.1 and PowerShell 7, `git diff --check` is clean, and both final test suites passed after the last production change.

### Concerns

- Actual `MSDEV.COM` switches, output encodings, process-tree behavior, logs, and artifacts remain qualification-gated because this environment has no real VC6/Bazaar installation. No real build profile is enabled.
- PowerShell 5.1 still requires a safely quoted `ProcessStartInfo.Arguments` representation of the fixed argument array because it lacks `ArgumentList`; executable selection remains separate and `UseShellExecute=false`.
- Per-attempt sandboxes and logs remain intentionally retained. If fixed `taskkill.exe` cannot complete tree termination within its bound, the result records `terminationComplete=false` and never reports success.

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

## Fix round 2: reject UNC and network aliases

### Files

- `profile/team-bob/tools/TeamBob-BuildCommon.ps1`
- `profile/team-bob/tools/Invoke-Vc6Build.ps1`
- `tests/Test-BuildTools.ps1`
- This report

No Task 4 document or implementation file was changed.

### Implementation

- The common canonical-path boundary now rejects lexical UNC, slash-normalized UNC, extended UNC, `\??\UNC`, `\GLOBAL??\UNC`, and resolved NT redirector forms for MUP, Lanman, WebDAV, RDR, DFS, and device UNC paths before filesystem access.
- Drive-letter paths remain supported, but `GetDriveTypeW` rejects a drive Windows identifies as remote. Local fixed drives and local SUBST mappings remain valid.
- Handle-based final-path resolution performs the same network-device rejection after resolving an existing path, preserving the prior reparse-component checks and physical overlap comparison.
- Registered Bazaar and MSDEV executable files now pass through the physical-path boundary as leaves, closing local symlink/junction/redirector routes that lexical validation alone would miss. Bazaar-only evidence still does not require MSDEV existence or hash validation.
- `LOCALAPPDATA`, the Work Packet path, canonical Bazaar root, local environment tool/root fields, and joined project/artifact/Allowed File paths all flow through the local-only canonical boundary. The build wrapper canonicalizes the Work Packet path before calling `Test-Path`, so a caller-supplied UNC packet path is refused before share access.
- Tests use only literal `.invalid` hostnames and raw device-form strings; they do not create or contact an SMB share. Integration cases cover Work Packet Bazaar root, registered MSDEV/Bazaar paths, sandbox/log roots, and project/artifact paths.

### TDD RED

The installed-helper regressions were added before production changes.

Command:

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\tests\Test-BuildTools.ps1
```

Exit code: `1`.

Observed output:

```text
ASSERTION FAILED: Common path boundary rejects lexical UNC without accessing a share
At C:\Users\stell\source\repos\bobPlan\tests\Test-BuildTools.ps1:5 char:116
```

The failure demonstrated that `Get-TeamBobCanonicalPath` returned the UNC form instead of refusing it.

### Focused GREEN

Windows PowerShell 5.1:

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\tests\Test-BuildTools.ps1
```

```text
PASS: 277 total package, tool, build, and evidence assertions succeeded.
```

Exit code: `0`.

PowerShell 7:

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -File .\tests\Test-BuildTools.ps1
```

```text
PASS: 277 total package, tool, build, and evidence assertions succeeded.
```

Exit code: `0`.

### Full-suite GREEN

Windows PowerShell 5.1:

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\tests\Test-Package.ps1
```

```text
PASS: 301 package contract assertions succeeded.
PASS: 394 total package and tool assertions succeeded.
PASS: 671 total package, tool, build, and evidence assertions succeeded.
```

Exit code: `0`.

PowerShell 7:

```powershell
pwsh -NoLogo -NoProfile -NonInteractive -File .\tests\Test-Package.ps1
```

```text
PASS: 301 package contract assertions succeeded.
PASS: 394 total package and tool assertions succeeded.
PASS: 671 total package, tool, build, and evidence assertions succeeded.
```

Exit code: `0`.

### SUBST compatibility check

A temporary local SUBST drive was mapped only to a GUID directory under the system temporary root. The common physical resolver accepted the drive and returned the same NT physical path as the direct local path:

```text
PASS: local SUBST drive remains accepted and resolves to the same physical NT path.
```

The mapping and empty temporary directory were removed in `finally`.

### Self-review

- Confirmed all changed behavior is confined to Task 3 common/build code, Task 3 behavior tests, and this report; Task 4 was untouched.
- Confirmed every externally supplied or derived Task 3 filesystem path reaches either the local canonical boundary, the safe-relative boundary rooted beneath a local canonical path, or both.
- Confirmed physical source/sandbox/log and registered executable paths reject reparse components and resolved network-device forms. Pairwise physical overlap checks and SUBST resolution remain intact.
- Confirmed no real VC6/Bazaar executable or SMB share was invoked, no enabled tracked build profile was introduced, and no shell/expression or process-name termination path was added.
- Confirmed changed PowerShell files parse in Windows PowerShell 5.1 and PowerShell 7, `git diff --check` is clean, and focused/full suites passed in both engines after the production change.

### Concerns

- Actual VC6/Bazaar behavior remains qualification-gated; no real profile is enabled.
- Network paths are intentionally unsupported for this dedicated-PC PoC, including legitimate UNC shares and mapped remote drives.
