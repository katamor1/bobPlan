$ErrorActionPreference = 'Stop'

$script:GovernanceAssertions = 0

function Assert-GovernanceTrue {
    param([bool]$Condition, [string]$Message)
    $script:GovernanceAssertions++
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Assert-GovernanceEqual {
    param([object]$Actual, [object]$Expected, [string]$Message)
    Assert-GovernanceTrue ($Actual -ceq $Expected) "$Message (expected '$Expected', got '$Actual')"
}

function Copy-GovernanceFixture {
    param([string]$Source, [string]$Name)
    $destination = Join-Path $script:GovernanceFixtureRoot $Name
    [System.IO.Directory]::CreateDirectory($destination) | Out-Null
    Get-ChildItem -LiteralPath $Source -Force | Copy-Item -Destination $destination -Recurse -Force
    return $destination
}

function Write-GovernanceJson {
    param([string]$Path, [object]$Value)
    $json = $Value | ConvertTo-Json -Depth 30
    [System.IO.File]::WriteAllText($Path, ($json + "`n"), (New-Object System.Text.UTF8Encoding($false, $true)))
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$profileRoot = Join-Path $repoRoot 'profile'
$governanceRoot = Join-Path $profileRoot '.bob\governance'
$commonPath = Join-Path $profileRoot 'team-bob\tools\TeamBob-GovernanceCommon.ps1'
$validatorPath = Join-Path $profileRoot 'team-bob\tools\Test-TeamBobGovernance.ps1'

Assert-GovernanceTrue (Test-Path -LiteralPath $commonPath -PathType Leaf) 'Governance common module exists'
Assert-GovernanceTrue (Test-Path -LiteralPath $validatorPath -PathType Leaf) 'Governance validator exists'
. $commonPath

$expectedFiles = @(
    'policy-manifest.json', 'glossary.json', 'checklists/authoring.json', 'checklists/review.json', 'roles.json',
    'schemas/policy-manifest.schema.json', 'schemas/glossary.schema.json', 'schemas/checklist.schema.json',
    'schemas/roles.schema.json', 'schemas/approval-record.schema.json', 'schemas/compliance-assessment.schema.json',
    'schemas/compliance-result.schema.json', 'schemas/phase-state.schema.json'
)
foreach ($relativePath in $expectedFiles) {
    Assert-GovernanceTrue (Test-Path -LiteralPath (Join-Path $governanceRoot $relativePath) -PathType Leaf) "Governance file exists: $relativePath"
}

$packageErrors = @(Test-TeamBobGovernancePackage -GovernanceRoot $governanceRoot)
Assert-GovernanceEqual $packageErrors.Count 0 'Shipped governance package validates'

$utf8 = New-Object System.Text.UTF8Encoding($false, $true)
foreach ($relativePath in $expectedFiles) {
    $bytes = [System.IO.File]::ReadAllBytes((Join-Path $governanceRoot $relativePath))
    Assert-GovernanceTrue (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xef -and $bytes[1] -eq 0xbb -and $bytes[2] -eq 0xbf)) "Governance JSON is BOM-free: $relativePath"
    try { [void]$utf8.GetString($bytes); $strictUtf8 = $true } catch { $strictUtf8 = $false }
    Assert-GovernanceTrue $strictUtf8 "Governance JSON is strict UTF-8: $relativePath"
}

$policy = Get-TeamBobGovernanceJson (Join-Path $governanceRoot 'policy-manifest.json')
Assert-GovernanceEqual $policy.policyVersion '0.2.0-poc' 'Policy version is active in the governance source'
Assert-GovernanceEqual $policy.maxApprovalValidityHours 168 'Policy approval validity is bounded to 168 hours'
$expectedPhaseContract = @(
    'requirements|bob-normalize-requirements|req-spec-draft|drafts/requirement-ledger.csv|',
    'specification|bob-draft-spec|req-spec-draft|drafts/external-spec.md|SPECIFICATION_APPROVER',
    'impact|bob-analyze-impact|impact-review|drafts/impact-analysis.md|IMPLEMENTATION_APPROVER',
    'implementation|bob-implement-green|green-implement|results/build-result-*.json|',
    'review|bob-review-change|change-review|drafts/code-review.md|INDEPENDENT_REVIEWER',
    'test|bob-draft-test|test-draft|drafts/test-spec.md|SPECIFICATION_APPROVER'
)
$actualPhaseContract = @($policy.phases | ForEach-Object { "$($_.id)|$($_.command)|$($_.mode)|$($_.artifact)|$($_.completionApprovalRole)" })
Assert-GovernanceEqual ($actualPhaseContract -join "`n") ($expectedPhaseContract -join "`n") 'Policy preserves the approved ordered phase contract'

$expectedGlossaryIds = @(
    'TERM-WORK-PACKET', 'TERM-REQID', 'TERM-IMMUTABLE-SOURCE-ANCHOR', 'TERM-REQUIREMENT-LEDGER', 'TERM-WORD-BASELINE',
    'TERM-QA-BASELINE', 'TERM-SPEC-BASELINE', 'TERM-ALLOWED-FILES', 'TERM-FORBIDDEN-AREAS', 'TERM-OPEN-QA', 'TERM-GREEN',
    'TERM-QUALIFICATION', 'TERM-MAKE', 'TERM-REBUILD', 'TERM-READY-FOR-HUMAN-REVIEW', 'TERM-SUCCEEDED',
    'TERM-CODE-FAILED-RETRYABLE', 'TERM-CODE-FAILED-STOP', 'TERM-ENVIRONMENT-FAILED', 'TERM-TIMED-OUT',
    'TERM-INTEGRITY-FAILED', 'TERM-SPECIFICATION-APPROVER', 'TERM-IMPLEMENTATION-APPROVER', 'TERM-INDEPENDENT-REVIEWER',
    'TERM-ACTUAL-MACHINE', 'TERM-CONTROL-NETWORK', 'TERM-MAINLINE', 'TERM-SECRETS'
)
$glossary = Get-TeamBobGovernanceJson (Join-Path $governanceRoot 'glossary.json')
Assert-GovernanceEqual (@($glossary.terms.id) -join ',') ($expectedGlossaryIds -join ',') 'Glossary contains exactly the approved active IDs in order'

$manifest = Get-TeamBobGovernanceJson (Join-Path $profileRoot 'team-bob\profile-manifest.json')
Assert-GovernanceEqual $manifest.version '0.1.0-poc' 'Transitional profile version remains v0.1'
$expectedContractPaths = @(
    'governancePolicy', 'governanceGlossary', 'governanceAuthoringChecklist', 'governanceReviewChecklist',
    'governanceRoles', 'governanceSchemas', 'governanceValidator'
)
foreach ($field in $expectedContractPaths) { Assert-GovernanceTrue ($null -ne $manifest.contracts.PSObject.Properties[$field]) "Profile manifest exposes $field" }

$independentRecords = @()
$sortedBundleMembers = [string[]]@($policy.bundleMembers)
[Array]::Sort($sortedBundleMembers, [System.StringComparer]::Ordinal)
foreach ($relativePath in $sortedBundleMembers) {
    $normalized = $relativePath.Replace('\', '/')
    $hash = Get-TeamBobGovernanceFileHash (Join-Path $governanceRoot $relativePath)
    $independentRecords += "$normalized`t$hash`n"
}
$recordBytes = $utf8.GetBytes(($independentRecords -join ''))
$sha = [System.Security.Cryptography.SHA256]::Create()
try { $expectedBundleHash = ([BitConverter]::ToString($sha.ComputeHash($recordBytes))).Replace('-', '').ToLowerInvariant() } finally { $sha.Dispose() }
Assert-GovernanceEqual (Get-TeamBobPolicyBundleHash -GovernanceRoot $governanceRoot) $expectedBundleHash 'Bundle hash uses sorted path-tab-rawhash-newline records'
Assert-GovernanceTrue (@($policy.bundleMembers) -notcontains 'roles.json') 'Policy bundle excludes mutable roles.json'
Assert-GovernanceEqual (Get-TeamBobRoleLedgerHash -GovernanceRoot $governanceRoot) (Get-TeamBobGovernanceFileHash (Join-Path $governanceRoot 'roles.json')) 'Role ledger hash is the exact roles.json byte hash'

$roles = Get-TeamBobGovernanceJson (Join-Path $governanceRoot 'roles.json')
Assert-GovernanceEqual @($roles.assignments).Count 0 'Distribution role ledger is intentionally empty'
$strictErrors = @(Test-TeamBobGovernanceStrictReadiness -GovernanceRoot $governanceRoot -NowUtc ([datetime]'2026-09-03T00:00:00Z'))
Assert-GovernanceTrue ($strictErrors.Count -gt 0) 'Strict readiness fails closed for the empty distribution ledger'

$script:GovernanceFixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('team-bob-governance-' + [guid]::NewGuid().ToString('N'))
[System.IO.Directory]::CreateDirectory($script:GovernanceFixtureRoot) | Out-Null
try {
    $bomRoot = Copy-GovernanceFixture $governanceRoot 'bom'
    $bomPath = Join-Path $bomRoot 'glossary.json'
    $original = [System.IO.File]::ReadAllBytes($bomPath)
    [System.IO.File]::WriteAllBytes($bomPath, ([byte[]](0xef, 0xbb, 0xbf) + $original))
    Assert-GovernanceTrue (@(@(Test-TeamBobGovernancePackage -GovernanceRoot $bomRoot) -match 'encoding').Count -gt 0) 'Package validator rejects a UTF-8 BOM'

    $shapeRoot = Copy-GovernanceFixture $governanceRoot 'shape'
    $shapeGlossaryPath = Join-Path $shapeRoot 'glossary.json'
    $shapeGlossary = Get-TeamBobGovernanceJson $shapeGlossaryPath
    $shapeGlossary.terms[0] | Add-Member -NotePropertyName unexpected -NotePropertyValue $true
    Write-GovernanceJson $shapeGlossaryPath $shapeGlossary
    Assert-GovernanceTrue (@(@(Test-TeamBobGovernancePackage -GovernanceRoot $shapeRoot) -match 'shape').Count -gt 0) 'Package validator rejects additional object properties'

    $collisionRoot = Copy-GovernanceFixture $governanceRoot 'collision'
    $collisionPath = Join-Path $collisionRoot 'glossary.json'
    $collision = Get-TeamBobGovernanceJson $collisionPath
    $collision.terms[1].aliases = @($collision.terms[0].canonical.ToUpperInvariant())
    Write-GovernanceJson $collisionPath $collision
    Assert-GovernanceTrue (@(@(Test-TeamBobGovernancePackage -GovernanceRoot $collisionRoot) -match 'collision').Count -gt 0) 'Package validator rejects case-insensitive canonical/alias/forbidden collisions'

    $forbiddenRoot = Copy-GovernanceFixture $governanceRoot 'forbidden'
    $forbiddenPath = Join-Path $forbiddenRoot 'glossary.json'
    $forbidden = Get-TeamBobGovernanceJson $forbiddenPath
    $forbidden.terms[0].forbidden += 'done'
    Write-GovernanceJson $forbiddenPath $forbidden
    Assert-GovernanceTrue (@(@(Test-TeamBobGovernancePackage -GovernanceRoot $forbiddenRoot) -match 'forbidden spellings').Count -gt 0) 'Package validator rejects broad or unapproved forbidden spellings'

    $ownerRoot = Copy-GovernanceFixture $governanceRoot 'owner'
    $ownerPath = Join-Path $ownerRoot 'glossary.json'
    $owner = Get-TeamBobGovernanceJson $ownerPath
    $owner.terms[0].ownerRole = 'INDEPENDENT_REVIEWER'
    Write-GovernanceJson $ownerPath $owner
    Assert-GovernanceTrue (@(@(Test-TeamBobGovernancePackage -GovernanceRoot $ownerRoot) -match 'owner role').Count -gt 0) 'Package validator rejects a glossary concept assigned to the wrong owner role'

    $canonicalRoot = Copy-GovernanceFixture $governanceRoot 'canonical'
    $canonicalPath = Join-Path $canonicalRoot 'glossary.json'
    $canonical = Get-TeamBobGovernanceJson $canonicalPath
    $canonical.terms[0].canonical = 'Packet'
    Write-GovernanceJson $canonicalPath $canonical
    Assert-GovernanceTrue (@(@(Test-TeamBobGovernancePackage -GovernanceRoot $canonicalRoot) -match 'canonical text').Count -gt 0) 'Package validator rejects non-canonical glossary text'

    $emptyTextRoot = Copy-GovernanceFixture $governanceRoot 'empty-text'
    $emptyGlossaryPath = Join-Path $emptyTextRoot 'glossary.json'
    $emptyGlossary = Get-TeamBobGovernanceJson $emptyGlossaryPath
    $emptyGlossary.terms[0].definition = ''
    Write-GovernanceJson $emptyGlossaryPath $emptyGlossary
    Assert-GovernanceTrue (@(@(Test-TeamBobGovernancePackage -GovernanceRoot $emptyTextRoot) -match 'shape').Count -gt 0) 'Package validator rejects an empty glossary definition'

    $emptyChecklistRoot = Copy-GovernanceFixture $governanceRoot 'empty-check-title'
    $emptyChecklistPath = Join-Path $emptyChecklistRoot 'checklists/authoring.json'
    $emptyChecklist = Get-TeamBobGovernanceJson $emptyChecklistPath
    $emptyChecklist.checks[0].title = ''
    Write-GovernanceJson $emptyChecklistPath $emptyChecklist
    Assert-GovernanceTrue (@(@(Test-TeamBobGovernancePackage -GovernanceRoot $emptyChecklistRoot) -match 'shape').Count -gt 0) 'Package validator rejects an empty checklist title'

    $referenceRoot = Copy-GovernanceFixture $governanceRoot 'reference'
    $referencePolicyPath = Join-Path $referenceRoot 'policy-manifest.json'
    $referencePolicy = Get-TeamBobGovernanceJson $referencePolicyPath
    $referencePolicy.phases[0].checkIds[0] = 'REQ-M-999'
    Write-GovernanceJson $referencePolicyPath $referencePolicy
    Assert-GovernanceTrue (@(@(Test-TeamBobGovernancePackage -GovernanceRoot $referenceRoot) -match 'cross-reference').Count -gt 0) 'Package validator rejects unknown phase check IDs'

    $mappingRoot = Copy-GovernanceFixture $governanceRoot 'mapping'
    $mappingPolicyPath = Join-Path $mappingRoot 'policy-manifest.json'
    $mappingPolicy = Get-TeamBobGovernanceJson $mappingPolicyPath
    $mappingPolicy.machineCheckImplementations = @($mappingPolicy.machineCheckImplementations | Select-Object -Skip 1)
    Write-GovernanceJson $mappingPolicyPath $mappingPolicy
    Assert-GovernanceTrue (@(@(Test-TeamBobGovernancePackage -GovernanceRoot $mappingRoot) -match 'machine implementation').Count -gt 0) 'Package validator requires one implementation mapping per machine check'

    $unsupportedMappingRoot = Copy-GovernanceFixture $governanceRoot 'unsupported-mapping'
    $unsupportedMappingPolicyPath = Join-Path $unsupportedMappingRoot 'policy-manifest.json'
    $unsupportedMappingPolicy = Get-TeamBobGovernanceJson $unsupportedMappingPolicyPath
    $unsupportedMappingPolicy.machineCheckImplementations[0].implementation = 'Invoke-ArbitraryMachineCheck'
    Write-GovernanceJson $unsupportedMappingPolicyPath $unsupportedMappingPolicy
    Assert-GovernanceTrue (@(@(Test-TeamBobGovernancePackage -GovernanceRoot $unsupportedMappingRoot) -match 'machine implementation registry').Count -gt 0) 'Package validator rejects unsupported machine implementation identifiers'

    $rolesBundleRoot = Copy-GovernanceFixture $governanceRoot 'roles-bundle'
    $rolesBundlePolicyPath = Join-Path $rolesBundleRoot 'policy-manifest.json'
    $rolesBundlePolicy = Get-TeamBobGovernanceJson $rolesBundlePolicyPath
    $rolesBundlePolicy.bundleMembers += 'roles.json'
    Write-GovernanceJson $rolesBundlePolicyPath $rolesBundlePolicy
    Assert-GovernanceTrue (@(@(Test-TeamBobGovernancePackage -GovernanceRoot $rolesBundleRoot) -match 'bundle').Count -gt 0) 'Package validator rejects roles.json in the immutable bundle'

    $strictRoot = Copy-GovernanceFixture $governanceRoot 'strict'
    $strictRolesPath = Join-Path $strictRoot 'roles.json'
    $strictRoles = Get-TeamBobGovernanceJson $strictRolesPath
    $allRolePhases = @('requirements', 'specification', 'impact', 'implementation', 'review', 'test')
    $strictRoles.assignments = @(
        [pscustomobject][ordered]@{ assignmentId = 'ASSIGN-SPEC-001'; role = 'SPECIFICATION_APPROVER'; principalId = 'principal-spec'; scope = [pscustomobject][ordered]@{ allTasks = $true; taskIds = @(); phases = $allRolePhases }; enabled = $true; validFromUtc = '2026-09-01T00:00:00Z'; validUntilUtc = '2026-09-10T00:00:00Z' },
        [pscustomobject][ordered]@{ assignmentId = 'ASSIGN-IMPL-001'; role = 'IMPLEMENTATION_APPROVER'; principalId = 'principal-impl'; scope = [pscustomobject][ordered]@{ allTasks = $true; taskIds = @(); phases = $allRolePhases }; enabled = $true; validFromUtc = '2026-09-01T00:00:00Z'; validUntilUtc = '2026-09-10T00:00:00Z' },
        [pscustomobject][ordered]@{ assignmentId = 'ASSIGN-REV-001'; role = 'INDEPENDENT_REVIEWER'; principalId = 'principal-review'; scope = [pscustomobject][ordered]@{ allTasks = $true; taskIds = @(); phases = $allRolePhases }; enabled = $true; validFromUtc = '2026-09-01T00:00:00Z'; validUntilUtc = '2026-09-10T00:00:00Z' }
    )
    Write-GovernanceJson $strictRolesPath $strictRoles
    Assert-GovernanceEqual @(Test-TeamBobGovernanceStrictReadiness -GovernanceRoot $strictRoot -NowUtc ([datetime]'2026-09-03T00:00:00Z')).Count 0 'Strict readiness accepts active in-scope unexpired distinct assignments'

    $roleMutations = @(
        [pscustomobject]@{ Name = 'empty-principal'; Apply = { param($assignment) $assignment.principalId = '' } },
        [pscustomobject]@{ Name = 'scalar-scope'; Apply = { param($assignment) $assignment.scope = '*' } },
        [pscustomobject]@{ Name = 'bad-role-casing'; Apply = { param($assignment) $assignment.role = 'specification_approver' } },
        [pscustomobject]@{ Name = 'bad-timestamp'; Apply = { param($assignment) $assignment.validFromUtc = '2026-09-01 00:00:00' } },
        [pscustomobject]@{ Name = 'malformed-assignment-id'; Apply = { param($assignment) $assignment.assignmentId = 'bad id' } }
    )
    foreach ($mutation in $roleMutations) {
        $mutationRoot = Copy-GovernanceFixture $governanceRoot ('role-' + $mutation.Name)
        $mutationRolesPath = Join-Path $mutationRoot 'roles.json'
        $mutationRoles = Get-TeamBobGovernanceJson $strictRolesPath
        & $mutation.Apply $mutationRoles.assignments[0]
        Write-GovernanceJson $mutationRolesPath $mutationRoles
        Assert-GovernanceTrue (@(Test-TeamBobGovernancePackage -GovernanceRoot $mutationRoot).Count -gt 0) "Package validation rejects role mutation: $($mutation.Name)"
        Assert-GovernanceTrue (@(Test-TeamBobGovernanceStrictReadiness -GovernanceRoot $mutationRoot -NowUtc ([datetime]'2026-09-03T00:00:00Z')).Count -gt 0) "Strict readiness rejects role mutation: $($mutation.Name)"
    }

    $scalarAssignmentsRoot = Copy-GovernanceFixture $governanceRoot 'scalar-assignments'
    $scalarAssignmentsPath = Join-Path $scalarAssignmentsRoot 'roles.json'
    $scalarAssignments = Get-TeamBobGovernanceJson $strictRolesPath
    $scalarAssignments.assignments = $scalarAssignments.assignments[0]
    Write-GovernanceJson $scalarAssignmentsPath $scalarAssignments
    Assert-GovernanceTrue (@(Test-TeamBobGovernancePackage -GovernanceRoot $scalarAssignmentsRoot).Count -gt 0) 'Package validation requires assignments to remain an array'

    $strictRoles.assignments[2].principalId = 'principal-spec'
    Write-GovernanceJson $strictRolesPath $strictRoles
    Assert-GovernanceTrue (@(@(Test-TeamBobGovernanceStrictReadiness -GovernanceRoot $strictRoot -NowUtc ([datetime]'2026-09-03T00:00:00Z')) -match 'distinct').Count -gt 0) 'Strict readiness rejects the same principal in two roles'
    $strictRoles.assignments[2].principalId = 'principal-review'
    $strictRoles.assignments[2].validUntilUtc = '2026-09-02T00:00:00Z'
    Write-GovernanceJson $strictRolesPath $strictRoles
    Assert-GovernanceTrue (@(@(Test-TeamBobGovernanceStrictReadiness -GovernanceRoot $strictRoot -NowUtc ([datetime]'2026-09-03T00:00:00Z')) -match 'unexpired').Count -gt 0) 'Strict readiness rejects expired assignments'
} finally {
    if (Test-Path -LiteralPath $script:GovernanceFixtureRoot) { Remove-Item -LiteralPath $script:GovernanceFixtureRoot -Recurse -Force }
}

Write-Host "PASS: $script:GovernanceAssertions governance contract assertions succeeded."
