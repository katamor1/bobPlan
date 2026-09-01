# Task 1 Implementation Report

## Status

DONE

## Implementation

Implemented the Team Bob Windows/VC6/Bazaar profile package at `profile/`.

- Added profile installation guidance, Bob and Bazaar ignore snippets, and profile `AGENTS.md`.
- Added five custom modes with the required mode slugs, normal-mode draft-only edits, Green source-extension/result controls, and excluded privileged/delegation groups.
- Added six `$1` work-packet commands. Each declares a parsed command contract, validates the packet, uses targeted context, has one prescribed output, and stops on missing evidence. The Green command governs edit → Make → at-most-two repairs → final Rebuild and gates `READY_FOR_HUMAN_REVIEW` on success and integrity.
- Added governance, VC6 real-time, traceability, output-status, and Green edit/build-loop rules.
- Added stable work-packet and VC6 build-target JSON Schemas, an empty shipped target collection, and one disabled example target.
- Added the `0.1.0-poc` profile manifest, all requested templates, task-only usage-log columns, review rubric, and exception record.
- Added `tests/Test-Package.ps1`, compatible with Windows PowerShell 5.1 and pwsh. It parses JSON and CSV contracts and the constrained custom-mode YAML structure; validates mode boundaries, work-packet rules, build-profile state, command contracts, review/exception contracts, output statuses, and the no-person-identifiers usage-log policy.

## Files

- `profile/AGENTS.md`, `profile/.bobignore.base`, `profile/.bzrignore.snippet`
- `profile/.bob/custom_modes.yaml` and six files in `profile/.bob/commands/`
- `profile/team-bob/profile-manifest.json`
- `profile/team-bob/config/work-packet.schema.json`
- `profile/team-bob/config/vc6-build-targets.schema.json`
- `profile/team-bob/config/vc6-build-targets.json`
- `profile/team-bob/config/vc6-build-targets.example.json`
- Four global rules and the Green edit/build-loop rule under `profile/team-bob/`
- Nine requested templates under `profile/team-bob/templates/`
- `tests/Test-Package.ps1`

## TDD Evidence

### RED

Command:

```powershell
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.\tests\Test-Package.ps1'
```

Output:

```text
ASSERTION FAILED: profile directory exists
```

Expected reason: the test was added before profile assets existed, so the package-contract precondition correctly failed on the missing `profile` directory.

The command-contract assertions were also added test-first later in the cycle and initially failed because command Markdown lacked the required parseable `bob-contract` JSON block. The command metadata was then added before the final GREEN run.

### GREEN

Command:

```powershell
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.\tests\Test-Package.ps1'
& pwsh -NoProfile -File '.\tests\Test-Package.ps1'
```

Output:

```text
PASS: 236 package contract assertions succeeded.
PASS: 236 package contract assertions succeeded.
```

## Self-Review

After commit `0d97931`, reviewed the committed diff with `git show --check --stat --oneline HEAD` and checked the contract coverage against the Task 1 brief. The review found no whitespace errors or missing requested package categories. The tests cover the structured contracts rather than merely checking arbitrary policy prose. A binary encoding audit confirmed that no profile artifact is UTF-16; profile text is UTF-8-oriented, while the CP932/no-BOM/CRLF requirement is explicitly limited to legacy C/C++ edits.

## Concerns

None. The shipped VC6 target collection is intentionally empty and its sole example target is explicitly disabled, so a human must add and approve a local build profile before Green execution can occur.
