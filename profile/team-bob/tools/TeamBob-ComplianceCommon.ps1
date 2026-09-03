$ErrorActionPreference = 'Stop'

$script:TeamBobPhaseOrder = @('requirements', 'specification', 'impact', 'implementation', 'review', 'test')

function New-TeamBobComplianceFailure {
    param([ValidateSet(20, 30)][int]$ExitCode, [string]$Message)
    $status = if ($ExitCode -eq 30) { 'INTEGRITY_FAILED' } else { 'CONTRACT_INVALID' }
    return New-TeamBobFailure $status $Message $ExitCode
}

function Read-TeamBobComplianceJson {
    param([string]$Path, [string]$Label)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw (New-TeamBobComplianceFailure 30 "$Label does not exist: $Path") }
    try { return Get-TeamBobGovernanceJson $Path }
    catch { throw (New-TeamBobComplianceFailure 20 "$Label is invalid: $($_.Exception.Message)") }
}

function Write-TeamBobCreateOnlyJson {
    param([string]$Path, [object]$Value)
    $json = ($Value | ConvertTo-Json -Depth 40) + [Environment]::NewLine
    Write-TeamBobCreateOnlyText $Path $json
}

function Write-TeamBobCreateOnlyText {
    param([string]$Path, [string]$Text)
    $bytes = (New-Object System.Text.UTF8Encoding($false, $true)).GetBytes($Text)
    $stream = $null
    try {
        $stream = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    } catch { throw (New-TeamBobComplianceFailure 30 "Create-only publication failed: $($_.Exception.Message)") }
    finally { if ($null -ne $stream) { $stream.Dispose() } }
}

function Write-TeamBobAtomicStateJson {
    param([string]$Path, [object]$Value)
    $parent = Split-Path -Parent $Path
    $temporary = Join-Path $parent ('.phase-state-' + [guid]::NewGuid().ToString('N') + '.tmp')
    $backup = Join-Path $parent ('.phase-state-' + [guid]::NewGuid().ToString('N') + '.bak')
    try {
        Write-TeamBobCreateOnlyJson $temporary $Value
        if (Test-Path -LiteralPath $Path -PathType Leaf) { [System.IO.File]::Replace($temporary, $Path, $backup); [System.IO.File]::Delete($backup) }
        else { [System.IO.File]::Move($temporary, $Path) }
    } catch {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) { [System.IO.File]::Delete($temporary) }
        if (Test-Path -LiteralPath $backup -PathType Leaf) { [System.IO.File]::Delete($backup) }
        throw
    }
}

function Assert-TeamBobComplianceExactProperties {
    param([object]$Value, [string[]]$Names, [string]$Label)
    if (-not (Test-TeamBobGovernanceExactProperties $Value $Names)) { throw (New-TeamBobComplianceFailure 20 "$Label has missing, mis-cased, or unsupported fields.") }
}

function Get-TeamBobGovernanceRoots {
    param([string]$ToolsRoot)
    $teamBobRoot = Split-Path -Parent $ToolsRoot
    $profileRoot = Split-Path -Parent $teamBobRoot
    return [pscustomobject]@{ ProfileRoot = $profileRoot; GovernanceRoot = (Join-Path $profileRoot '.bob\governance'); ManifestPath = (Join-Path $teamBobRoot 'profile-manifest.json') }
}

function Get-TeamBobCurrentGovernance {
    param([string]$ToolsRoot, [object]$Packet)
    $roots = Get-TeamBobGovernanceRoots $ToolsRoot
    $errors = @(Test-TeamBobGovernancePackage -GovernanceRoot $roots.GovernanceRoot)
    if ($errors.Count -gt 0) { throw (New-TeamBobComplianceFailure 20 ('Governance package is invalid: ' + ($errors -join '; '))) }
    $manifest = Read-TeamBobComplianceJson $roots.ManifestPath 'Profile manifest'
    if (-not ($manifest.version -is [string]) -or $manifest.version -cne '0.2.0-poc') { throw (New-TeamBobComplianceFailure 20 'Profile manifest version is not 0.2.0-poc.') }
    $policy = Read-TeamBobComplianceJson (Join-Path $roots.GovernanceRoot 'policy-manifest.json') 'Policy manifest'
    $roles = Read-TeamBobComplianceJson (Join-Path $roots.GovernanceRoot 'roles.json') 'Role ledger'
    $policyHash = Get-TeamBobPolicyBundleHash $roots.GovernanceRoot
    $roleHash = Get-TeamBobRoleLedgerHash $roots.GovernanceRoot
    if ($Packet.'Policy Version' -cne $policy.policyVersion) { throw (New-TeamBobComplianceFailure 20 'Work packet Policy Version does not cross-reference the current policy.') }
    if ($Packet.'Policy Bundle SHA256' -cne $policyHash) { throw (New-TeamBobComplianceFailure 30 'Work packet Policy Bundle SHA256 is not current.') }
    if ($Packet.'Role Ledger SHA256' -cne $roleHash) { throw (New-TeamBobComplianceFailure 30 'Work packet Role Ledger SHA256 is not current.') }
    return [pscustomobject]@{ Roots = $roots; Policy = $policy; Roles = $roles; PolicyHash = $policyHash; RoleHash = $roleHash }
}

function Get-TeamBobTaskGovernanceContext {
    param([string]$WorkPacketPath, [object]$Packet)
    if (-not (Test-TeamBobAbsolutePath $WorkPacketPath)) { throw (New-TeamBobComplianceFailure 30 'WorkPacket must be absolute.') }
    $packetFull = Get-TeamBobCanonicalPath $WorkPacketPath 'Work packet' 'INTEGRITY_FAILED'
    [void](Get-TeamBobPhysicalPath $packetFull 'Work packet' 'Leaf' 'INTEGRITY_FAILED')
    if (-not (Test-TeamBobAbsolutePath ([string]$Packet.'Bazaar Root'))) { throw (New-TeamBobComplianceFailure 30 'Bazaar Root must be absolute.') }
    $bazaarRoot = Get-TeamBobCanonicalPath ([string]$Packet.'Bazaar Root') 'Bazaar Root' 'INTEGRITY_FAILED'
    if (-not (Test-Path -LiteralPath (Join-Path $bazaarRoot '.bzr') -PathType Container)) { throw (New-TeamBobComplianceFailure 30 'Bazaar Root must contain .bzr.') }
    $bazaarPhysical=Get-TeamBobPhysicalPath $bazaarRoot 'Bazaar Root' 'Container' 'INTEGRITY_FAILED'
    $bzrPhysical=Get-TeamBobPhysicalPath (Join-Path $bazaarRoot '.bzr') 'Bazaar metadata root' 'Container' 'INTEGRITY_FAILED';Assert-TeamBobPhysicalChild $bzrPhysical $bazaarPhysical 'Bazaar metadata root' 'INTEGRITY_FAILED'
    $taskRoot = Get-TeamBobCanonicalPath (Join-Path $bazaarRoot (Join-Path 'team-bob-work' ([string]$Packet.'Task ID'))) 'Task root' 'INTEGRITY_FAILED'
    $expectedPacket = Join-Path $taskRoot 'work-packet.md'
    if (-not $packetFull.Equals($expectedPacket, [System.StringComparison]::OrdinalIgnoreCase)) { throw (New-TeamBobComplianceFailure 30 'Work packet path does not match Task ID and Bazaar Root.') }
    $taskPhysical = Get-TeamBobPhysicalPath $taskRoot 'Task root' 'Container' 'INTEGRITY_FAILED'
    Assert-TeamBobPhysicalChild $taskPhysical $bazaarPhysical 'Task root' 'INTEGRITY_FAILED'
    $childPhysical=@{}
    foreach ($child in @('drafts', 'approvals', 'results', 'state')) {
        $path = Join-Path $taskRoot $child
        if (-not (Test-Path -LiteralPath $path -PathType Container)) { throw (New-TeamBobComplianceFailure 30 "Task directory is missing: $child") }
        $physical = Get-TeamBobPhysicalPath $path "Task $child" 'Container' 'INTEGRITY_FAILED'
        Assert-TeamBobPhysicalChild $physical $taskPhysical "Task $child" 'INTEGRITY_FAILED'
        $childPhysical[$child]=$physical
    }
    $statePath=Join-Path $taskRoot 'state\phase-state.json'
    if(-not(Test-Path -LiteralPath $statePath -PathType Leaf)){throw (New-TeamBobComplianceFailure 30 'Phase state is missing.')}
    $statePhysical=Get-TeamBobPhysicalPath $statePath 'Phase state' 'Leaf' 'INTEGRITY_FAILED';Assert-TeamBobPhysicalChild $statePhysical $childPhysical['state'] 'Phase state' 'INTEGRITY_FAILED'
    return [pscustomobject]@{ TaskId = [string]$Packet.'Task ID'; TaskRoot = $taskRoot; TaskPhysical = $taskPhysical; BazaarPhysical=$bazaarPhysical;DraftsPhysical=$childPhysical['drafts'];ApprovalsPhysical=$childPhysical['approvals'];ResultsPhysical=$childPhysical['results'];StatePhysical=$statePhysical;PacketPath = $packetFull; PacketHash = (Get-TeamBobGovernanceFileHash $packetFull); StatePath = $statePath;StateHash=(Get-TeamBobGovernanceFileHash $statePath) }
}

function Get-TeamBobSelectedAssignments {
    param([object]$Packet, [object]$Roles, [string]$TaskId, [switch]$RequireActive, [datetimeoffset]$AtUtc = [datetimeoffset]::UtcNow)
    $contracts = @(
        [pscustomobject]@{ Field='Specification Assignment ID'; Role='SPECIFICATION_APPROVER'; Phases=@('specification','test') },
        [pscustomobject]@{ Field='Implementation Assignment ID'; Role='IMPLEMENTATION_APPROVER'; Phases=@('impact') },
        [pscustomobject]@{ Field='Independent Reviewer Assignment ID'; Role='INDEPENDENT_REVIEWER'; Phases=@('review') }
    )
    $selected = @{}
    $principalSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($contract in $contracts) {
        $assignmentId = [string]$Packet.PSObject.Properties[$contract.Field].Value
        $matches = @($Roles.assignments | Where-Object { $_.assignmentId -ceq $assignmentId })
        if ($matches.Count -ne 1) { throw (New-TeamBobComplianceFailure 20 "Selected assignment is missing or duplicated: $assignmentId") }
        $assignment = $matches[0]
        if (@(Test-TeamBobGovernanceRoleAssignment $assignment).Count -gt 0 -or $assignment.role -cne $contract.Role -or $assignment.enabled -ne $true) { throw (New-TeamBobComplianceFailure 20 "Selected assignment has an invalid role or is disabled: $assignmentId") }
        if (-not ($assignment.scope.allTasks -eq $true -or @($assignment.scope.taskIds) -ccontains $TaskId)) { throw (New-TeamBobComplianceFailure 20 "Selected assignment is out of task scope: $assignmentId") }
        foreach ($phase in $contract.Phases) { if (@($assignment.scope.phases) -cnotcontains $phase) { throw (New-TeamBobComplianceFailure 20 "Selected assignment lacks required phase scope: $assignmentId/$phase") } }
        if ($RequireActive) {
            $validFrom = ConvertFrom-TeamBobGovernanceUtcInstant $assignment.validFromUtc
            $validUntil = ConvertFrom-TeamBobGovernanceUtcInstant $assignment.validUntilUtc
            if ($null -eq $validFrom -or $null -eq $validUntil -or $validFrom -gt $AtUtc -or $validUntil -le $AtUtc) { throw (New-TeamBobComplianceFailure 20 "Selected assignment is not active: $assignmentId") }
        }
        if (-not $principalSet.Add([string]$assignment.principalId)) { throw (New-TeamBobComplianceFailure 20 'Selected assignments violate separation of duties.') }
        $selected[$contract.Role] = $assignment
    }
    return $selected
}

function Assert-TeamBobPriorComplianceResult {
    param([object]$Result,[object]$Context,[object]$Governance,[string]$ExpectedPhase)
    Assert-TeamBobComplianceExactProperties $Result @('schemaVersion','profileVersion','policyVersion','taskId','phase','evaluatedAtUtc','status','workPacketPath','workPacketSha256','policyBundleSha256','roleLedgerSha256','artifactPath','artifactSha256','assessmentPath','assessmentSha256','approvalRecordPath','approvalRecordSha256','prerequisiteResultPath','prerequisiteResultSha256','checks') 'Prior compliance result'
    if($Result.schemaVersion -cne '1.0' -or $Result.profileVersion -cne '0.2.0-poc' -or $Result.policyVersion -cne '0.2.0-poc' -or $Result.taskId -cne $Context.TaskId -or $Result.phase -cne $ExpectedPhase -or $Result.status -cne 'PASS' -or $Result.workPacketPath -cne $Context.PacketPath -or $null -eq (ConvertFrom-TeamBobGovernanceUtcInstant $Result.evaluatedAtUtc)){throw (New-TeamBobComplianceFailure 20 'Prior compliance result identity is invalid.')}
    if($Result.workPacketSha256 -cne $Context.PacketHash -or $Result.policyBundleSha256 -cne $Governance.PolicyHash -or $Result.roleLedgerSha256 -cne $Governance.RoleHash){throw (New-TeamBobComplianceFailure 30 'Prior compliance result governance anchors changed.')}
    $phasePolicy=Get-TeamBobPhasePolicy $Governance.Policy $ExpectedPhase
    $definitions=Get-TeamBobChecklistDefinitions $Governance $phasePolicy
    if(-not($Result.checks -is [System.Array]) -or (@($Result.checks|ForEach-Object{[string]$_.id}) -join "`n") -cne (@($definitions|ForEach-Object{[string]$_.id}) -join "`n")){throw (New-TeamBobComplianceFailure 20 'Prior compliance result check order or coverage is invalid.')}
    for($index=0;$index -lt @($definitions).Count;$index++){
        $definition=$definitions[$index];$check=$Result.checks[$index]
        Assert-TeamBobComplianceExactProperties $check @('id','kind','status','evidence','message') "Prior result check $index"
        if($check.id -cne $definition.id -or $check.kind -cne $definition.kind -or $check.status -cne 'PASS' -or -not($check.message -is [string]) -or [string]::IsNullOrWhiteSpace($check.message) -or -not($check.evidence -is [System.Array]) -or -not(Test-TeamBobEvidenceTypes @($check.evidence) @($definition.requiredEvidence))){throw (New-TeamBobComplianceFailure 20 "Prior result check is invalid: $($definition.id)")}
        foreach($item in @($check.evidence)){
            Assert-TeamBobComplianceExactProperties $item @('type','value') "Prior result evidence $($definition.id)"
            if(@('path','line','sha256','rationale','command','approvalRecord','resultHash') -cnotcontains $item.type -or -not($item.value -is [string]) -or [string]::IsNullOrWhiteSpace($item.value)){throw (New-TeamBobComplianceFailure 20 "Prior result evidence is invalid: $($definition.id)")}
            if($item.type -ceq 'line' -and $item.value -cnotmatch '^[1-9][0-9]*$'){throw (New-TeamBobComplianceFailure 20 'Prior result line evidence is invalid.')}
            if(@('sha256','resultHash') -ccontains $item.type -and $item.value -cnotmatch '^[0-9a-f]{64}$'){throw (New-TeamBobComplianceFailure 20 'Prior result hash evidence is invalid.')}
            if($item.type -ceq 'command' -and @('Make','Rebuild') -cnotcontains $item.value){throw (New-TeamBobComplianceFailure 20 'Prior result command evidence is invalid.')}
        }
    }
    foreach($reference in @(
        [pscustomobject]@{Path=[string]$Result.artifactPath;Hash=$Result.artifactSha256;Root=$Context.TaskPhysical;Label='Prior artifact'},
        [pscustomobject]@{Path=[string]$Result.assessmentPath;Hash=$Result.assessmentSha256;Root=$Context.TaskPhysical;Label='Prior assessment'}
    )){
        if([string]::IsNullOrWhiteSpace($reference.Path) -or -not($reference.Hash -is [string]) -or $reference.Hash -cnotmatch '^[0-9a-f]{64}$'){throw (New-TeamBobComplianceFailure 20 "$($reference.Label) reference is invalid.")}
        $full=Get-TeamBobCanonicalPath (Join-Path $Context.TaskRoot $reference.Path) $reference.Label 'INTEGRITY_FAILED'
        if(-not(Test-TeamBobPathAtOrBelow $full $Context.TaskRoot) -or -not(Test-Path -LiteralPath $full -PathType Leaf)){throw (New-TeamBobComplianceFailure 30 "$($reference.Label) is outside the task or missing.")}
        $physical=Get-TeamBobPhysicalPath $full $reference.Label 'Leaf' 'INTEGRITY_FAILED';Assert-TeamBobPhysicalChild $physical $reference.Root $reference.Label 'INTEGRITY_FAILED'
        if((Get-TeamBobGovernanceFileHash $full) -cne $reference.Hash){throw (New-TeamBobComplianceFailure 30 "$($reference.Label) hash changed.")}
    }
    if(-not([string]$Result.artifactPath -clike ([string]$phasePolicy.artifact).Replace('\','/'))){throw (New-TeamBobComplianceFailure 20 'Prior result artifact does not match phase policy.')}
    if($null -eq $phasePolicy.completionApprovalRole){if($null -ne $Result.approvalRecordPath -or $null -ne $Result.approvalRecordSha256){throw (New-TeamBobComplianceFailure 20 'Prior result has an unexpected approval reference.')}}
    else{
        if(-not($Result.approvalRecordPath -is [string]) -or -not($Result.approvalRecordSha256 -is [string]) -or $Result.approvalRecordSha256 -cnotmatch '^[0-9a-f]{64}$'){throw (New-TeamBobComplianceFailure 20 'Prior result approval reference is invalid.')}
        $approvalFull=Get-TeamBobCanonicalPath (Join-Path $Context.TaskRoot ([string]$Result.approvalRecordPath)) 'Prior approval' 'INTEGRITY_FAILED'
        if(-not(Test-TeamBobPathAtOrBelow $approvalFull (Join-Path $Context.TaskRoot 'approvals')) -or -not(Test-Path -LiteralPath $approvalFull -PathType Leaf)){throw (New-TeamBobComplianceFailure 30 'Prior approval is outside approvals or missing.')}
        $approvalPhysical=Get-TeamBobPhysicalPath $approvalFull 'Prior approval' 'Leaf' 'INTEGRITY_FAILED';Assert-TeamBobPhysicalChild $approvalPhysical $Context.ApprovalsPhysical 'Prior approval' 'INTEGRITY_FAILED'
        if((Get-TeamBobGovernanceFileHash $approvalFull) -cne $Result.approvalRecordSha256){throw (New-TeamBobComplianceFailure 30 'Prior approval hash changed.')}
    }
    $hasPreviousPath=$Result.prerequisiteResultPath -is [string];$hasPreviousHash=$Result.prerequisiteResultSha256 -is [string]
    if($hasPreviousPath -ne $hasPreviousHash -or ($hasPreviousHash -and $Result.prerequisiteResultSha256 -cnotmatch '^[0-9a-f]{64}$')){throw (New-TeamBobComplianceFailure 20 'Prior result prerequisite reference is invalid.')}
    $phaseIndex=[array]::IndexOf($script:TeamBobPhaseOrder,$ExpectedPhase)
    if($phaseIndex -eq 0 -and ($null -ne $Result.prerequisiteResultPath -or $null -ne $Result.prerequisiteResultSha256)){throw(New-TeamBobComplianceFailure 20 'Requirements result must have a null predecessor.')}
    if($phaseIndex -gt 0 -and (-not $hasPreviousPath -or -not $hasPreviousHash)){throw(New-TeamBobComplianceFailure 20 'Non-requirements result must reference its exact predecessor.')}
    Assert-TeamBobPriorReferencedContracts $Result $Context $Governance $ExpectedPhase
}

function Assert-TeamBobPhaseState {
    param([object]$State, [object]$Context, [object]$Governance, [string]$Phase)
    Assert-TeamBobComplianceExactProperties $State @('schemaVersion','profileVersion','policyVersion','taskId','currentPhase','completedPhases','workPacketPath','workPacketSha256','policyBundleSha256','roleLedgerSha256','latestResultPath','latestResultSha256','updatedAtUtc') 'Phase state'
    if ($State.schemaVersion -cne '1.0' -or $State.profileVersion -cne '0.2.0-poc' -or $State.policyVersion -cne '0.2.0-poc' -or $State.taskId -cne $Context.TaskId) { throw (New-TeamBobComplianceFailure 20 'Phase state identity is invalid.') }
    if (-not ($State.completedPhases -is [System.Array]) -or $null -eq (ConvertFrom-TeamBobGovernanceUtcInstant $State.updatedAtUtc)) { throw (New-TeamBobComplianceFailure 20 'Phase state sequence or timestamp is invalid.') }
    if ($State.workPacketPath -cne $Context.PacketPath -or $State.workPacketSha256 -cne $Context.PacketHash -or $State.policyBundleSha256 -cne $Governance.PolicyHash -or $State.roleLedgerSha256 -cne $Governance.RoleHash) { throw (New-TeamBobComplianceFailure 30 'Phase state integrity anchors changed.') }
    $phaseIndex = [array]::IndexOf($script:TeamBobPhaseOrder, $Phase)
    if ($phaseIndex -lt 0 -or $State.currentPhase -cne $Phase) { throw (New-TeamBobComplianceFailure 20 'Requested phase is out of order or already completed.') }
    $expectedPrefix = @($script:TeamBobPhaseOrder | Select-Object -First $phaseIndex)
    if ((@($State.completedPhases) -join "`n") -cne ($expectedPrefix -join "`n")) { throw (New-TeamBobComplianceFailure 20 'Completed phases are not the exact ordered prefix.') }
    if ($phaseIndex -eq 0) {
        if ($null -ne $State.latestResultPath -or $null -ne $State.latestResultSha256) { throw (New-TeamBobComplianceFailure 20 'Requirements state must not have a prerequisite result.') }
        return $null
    }
    if (-not ($State.latestResultPath -is [string]) -or -not ($State.latestResultSha256 -is [string])) { throw (New-TeamBobComplianceFailure 20 'Phase prerequisite result reference is missing.') }
    $previousPath = Get-TeamBobCanonicalPath (Join-Path $Context.TaskRoot ([string]$State.latestResultPath)) 'Prerequisite result' 'INTEGRITY_FAILED'
    if (-not (Test-TeamBobPathAtOrBelow $previousPath (Join-Path $Context.TaskRoot 'results'))) { throw (New-TeamBobComplianceFailure 30 'Prerequisite result path escapes results.') }
    if ((Get-TeamBobGovernanceFileHash $previousPath) -cne $State.latestResultSha256) { throw (New-TeamBobComplianceFailure 30 'Prerequisite result hash changed.') }
    $previousPhysical=Get-TeamBobPhysicalPath $previousPath 'Prerequisite result' 'Leaf' 'INTEGRITY_FAILED';Assert-TeamBobPhysicalChild $previousPhysical $Context.ResultsPhysical 'Prerequisite result' 'INTEGRITY_FAILED'
    $previous = Read-TeamBobComplianceJson $previousPath 'Prerequisite compliance result'
    Assert-TeamBobPriorComplianceResult $previous $Context $Governance $expectedPrefix[-1]
    if ($previous.taskId -cne $Context.TaskId -or $previous.phase -cne $expectedPrefix[-1] -or $previous.status -cne 'PASS' -or $previous.workPacketSha256 -cne $Context.PacketHash -or $previous.policyBundleSha256 -cne $Governance.PolicyHash -or $previous.roleLedgerSha256 -cne $Governance.RoleHash) { throw (New-TeamBobComplianceFailure 20 'Prerequisite result is not the exact prior PASS result.') }
    $prerequisite=[pscustomobject]@{ Path = [string]$State.latestResultPath; Hash = [string]$State.latestResultSha256; Phase=$expectedPrefix[-1]; Document = $previous }
    [void](Get-TeamBobBoundPriorResult $prerequisite 'requirements' $Context $Governance)
    return $prerequisite
}

function Get-TeamBobPhasePolicy {
    param([object]$Policy, [string]$Phase)
    $matches = @($Policy.phases | Where-Object { $_.id -ceq $Phase })
    if ($matches.Count -ne 1) { throw (New-TeamBobComplianceFailure 20 'Phase does not cross-reference exactly one policy phase.') }
    return $matches[0]
}

function Get-TeamBobGovernedRelativeFile {
    param([object]$Context, [string]$Path, [string]$Label)
    if (-not (Test-TeamBobAbsolutePath $Path)) { throw (New-TeamBobComplianceFailure 30 "$Label path must be absolute.") }
    $full = Get-TeamBobCanonicalPath $Path $Label 'INTEGRITY_FAILED'
    if (-not (Test-TeamBobPathAtOrBelow $full $Context.TaskRoot) -or -not (Test-Path -LiteralPath $full -PathType Leaf)) { throw (New-TeamBobComplianceFailure 30 "$Label path is outside the task or missing.") }
    $physical=Get-TeamBobPhysicalPath $full $Label 'Leaf' 'INTEGRITY_FAILED';Assert-TeamBobPhysicalChild $physical $Context.TaskPhysical $Label 'INTEGRITY_FAILED'
    return [pscustomobject]@{ FullPath = $full; PhysicalPath=$physical; RelativePath = (Get-TeamBobRelativePath $Context.TaskRoot $full); Hash = (Get-TeamBobGovernanceFileHash $full) }
}

function Test-TeamBobEvidenceTypes {
    param([object[]]$Evidence, [string[]]$Required)
    foreach ($requiredType in $Required) { if (@($Evidence | Where-Object { $_.type -ceq $requiredType }).Count -eq 0) { return $false } }
    return $true
}

function New-TeamBobCheckResult {
    param([object]$Definition, [string]$Status, [object[]]$Evidence, [string]$Message)
    return [ordered]@{ id = [string]$Definition.id; kind = [string]$Definition.kind; status = $Status; evidence = @($Evidence); message = $Message }
}

function Get-TeamBobJsonStringValues {
    param([object]$Value)
    $values=@()
    if($Value -is [string]){return @([string]$Value)}
    if($Value -is [System.Array]){foreach($item in @($Value)){$values+=@(Get-TeamBobJsonStringValues $item)};return @($values)}
    if($Value -is [System.Management.Automation.PSCustomObject]){foreach($property in @($Value.PSObject.Properties)){$values+=@(Get-TeamBobJsonStringValues $property.Value)};return @($values)}
    return @()
}

function Get-TeamBobChecklistDefinitions {
    param([object]$Governance, [object]$PhasePolicy)
    $all = @()
    foreach ($name in @('checklists\authoring.json','checklists\review.json')) {
        $document = Read-TeamBobComplianceJson (Join-Path $Governance.Roots.GovernanceRoot $name) 'Checklist'
        $all += @($document.checks)
    }
    $orderedIds = @($PhasePolicy.commonCheckIds) + @($PhasePolicy.checkIds)
    $definitions = @()
    foreach ($id in $orderedIds) {
        $matches = @($all | Where-Object { $_.id -ceq $id })
        if ($matches.Count -ne 1) { throw (New-TeamBobComplianceFailure 20 "Checklist ID does not resolve exactly once: $id") }
        $definitions += $matches[0]
    }
    return @($definitions)
}

function Get-TeamBobMarkdownH2Section {
    param([string]$Text,[string]$Heading)
    $pattern='(?ms)^## '+[regex]::Escape($Heading)+'[ \t]*\r?\n(?<body>.*?)(?=^## |\z)'
    $matches=@([regex]::Matches($Text,$pattern))
    if($matches.Count -ne 1){return $null}
    return $matches[0].Groups['body'].Value
}

function Get-TeamBobRequirementLedgerRows {
    param([string]$Text)
    $header='ReqID,Immutable Source Anchor,Interpretation,Acceptance Criteria,QA Links,QA Status,Evidence,Human Approval State'
    $lines=@($Text -split "`r?`n")
    if($lines.Count -eq 0 -or $lines[0] -cne $header){return $null}
    try{$rows=@(($Text|ConvertFrom-Csv))}catch{return $null}
    return @($rows)
}

function Get-TeamBobBoundPriorResult {
    param([object]$Prerequisite,[string]$TargetPhase,[object]$Context,[object]$Governance)
    if($null -eq $Prerequisite){return $null}
    $current=$Prerequisite.Document;$expectedPhase=[string]$Prerequisite.Phase;$depth=0
    if([string]::IsNullOrWhiteSpace($expectedPhase)){$expectedPhase=[string]$current.phase}
    $visited=New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    if($Prerequisite.Path -is [string]){[void]$visited.Add([string]$Prerequisite.Path)}
    while($null -ne $current){
        $depth++;if($depth -gt $script:TeamBobPhaseOrder.Count){throw (New-TeamBobComplianceFailure 20 'Prior result chain exceeds the six-phase bound.')}
        Assert-TeamBobPriorComplianceResult $current $Context $Governance $expectedPhase
        if($current.taskId -cne $Context.TaskId -or $current.workPacketSha256 -cne $Context.PacketHash -or $current.policyBundleSha256 -cne $Governance.PolicyHash -or $current.roleLedgerSha256 -cne $Governance.RoleHash -or $current.status -cne 'PASS'){throw (New-TeamBobComplianceFailure 20 'Prior result chain identity is invalid.')}
        if($expectedPhase -ceq $TargetPhase){return $current}
        $expectedIndex=[array]::IndexOf($script:TeamBobPhaseOrder,$expectedPhase)
        if($expectedIndex -le 0){return $null}
        $path=Get-TeamBobCanonicalPath (Join-Path $Context.TaskRoot ([string]$current.prerequisiteResultPath)) 'Prior result chain' 'INTEGRITY_FAILED'
        $relative=Get-TeamBobRelativePath $Context.TaskRoot $path
        if(-not $visited.Add($relative)){throw(New-TeamBobComplianceFailure 20 'Prior result chain contains a cycle.')}
        $physical=Get-TeamBobPhysicalPath $path 'Prior result chain' 'Leaf' 'INTEGRITY_FAILED';Assert-TeamBobPhysicalChild $physical $Context.ResultsPhysical 'Prior result chain' 'INTEGRITY_FAILED'
        if((Get-TeamBobGovernanceFileHash $path) -cne $current.prerequisiteResultSha256){throw (New-TeamBobComplianceFailure 30 'Prior result chain hash changed.')}
        $current=Read-TeamBobComplianceJson $path 'Prior result chain'
        $expectedPhase=$script:TeamBobPhaseOrder[$expectedIndex-1]
    }
    return $null
}

function Get-TeamBobTask2BuildResult {
    param([object]$Artifact,[object]$Packet,[object]$Context)
    $build=Read-TeamBobComplianceJson $Artifact.FullPath 'Build result'
    try{Assert-TeamBobBuildResultContract $build 'CONTRACT_INVALID'}catch{throw(New-TeamBobComplianceFailure 20 $_.Exception.Message)}
    if($build.taskId -cne $Context.TaskId -or $build.action -cne 'Rebuild' -or $build.status -cne 'SUCCEEDED' -or [int]$build.exitCode -ne 0 -or $build.workPacket -cne $Context.PacketPath -or $build.buildProfileId -cne $Packet.'Build Profile ID' -or -not([string]$build.resultPath).Equals($Artifact.FullPath,[System.StringComparison]::OrdinalIgnoreCase)){throw(New-TeamBobComplianceFailure 20 'Build result does not identify the current task successful Rebuild artifact.')}
    if(-not(Test-TeamBobInteger $build.processId) -or [int64]$build.processId -le 0 -or -not(Test-TeamBobInteger $build.processExitCode) -or [int]$build.processExitCode -ne 0 -or $build.captureComplete -ne $true){throw(New-TeamBobComplianceFailure 20 'Successful Rebuild process evidence is invalid.')}
    $started=ConvertFrom-TeamBobGovernanceUtcInstant $build.processStartedAt;$finished=ConvertFrom-TeamBobGovernanceUtcInstant $build.processFinishedAt
    if($null -eq $started -or $null -eq $finished -or $finished -lt $started){throw(New-TeamBobComplianceFailure 20 'Successful Rebuild timestamps are invalid.')}
    if($build.preBazaarStatus -cne $build.postBazaarStatus -or $build.preBazaarBranch -cne $build.postBazaarBranch -or $build.preBazaarRevision -cne $build.postBazaarRevision -or $build.preBazaarBranch -cne $Packet.'Bazaar Branch' -or $build.preBazaarRevision -cne $Packet.'Bazaar Full Revision ID'){throw(New-TeamBobComplianceFailure 20 'Build result Bazaar pre/post identity is inconsistent.')}
    foreach($field in @('preSourceInventory','preBzrInventory','preAllowedHashes')){$postField='post'+$field.Substring(3);if((@($build.$field)-join "`n") -cne (@($build.$postField)-join "`n")){throw(New-TeamBobComplianceFailure 20 "Build result $field integrity pair differs.")}}
    $expectedAllowed=@()
    foreach($relative in @($Packet.'Allowed Files')){$source=Get-TeamBobCanonicalPath (Join-Path ([string]$Packet.'Bazaar Root') $relative) 'Allowed file' 'INTEGRITY_FAILED';$physical=Get-TeamBobPhysicalPath $source 'Allowed file' 'Leaf' 'INTEGRITY_FAILED';Assert-TeamBobPhysicalChild $physical $Context.BazaarPhysical 'Allowed file' 'INTEGRITY_FAILED';$expectedAllowed+=([string]$relative+'|'+(Get-TeamBobGovernanceFileHash $source))}
    $expectedAllowed=@($expectedAllowed|Sort-Object)
    if((@($build.preAllowedHashes)-join "`n") -cne ($expectedAllowed-join "`n")){throw(New-TeamBobComplianceFailure 30 'Build result Allowed File hashes do not match current bound bytes.')}
    if(@($build.invokedArguments) -cnotcontains '/REBUILD' -or @($build.invokedArguments) -ccontains '/MAKE'){throw(New-TeamBobComplianceFailure 20 'Build result arguments do not identify exactly a Rebuild action.')}
    return $build
}

function Invoke-TeamBobMachineCheck {
    param([object]$Definition, [object]$Packet, [object]$Context, [object]$Artifact, [object]$Prerequisite, [object]$Governance)
    $pathEvidence = [ordered]@{ type='path'; value=$Artifact.RelativePath }
    $lineEvidence = [ordered]@{ type='line'; value='1' }
    $shaEvidence = [ordered]@{ type='sha256'; value=$Artifact.Hash }
    $resultEvidence = [ordered]@{ type='resultHash'; value=$(if ($null -eq $Prerequisite) { $Context.StateHash } else { $Prerequisite.Hash }) }
    $status = 'PASS'; $message = 'Machine check passed.'; $evidence = @()
    $text = $null
    switch ([string]$Definition.id) {
        'GOV-M-001' { $evidence = @($shaEvidence) }
        'GOV-M-002' { $evidence = @([ordered]@{type='sha256';value=$Context.StateHash});if($null -ne $Prerequisite){$evidence += $resultEvidence} }
        'GOV-M-003' {
            try { $text = Read-TeamBobUtf8File $Artifact.FullPath 'Governed artifact' 'INTEGRITY_FAILED' } catch { $status='FAIL'; $message=$_.Exception.Message }
            $evidence = @($pathEvidence)
        }
        'GOV-M-004' {
            if ($null -eq $text) { try { $text = Read-TeamBobUtf8File $Artifact.FullPath 'Governed artifact' 'INTEGRITY_FAILED' } catch { $text = '' } }
            $glossary = Read-TeamBobComplianceJson (Join-Path $Governance.Roots.GovernanceRoot 'glossary.json') 'Glossary'
            $foundLine = 0
            $lines = if([System.IO.Path]::GetExtension($Artifact.FullPath) -ceq '.json'){
                try{@(Get-TeamBobJsonStringValues ($text|ConvertFrom-Json))}catch{@($text -split "`r?`n")}
            } else {@($text -split "`r?`n")}
            foreach ($term in @($glossary.terms)) {
                foreach ($forbidden in @($term.forbidden)) {
                    for ($index=0; $index -lt $lines.Count; $index++) {
                        if ($lines[$index].IndexOf([string]$forbidden, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { $foundLine=$index+1; break }
                    }
                    if ($foundLine -gt 0) { break }
                }
                if ($foundLine -gt 0) { break }
            }
            if ($foundLine -gt 0) { $status='FAIL'; $message='Governed artifact contains forbidden terminology.' }
            $evidenceLine = if ($foundLine -gt 0) { $foundLine } else { 1 }
            $evidence = @($pathEvidence, [ordered]@{type='line';value=[string]$evidenceLine})
        }
        'REQ-M-001' {
            if ($null -eq $text) { $text = Read-TeamBobUtf8File $Artifact.FullPath 'Requirement ledger' 'INTEGRITY_FAILED' }
            $rows = @(Get-TeamBobRequirementLedgerRows $text)
            if ($rows.Count -eq 0) { $status='FAIL'; $message='Requirement ledger header or CSV encoding is invalid.';$rows=@() }
            $seenReqIds=New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
            for ($rowIndex=0;$rowIndex -lt $rows.Count;$rowIndex++) {
                $row=$rows[$rowIndex]
                if ([string]::IsNullOrWhiteSpace($row.ReqID) -or [string]::IsNullOrWhiteSpace($row.'Immutable Source Anchor')) { $status='FAIL';$message="Requirement ledger row $($rowIndex+2) has a blank ReqID/source anchor.";continue }
                if (-not $seenReqIds.Add([string]$row.ReqID)) { $status='FAIL';$message="Requirement ledger duplicates ReqID $($row.ReqID)." }
            }
            foreach ($reqId in @($Packet.ReqIDs)) { if (-not $seenReqIds.Contains([string]$reqId)) { $status='FAIL'; $message="Requirement ledger is missing ReqID $reqId" } }
            $evidence=@($pathEvidence,$lineEvidence)
        }
        'SPEC-M-001' {
            if ($null -eq $text) { $text=Read-TeamBobUtf8File $Artifact.FullPath 'Specification' 'INTEGRITY_FAILED' }
            foreach ($heading in @('ReqIDs','Scope','Acceptance Criteria','Evidence','Human Approval')) { if ($null -eq (Get-TeamBobMarkdownH2Section $text $heading)) { $status='FAIL'; $message="Specification is missing exact H2 $heading" } }
            $evidence=@($pathEvidence,$lineEvidence)
        }
        'SPEC-M-002' {
            if ($null -eq $text) { $text=Read-TeamBobUtf8File $Artifact.FullPath 'Specification' 'INTEGRITY_FAILED' }
            $requirementsResult=Get-TeamBobBoundPriorResult $Prerequisite 'requirements' $Context $Governance
            if ($null -eq $requirementsResult -or $requirementsResult.artifactPath -cne 'drafts/requirement-ledger.csv') { $status='FAIL';$message='Specification requires the fixed prior requirement ledger result.' }
            else {
                $ledgerPath=Get-TeamBobCanonicalPath (Join-Path $Context.TaskRoot 'drafts/requirement-ledger.csv') 'Requirement ledger' 'INTEGRITY_FAILED'
                $ledgerPhysical=Get-TeamBobPhysicalPath $ledgerPath 'Requirement ledger' 'Leaf' 'INTEGRITY_FAILED';Assert-TeamBobPhysicalChild $ledgerPhysical $Context.DraftsPhysical 'Requirement ledger' 'INTEGRITY_FAILED'
                if((Get-TeamBobGovernanceFileHash $ledgerPath) -cne $requirementsResult.artifactSha256){throw (New-TeamBobComplianceFailure 30 'Requirement ledger hash changed after its PASS result.')}
                $ledgerText=Read-TeamBobUtf8File $ledgerPath 'Requirement ledger' 'INTEGRITY_FAILED'
                $ledgerIds=New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
                $ledgerRows=@(Get-TeamBobRequirementLedgerRows $ledgerText)
                if($ledgerRows.Count -eq 0){throw(New-TeamBobComplianceFailure 20 'Bound requirement ledger CSV is invalid.')}
                foreach ($row in @($ledgerRows)) {[void]$ledgerIds.Add([string]$row.ReqID)}
                $reqSection=Get-TeamBobMarkdownH2Section $text 'ReqIDs'
                $specIds=@([regex]::Matches($reqSection,'(?m)^\s*(REQ-[A-Za-z0-9_-]+)\s*$')|ForEach-Object{$_.Groups[1].Value})
                if ($specIds.Count -eq 0) { $status='FAIL';$message='Specification ReqIDs section is empty.' }
                foreach ($reqId in $specIds) { if (-not $ledgerIds.Contains([string]$reqId)) { $status='FAIL';$message="Specification ReqID is absent from requirement ledger: $reqId" } }
                foreach ($reqId in @($Packet.ReqIDs)) { if ($specIds -cnotcontains [string]$reqId) { $status='FAIL';$message="Specification is missing packet ReqID $reqId" } }
            }
            $evidence=@($pathEvidence,$lineEvidence)
        }
        'IMP-M-001' {
            if ($null -eq $text) { $text=Read-TeamBobUtf8File $Artifact.FullPath 'Impact analysis' 'INTEGRITY_FAILED' }
            foreach ($area in @('RT','Safety','Board','Driver','ABI','Build','Customer Branch')) { if ($text -notmatch ('(?m)^\|\s*'+[regex]::Escape($area)+'\s*\|')) { $status='FAIL'; $message="Impact analysis is missing $area" } }
            $evidence=@($pathEvidence,$lineEvidence)
        }
        'IMPL-M-001' {
            if ($Packet.Risk -cne 'Green' -or @($Packet.'Open QA').Count -ne 0) { $status='FAIL'; $message='Implementation requires Green risk and empty Open QA.' }
            foreach ($field in @('RT Impact Clear','Safety Impact Clear','Board Impact Clear','Driver Impact Clear','ABI Impact Clear','Build Impact Clear','Customer Branch Impact Clear','Clean Working Copy')) { if ($Packet.PSObject.Properties[$field].Value -cne 'YES') { $status='FAIL'; $message="Implementation entry gate is not clear: $field" } }
            $evidence=@($resultEvidence)
        }
        'IMPL-M-002' {
            $build=Get-TeamBobTask2BuildResult $Artifact $Packet $Context
            if ((@($build.preSourceInventory) -join "`n") -cne (@($build.postSourceInventory) -join "`n") -or (@($build.preBzrInventory) -join "`n") -cne (@($build.postBzrInventory) -join "`n") -or (@($build.preAllowedHashes) -join "`n") -cne (@($build.postAllowedHashes) -join "`n")) { $status='FAIL'; $message='Build result records post-build source, allowed-file, or Bazaar integrity drift.' }
            $evidence=@($pathEvidence,$shaEvidence)
        }
        'IMPL-M-003' {
            $allowedObjects=@();$evidence=@()
            foreach ($relative in @($Packet.'Allowed Files')) {
                $source=Get-TeamBobCanonicalPath (Join-Path ([string]$Packet.'Bazaar Root') $relative) 'Allowed file' 'INTEGRITY_FAILED'
                $physical=Get-TeamBobPhysicalPath $source 'Allowed file' 'Leaf' 'INTEGRITY_FAILED'
                Assert-TeamBobPhysicalChild $physical $Context.BazaarPhysical 'Allowed file' 'INTEGRITY_FAILED'
                $allowedObjects += [pscustomobject]@{FullPath=$source;RelativePath=[string]$relative;PhysicalPath=$physical}
                $evidence += [ordered]@{type='path';value=[string]$relative};$evidence += [ordered]@{type='sha256';value=(Get-TeamBobGovernanceFileHash $source)}
            }
            try{Assert-TeamBobAllowedEncoding $allowedObjects}catch{$status='FAIL';$message=$_.Exception.Message}
        }
        'IMPL-M-004' {
            $build=Get-TeamBobTask2BuildResult $Artifact $Packet $Context
            if ($build.status -cne 'SUCCEEDED' -or $build.action -cne 'Rebuild') { $status='FAIL'; $message='Implementation requires a successful final Rebuild result.' }
            $evidence=@([ordered]@{type='command';value='Rebuild'},$resultEvidence)
        }
        'REV-M-001' {
            if ($null -eq $text) { $text=Read-TeamBobUtf8File $Artifact.FullPath 'Code review' 'INTEGRITY_FAILED' }
            foreach ($heading in @('ReqIDs','Allowed Files','Findings','Evidence','Human Disposition')) { if ($null -eq (Get-TeamBobMarkdownH2Section $text $heading)) { $status='FAIL'; $message="Code review is missing exact H2 $heading" } }
            $findingSection=Get-TeamBobMarkdownH2Section $text 'Findings'
            $findings=if($null -eq $findingSection){''}else{$findingSection.Trim()}
            if ($findings -cne 'No findings.') {
                $findingLines=@($findings -split "`r?`n" | Where-Object {-not [string]::IsNullOrWhiteSpace($_)})
                if ($findingLines.Count -eq 0) { $status='FAIL';$message='Review must contain structured findings or the exact clean declaration.' }
                $knownIds=@();foreach($policyPhase in @($Governance.Policy.phases)){$knownIds+=@(Get-TeamBobChecklistDefinitions $Governance $policyPhase|ForEach-Object{[string]$_.id})}
                foreach ($findingLine in $findingLines) {
                    $match=[regex]::Match($findingLine,'^\[(?<severity>BLOCKER|WARNING)\] CheckId=(?<check>[A-Z]+-[AMH]-[0-9]{3}); ReqID=(?<req>REQ-[A-Za-z0-9_-]+); Path=(?<path>[^;]+); Line=(?<line>[1-9][0-9]*); Evidence=(?<evidence>[^;]+); Rationale=(?<rationale>[^;]+); Action=(?<action>[^;]+); Disposition=(?<disposition>OPEN|RESOLVED|ACCEPTED)$')
                    if(-not $match.Success){$status='FAIL';$message='Review finding is not in the required structured form.';continue}
                    $blankMandatory=$false;foreach($captureName in @('evidence','rationale','action')){if([string]::IsNullOrWhiteSpace($match.Groups[$captureName].Value)){$blankMandatory=$true}}
                    if($blankMandatory){$status='FAIL';$message='Review finding mandatory text fields must be nonblank.';continue}
                    $relative=$match.Groups['path'].Value.Replace('\','/')
                    if($knownIds -cnotcontains $match.Groups['check'].Value -or @($Packet.ReqIDs) -cnotcontains $match.Groups['req'].Value -or @($Packet.'Allowed Files') -cnotcontains $relative){$status='FAIL';$message='Review finding references an unknown check, requirement, or Allowed File.';continue}
                    if($relative -match '(^|/)\.\.?(/|$)|(^|/)\.bzr(/|$)' -or [System.IO.Path]::IsPathRooted($relative)){$status='FAIL';$message='Review finding path is not a normalized Allowed File.';continue}
                    $source=Get-TeamBobCanonicalPath (Join-Path ([string]$Packet.'Bazaar Root') $relative) 'Review finding source' 'INTEGRITY_FAILED'
                    Assert-TeamBobAllowedEncoding @([pscustomobject]@{FullPath=$source;RelativePath=$relative})
                    $sourceText=Read-TeamBobStrictCp932File $source
                    $sourceBody=$sourceText.TrimEnd([char[]]@([char]13,[char]10));$sourceLineCount=if($sourceBody.Length -eq 0){0}else{@($sourceBody -split "`r`n").Count}
                    if([int]$match.Groups['line'].Value -gt $sourceLineCount){$status='FAIL';$message='Review finding source line is out of range.'}
                }
            }
            $evidence=@($pathEvidence,$lineEvidence)
        }
        'TEST-M-001' {
            if ($null -eq $text) { $text=Read-TeamBobUtf8File $Artifact.FullPath 'Test specification' 'INTEGRITY_FAILED' }
            $cases=Get-TeamBobMarkdownH2Section $text 'Test Cases';if($null -eq $cases){$cases='';$status='FAIL';$message='Test specification is missing exact Test Cases H2.'}
            foreach ($reqId in @($Packet.ReqIDs)) {
                $tokenPattern='(?<![A-Za-z0-9_-])'+[regex]::Escape([string]$reqId)+'(?![A-Za-z0-9_-])'
                if (-not [regex]::IsMatch($cases,$tokenPattern)) { $status='FAIL'; $message="Test cases do not map ReqID $reqId" }
            }
            $specificationResult=Get-TeamBobBoundPriorResult $Prerequisite 'specification' $Context $Governance
            if($null -eq $specificationResult -or $specificationResult.artifactPath -cne 'drafts/external-spec.md'){$status='FAIL';$message='Test traceability requires the bound specification PASS result.';$acceptanceIds=@()}
            else{
                $specPath=Get-TeamBobCanonicalPath (Join-Path $Context.TaskRoot 'drafts/external-spec.md') 'Specification' 'INTEGRITY_FAILED';$specPhysical=Get-TeamBobPhysicalPath $specPath 'Specification' 'Leaf' 'INTEGRITY_FAILED';Assert-TeamBobPhysicalChild $specPhysical $Context.DraftsPhysical 'Specification' 'INTEGRITY_FAILED'
                if((Get-TeamBobGovernanceFileHash $specPath) -cne $specificationResult.artifactSha256){throw (New-TeamBobComplianceFailure 30 'Specification hash changed after its PASS result.')}
                $specText=Read-TeamBobUtf8File $specPath 'Specification' 'INTEGRITY_FAILED';$acceptance=Get-TeamBobMarkdownH2Section $specText 'Acceptance Criteria'
                $acceptanceIds=@([regex]::Matches($acceptance,'(?m)^\s*([A-Za-z0-9_-]+):\s*.+$')|ForEach-Object{$_.Groups[1].Value})
                if($acceptanceIds.Count -eq 0){$status='FAIL';$message='Bound specification has no identified acceptance criteria.'}
            }
            foreach ($acceptanceId in $acceptanceIds) {
                $tokenPattern='(?<![A-Za-z0-9_-])'+[regex]::Escape([string]$acceptanceId)+'(?![A-Za-z0-9_-])'
                if (-not [regex]::IsMatch($cases,$tokenPattern)) { $status='FAIL';$message="Test cases do not map acceptance criterion $acceptanceId" }
            }
            $evidence=@($pathEvidence,$lineEvidence)
        }
        default { throw (New-TeamBobComplianceFailure 20 "Machine check has no closed implementation: $($Definition.id)") }
    }
    return New-TeamBobCheckResult $Definition $status $evidence $message
}

function Read-TeamBobAssessment {
    param([object]$Context,[object]$Governance,[object]$Artifact,[object]$PhasePolicy,[string]$Phase,[string]$Path,[object]$Prerequisite,[object]$Approval)
    $info=Get-TeamBobGovernedRelativeFile $Context $Path 'Assessment'
    $document=Read-TeamBobComplianceJson $info.FullPath 'Compliance assessment'
    Assert-TeamBobComplianceExactProperties $document @('schemaVersion','profileVersion','policyVersion','taskId','phase','workPacketSha256','policyBundleSha256','roleLedgerSha256','artifactPath','artifactSha256','checks') 'Compliance assessment'
    if ($document.schemaVersion -cne '1.0' -or $document.profileVersion -cne '0.2.0-poc' -or $document.policyVersion -cne '0.2.0-poc' -or $document.taskId -cne $Context.TaskId -or $document.phase -cne $Phase -or $document.artifactPath -cne $Artifact.RelativePath) { throw (New-TeamBobComplianceFailure 20 'Compliance assessment cross-reference is invalid.') }
    if ($document.workPacketSha256 -cne $Context.PacketHash -or $document.policyBundleSha256 -cne $Governance.PolicyHash -or $document.roleLedgerSha256 -cne $Governance.RoleHash -or $document.artifactSha256 -cne $Artifact.Hash) { throw (New-TeamBobComplianceFailure 30 'Compliance assessment integrity anchor changed.') }
    $expectedIds=@()
    $definitions=Get-TeamBobChecklistDefinitions $Governance $PhasePolicy
    foreach ($definition in $definitions) { if ($definition.kind -ceq 'ai') { $expectedIds += [string]$definition.id } }
    $actualIds=@($document.checks | ForEach-Object { [string]$_.id })
    if (($actualIds -join "`n") -cne ($expectedIds -join "`n")) { throw (New-TeamBobComplianceFailure 20 'Assessment must contain exactly the expected AI check IDs in policy order.') }
    $validated=@{}
    for ($index=0;$index -lt @($document.checks).Count;$index++) {
        $check=$document.checks[$index]
        $definition=@($definitions|Where-Object{$_.id -ceq $check.id})[0]
        $supportValid=$true
        Assert-TeamBobComplianceExactProperties $check @('id','status','evidence','message') "Assessment check $index"
        if (@('PASS','FAIL','NOT_APPLICABLE','NEEDS_HUMAN_REVIEW') -cnotcontains $check.status -or -not ($check.message -is [string]) -or [string]::IsNullOrWhiteSpace($check.message) -or -not ($check.evidence -is [System.Array])) { throw (New-TeamBobComplianceFailure 20 "Assessment check has invalid values: $($check.id)") }
        foreach ($item in @($check.evidence)) {
            Assert-TeamBobComplianceExactProperties $item @('type','value') "Assessment evidence $($check.id)"
            if (@('path','line','sha256','rationale','command','approvalRecord','resultHash') -cnotcontains $item.type -or -not ($item.value -is [string]) -or [string]::IsNullOrWhiteSpace($item.value)) { throw (New-TeamBobComplianceFailure 20 "Assessment evidence is invalid: $($check.id)") }
            switch([string]$item.type){
                'path' {$evidenceFull=Get-TeamBobCanonicalPath (Join-Path $Context.TaskRoot ([string]$item.value)) 'Assessment evidence path' 'INTEGRITY_FAILED';if((-not (Test-TeamBobPathAtOrBelow $evidenceFull $Context.TaskRoot)) -or (-not (Test-Path -LiteralPath $evidenceFull -PathType Leaf))){throw(New-TeamBobComplianceFailure 30 'Assessment path evidence escapes governed task files or is missing.')} $evidencePhysical=Get-TeamBobPhysicalPath $evidenceFull 'Assessment evidence path' 'Leaf' 'INTEGRITY_FAILED';Assert-TeamBobPhysicalChild $evidencePhysical $Context.TaskPhysical 'Assessment evidence path' 'INTEGRITY_FAILED';if((Get-TeamBobRelativePath $Context.TaskRoot $evidenceFull) -cne $Artifact.RelativePath){$supportValid=$false}}
                'line' {if($item.value -cnotmatch '^[1-9][0-9]*$'){throw(New-TeamBobComplianceFailure 20 'Assessment line evidence must be a positive integer.')} $artifactText=Read-TeamBobUtf8File $Artifact.FullPath 'Assessed artifact' 'INTEGRITY_FAILED';if([int64]$item.value -gt @($artifactText -split "`r?`n").Count){$supportValid=$false}}
                'sha256' {if($item.value -cnotmatch '^[0-9a-f]{64}$'){throw(New-TeamBobComplianceFailure 20 'Assessment SHA-256 evidence is malformed.')}if($item.value -cne $Artifact.Hash){throw(New-TeamBobComplianceFailure 30 'Assessment SHA-256 evidence does not match assessed artifact bytes.')}}
                'resultHash' {if($item.value -cnotmatch '^[0-9a-f]{64}$'){throw(New-TeamBobComplianceFailure 20 'Assessment result-hash evidence is malformed.')}if($null -eq $Prerequisite -or $item.value -cne $Prerequisite.Hash){throw(New-TeamBobComplianceFailure 30 'Assessment result-hash evidence does not match its bound predecessor.')}}
                'approvalRecord' {if($null -eq $Approval -or $item.value -cne $Approval.Info.RelativePath){$supportValid=$false}}
                'command' {if(@('Make','Rebuild') -cnotcontains $item.value){throw(New-TeamBobComplianceFailure 20 'Assessment command evidence is not a fixed command.')}}
            }
        }
        if($check.status -ceq 'PASS' -and ((-not $supportValid) -or (-not (Test-TeamBobEvidenceTypes @($check.evidence) @($definition.requiredEvidence))))){$check.status='NEEDS_HUMAN_REVIEW';$check.message='Assessment PASS evidence is missing or cannot be verified against the assessed artifact.'}
        $validated[[string]$check.id]=$check
    }
    return [pscustomobject]@{ Info=$info; Document=$document; Checks=$validated }
}

function Read-TeamBobApprovalForPhase {
    param([object]$Context,[object]$Governance,[object]$Artifact,[object]$Prerequisite,[object]$PhasePolicy,[hashtable]$Assignments,[string]$Phase,[string]$Path,[datetimeoffset]$NowUtc)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $info=Get-TeamBobGovernedRelativeFile $Context $Path 'Approval record'
    if (-not (Test-TeamBobPathAtOrBelow $info.FullPath (Join-Path $Context.TaskRoot 'approvals'))) { throw (New-TeamBobComplianceFailure 30 'Approval record is outside approvals.') }
    Assert-TeamBobPhysicalChild $info.PhysicalPath $Context.ApprovalsPhysical 'Approval record' 'INTEGRITY_FAILED'
    $record=Read-TeamBobComplianceJson $info.FullPath 'Approval record'
    Assert-TeamBobComplianceExactProperties $record @('schemaVersion','profileVersion','policyVersion','approvalId','decision','taskId','phase','assignmentId','role','principalId','approvedAtUtc','expiresAtUtc','workPacketPath','workPacketSha256','policyBundleSha256','roleLedgerSha256','artifactPath','artifactSha256','prerequisiteResultPath','prerequisiteResultSha256','evidence') 'Approval record'
    $requiredRole=[string]$PhasePolicy.completionApprovalRole
    if ($record.schemaVersion -cne '1.0' -or $record.profileVersion -cne '0.2.0-poc' -or $record.policyVersion -cne '0.2.0-poc' -or -not ($record.approvalId -is [string]) -or $record.approvalId -cnotmatch '^APPROVAL-[A-Z0-9]+(?:-[A-Z0-9]+)*$' -or $record.decision -cne 'APPROVED' -or $record.taskId -cne $Context.TaskId -or $record.phase -cne $Phase -or $record.role -cne $requiredRole -or $record.assignmentId -cne $Assignments[$requiredRole].assignmentId -or $record.principalId -cne $Assignments[$requiredRole].principalId -or $record.artifactPath -cne $Artifact.RelativePath -or $record.workPacketPath -cne $Context.PacketPath) { throw (New-TeamBobComplianceFailure 20 'Approval record cross-reference is invalid.') }
    $expectedPreviousPath=if($null -eq $Prerequisite){$null}else{$Prerequisite.Path}; $expectedPreviousHash=if($null -eq $Prerequisite){$null}else{$Prerequisite.Hash}
    if ($record.prerequisiteResultPath -cne $expectedPreviousPath) { throw (New-TeamBobComplianceFailure 20 'Approval record prerequisite path is a cross-phase replay.') }
    if ($record.workPacketSha256 -cne $Context.PacketHash -or $record.policyBundleSha256 -cne $Governance.PolicyHash -or $record.roleLedgerSha256 -cne $Governance.RoleHash -or $record.artifactSha256 -cne $Artifact.Hash -or $record.prerequisiteResultSha256 -cne $expectedPreviousHash) { throw (New-TeamBobComplianceFailure 30 'Approval record integrity anchor changed.') }
    $approved=ConvertFrom-TeamBobGovernanceUtcInstant $record.approvedAtUtc; $expires=ConvertFrom-TeamBobGovernanceUtcInstant $record.expiresAtUtc; $roleFrom=ConvertFrom-TeamBobGovernanceUtcInstant $Assignments[$requiredRole].validFromUtc; $roleUntil=ConvertFrom-TeamBobGovernanceUtcInstant $Assignments[$requiredRole].validUntilUtc
    if ($null -eq $approved -or $null -eq $expires -or $expires -le $approved -or $expires -gt $approved.AddHours([int]$Governance.Policy.maxApprovalValidityHours) -or $approved -lt $roleFrom -or $expires -gt $roleUntil) { throw (New-TeamBobComplianceFailure 20 'Approval validity window is invalid.') }
    if (-not ($record.evidence -is [System.Array]) -or @($record.evidence).Count -eq 0) { throw (New-TeamBobComplianceFailure 20 'Approval evidence is missing.') }
    $seenEvidence=New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($evidence in @($record.evidence)) {
        Assert-TeamBobComplianceExactProperties $evidence @('path','sha256') 'Approval evidence'
        if (-not ($evidence.path -is [string]) -or [string]::IsNullOrWhiteSpace($evidence.path) -or -not ($evidence.sha256 -is [string]) -or $evidence.sha256 -cnotmatch '^[0-9a-f]{64}$' -or -not $seenEvidence.Add([string]$evidence.path)) { throw (New-TeamBobComplianceFailure 20 'Approval evidence shape or uniqueness is invalid.') }
        $evidencePath=Get-TeamBobCanonicalPath (Join-Path $Context.TaskRoot ([string]$evidence.path)) 'Approval evidence' 'INTEGRITY_FAILED'
        if (-not (Test-TeamBobPathAtOrBelow $evidencePath $Context.TaskRoot) -or -not (Test-Path -LiteralPath $evidencePath -PathType Leaf) -or (Get-TeamBobGovernanceFileHash $evidencePath) -cne $evidence.sha256) { throw (New-TeamBobComplianceFailure 30 'Approval evidence path or hash changed.') }
        $evidencePhysical=Get-TeamBobPhysicalPath $evidencePath 'Approval evidence' 'Leaf' 'INTEGRITY_FAILED';Assert-TeamBobPhysicalChild $evidencePhysical $Context.TaskPhysical 'Approval evidence' 'INTEGRITY_FAILED'
    }
    if ($approved -gt $NowUtc) { throw (New-TeamBobComplianceFailure 20 'Approval time is in the future.') }
    return [pscustomobject]@{ Info=$info; Record=$record; IsCurrent=($expires -gt $NowUtc) }
}

function Assert-TeamBobPriorReferencedContracts {
    param([object]$Result,[object]$Context,[object]$Governance,[string]$Phase)
    $evaluated=ConvertFrom-TeamBobGovernanceUtcInstant $Result.evaluatedAtUtc
    $packet=Read-TeamBobCanonicalPacket $Context.PacketPath
    $assignments=Get-TeamBobSelectedAssignments $packet $Governance.Roles $Context.TaskId -RequireActive -AtUtc $evaluated
    $phasePolicy=Get-TeamBobPhasePolicy $Governance.Policy $Phase
    $artifactPath=Get-TeamBobCanonicalPath (Join-Path $Context.TaskRoot ([string]$Result.artifactPath)) 'Prior artifact' 'INTEGRITY_FAILED'
    $artifact=Get-TeamBobGovernedRelativeFile $Context $artifactPath 'Prior artifact'
    $prerequisite=if($Result.prerequisiteResultPath -is [string]){[pscustomobject]@{Path=[string]$Result.prerequisiteResultPath;Hash=[string]$Result.prerequisiteResultSha256;Phase=$script:TeamBobPhaseOrder[[array]::IndexOf($script:TeamBobPhaseOrder,$Phase)-1]}}else{$null}
    $approval=$null
    if($null -ne $phasePolicy.completionApprovalRole){
        $approvalPath=Get-TeamBobCanonicalPath (Join-Path $Context.TaskRoot ([string]$Result.approvalRecordPath)) 'Prior approval' 'INTEGRITY_FAILED'
        $approval=Read-TeamBobApprovalForPhase $Context $Governance $artifact $prerequisite $phasePolicy $assignments $Phase $approvalPath $evaluated
        if(-not $approval.IsCurrent){throw(New-TeamBobComplianceFailure 20 'Prior PASS references an approval that was not current at evaluation.')}
        if($approval.Info.Hash -cne $Result.approvalRecordSha256){throw(New-TeamBobComplianceFailure 30 'Prior PASS approval hash changed.')}
    }
    $assessmentPath=Get-TeamBobCanonicalPath (Join-Path $Context.TaskRoot ([string]$Result.assessmentPath)) 'Prior assessment' 'INTEGRITY_FAILED'
    $assessment=Read-TeamBobAssessment $Context $Governance $artifact $phasePolicy $Phase $assessmentPath $prerequisite $approval
    if($assessment.Info.Hash -cne $Result.assessmentSha256){throw(New-TeamBobComplianceFailure 30 'Prior PASS assessment hash changed.')}
    foreach($definition in @(Get-TeamBobChecklistDefinitions $Governance $phasePolicy)){
        $resultCheck=@($Result.checks|Where-Object{$_.id -ceq $definition.id})[0]
        if($definition.kind -ceq 'ai'){
            $assessmentCheck=$assessment.Checks[[string]$definition.id]
            if($resultCheck.status -cne $assessmentCheck.status -or $resultCheck.message -cne $assessmentCheck.message -or ((@($resultCheck.evidence)|ConvertTo-Json -Compress -Depth 10) -cne (@($assessmentCheck.evidence)|ConvertTo-Json -Compress -Depth 10))){throw(New-TeamBobComplianceFailure 20 "Prior PASS AI result does not match its bound assessment: $($definition.id)")}
        } elseif($definition.kind -ceq 'human'){
            if($null -eq $approval -or $resultCheck.status -cne 'PASS' -or @($resultCheck.evidence).Count -ne 1 -or $resultCheck.evidence[0].type -cne 'approvalRecord' -or $resultCheck.evidence[0].value -cne $approval.Info.RelativePath){throw(New-TeamBobComplianceFailure 20 'Prior PASS human result does not match its bound approval.')}
        }
    }
}
