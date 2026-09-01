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

---

## Fix Round 1

### Changed Files

- Replaced `profile/.bob/custom_modes.yaml` with the documented mode shape (`slug`, `name`, `description`, `roleDefinition`, `whenToUse`, `customInstructions`, and nested edit groups). Normal modes now accept only task-draft Markdown/CSV artifacts; Green accepts the approved legacy C/C++ extensions anywhere and safe task-result artifacts. Rules and commands retain the dynamic Work Packet Allowed Files gate.
- Moved all rules to `profile/.bob/rules/` and `profile/.bob/rules-green-implement/`; updated manifest contract paths to resolve from `team-bob` with `../.bob/...`.
- Replaced comment-only command contracts with slash-command frontmatter and structured Input, Preconditions, Context, Output, Stop Conditions, and Green Workflow sections.
- Replaced the work-packet Markdown table contract with a clearly delimited canonical JSON object. The schema now represents Green-only Open QA, impact-clear, and clean-working-copy gates while allowing Amber/Red Open QA.
- Replaced the build target command interface with the approved no-command-injection profile fields and a disabled relative-path example plus qualification record.
- Reworked `tests/Test-Package.ps1` to parse the documented constrained YAML subset, actual command frontmatter/sections, the canonical packet JSON, schema gates, manifest-relative paths, and the build-profile interface. It no longer trusts `bob-contract` comment metadata.

### TDD RED

Command:

```powershell
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.\tests\Test-Package.ps1'
```

Output:

```text
ASSERTION FAILED: Required profile file exists: .bob/rules/00-governance.md
```

Expected reason: the new consuming test required the approved `.bob/rules` location before the rule migration had been implemented.

### Tests

Commands:

```powershell
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.\tests\Test-Package.ps1'
& pwsh -NoProfile -File '.\tests\Test-Package.ps1'
```

Output:

```text
PASS: 331 package contract assertions succeeded.
PASS: 331 package contract assertions succeeded.
```

### Commit and Self-Review

Commit: `8415ff9 fix: harden Team Bob profile contracts`

Reviewed the committed diff with `git show --check --stat --oneline HEAD`. No whitespace errors were reported. Manual review confirmed: Green supports both allowed source/header files and safe result artifacts; manifest paths resolve from the manifest directory; canonical packet JSON is schema-validated with an Amber example and Green mutations; commands use real frontmatter/sections; rules occupy `.bob`; and the build profile no longer contains command strings or absolute workspaces.

### Concerns

None. The runtime’s custom-mode file regex cannot express a dynamic Work Packet Allowed Files array, so that boundary is explicitly enforced again by the Green rule and command, as required.

---

## Fix Round 2

### Changed Files

- `profile/.bob/custom_modes.yaml` is now JSON syntax, which is a strict YAML 1.2 subset. It is parsed by the real Windows PowerShell `ConvertFrom-Json` parser without an external dependency. Every constrained edit permission is an actual two-element group tuple: `["edit", {"fileRegex": "...", "description": "..."}]`.
- `tests/Test-Package.ps1` now consumes the parsed JSON mode arrays, checks the exact group shapes and absence of extra groups, and executes each edit regex against allowed C/C++, drafts, results, and all forbidden `.rc`, `.dsp`, `.dsw`, `.def`, `.idl`, and `.mak` examples.
- `tests/Test-Package.ps1` replaces the partial packet interpreter with a recursive validator covering every keyword used by the work-packet schema: object/array/string/integer types, required fields, additional-properties rejection, properties, const, enum, minLength, minItems, maxItems, items, pattern, allOf, if, and then. A recursive keyword guard fails if an unsupported schema keyword is introduced.
- `profile/team-bob/config/work-packet.schema.json` now declares `Max-Repair-Cycles` as an integer in addition to its fixed value, preventing decimal and string coercion.

### TDD RED

Command:

```powershell
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.\tests\Test-Package.ps1'
```

Output:

```text
ConvertFrom-Json : Invalid JSON primitive: customModes.
```

Expected reason: the test was changed first to parse the mode file with the real JSON parser, while the file was still YAML-only syntax. This proved the former handwritten parser had concealed the consumer incompatibility.

The subsequent integer behavior case also initially failed for the expected reason: the string value `"2"` was coercible against a const-only schema. Adding `"type": "integer"` made decimal and string values reject explicitly.

### Covering Test

Commands:

```powershell
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File '.\tests\Test-Package.ps1'
& pwsh -NoProfile -File '.\tests\Test-Package.ps1'
```

Output:

```text
PASS: 298 package contract assertions succeeded.
PASS: 298 package contract assertions succeeded.
```

The behavior cases cover the canonical Amber packet, a fully converted Green packet, extra properties, empty minLength strings, invalid array items, decimal/string repair-cycle values, pattern rejection, Open QA, and each of the eight Green YES gates.

### Commit and Self-Review

Commit: `382b2e1 fix: parse modes and validate work packets`

Reviewed with `git show --check --stat --oneline HEAD`; no whitespace errors were reported. Self-review confirmed that the JSON mode document keeps exactly five required slugs, every edit group is a documented two-element tuple, normal modes have only read/edit, Green has only read/edit/execute, and no excluded group can appear. The schema validator remains dependency-free and runs under Windows PowerShell 5.1 as well as pwsh.

### Concerns

None.
