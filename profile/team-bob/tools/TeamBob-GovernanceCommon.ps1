$ErrorActionPreference = 'Stop'

# Closed dispatch keys, not PowerShell command names. Task 2's evaluator must
# dispatch only through this exact registry and must not invoke policy strings.
$script:TeamBobMachineImplementationRegistry = [ordered]@{
    'GOV-M-001' = 'governance.integrity'
    'GOV-M-002' = 'governance.phase-prerequisites'
    'GOV-M-003' = 'governance.path-encoding'
    'GOV-M-004' = 'governance.forbidden-terminology'
    'REQ-M-001' = 'requirements.ledger-identity'
    'SPEC-M-001' = 'specification.required-sections'
    'SPEC-M-002' = 'specification.reqid-references'
    'IMP-M-001' = 'impact.required-areas'
    'IMPL-M-001' = 'implementation.entry-gates'
    'IMPL-M-002' = 'implementation.allowed-files'
    'IMPL-M-003' = 'implementation.legacy-encoding'
    'IMPL-M-004' = 'implementation.build-evidence'
    'REV-M-001' = 'review.finding-shape'
    'TEST-M-001' = 'test.traceability'
}

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
    $actual = @($Value.PSObject.Properties.Name)
    $allowed = @($Required + $Optional)
    if ($actual.Count -lt $Required.Count -or $actual.Count -gt $allowed.Count) { return $false }
    foreach ($requiredName in $Required) {
        $found = $false
        foreach ($actualName in $actual) {
            if ([string]::Equals($actualName, $requiredName, [System.StringComparison]::Ordinal)) { $found = $true; break }
        }
        if (-not $found) { return $false }
    }
    foreach ($actualName in $actual) {
        $found = $false
        foreach ($allowedName in $allowed) {
            if ([string]::Equals($actualName, $allowedName, [System.StringComparison]::Ordinal)) { $found = $true; break }
        }
        if (-not $found) { return $false }
    }
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

function ConvertFrom-TeamBobGovernanceUtcInstant {
    param([object]$Value)
    if (-not ($Value -is [string]) -or $Value -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?Z$') { return $null }
    $parsed = [datetimeoffset]::MinValue
    $formats = [string[]]@("yyyy-MM-dd'T'HH:mm:ss'Z'", "yyyy-MM-dd'T'HH:mm:ss.FFFFFFF'Z'")
    $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
    if (-not [datetimeoffset]::TryParseExact($Value, $formats, [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) { return $null }
    return $parsed
}

function Test-TeamBobGovernanceUniqueStrings {
    param([object[]]$Values)
    for ($left = 0; $left -lt $Values.Count; $left++) {
        for ($right = $left + 1; $right -lt $Values.Count; $right++) {
            if ([string]::Equals([string]$Values[$left], [string]$Values[$right], [System.StringComparison]::Ordinal)) { return $false }
        }
    }
    return $true
}

function Test-TeamBobGovernanceRoleAssignment {
    param([object]$Assignment)
    $errors = @()
    $fields = @('assignmentId', 'role', 'principalId', 'scope', 'enabled', 'validFromUtc', 'validUntilUtc')
    if (-not (Test-TeamBobGovernanceExactProperties $Assignment $fields)) { return @('shape: role assignment fields') }
    if (-not ($Assignment.assignmentId -is [string]) -or $Assignment.assignmentId -cnotmatch '^ASSIGN-[A-Z0-9]+(?:-[A-Z0-9]+)*$') { $errors += 'shape: role assignmentId' }
    if (-not ($Assignment.principalId -is [string]) -or [string]::IsNullOrWhiteSpace($Assignment.principalId)) { $errors += 'shape: role principalId' }
    if (@('SPECIFICATION_APPROVER', 'IMPLEMENTATION_APPROVER', 'INDEPENDENT_REVIEWER') -cnotcontains $Assignment.role) { $errors += 'shape: role enum' }
    if (-not ($Assignment.enabled -is [bool])) { $errors += 'shape: role enabled' }
    if (-not (Test-TeamBobGovernanceExactProperties $Assignment.scope @('allTasks', 'taskIds', 'phases'))) {
        $errors += 'shape: role scope'
    } else {
        if (-not ($Assignment.scope.allTasks -is [bool])) { $errors += 'shape: role scope allTasks' }
        if (-not ($Assignment.scope.taskIds -is [System.Array])) {
            $errors += 'shape: role scope taskIds'
        } else {
            foreach ($taskId in @($Assignment.scope.taskIds)) {
                if (-not ($taskId -is [string]) -or [string]::IsNullOrWhiteSpace($taskId)) { $errors += 'shape: role scope taskId' }
            }
            if (-not (Test-TeamBobGovernanceUniqueStrings @($Assignment.scope.taskIds))) { $errors += 'shape: duplicate role scope taskId' }
            if ($Assignment.scope.allTasks -eq $true -and @($Assignment.scope.taskIds).Count -ne 0) { $errors += 'shape: role scope allTasks/taskIds consistency' }
            if ($Assignment.scope.allTasks -eq $false -and @($Assignment.scope.taskIds).Count -eq 0) { $errors += 'shape: role scope allTasks/taskIds consistency' }
        }
        if (-not ($Assignment.scope.phases -is [System.Array]) -or @($Assignment.scope.phases).Count -eq 0) {
            $errors += 'shape: role scope phases'
        } else {
            $phaseIds = @('requirements', 'specification', 'impact', 'implementation', 'review', 'test')
            foreach ($phase in @($Assignment.scope.phases)) {
                if (-not ($phase -is [string]) -or $phaseIds -cnotcontains $phase) { $errors += 'shape: role scope phase' }
            }
            if (-not (Test-TeamBobGovernanceUniqueStrings @($Assignment.scope.phases))) { $errors += 'shape: duplicate role scope phase' }
        }
    }
    $validFrom = ConvertFrom-TeamBobGovernanceUtcInstant $Assignment.validFromUtc
    $validUntil = ConvertFrom-TeamBobGovernanceUtcInstant $Assignment.validUntilUtc
    if ($null -eq $validFrom -or $null -eq $validUntil -or $validUntil -le $validFrom) { $errors += 'shape: role assignment UTC validity' }
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
        $registeredImplementation = $null
        foreach ($registeredCheckId in $script:TeamBobMachineImplementationRegistry.Keys) {
            if ([string]$registeredCheckId -ceq [string]$mapping.checkId) { $registeredImplementation = $script:TeamBobMachineImplementationRegistry[$registeredCheckId]; break }
        }
        if ($null -eq $registeredImplementation -or [string]$mapping.implementation -cne [string]$registeredImplementation) {
            $errors += "machine implementation registry: unsupported mapping $($mapping.checkId)=$($mapping.implementation)"
        }
    }
    if ((@($mappingIds | Sort-Object) -join ',') -cne ($machineIds -join ',')) { $errors += 'machine implementation: mapping must cover every machine check exactly once' }
    if ($script:TeamBobMachineImplementationRegistry.Count -ne $machineIds.Count) { $errors += 'machine implementation registry: registry must cover every machine check exactly once' }

    $roles = $documents['roles.json']
    if (-not (Test-TeamBobGovernanceExactProperties $roles @('policyVersion', 'assignments')) -or $roles.policyVersion -ne '0.2.0-poc') { $errors += 'shape: roles document' }
    if (-not ($roles.assignments -is [System.Array])) { $errors += 'shape: roles assignments array' }
    $assignmentIds = @{}
    foreach ($assignment in @($roles.assignments)) {
        $assignmentErrors = @(Test-TeamBobGovernanceRoleAssignment $assignment)
        foreach ($assignmentError in $assignmentErrors) { $errors += $assignmentError }
        if ($assignmentErrors.Count -eq 0) {
            if ($assignmentIds.ContainsKey([string]$assignment.assignmentId)) { $errors += 'ids: duplicate role assignment' } else { $assignmentIds[[string]$assignment.assignmentId] = $true }
        }
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
        [string]$TaskId = '*',
        [string]$Phase = ''
    )
    $errors = @()
    $packageErrors = @(Test-TeamBobGovernancePackage -GovernanceRoot $GovernanceRoot)
    if ($packageErrors.Count -gt 0) { return @($packageErrors) }
    $roles = Get-TeamBobGovernanceJson (Join-Path $GovernanceRoot 'roles.json')
    $selected = @()
    foreach ($role in @('SPECIFICATION_APPROVER', 'IMPLEMENTATION_APPROVER', 'INDEPENDENT_REVIEWER')) {
        $matches = @($roles.assignments | Where-Object {
            @(Test-TeamBobGovernanceRoleAssignment $_).Count -eq 0 -and $_.role -ceq $role -and $_.enabled -eq $true -and
            (ConvertFrom-TeamBobGovernanceUtcInstant $_.validFromUtc) -le ([datetimeoffset]$NowUtc.ToUniversalTime()) -and
            (ConvertFrom-TeamBobGovernanceUtcInstant $_.validUntilUtc) -gt ([datetimeoffset]$NowUtc.ToUniversalTime()) -and
            ($_.scope.allTasks -eq $true -or @($_.scope.taskIds) -ccontains $TaskId) -and
            ([string]::IsNullOrWhiteSpace($Phase) -or @($_.scope.phases) -ccontains $Phase)
        })
        if ($matches.Count -ne 1) { $errors += "strict: one active in-scope unexpired assignment required for $role" }
        else { $selected += $matches[0] }
    }
    if ($selected.Count -eq 3 -and @($selected.principalId | Sort-Object -Unique).Count -ne 3) { $errors += 'strict: role principals must be distinct' }
    return @($errors)
}
