$ErrorActionPreference = 'Stop'

function Get-TeamBobGovernanceFileHash {
    param([Parameter(Mandatory = $true)][string]$Path)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        try { return ([BitConverter]::ToString($sha256.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
        finally { $stream.Dispose() }
    } finally { $sha256.Dispose() }
}

function Get-TeamBobGovernanceJson {
    param([Parameter(Mandatory = $true)][string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xef -and $bytes[1] -eq 0xbb -and $bytes[2] -eq 0xbf) { throw "encoding: UTF-8 BOM is forbidden: $Path" }
    $encoding = New-Object System.Text.UTF8Encoding($false, $true)
    try { $text = $encoding.GetString($bytes) } catch { throw "encoding: invalid UTF-8: $Path" }
    try { return ($text | ConvertFrom-Json) } catch { throw "json: invalid JSON: $Path ($($_.Exception.Message))" }
}

function Test-TeamBobGovernanceExactProperties {
    param([object]$Value, [string[]]$Required, [string[]]$Optional = @())
    if (-not ($Value -is [System.Management.Automation.PSCustomObject])) { return $false }
    $actual = @($Value.PSObject.Properties.Name | Sort-Object)
    $allowed = @($Required + $Optional | Sort-Object)
    foreach ($name in $Required) { if ($actual -notcontains $name) { return $false } }
    foreach ($name in $actual) { if ($allowed -notcontains $name) { return $false } }
    return $true
}

function Get-TeamBobPolicyBundleHash {
    param([Parameter(Mandatory = $true)][string]$GovernanceRoot)
    $policy = Get-TeamBobGovernanceJson (Join-Path $GovernanceRoot 'policy-manifest.json')
    $records = @()
    $memberPaths = [string[]]@($policy.bundleMembers)
    [Array]::Sort($memberPaths, [System.StringComparer]::Ordinal)
    foreach ($relativePath in $memberPaths) {
        $normalized = ([string]$relativePath).Replace('\', '/')
        $records += ($normalized + "`t" + (Get-TeamBobGovernanceFileHash (Join-Path $GovernanceRoot $relativePath)) + "`n")
    }
    $bytes = (New-Object System.Text.UTF8Encoding($false, $true)).GetBytes(($records -join ''))
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha256.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha256.Dispose() }
}

function Get-TeamBobRoleLedgerHash {
    param([Parameter(Mandatory = $true)][string]$GovernanceRoot)
    return Get-TeamBobGovernanceFileHash (Join-Path $GovernanceRoot 'roles.json')
}

function Test-TeamBobGovernanceSchemaClosed {
    param([object]$Node, [string]$Path = '$')
    $errors = @()
    if ($Node -is [System.Management.Automation.PSCustomObject]) {
        if ($Node.type -eq 'object' -and $Node.additionalProperties -ne $false) { $errors += "schema closed shape: $Path" }
        foreach ($property in $Node.PSObject.Properties) { $errors += @(Test-TeamBobGovernanceSchemaClosed $property.Value "$Path.$($property.Name)") }
    } elseif ($Node -is [System.Array]) {
        for ($index = 0; $index -lt $Node.Count; $index++) { $errors += @(Test-TeamBobGovernanceSchemaClosed $Node[$index] "$Path[$index]") }
    }
    return @($errors)
}

function Test-TeamBobGovernancePackage {
    param([Parameter(Mandatory = $true)][string]$GovernanceRoot)
    $errors = @()
    $expectedFiles = @(
        'policy-manifest.json', 'glossary.json', 'checklists/authoring.json', 'checklists/review.json', 'roles.json',
        'schemas/policy-manifest.schema.json', 'schemas/glossary.schema.json', 'schemas/checklist.schema.json',
        'schemas/roles.schema.json', 'schemas/approval-record.schema.json', 'schemas/compliance-assessment.schema.json',
        'schemas/compliance-result.schema.json', 'schemas/phase-state.schema.json'
    )
    $documents = @{}
    foreach ($relativePath in $expectedFiles) {
        $path = Join-Path $GovernanceRoot $relativePath
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { $errors += "missing: $relativePath"; continue }
        try { $documents[$relativePath] = Get-TeamBobGovernanceJson $path } catch { $errors += $_.Exception.Message }
    }
    if ($errors.Count -gt 0) { return @($errors) }

    $policy = $documents['policy-manifest.json']
    if (-not (Test-TeamBobGovernanceExactProperties $policy @('policyVersion', 'maxApprovalValidityHours', 'commonCheckIds', 'bundleMembers', 'machineCheckImplementations', 'phases'))) { $errors += 'shape: policy manifest' }
    if ($policy.policyVersion -ne '0.2.0-poc' -or $policy.maxApprovalValidityHours -ne 168) { $errors += 'identity: policy version or approval validity' }
    $expectedCommon = @('GOV-M-001', 'GOV-M-002', 'GOV-M-003', 'GOV-M-004', 'GOV-A-001')
    if ((@($policy.commonCheckIds) -join ',') -cne ($expectedCommon -join ',')) { $errors += 'cross-reference: common check IDs' }
    $expectedBundle = @(
        'checklists/authoring.json', 'checklists/review.json', 'glossary.json', 'policy-manifest.json',
        'schemas/approval-record.schema.json', 'schemas/checklist.schema.json', 'schemas/compliance-assessment.schema.json',
        'schemas/compliance-result.schema.json', 'schemas/glossary.schema.json', 'schemas/phase-state.schema.json',
        'schemas/policy-manifest.schema.json', 'schemas/roles.schema.json'
    )
    if ((@($policy.bundleMembers | Sort-Object) -join ',') -cne (($expectedBundle | Sort-Object) -join ',')) { $errors += 'bundle: membership must be exact and exclude roles.json' }

    $expectedPhases = @(
        @('requirements', 'bob-normalize-requirements', 'req-spec-draft', 'drafts/requirement-ledger.csv', '', 'REQ-M-001', 'REQ-A-001'),
        @('specification', 'bob-draft-spec', 'req-spec-draft', 'drafts/external-spec.md', 'SPECIFICATION_APPROVER', 'SPEC-M-001', 'SPEC-M-002', 'SPEC-A-001', 'SPEC-H-001'),
        @('impact', 'bob-analyze-impact', 'impact-review', 'drafts/impact-analysis.md', 'IMPLEMENTATION_APPROVER', 'IMP-M-001', 'IMP-A-001', 'IMP-H-001'),
        @('implementation', 'bob-implement-green', 'green-implement', 'results/build-result-*.json', '', 'IMPL-M-001', 'IMPL-M-002', 'IMPL-M-003', 'IMPL-M-004', 'IMPL-A-001'),
        @('review', 'bob-review-change', 'change-review', 'drafts/code-review.md', 'INDEPENDENT_REVIEWER', 'REV-M-001', 'REV-A-001', 'REV-H-001'),
        @('test', 'bob-draft-test', 'test-draft', 'drafts/test-spec.md', 'SPECIFICATION_APPROVER', 'TEST-M-001', 'TEST-A-001', 'TEST-H-001')
    )
    if (@($policy.phases).Count -ne 6) { $errors += 'shape: six phases required' }
    for ($index = 0; $index -lt [Math]::Min(@($policy.phases).Count, 6); $index++) {
        $phase = $policy.phases[$index]
        if (-not (Test-TeamBobGovernanceExactProperties $phase @('id', 'ordinal', 'command', 'mode', 'artifact', 'commonCheckIds', 'checkIds', 'completionApprovalRole'))) { $errors += "shape: phase $index"; continue }
        $expected = $expectedPhases[$index]
        $actualRole = if ($null -eq $phase.completionApprovalRole) { '' } else { [string]$phase.completionApprovalRole }
        if ($phase.id -cne $expected[0] -or $phase.ordinal -ne ($index + 1) -or $phase.command -cne $expected[1] -or $phase.mode -cne $expected[2] -or $phase.artifact -cne $expected[3] -or $actualRole -cne $expected[4]) { $errors += "cross-reference: phase contract $index" }
        if ((@($phase.commonCheckIds) -join ',') -cne ($expectedCommon -join ',')) { $errors += "cross-reference: phase common checks $($phase.id)" }
        if ((@($phase.checkIds) -join ',') -cne (@($expected | Select-Object -Skip 5) -join ',')) { $errors += "cross-reference: phase checks $($phase.id)" }
    }

    $glossary = $documents['glossary.json']
    if (-not (Test-TeamBobGovernanceExactProperties $glossary @('policyVersion', 'terms')) -or $glossary.policyVersion -ne '0.2.0-poc') { $errors += 'shape: glossary document' }
    $expectedTermIds = @(
        'TERM-WORK-PACKET', 'TERM-REQID', 'TERM-IMMUTABLE-SOURCE-ANCHOR', 'TERM-REQUIREMENT-LEDGER', 'TERM-WORD-BASELINE', 'TERM-QA-BASELINE',
        'TERM-SPEC-BASELINE', 'TERM-ALLOWED-FILES', 'TERM-FORBIDDEN-AREAS', 'TERM-OPEN-QA', 'TERM-GREEN', 'TERM-QUALIFICATION', 'TERM-MAKE',
        'TERM-REBUILD', 'TERM-READY-FOR-HUMAN-REVIEW', 'TERM-SUCCEEDED', 'TERM-CODE-FAILED-RETRYABLE', 'TERM-CODE-FAILED-STOP',
        'TERM-ENVIRONMENT-FAILED', 'TERM-TIMED-OUT', 'TERM-INTEGRITY-FAILED', 'TERM-SPECIFICATION-APPROVER', 'TERM-IMPLEMENTATION-APPROVER',
        'TERM-INDEPENDENT-REVIEWER', 'TERM-ACTUAL-MACHINE', 'TERM-CONTROL-NETWORK', 'TERM-MAINLINE', 'TERM-SECRETS'
    )
    if ((@($glossary.terms.id) -join ',') -cne ($expectedTermIds -join ',')) { $errors += 'ids: glossary IDs must be exact and unique' }
    $expectedCanonical = @(
        'Work Packet', 'ReqID', 'Immutable Source Anchor', 'Requirement Ledger', 'Word Baseline', 'QA Baseline', 'Spec Baseline',
        'Allowed Files', 'Forbidden Areas', 'Open QA', 'Green', 'Qualification', 'Make', 'Rebuild', 'READY_FOR_HUMAN_REVIEW',
        'SUCCEEDED', 'CODE_FAILED_RETRYABLE', 'CODE_FAILED_STOP', 'ENVIRONMENT_FAILED', 'TIMED_OUT', 'INTEGRITY_FAILED',
        'Specification Approver', 'Implementation Approver', 'Independent Reviewer', 'Actual Machine', 'Control Network', 'Mainline', 'Secrets'
    )
    $expectedOwners = @(
        'SPECIFICATION_APPROVER', 'SPECIFICATION_APPROVER', 'SPECIFICATION_APPROVER', 'SPECIFICATION_APPROVER',
        'SPECIFICATION_APPROVER', 'SPECIFICATION_APPROVER', 'SPECIFICATION_APPROVER', 'IMPLEMENTATION_APPROVER',
        'IMPLEMENTATION_APPROVER', 'SPECIFICATION_APPROVER', 'IMPLEMENTATION_APPROVER', 'IMPLEMENTATION_APPROVER',
        'IMPLEMENTATION_APPROVER', 'IMPLEMENTATION_APPROVER', 'INDEPENDENT_REVIEWER', 'IMPLEMENTATION_APPROVER',
        'IMPLEMENTATION_APPROVER', 'IMPLEMENTATION_APPROVER', 'IMPLEMENTATION_APPROVER', 'IMPLEMENTATION_APPROVER',
        'IMPLEMENTATION_APPROVER', 'SPECIFICATION_APPROVER', 'IMPLEMENTATION_APPROVER', 'INDEPENDENT_REVIEWER',
        'IMPLEMENTATION_APPROVER', 'IMPLEMENTATION_APPROVER', 'IMPLEMENTATION_APPROVER', 'IMPLEMENTATION_APPROVER'
    )
    $expectedForbidden = @('', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '', '')
    $expectedForbidden[0] = 'WorkPacket'
    $expectedForbidden[1] = 'Req ID'
    $expectedForbidden[14] = 'ready-for-review'
    $expectedForbidden[15] = 'Build Success'
    $expectedForbidden[17] = 'Build Failure'
    $termValues = @{}
    for ($termIndex = 0; $termIndex -lt @($glossary.terms).Count; $termIndex++) {
        $term = $glossary.terms[$termIndex]
        if (-not (Test-TeamBobGovernanceExactProperties $term @('id', 'canonical', 'definition', 'aliases', 'forbidden', 'ownerRole', 'status', 'replacementTermId'))) { $errors += "shape: glossary term $($term.id)"; continue }
        if (-not ($term.definition -is [string]) -or [string]::IsNullOrWhiteSpace($term.definition) -or -not ($term.aliases -is [System.Array]) -or -not ($term.forbidden -is [System.Array]) -or
            $term.status -ne 'ACTIVE' -or $null -ne $term.replacementTermId -or @('SPECIFICATION_APPROVER', 'IMPLEMENTATION_APPROVER', 'INDEPENDENT_REVIEWER') -notcontains $term.ownerRole) { $errors += "shape: glossary term values $($term.id)" }
        if ($termIndex -lt $expectedCanonical.Count -and $term.canonical -cne $expectedCanonical[$termIndex]) { $errors += "canonical text: $($term.id)" }
        if ($termIndex -lt $expectedOwners.Count -and $term.ownerRole -cne $expectedOwners[$termIndex]) { $errors += "owner role: $($term.id)" }
        if ($termIndex -lt $expectedForbidden.Count -and (@($term.forbidden) -join ',') -cne $expectedForbidden[$termIndex]) { $errors += "forbidden spellings: $($term.id)" }
        foreach ($value in @($term.canonical) + @($term.aliases) + @($term.forbidden)) {
            if (-not ($value -is [string]) -or [string]::IsNullOrWhiteSpace($value)) { $errors += "shape: empty glossary value $($term.id)"; continue }
            $key = $value.ToLowerInvariant()
            if ($termValues.ContainsKey($key)) { $errors += "collision: glossary value '$value'" } else { $termValues[$key] = $term.id }
        }
    }

    $allChecks = @()
    foreach ($relativePath in @('checklists/authoring.json', 'checklists/review.json')) {
        $checklist = $documents[$relativePath]
        if (-not (Test-TeamBobGovernanceExactProperties $checklist @('policyVersion', 'checks')) -or $checklist.policyVersion -ne '0.2.0-poc') { $errors += "shape: $relativePath"; continue }
        foreach ($check in @($checklist.checks)) {
            if (-not (Test-TeamBobGovernanceExactProperties $check @('id', 'phase', 'title', 'kind', 'severity', 'allowNotApplicable', 'requiredEvidence') @('requiredRole'))) { $errors += "shape: checklist check $($check.id)"; continue }
            $allChecks += $check
        }
    }
    $expectedCheckIds = @($expectedCommon)
    foreach ($phase in $expectedPhases) { $expectedCheckIds += @($phase | Select-Object -Skip 5) }
    if ((@($allChecks.id | Sort-Object) -join ',') -cne (($expectedCheckIds | Sort-Object) -join ',')) { $errors += 'ids: checklist IDs must be exact and unique' }
    $evidenceEnum = @('path', 'line', 'sha256', 'rationale', 'command', 'approvalRecord', 'resultHash')
    foreach ($check in $allChecks) {
        $expectedKind = if ($check.id -match '-M-') { 'machine' } elseif ($check.id -match '-A-') { 'ai' } elseif ($check.id -match '-H-') { 'human' } else { '' }
        if (-not ($check.title -is [string]) -or [string]::IsNullOrWhiteSpace($check.title) -or $check.kind -ne $expectedKind -or $check.severity -ne 'blocker' -or
            -not ($check.allowNotApplicable -is [bool]) -or -not ($check.requiredEvidence -is [System.Array]) -or @($check.requiredEvidence).Count -eq 0 -or
            @($check.requiredEvidence | Where-Object { $evidenceEnum -notcontains $_ }).Count -gt 0) { $errors += "shape: checklist values $($check.id)" }
        if ($check.phase -ne 'common') {
            $phase = @($policy.phases | Where-Object { $_.id -eq $check.phase })
            if ($phase.Count -ne 1 -or @($phase[0].checkIds) -notcontains $check.id) { $errors += "cross-reference: checklist phase $($check.id)" }
            if ($check.kind -eq 'human') {
                if ($null -eq $check.PSObject.Properties['requiredRole'] -or $check.requiredRole -ne $phase[0].completionApprovalRole) { $errors += "cross-reference: human role $($check.id)" }
            } elseif ($null -ne $check.PSObject.Properties['requiredRole']) { $errors += "shape: non-human requiredRole $($check.id)" }
        }
    }
    $machineIds = @($allChecks | Where-Object { $_.kind -eq 'machine' } | ForEach-Object { $_.id } | Sort-Object)
    $mappingIds = @()
    foreach ($mapping in @($policy.machineCheckImplementations)) {
        if (-not (Test-TeamBobGovernanceExactProperties $mapping @('checkId', 'implementation')) -or [string]::IsNullOrWhiteSpace([string]$mapping.implementation)) { $errors += 'machine implementation: invalid mapping' }
        $mappingIds += $mapping.checkId
    }
    if ((@($mappingIds | Sort-Object) -join ',') -cne ($machineIds -join ',')) { $errors += 'machine implementation: mapping must cover every machine check exactly once' }

    $roles = $documents['roles.json']
    if (-not (Test-TeamBobGovernanceExactProperties $roles @('policyVersion', 'assignments')) -or $roles.policyVersion -ne '0.2.0-poc') { $errors += 'shape: roles document' }
    $assignmentIds = @{}
    foreach ($assignment in @($roles.assignments)) {
        if (-not (Test-TeamBobGovernanceExactProperties $assignment @('id', 'role', 'principalId', 'scope', 'status', 'validFromUtc', 'expiresAtUtc'))) { $errors += 'shape: role assignment'; continue }
        if ($assignmentIds.ContainsKey([string]$assignment.id)) { $errors += 'ids: duplicate role assignment' } else { $assignmentIds[[string]$assignment.id] = $true }
        if (@('SPECIFICATION_APPROVER', 'IMPLEMENTATION_APPROVER', 'INDEPENDENT_REVIEWER') -notcontains $assignment.role -or @('ACTIVE', 'INACTIVE') -notcontains $assignment.status -or @($assignment.scope).Count -eq 0) { $errors += "shape: role assignment values $($assignment.id)" }
        $from = [datetime]::MinValue; $to = [datetime]::MinValue
        if (-not [datetime]::TryParse([string]$assignment.validFromUtc, [ref]$from) -or -not [datetime]::TryParse([string]$assignment.expiresAtUtc, [ref]$to) -or $to -le $from) { $errors += "shape: role assignment dates $($assignment.id)" }
    }

    foreach ($relativePath in @($expectedFiles | Where-Object { $_ -like 'schemas/*' })) {
        $errors += @(Test-TeamBobGovernanceSchemaClosed $documents[$relativePath] $relativePath)
    }
    return @($errors)
}

function Test-TeamBobGovernanceStrictReadiness {
    param(
        [Parameter(Mandatory = $true)][string]$GovernanceRoot,
        [datetime]$NowUtc = [datetime]::UtcNow,
        [string]$Scope = '*'
    )
    $errors = @()
    $packageErrors = @(Test-TeamBobGovernancePackage -GovernanceRoot $GovernanceRoot)
    if ($packageErrors.Count -gt 0) { return @($packageErrors) }
    $roles = Get-TeamBobGovernanceJson (Join-Path $GovernanceRoot 'roles.json')
    $selected = @()
    foreach ($role in @('SPECIFICATION_APPROVER', 'IMPLEMENTATION_APPROVER', 'INDEPENDENT_REVIEWER')) {
        $matches = @($roles.assignments | Where-Object {
            $_.role -eq $role -and $_.status -eq 'ACTIVE' -and
            ([datetime]$_.validFromUtc).ToUniversalTime() -le $NowUtc.ToUniversalTime() -and
            ([datetime]$_.expiresAtUtc).ToUniversalTime() -gt $NowUtc.ToUniversalTime() -and
            (@($_.scope) -contains '*' -or @($_.scope) -contains $Scope)
        })
        if ($matches.Count -ne 1) { $errors += "strict: one active in-scope unexpired assignment required for $role" }
        else { $selected += $matches[0] }
    }
    if ($selected.Count -eq 3 -and @($selected.principalId | Sort-Object -Unique).Count -ne 3) { $errors += 'strict: role principals must be distinct' }
    return @($errors)
}
