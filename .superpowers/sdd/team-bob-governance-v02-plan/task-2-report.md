# Task 2 implementation report

## Outcome

Implemented Task 2 on `codex/team-bob-governance-v02` from base `f71b43f`. The implementation commit is `486dd35` (`f71b43f..486dd35`). No push, merge, tag, or main-checkout change was performed.

The profile and packet runtime now activate `0.2.0-poc` together. Work packets bind current policy/role hashes and three assignment IDs; Start validates governance, role/scope/activity/separation, paths, and Bazaar preflight before atomically publishing a complete task tree. Approval records are human-terminal and create-only. Compliance evaluates the closed machine/AI/human contract, writes immutable results for trusted PASS/FAIL/UNRESOLVED evaluations, and atomically advances one-way phase state only after PASS.

The controller-approved minimal registration compatibility was pulled forward from Task 3: the runtime and demo compatibility path now use `%LOCALAPPDATA%\IBM\BobTeamProfile\vc6-machine-control-poc\v0.2.0-poc\environment.json`, without reading or overwriting the unversioned v0.1 registration. Richer registration identities and installer migration enforcement remain Task 3.

## TDD evidence

Initial RED command:

```text
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\tests\Test-Compliance.ps1
exit 1
ASSERTION FAILED: Task 2 atomically activates the v0.2 profile (expected '0.2.0-poc', got '0.1.0-poc')
```

Additional focused RED evidence captured while closing adversarial semantics:

```text
REQ-M-001 duplicate/blank-anchor fixture: expected FAIL, got PASS
requirements result line evidence: expected a positive line number, got 0
TEST-M-001 prefix-collision fixture: expected FAIL, got PASS
expired selected assignments at evaluation: expected exit 20, got 0
```

Each failure was followed by the narrow implementation change and a focused rerun. The resulting compliance suite passed 137 assertions.

## Focused verification

All focused commands exited 0:

```text
Test-Governance.ps1       PASS: 95 governance contract assertions succeeded.
Test-Tools.ps1            PASS: 162 tool assertions (focused run before aggregate full run).
Test-BuildTools.ps1       PASS: 566 build/evidence assertions (focused run before aggregate full run).
Test-Compliance.ps1       PASS: 137 compliance assertions succeeded.
Test-DemoAdapter.ps1      PASS: 430 demo adapter contract assertions succeeded.
Test-DemoAdapterE2E.ps1   PASS: 69 unchanged-wrapper demo adapter E2E assertions succeeded.
Test-DemoPackage.ps1      PASS: 247 demo package contract assertions succeeded.
Test-DemoLifecycle.ps1    PASS: 262 assertions.
Test-DemoPackets.ps1      PASS: 219 demo packet assertions.
```

Static verification also passed: every modified PowerShell file parsed under Windows PowerShell syntax checks, every modified JSON document parsed, and `git diff --check` reported no errors.

## Full-suite evidence

Exactly one final full-suite run was executed:

```text
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\tests\Test-Package.ps1
exit 0
PASS: 2326 total package, tool, build, and evidence assertions succeeded.
```

Intermediate milestones from that same process included package 371, governance 95, compliance 137, demo adapter 430, adapter E2E 69, demo package 247, demo packets 219, and aggregate package/tool 1760 assertions.

## Files and interfaces

Primary new runtime interfaces:

- `profile/team-bob/tools/New-TeamBobApprovalRecord.ps1`: `-WorkPacket`, `-Phase`, `-AssignmentId`, `-ArtifactPath`, one or more `-EvidencePath`, `-ExpiresAtUtc`, and mandatory `-HumanTerminal`; exits 0/20/30 and publishes create-only approval JSON.
- `profile/team-bob/tools/Invoke-TeamBobComplianceCheck.ps1`: `-WorkPacket`, six-valued `-Phase`, `-ArtifactPath`, `-AssessmentPath`, optional `-ApprovalRecordPath`; exits 0 PASS, 10 FAIL, 11 UNRESOLVED, 20 contract/policy/version/cross-reference invalid, or 30 path/hash/integrity failure.
- `profile/team-bob/tools/TeamBob-ComplianceCommon.ps1`: closed governance/role/state/result/assessment/approval validation, machine-check implementations, physical containment, create-only publication, and atomic state replacement.

Changed contracts and consumers:

- v0.2 work-packet schema/template, profile manifest, profile validator, registration initializer, Start task runtime, build common packet reader, and governance JSON reader.
- Approval, assessment, compliance-result, and phase-state schemas now carry closed version/provenance/hash/reference/check/message/status shapes.
- Strict recursive duplicate-member scanning applies to governed JSON. Duplicate or ambiguous decoded `Profile Version` is reported as `PACKET_VERSION_UNSUPPORTED` before shape/path/side effects; other duplicates are contract-invalid.
- `Start-TeamBobTask.ps1` now accepts the three assignment IDs, validates shipped-empty/missing/invalid roles before Bazaar or task side effects, stages the full task tree on the destination volume, and publishes it with one directory move.
- Minimal demo lifecycle/packet fixture compatibility was migrated to the v0.2 registration and assignment-ID packet shape so the existing suite continues to exercise the activated runtime. Task 5's richer demo phase/result/approval redesign was not implemented.

## Behavioral coverage and side effects

Tests cover the normal six-phase prefix, exact policy check ordering, immutable packet/policy/role/artifact/prerequisite references, active/in-scope exact-role selection, case-insensitive principal separation, approval expiry and replay rejection, required evidence types/values, NOT_APPLICABLE rejection, trusted FAIL/UNRESOLVED results, and no result/state mutation for exits 20/30. Machine checks cover ledger uniqueness/source anchors, specification-to-bound-ledger ReqIDs, seven impact areas, implementation entry gates/inventory/CP932/Rebuild evidence, structured review findings, and exact upstream ReqID/acceptance-token traceability.

## Residual risks and deliberate exclusions

- Task 2 validates the deliberately minimal closed build-result shape available at this layer. Same-attempt Make-to-Rebuild provenance, richer registration identities, installer migration enforcement, and build/evidence wrapper provenance gates remain Task 3.
- Bob hooks/rules/assets remain Task 4. Full demo/docs/CI migration beyond the minimal runtime compatibility needed for Task 2 tests remains Task 5.
- Approval records bind hashes, assignment, principal identifier, time, and evidence, but do not provide human authentication or non-repudiation; this is the governance plan's stated limitation.
- Atomicity is per-file/per-directory publication: result JSON is create-only, phase-state replacement is atomic, and Start publishes the staged task directory atomically on one volume. There is no multi-file filesystem transaction across an immutable result and its subsequent state replacement.
- No external libraries were added; runtime code remains compatible with Windows PowerShell 5.1 constraints.
