# Task 2 report: installer and task/bootstrap utilities

## Status

Implemented the Task 2 installer, fixed local-environment registration, task bootstrap, strict profile validator, and behavior-focused test coverage. No real Bazaar or MSDEV executable was invoked, and the tests isolated and restored `LOCALAPPDATA` and fake-tool controls.

## Implementation

- `scripts/Install-TeamBobProfile.ps1`
  - Installs the repository `profile` tree into an absolute target directory.
  - Preflights every destination as `CREATE`, `IDENTICAL`, or `CONFLICT` before any write.
  - Treats byte-identical files as idempotent no-ops and stops the whole install on any different file or file/directory collision.
  - Supports reporting-only `-WhatIf` and returns nonzero for invalid targets, invalid source layout, and conflicts.
  - Copies `.bobignore.base` and `.bzrignore.snippet` only under their snippet names; it never creates or merges `.bobignore` or `.bzrignore` and performs no Bazaar operation.
- `profile/team-bob/tools/Initialize-LocalEnvironment.ps1`
  - Validates absolute tool/root paths and existing MSDEV/Bazaar files.
  - Writes only `%LOCALAPPDATA%\IBM\BobTeamProfile\vc6-machine-control-poc\environment.json`.
  - Defines the Task 3-consumable flat environment contract: `schemaVersion`, profile/schema identities, canonical `msdevPath`, `bazaarPath`, `sandboxRoot`, `logRoot`, and lowercase SHA-256 hashes for both tool files.
  - Creates sandbox/log roots, preserves identical registrations byte-for-byte, refuses different registrations without `-Force`, and uses same-directory temporary file plus `File.Replace`/`File.Move` for atomic publication.
- `profile/team-bob/tools/Start-TeamBobTask.ps1`
  - Validates task identity, repair budget, required metadata, root containment, and supported legacy C/C++ extensions.
  - Resolves and hash-validates Bazaar from the fixed environment registration.
  - Runs only read-only `status --short`, `nick`, and `version-info --custom --template={revision_id}` in the supplied Bazaar root.
  - Refuses dirty trees, empty Bazaar identity, duplicate task directories, invalid/outside/unsupported allowed files, and incomplete Green gates.
  - Creates only `team-bob-work/<TaskId>/{drafts,results}` and an atomically published `work-packet.md` populated from the Task 1 template and exact schema field layout.
- `profile/team-bob/tools/Test-TeamBobProfile.ps1`
  - Derives its default repository root from the installed location and supports explicit root/build profile selection.
  - Emits one `PASS`, `FAIL`, or `SKIP` record per validation plus a summary.
  - Validates manifest identity, required package assets/tools, modes, JSON/schema shape, fixed local environment identity, tool existence/hashes, external sandbox/log roots, and requested build-profile enablement/qualification.
  - Requires the local environment under `-Strict`; an empty catalog is accepted only when no Build Profile ID is requested.

## Files

- Added `scripts/Install-TeamBobProfile.ps1`.
- Added `profile/team-bob/tools/Initialize-LocalEnvironment.ps1`.
- Added `profile/team-bob/tools/Start-TeamBobTask.ps1`.
- Added `profile/team-bob/tools/Test-TeamBobProfile.ps1`.
- Added `tests/Test-Tools.ps1`.
- Extended `tests/Test-Package.ps1` to keep it as the suite entrypoint.
- Added this report.

## TDD RED

Command:

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\tests\Test-Package.ps1
```

Observed exit code: `1`.

Observed output:

```text
PASS: 298 package contract assertions succeeded.
powershell.exe : The argument 'C:\Users\stell\source\repos\bobPlan\scripts\Install-TeamBobProfile.ps1' to the -File parameter does not exist.
```

Reason: the new behavior tests executed the real installer entrypoint before any Task 2 production script existed. The failure was the expected missing-feature failure, not an assertion typo or a real external-tool dependency.

## GREEN and verification

Focused iterations exercised the installer WhatIf path, environment initialization/force replacement, Strict validator check records, and the task bootstrap parser/fake-Bazaar path. The complete Windows PowerShell 5.1-compatible entrypoint was rerun after each correction.

Windows PowerShell 5.1 full suite:

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\tests\Test-Package.ps1
```

```text
PASS: 298 package contract assertions succeeded.
PASS: 361 total package and tool assertions succeeded.
```

Exit code: `0`.

PowerShell 7 full suite:

```powershell
pwsh.exe -NoLogo -NoProfile -NonInteractive -File .\tests\Test-Package.ps1
```

```text
PASS: 298 package contract assertions succeeded.
PASS: 361 total package and tool assertions succeeded.
```

Exit code: `0`.

Windows PowerShell 5.1 parser verification covered all four production scripts and `tests/Test-Tools.ps1`; every file reported `PASS` and the command exited `0`.

Default-location validator smoke check, with an isolated nonexistent LOCALAPPDATA registration, emitted eight passes, one expected non-Strict skip, `SUMMARY Passed=8 Failed=0 Skipped=1`, and exit code `0`.

## Self-review

- Compared the implementation line by line with the Task 2 exact interfaces and Task 1 contracts.
- Confirmed `Start-TeamBobTask.ps1` contains exactly the three allowed Bazaar query argument sets and no mutation command.
- Confirmed the installer never names `.bobignore`/`.bzrignore` as destinations and preserves a target `.bzr` marker across successful, idempotent, and conflict runs.
- Confirmed conflict tests prove all-file preflight: an otherwise missing destination stays missing when another destination conflicts.
- Confirmed tests use runtime fake `.cmd`/tool files only, operate beneath GUID-named temp roots, verify the root before recursive cleanup, and restore all modified environment variables.
- Confirmed no script accepts an alternate local-environment output path or direct build/tool command parameters.
- Confirmed the generated canonical packet uses all 36 Task 1 schema fields, exact field spelling, fixed profile version, and repair cycle value `2`.
- Ran `git diff --check`; no whitespace error was reported.

## Concerns

- The environment JSON shape is now the Task 3 contract and must be consumed without renaming its flat fields.
- Actual VC6/Bazaar qualification remains intentionally out of scope; the shipped build-target catalog remains empty, and tests use fake executables only.
- Atomic replacement uses the Windows/.NET same-volume `File.Replace` behavior with a short-lived backup that is removed immediately after successful replacement.

## Fix round 1/5

### Findings addressed

All reviewer and controller findings in round 1 were addressed:

1. Local initialization now derives the whole source repository boundary for `profile/team-bob/tools`, uses the installed target root for `team-bob/tools`, and rejects sandbox/log roots equal to or below that boundary.
2. Identical registration validation now checks root/file collisions and creates missing sandbox/log directories before returning `IDENTICAL`.
3. Task bootstrap now requires `<BazaarRoot>/.bzr` without adding a Bazaar command.
4. Every catalog profile, selected or not, is validated for exact fields, types, safe project/artifact paths, positive timeout, arrays, compilable regexes, and complete qualification shape.
5. Strict validation now requires absolute existing tool paths and absolute external sandbox/log roots before checking hashes/containment.
6. Directory canonicalization preserves volume roots such as `C:\`; the Allowed Files containment prefix does not append a second separator to a volume root.
7. Work-packet insertion uses a `MatchEvaluator`, so `$1`, `${2}`, `$&`, and related replacement metacharacters remain ordinary JSON data.
8. Every Allowed File must exist as a leaf beneath the Bazaar root.
9. The installer rejects its profile source directory and descendants before enumeration/preflight while still accepting an unrelated `profile` directory in an ordinary external target.
10. The flat environment contract now includes `pcId = [Environment]::MachineName`; Strict validation checks the registration machine and requires the selected qualification `pcId` to match it.

The build-target schema now declares `expectedArtifacts.minItems = 1`; the shipped catalog remains empty and the example remains disabled.

### Covering test names

- `Installer rejects its own profile source directory as TargetPath`
- `Rejected source-directory install leaves every source file unchanged`
- `Installer rejects a TargetPath beneath its profile source directory`
- `Rejected source-descendant install creates no directory`
- `Rejected source-descendant install leaves the source tree unchanged`
- `Installer accepts an ordinary target containing an unrelated profile directory`
- `Environment registration records stable machine identity`
- `Identical environment rerun recreates a deleted sandbox root`
- `Identical environment rerun restores the sandbox directory`
- `Identical environment rerun rejects a log root replaced by a file`
- `Environment initializer rejects roots inside the whole source repository`
- `Environment initializer rejects sandbox and log roots nested beneath each other`
- `Strict validator rejects relative tool paths even when they resolve and hash-match`
- `Strict validator rejects relative sandbox and log root registrations`
- `Strict validator rejects an environment registered for another machine`
- `Build-target schema requires at least one expected artifact`
- `Validator rejects malformed unselected catalog profiles`
- `Validator rejects a selected qualification recorded for another PC`
- `Validator accepts one complete enabled qualification for the registered PC`
- `Start task safely inserts regex-replacement metacharacters from metadata`
- `Metacharacter-bearing metadata round-trips exactly in canonical JSON`
- `Start task rejects an Allowed File that does not exist as a leaf`
- `Missing Allowed File rejection creates no task directory`
- `Start task requires the supplied BazaarRoot itself to contain the .bzr root marker`
- `Nested non-root rejection creates no task directory`

All tests run the real PowerShell entrypoints against GUID-named temp roots and runtime fake tool files. No real Bazaar/MSDEV process or real LOCALAPPDATA registration was used.

### TDD RED

Command:

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\tests\Test-Package.ps1
```

Exit code: `1`.

Output:

```text
PASS: 298 package contract assertions succeeded.
ASSERTION FAILED: Installer rejects its own profile source directory as TargetPath
```

The failure was the expected first newly exposed behavior: the pre-fix installer accepted its own profile source as a target. The test also fingerprints every source file to prove rejected attempts are non-mutating.

### GREEN and compatibility iteration

Windows PowerShell 5.1 after the fixes:

```text
PASS: 298 package contract assertions succeeded.
PASS: 391 total package and tool assertions succeeded.
```

PowerShell 7 initially exposed that its `ConvertFrom-Json` projects an ISO `recordedAt` JSON string to `[datetime]`, while Windows PowerShell 5.1 retains `[string]`. Validation now accepts only a nonempty string or that engine-produced datetime representation for `recordedAt`; the subsequent `pwsh` run produced:

```text
PASS: 298 package contract assertions succeeded.
PASS: 391 total package and tool assertions succeeded.
```

Fresh final command/output evidence is recorded below after the final pre-commit rerun.

### Fix-round self-review

- Re-read every round-1 finding against the staged behavior, not only test output.
- Confirmed the initializer source-layout boundary resolves to the parent of `profile`, while an installed layout resolves to the target root.
- Confirmed missing roots are recreated only after registration conflict handling and file collisions fail before an identical success response.
- Confirmed all catalog entries are checked even without `-BuildProfileId`; selected profiles additionally require unique selection, enabled state, all qualification booleans true, and matching PC identity.
- Confirmed exact/no-extra fields are enforced at catalog root, profile, and qualification levels.
- Confirmed project/artifact paths are relative and traversal-free, timeout is a positive integer, expected artifacts are nonempty, and all five regex fields compile.
- Confirmed Start Task still contains only `status --short`, `nick`, and `version-info --custom --template={revision_id}` Bazaar invocations.
- Confirmed the generated packet round-trips replacement metacharacters exactly and missing files/nested Bazaar directories produce no task directory.
- Confirmed `git diff --check` reports no whitespace error.

### Fix-round concerns

- Task 3 must consume the new required flat `pcId` environment field and compare it to selected qualification metadata.
- PowerShell 7's ISO-date projection is explicitly normalized at validation time; the on-disk JSON contract remains a string as defined by the schema.

### Final pre-commit verification

Commands:

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\tests\Test-Package.ps1
pwsh.exe -NoLogo -NoProfile -NonInteractive -File .\tests\Test-Package.ps1
```

Both commands exited `0` with:

```text
PASS: 298 package contract assertions succeeded.
PASS: 391 total package and tool assertions succeeded.
```
