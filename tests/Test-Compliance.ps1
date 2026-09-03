$ErrorActionPreference = 'Stop'

$script:ComplianceAssertions = 0
function Assert-ComplianceTrue {
    param([bool]$Condition, [string]$Message)
    $script:ComplianceAssertions++
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}
function Assert-ComplianceEqual {
    param([object]$Actual, [object]$Expected, [string]$Message)
    Assert-ComplianceTrue ($Actual -eq $Expected) "$Message (expected '$Expected', got '$Actual')"
}
function Write-ComplianceUtf8 {
    param([string]$Path, [string]$Text)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}
function Write-ComplianceJson {
    param([string]$Path, [object]$Value)
    Write-ComplianceUtf8 $Path (($Value | ConvertTo-Json -Depth 30) + [Environment]::NewLine)
}
function Get-ComplianceHash {
    param([string]$Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
        finally { $stream.Dispose() }
    } finally { $sha.Dispose() }
}
function Invoke-ComplianceScript {
    param([string]$Path, [string[]]$Arguments)
    $powerShell = (Get-Process -Id $PID).Path
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $output = & $powerShell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Path @Arguments 2>&1 | Out-String }
    finally { $ErrorActionPreference = $savedPreference }
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
}
function Copy-ComplianceProfile {
    param([string]$Source, [string]$Destination)
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    foreach ($item in Get-ChildItem -LiteralPath $Source -Force) { Copy-Item -LiteralPath $item.FullName -Destination $Destination -Recurse -Force }
}
function Get-CanonicalPacketObject {
    param([string]$Path)
    $text = [System.IO.File]::ReadAllText($Path)
    $match = [regex]::Match($text, '(?s)<!-- canonical-work-packet-json:start -->\s*```json\s*(?<json>\{.*?\})\s*```\s*<!-- canonical-work-packet-json:end -->')
    if (-not $match.Success) { throw "Missing canonical packet JSON: $Path" }
    return ($match.Groups['json'].Value | ConvertFrom-Json)
}
function Write-CanonicalPacketObject {
    param([string]$Path, [object]$Packet)
    $json = $Packet | ConvertTo-Json -Depth 30
    $document = "# Work Packet`r`n`r`n<!-- canonical-work-packet-json:start -->`r`n" + '```json' + "`r`n$json`r`n" + '```' + "`r`n<!-- canonical-work-packet-json:end -->`r`n"
    Write-ComplianceUtf8 $Path $document
}
function New-CompliancePacket {
    param([string]$TaskId, [string]$BazaarRoot, [string]$PolicyHash, [string]$RoleHash)
    return [ordered]@{
        'Profile Version' = '0.2.0-poc'; 'Policy Version' = '0.2.0-poc'; 'Policy Bundle SHA256' = $PolicyHash; 'Role Ledger SHA256' = $RoleHash
        'Task ID' = $TaskId; 'Difficulty' = 'Small'; 'Risk' = 'Green'; 'Customer' = 'Fixture Customer'; 'ReqIDs' = @('REQ-100')
        'Word Baseline' = 'WORD-1'; 'QA Baseline' = 'QA-1'; 'Spec Baseline' = 'SPEC-1'; 'Bazaar Root' = $BazaarRoot
        'Bazaar Branch' = 'fixture-branch'; 'Bazaar Full Revision ID' = 'fixture-revision'; 'Allowed Files' = @('src/example.cpp')
        'Forbidden Areas' = @('actual-machine', 'control-network', 'mainline', 'secrets'); 'RT Impact' = 'Clear'; 'Safety Impact' = 'Clear'
        'Board Impact' = 'Clear'; 'Driver Impact' = 'Clear'; 'ABI Impact' = 'Clear'; 'Build Impact' = 'Clear'; 'Customer Branch Impact' = 'Clear'
        'RT Impact Clear' = 'YES'; 'Safety Impact Clear' = 'YES'; 'Board Impact Clear' = 'YES'; 'Driver Impact Clear' = 'YES'
        'ABI Impact Clear' = 'YES'; 'Build Impact Clear' = 'YES'; 'Customer Branch Impact Clear' = 'YES'; 'Clean Working Copy' = 'YES'
        'Open QA' = @(); 'Build Profile ID' = 'fixture-vc6'; 'Max-Repair-Cycles' = 2
        'Specification Assignment ID' = 'ASSIGN-SPEC'; 'Implementation Assignment ID' = 'ASSIGN-IMPL'; 'Independent Reviewer Assignment ID' = 'ASSIGN-REVIEW'
    }
}
function New-ComplianceTaskFixture {
    param([string]$TaskId, [string]$BazaarRoot, [string]$PolicyHash, [string]$RoleHash)
    $taskRoot = Join-Path $BazaarRoot "team-bob-work/$TaskId"
    foreach ($child in @('drafts', 'approvals', 'results', 'state')) { New-Item -ItemType Directory -Path (Join-Path $taskRoot $child) -Force | Out-Null }
    $packetPath = Join-Path $taskRoot 'work-packet.md'
    Write-CanonicalPacketObject $packetPath (New-CompliancePacket $TaskId $BazaarRoot $PolicyHash $RoleHash)
    $packetHash = Get-ComplianceHash $packetPath
    Write-ComplianceJson (Join-Path $taskRoot 'state/phase-state.json') ([ordered]@{
        schemaVersion = '1.0'; profileVersion = '0.2.0-poc'; policyVersion = '0.2.0-poc'; taskId = $TaskId; currentPhase = 'requirements'
        completedPhases = @(); workPacketPath = $packetPath; workPacketSha256 = $packetHash; policyBundleSha256 = $PolicyHash
        roleLedgerSha256 = $RoleHash; latestResultPath = $null; latestResultSha256 = $null; updatedAtUtc = [DateTimeOffset]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')
    })
    return [pscustomobject]@{ Root = $taskRoot; Packet = $packetPath }
}
function New-ComplianceAssessment {
    param([string]$Path, [string]$TaskId, [string]$Phase, [string]$PacketHash, [string]$PolicyHash, [string]$RoleHash, [string]$ArtifactPath, [string]$ArtifactHash, [string[]]$Ids, [string]$Status = 'PASS', [switch]$MissingRationaleEvidence)
    $checks = @()
    foreach ($id in $Ids) {
        $evidence = @(
            [ordered]@{ type = 'path'; value = $ArtifactPath },
            [ordered]@{ type = 'line'; value = '1' }
        )
        if (-not $MissingRationaleEvidence) { $evidence += [ordered]@{ type = 'rationale'; value = 'Fixture assessment evidence.' } }
        $checks += [ordered]@{ id = $id; status = $Status; evidence = $evidence; message = 'Fixture assessment.' }
    }
    Write-ComplianceJson $Path ([ordered]@{
        schemaVersion = '1.0'; profileVersion = '0.2.0-poc'; policyVersion = '0.2.0-poc'; taskId = $TaskId; phase = $Phase
        workPacketSha256 = $PacketHash; policyBundleSha256 = $PolicyHash; roleLedgerSha256 = $RoleHash
        artifactPath = $ArtifactPath; artifactSha256 = $ArtifactHash; checks = $checks
    })
}
function Get-LatestComplianceResult {
    param([string]$TaskRoot, [string]$Phase)
    return Get-ChildItem -LiteralPath (Join-Path $TaskRoot 'results') -Filter "compliance-$Phase-*.json" -File | Sort-Object Name | Select-Object -Last 1
}
function New-ComplianceBuildResult {
    param([string]$Path,[string]$TaskId,[string]$WorkPacket,[string]$BuildProfileId,[string]$BazaarBranch,[string]$BazaarRevision,[string]$AllowedPath,[string]$AllowedHash)
    $root=Split-Path -Parent (Split-Path -Parent $Path)
    return [ordered]@{
        schemaVersion='1.0';status='SUCCEEDED';exitCode=0;message='Fixture producer-shaped successful Rebuild.';taskId=$TaskId;action='Rebuild';attempt=1
        workPacket=$WorkPacket;buildProfileId=$BuildProfileId;sandboxPath=(Join-Path $root 'sandbox');logDirectory=(Join-Path $root 'logs');stdoutPath=(Join-Path $root 'logs/stdout.log');stderrPath=(Join-Path $root 'logs/stderr.log')
        outputLogPath=(Join-Path $root 'logs/build.log');processId=1234;processExitCode=0;processStartedAt='2026-09-04T00:00:00.0000000Z';processFinishedAt='2026-09-04T00:00:01.0000000Z'
        terminationComplete=$true;captureComplete=$true;preBazaarStatus='';postBazaarStatus='';preBazaarBranch=$BazaarBranch;postBazaarBranch=$BazaarBranch;preBazaarRevision=$BazaarRevision;postBazaarRevision=$BazaarRevision
        preSourceInventory=@('F|src/example.cpp|1|'+$AllowedHash);postSourceInventory=@('F|src/example.cpp|1|'+$AllowedHash);preBzrInventory=@('F|branch.conf|1|'+('1'*64));postBzrInventory=@('F|branch.conf|1|'+('1'*64))
        preAllowedHashes=@($AllowedPath+'|'+$AllowedHash);postAllowedHashes=@($AllowedPath+'|'+$AllowedHash);expectedArtifacts=@('bin/fixture.exe');invokedArguments=@('fixture.dsp','/REBUILD','Fixture - Win32 Release','/OUT',(Join-Path $root 'logs/build.log'));resultPath=$Path
    }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$profileRoot = Join-Path $repoRoot 'profile'
$manifest = Get-Content -Raw -LiteralPath (Join-Path $profileRoot 'team-bob/profile-manifest.json') | ConvertFrom-Json
Assert-ComplianceEqual $manifest.version '0.2.0-poc' 'Task 2 atomically activates the v0.2 profile'

$schema = Get-Content -Raw -LiteralPath (Join-Path $profileRoot 'team-bob/config/work-packet.schema.json') | ConvertFrom-Json
foreach ($field in @('Policy Version', 'Policy Bundle SHA256', 'Role Ledger SHA256', 'Specification Assignment ID', 'Implementation Assignment ID', 'Independent Reviewer Assignment ID')) {
    Assert-ComplianceTrue ($schema.required -ccontains $field) "Work packet requires $field"
}
foreach ($removed in @('Specification Approver', 'Implementation Approver', 'Autonomous-Edit-Build-Approved', 'Soft-Execute-Risk-Accepted')) {
    Assert-ComplianceTrue ($null -eq $schema.properties.PSObject.Properties[$removed]) "Work packet removes legacy field $removed"
}

$approvalScriptName = 'New-TeamBobApprovalRecord.ps1'
$complianceScriptName = 'Invoke-TeamBobComplianceCheck.ps1'
foreach ($name in @($approvalScriptName, $complianceScriptName)) {
    Assert-ComplianceTrue (Test-Path -LiteralPath (Join-Path $profileRoot "team-bob/tools/$name") -PathType Leaf) "Task 2 runtime exists: $name"
}
foreach ($schemaContract in @(
    [pscustomobject]@{Name='approval-record.schema.json';Fields=@('profileVersion','approvalId','decision','workPacketPath','prerequisiteResultPath','evidence')},
    [pscustomobject]@{Name='compliance-assessment.schema.json';Fields=@('profileVersion','artifactPath','checks')},
    [pscustomobject]@{Name='compliance-result.schema.json';Fields=@('profileVersion','workPacketPath','assessmentPath','approvalRecordPath','prerequisiteResultPath','checks','status')},
    [pscustomobject]@{Name='phase-state.schema.json';Fields=@('profileVersion','workPacketPath','latestResultPath','currentPhase','completedPhases')}
)) {
    $governanceSchema=Get-Content -Raw -LiteralPath (Join-Path $profileRoot ('.bob/governance/schemas/'+$schemaContract.Name))|ConvertFrom-Json
    Assert-ComplianceTrue ($governanceSchema.additionalProperties -eq $false) "$($schemaContract.Name) is closed"
    foreach($field in $schemaContract.Fields){Assert-ComplianceTrue ($governanceSchema.required -ccontains $field) "$($schemaContract.Name) requires $field"}
}

$fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('team-bob-compliance-' + [guid]::NewGuid().ToString('N'))
try {
    $fixtureProfile = Join-Path $fixtureRoot 'profile'
    Copy-ComplianceProfile $profileRoot $fixtureProfile
    $governanceRoot = Join-Path $fixtureProfile '.bob/governance'
    $now = [DateTimeOffset]::UtcNow
    $roles = [ordered]@{ policyVersion = '0.2.0-poc'; assignments = @(
        [ordered]@{ assignmentId = 'ASSIGN-SPEC'; role = 'SPECIFICATION_APPROVER'; principalId = 'principal-spec'; scope = [ordered]@{ allTasks = $true; taskIds = @(); phases = @('specification', 'test') }; enabled = $true; validFromUtc = $now.AddHours(-1).ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ'); validUntilUtc = $now.AddDays(14).ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ') },
        [ordered]@{ assignmentId = 'ASSIGN-IMPL'; role = 'IMPLEMENTATION_APPROVER'; principalId = 'principal-impl'; scope = [ordered]@{ allTasks = $true; taskIds = @(); phases = @('impact') }; enabled = $true; validFromUtc = $now.AddHours(-1).ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ'); validUntilUtc = $now.AddDays(14).ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ') },
        [ordered]@{ assignmentId = 'ASSIGN-REVIEW'; role = 'INDEPENDENT_REVIEWER'; principalId = 'principal-review'; scope = [ordered]@{ allTasks = $true; taskIds = @(); phases = @('review') }; enabled = $true; validFromUtc = $now.AddHours(-1).ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ'); validUntilUtc = $now.AddDays(14).ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ') }
    ) }
    Write-ComplianceJson (Join-Path $governanceRoot 'roles.json') $roles
    . (Join-Path $fixtureProfile 'team-bob/tools/TeamBob-GovernanceCommon.ps1')
    $policyHash = Get-TeamBobPolicyBundleHash $governanceRoot
    $roleHash = Get-TeamBobRoleLedgerHash $governanceRoot

    $bazaarRoot = Join-Path $fixtureRoot 'bazaar'
    New-Item -ItemType Directory -Path (Join-Path $bazaarRoot '.bzr') -Force | Out-Null
    Write-ComplianceUtf8 (Join-Path $bazaarRoot 'src/example.cpp') "int main() { return 0; }`r`n"
    $task = New-ComplianceTaskFixture 'CHAIN-1' $bazaarRoot $policyHash $roleHash
    $approvalPath = Join-Path $fixtureProfile "team-bob/tools/$approvalScriptName"
    $compliancePath = Join-Path $fixtureProfile "team-bob/tools/$complianceScriptName"

    $phaseData = @(
        [pscustomobject]@{ Phase='requirements'; Artifact='drafts/requirement-ledger.csv'; Text="ReqID,Immutable Source Anchor,Interpretation,Acceptance Criteria,QA Links,QA Status,Evidence,Human Approval State`r`nREQ-100,WORD-1#1,Interpretation,Acceptance,QA-1,CLOSED,Evidence,N/A`r`n"; Ai=@('GOV-A-001','REQ-A-001'); Assignment=$null },
        [pscustomobject]@{ Phase='specification'; Artifact='drafts/external-spec.md'; Text="# External Specification`r`n## ReqIDs`r`nREQ-100`r`n## Scope`r`nScope.`r`n## Acceptance Criteria`r`nAC-1: Acceptance.`r`n## Evidence`r`nEvidence.`r`n## Human Approval`r`nPending.`r`n"; Ai=@('GOV-A-001','SPEC-A-001'); Assignment='ASSIGN-SPEC' },
        [pscustomobject]@{ Phase='impact'; Artifact='drafts/impact-analysis.md'; Text="# Impact Analysis`r`n| Area | Impact | Evidence | Disposition |`r`n| RT | none | x | clear |`r`n| Safety | none | x | clear |`r`n| Board | none | x | clear |`r`n| Driver | none | x | clear |`r`n| ABI | none | x | clear |`r`n| Build | none | x | clear |`r`n| Customer Branch | none | x | clear |`r`n"; Ai=@('GOV-A-001','IMP-A-001'); Assignment='ASSIGN-IMPL' },
        [pscustomobject]@{ Phase='implementation'; Artifact='results/build-result-fixture.json'; Text=$null; Ai=@('GOV-A-001','IMPL-A-001'); Assignment=$null },
        [pscustomobject]@{ Phase='review'; Artifact='drafts/code-review.md'; Text="# Code Review`r`n## ReqIDs`r`nREQ-100`r`n## Allowed Files`r`nsrc/example.cpp`r`n## Findings`r`nNo findings.`r`n## Evidence`r`nEvidence.`r`n## Human Disposition`r`nPending.`r`n"; Ai=@('GOV-A-001','REV-A-001'); Assignment='ASSIGN-REVIEW' },
        [pscustomobject]@{ Phase='test'; Artifact='drafts/test-spec.md'; Text="# Test Specification`r`n## ReqIDs`r`nREQ-100`r`n## Acceptance Criteria`r`nAC-1: Acceptance.`r`n## Test Cases`r`nTEST-1: REQ-100; AC-1.`r`n## Build Evidence`r`nEvidence.`r`n## Human Approval`r`nPending.`r`n"; Ai=@('GOV-A-001','TEST-A-001'); Assignment='ASSIGN-SPEC' }
    )

    foreach ($phase in $phaseData) {
        $artifactPath = Join-Path $task.Root $phase.Artifact
        if($phase.Phase -ceq 'implementation'){
            $allowedHash=Get-ComplianceHash (Join-Path $bazaarRoot 'src/example.cpp')
            Write-ComplianceJson $artifactPath (New-ComplianceBuildResult $artifactPath 'CHAIN-1' $task.Packet 'fixture-vc6' 'fixture-branch' 'fixture-revision' 'src/example.cpp' $allowedHash)
        } else { Write-ComplianceUtf8 $artifactPath $phase.Text }
        $packetHash = Get-ComplianceHash $task.Packet
        $artifactHash = Get-ComplianceHash $artifactPath
        $assessmentPath = Join-Path $task.Root ("drafts/assessment-" + $phase.Phase + '.json')
        New-ComplianceAssessment $assessmentPath 'CHAIN-1' $phase.Phase $packetHash $policyHash $roleHash $phase.Artifact $artifactHash $phase.Ai

        $approvalRecordPath = $null
        if ($null -ne $phase.Assignment) {
            $approval = Invoke-ComplianceScript $approvalPath @('-WorkPacket', $task.Packet, '-Phase', $phase.Phase, '-AssignmentId', $phase.Assignment, '-ArtifactPath', $artifactPath, '-EvidencePath', $artifactPath, '-ExpiresAtUtc', $now.AddHours(2).ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ'), '-HumanTerminal')
            Assert-ComplianceEqual $approval.ExitCode 0 "$($phase.Phase) approval is created"
            $approvalRecordPath = ([regex]::Match($approval.Output, '(?m)^CREATED\s+(.+\.json)\s*$')).Groups[1].Value.Trim()
            Assert-ComplianceTrue (Test-Path -LiteralPath $approvalRecordPath -PathType Leaf) "$($phase.Phase) approval path is durable"
        }
        $arguments = @('-WorkPacket', $task.Packet, '-Phase', $phase.Phase, '-ArtifactPath', $artifactPath, '-AssessmentPath', $assessmentPath)
        if ($null -ne $approvalRecordPath) { $arguments += @('-ApprovalRecordPath', $approvalRecordPath) }
        $result = Invoke-ComplianceScript $compliancePath $arguments
        Assert-ComplianceEqual $result.ExitCode 0 "$($phase.Phase) compliance passes; output: $($result.Output.Trim())"
        $resultFile = Get-LatestComplianceResult $task.Root $phase.Phase
        Assert-ComplianceTrue ($null -ne $resultFile) "$($phase.Phase) creates an immutable timestamped result"
        $resultJson = Get-Content -Raw -LiteralPath $resultFile.FullName | ConvertFrom-Json
        Assert-ComplianceEqual $resultJson.status 'PASS' "$($phase.Phase) result is PASS"
        Assert-ComplianceEqual $resultJson.workPacketSha256 $packetHash "$($phase.Phase) result binds packet bytes"
        foreach ($lineEvidence in @($resultJson.checks.evidence | Where-Object { $_.type -ceq 'line' })) {
            Assert-ComplianceTrue ([string]$lineEvidence.value -match '^[1-9][0-9]*$') "$($phase.Phase) result line evidence is a positive line number"
        }
    }
    $finalState = Get-Content -Raw -LiteralPath (Join-Path $task.Root 'state/phase-state.json') | ConvertFrom-Json
    Assert-ComplianceEqual $finalState.currentPhase 'complete' 'Six successful phases advance state to complete'
    Assert-ComplianceEqual @($finalState.completedPhases).Count 6 'Six successful phases are recorded once and in order'

    # Named machine checks enforce semantics, not only headings.
    . (Join-Path $fixtureProfile 'team-bob/tools/TeamBob-BuildCommon.ps1')
    . (Join-Path $fixtureProfile 'team-bob/tools/TeamBob-ComplianceCommon.ps1')
    $chainPacket = Get-CanonicalPacketObject $task.Packet
    $chainContext = Get-TeamBobTaskGovernanceContext $task.Packet $chainPacket
    $chainGovernance = Get-TeamBobCurrentGovernance (Join-Path $fixtureProfile 'team-bob/tools') $chainPacket
    $producerBuildPath=Join-Path $task.Root 'results/build-result-fixture.json'
    $producerBuild=Get-Content -Raw -LiteralPath $producerBuildPath|ConvertFrom-Json
    foreach($invalidBuildCase in @('missing','extra','bad-exit')){
        $invalidBuild=$producerBuild|ConvertTo-Json -Depth 30|ConvertFrom-Json
        if($invalidBuildCase -ceq 'missing'){$invalidBuild.PSObject.Properties.Remove('taskId')}
        elseif($invalidBuildCase -ceq 'extra'){$invalidBuild|Add-Member -NotePropertyName unsupported -NotePropertyValue $true}
        else{$invalidBuild.exitCode=10}
        $invalidBuildPath=Join-Path $task.Root ("results/build-result-invalid-$invalidBuildCase.json");Write-ComplianceJson $invalidBuildPath $invalidBuild
        $invalidInfo=[pscustomobject]@{FullPath=$invalidBuildPath;RelativePath=("results/build-result-invalid-$invalidBuildCase.json");Hash=(Get-ComplianceHash $invalidBuildPath)}
        $invalidRejected=$false;try{[void](Get-TeamBobTask2BuildResult $invalidInfo $chainPacket $chainContext)}catch{$invalidRejected=$true}
        Assert-ComplianceTrue $invalidRejected "Build-result contract rejects the $invalidBuildCase producer-shape violation"
    }
    $allDefinitions = @()
    foreach ($checklistName in @('checklists/authoring.json','checklists/review.json')) { $allDefinitions += @((Get-Content -Raw -LiteralPath (Join-Path $governanceRoot $checklistName) | ConvertFrom-Json).checks) }
    $badLedgerPath = Join-Path $task.Root 'drafts/bad-ledger.csv'
    Write-ComplianceUtf8 $badLedgerPath "ReqID,Immutable Source Anchor,Interpretation,Acceptance Criteria,QA Links,QA Status,Evidence,Human Approval State`r`nREQ-100,,One,Acceptance,QA,CLOSED,Evidence,N/A`r`nREQ-100,WORD-1#2,Duplicate,Acceptance,QA,CLOSED,Evidence,N/A`r`n"
    $badLedgerInfo = [pscustomobject]@{FullPath=$badLedgerPath;RelativePath='drafts/bad-ledger.csv';Hash=(Get-ComplianceHash $badLedgerPath)}
    $reqSemantic = Invoke-TeamBobMachineCheck (@($allDefinitions | Where-Object {$_.id -ceq 'REQ-M-001'})[0]) $chainPacket $chainContext $badLedgerInfo $null $chainGovernance
    Assert-ComplianceEqual $reqSemantic.status 'FAIL' 'REQ-M-001 rejects duplicate ReqIDs and blank immutable source anchors'

    $badSpecPath = Join-Path $task.Root 'drafts/bad-spec.md'
    Write-ComplianceUtf8 $badSpecPath "# External Specification`r`n## ReqIDs`r`nREQ-100`r`nREQ-UNKNOWN`r`n## Scope`r`nScope`r`n## Acceptance Criteria`r`nAcceptance`r`n## Evidence`r`nEvidence`r`n## Human Approval`r`nPending`r`n"
    $badSpecInfo=[pscustomobject]@{FullPath=$badSpecPath;RelativePath='drafts/bad-spec.md';Hash=(Get-ComplianceHash $badSpecPath)}
    $ledgerResult=Get-Content -Raw -LiteralPath (Get-LatestComplianceResult $task.Root 'requirements').FullName|ConvertFrom-Json
    $ledgerPrerequisite=[pscustomobject]@{Path=(Get-TeamBobRelativePath $task.Root (Get-LatestComplianceResult $task.Root 'requirements').FullName);Hash=(Get-ComplianceHash (Get-LatestComplianceResult $task.Root 'requirements').FullName);Phase='requirements';Document=$ledgerResult}
    $specSemantic=Invoke-TeamBobMachineCheck (@($allDefinitions | Where-Object {$_.id -ceq 'SPEC-M-002'})[0]) $chainPacket $chainContext $badSpecInfo $ledgerPrerequisite $chainGovernance
    Assert-ComplianceEqual $specSemantic.status 'FAIL' 'SPEC-M-002 rejects specification ReqIDs absent from the requirement ledger'

    $badReviewPath=Join-Path $task.Root 'drafts/bad-review.md'
    Write-ComplianceUtf8 $badReviewPath "# Code Review`r`n## ReqIDs`r`nREQ-100`r`n## Allowed Files`r`nsrc/example.cpp`r`n## Findings`r`nSomething may be wrong.`r`n## Evidence`r`nNone`r`n## Human Disposition`r`nPending`r`n"
    $badReviewInfo=[pscustomobject]@{FullPath=$badReviewPath;RelativePath='drafts/bad-review.md';Hash=(Get-ComplianceHash $badReviewPath)}
    $reviewSemantic=Invoke-TeamBobMachineCheck (@($allDefinitions | Where-Object {$_.id -ceq 'REV-M-001'})[0]) $chainPacket $chainContext $badReviewInfo $null $chainGovernance
    Assert-ComplianceEqual $reviewSemantic.status 'FAIL' 'REV-M-001 rejects unstructured findings without an explicit clean declaration'
    $unsafeReviewPath=Join-Path $task.Root 'drafts/unsafe-review.md'
    Write-ComplianceUtf8 $unsafeReviewPath "# Code Review`r`n## ReqIDs`r`nREQ-100`r`n## Allowed Files`r`nsrc/example.cpp`r`n## Findings`r`n[BLOCKER] ReqID=REQ-100; Path=../.bzr/branch.conf; Line=0; Message=unsafe`r`n## Evidence`r`nEvidence`r`n## Human Disposition`r`nPending`r`n"
    $unsafeReviewInfo=[pscustomobject]@{FullPath=$unsafeReviewPath;RelativePath='drafts/unsafe-review.md';Hash=(Get-ComplianceHash $unsafeReviewPath)}
    $unsafeReview=Invoke-TeamBobMachineCheck (@($allDefinitions | Where-Object {$_.id -ceq 'REV-M-001'})[0]) $chainPacket $chainContext $unsafeReviewInfo $null $chainGovernance
    Assert-ComplianceEqual $unsafeReview.status 'FAIL' 'REV-M-001 rejects traversal, line zero, and the legacy open finding shape'

    $badTestPath=Join-Path $task.Root 'drafts/bad-test.md'
    Write-ComplianceUtf8 $badTestPath "# Test Specification`r`n## ReqIDs`r`nREQ-100`r`n## Acceptance Criteria`r`nAC-1: Required behavior.`r`n## Test Cases`r`nGeneric smoke test only.`r`n## Build Evidence`r`nEvidence`r`n## Human Approval`r`nPending`r`n"
    $badTestInfo=[pscustomobject]@{FullPath=$badTestPath;RelativePath='drafts/bad-test.md';Hash=(Get-ComplianceHash $badTestPath)}
    $testSemantic=Invoke-TeamBobMachineCheck (@($allDefinitions | Where-Object {$_.id -ceq 'TEST-M-001'})[0]) $chainPacket $chainContext $badTestInfo $null $chainGovernance
    Assert-ComplianceEqual $testSemantic.status 'FAIL' 'TEST-M-001 requires every ReqID and acceptance criterion in a test case mapping'

    $collisionTestPath=Join-Path $task.Root 'drafts/collision-test.md'
    Write-ComplianceUtf8 $collisionTestPath "# Test Specification`r`n## Test Cases`r`nTEST-1: REQ-1000; AC-10.`r`n"
    $collisionTestInfo=[pscustomobject]@{FullPath=$collisionTestPath;RelativePath='drafts/collision-test.md';Hash=(Get-ComplianceHash $collisionTestPath)}
    $reviewResultFile=Get-LatestComplianceResult $task.Root 'review'
    $reviewPrerequisite=[pscustomobject]@{Path=(Get-TeamBobRelativePath $task.Root $reviewResultFile.FullName);Hash=(Get-ComplianceHash $reviewResultFile.FullName);Phase='review';Document=(Get-Content -Raw -LiteralPath $reviewResultFile.FullName|ConvertFrom-Json)}
    $collisionSemantic=Invoke-TeamBobMachineCheck (@($allDefinitions | Where-Object {$_.id -ceq 'TEST-M-001'})[0]) $chainPacket $chainContext $collisionTestInfo $reviewPrerequisite $chainGovernance
    Assert-ComplianceEqual $collisionSemantic.status 'FAIL' 'TEST-M-001 requires exact ReqID and acceptance-ID tokens, not prefix collisions'

    # A result may not skip or backtrack in the predecessor chain merely by self-declaring a phase.
    $skippedReview=$reviewPrerequisite.Document|ConvertTo-Json -Depth 30|ConvertFrom-Json
    $skippedReview.prerequisiteResultPath=$ledgerPrerequisite.Path
    $skippedReview.prerequisiteResultSha256=$ledgerPrerequisite.Hash
    $skipWrapper=[pscustomobject]@{Path=$reviewPrerequisite.Path;Hash=$reviewPrerequisite.Hash;Phase='review';Document=$skippedReview}
    $skipRejected=$false;try{[void](Get-TeamBobBoundPriorResult $skipWrapper 'requirements' $chainContext $chainGovernance)}catch{$skipRejected=$true}
    Assert-ComplianceTrue $skipRejected 'Prior result traversal rejects review-to-requirements phase skips'
    $badRequirements=$ledgerResult|ConvertTo-Json -Depth 30|ConvertFrom-Json;$badRequirements.prerequisiteResultPath=$ledgerPrerequisite.Path;$badRequirements.prerequisiteResultSha256=$ledgerPrerequisite.Hash
    $requirementsPredecessorRejected=$false;try{Assert-TeamBobPriorComplianceResult $badRequirements $chainContext $chainGovernance 'requirements'}catch{$requirementsPredecessorRejected=$true}
    Assert-ComplianceTrue $requirementsPredecessorRejected 'Requirements result requires a null predecessor'
    $nullReview=$reviewPrerequisite.Document|ConvertTo-Json -Depth 30|ConvertFrom-Json;$nullReview.prerequisiteResultPath=$null;$nullReview.prerequisiteResultSha256=$null
    $nullReviewRejected=$false;try{Assert-TeamBobPriorComplianceResult $nullReview $chainContext $chainGovernance 'review'}catch{$nullReviewRejected=$true}
    Assert-ComplianceTrue $nullReviewRejected 'Later results require a non-null predecessor'
    $specResultFile=Get-LatestComplianceResult $task.Root 'specification';$crossReview=$reviewPrerequisite.Document|ConvertTo-Json -Depth 30|ConvertFrom-Json;$crossReview.prerequisiteResultPath=(Get-TeamBobRelativePath $task.Root $specResultFile.FullName);$crossReview.prerequisiteResultSha256=(Get-ComplianceHash $specResultFile.FullName)
    $crossWrapper=[pscustomobject]@{Path=$reviewPrerequisite.Path;Hash=$reviewPrerequisite.Hash;Phase='review';Document=$crossReview}
    $crossRejected=$false;try{[void](Get-TeamBobBoundPriorResult $crossWrapper 'requirements' $chainContext $chainGovernance)}catch{$crossRejected=$true}
    Assert-ComplianceTrue $crossRejected 'Prior result traversal rejects cross-phase backtracking'

    # Recursive PASS-chain validation must parse and validate its referenced assessment and approval bytes.
    $forgedAssessmentResult=$ledgerResult|ConvertTo-Json -Depth 30|ConvertFrom-Json
    $forgedAssessmentResult.assessmentPath='work-packet.md';$forgedAssessmentResult.assessmentSha256=(Get-ComplianceHash $task.Packet)
    $forgedAssessmentRejected=$false;try{Assert-TeamBobPriorComplianceResult $forgedAssessmentResult $chainContext $chainGovernance 'requirements'}catch{$forgedAssessmentRejected=$true}

    $specResult=Get-Content -Raw -LiteralPath $specResultFile.FullName|ConvertFrom-Json
    $arbitraryApprovalPath=Join-Path $task.Root 'approvals/arbitrary.json';Write-ComplianceJson $arbitraryApprovalPath ([ordered]@{not='an approval'})
    $arbitraryApprovalResult=$specResult|ConvertTo-Json -Depth 30|ConvertFrom-Json
    $arbitraryApprovalResult.approvalRecordPath='approvals/arbitrary.json';$arbitraryApprovalResult.approvalRecordSha256=(Get-ComplianceHash $arbitraryApprovalPath)
    $arbitraryApprovalRejected=$false;try{Assert-TeamBobPriorComplianceResult $arbitraryApprovalResult $chainContext $chainGovernance 'specification'}catch{$arbitraryApprovalRejected=$true}

    $reviewApprovalPath=[string]$reviewPrerequisite.Document.approvalRecordPath
    $replayedApprovalResult=$specResult|ConvertTo-Json -Depth 30|ConvertFrom-Json
    $replayedApprovalResult.approvalRecordPath=$reviewApprovalPath;$replayedApprovalResult.approvalRecordSha256=(Get-ComplianceHash (Join-Path $task.Root $reviewApprovalPath))
    $replayedApprovalRejected=$false;try{Assert-TeamBobPriorComplianceResult $replayedApprovalResult $chainContext $chainGovernance 'specification'}catch{$replayedApprovalRejected=$true}

    $blankFindingPath=Join-Path $task.Root 'drafts/blank-finding-review.md'
    Write-ComplianceUtf8 $blankFindingPath "# Code Review`r`n## ReqIDs`r`nREQ-100`r`n## Allowed Files`r`nsrc/example.cpp`r`n## Findings`r`n[BLOCKER] CheckId=REV-A-001; ReqID=REQ-100; Path=src/example.cpp; Line=1; Evidence=   ; Rationale= `t; Action=   ; Disposition=OPEN`r`n## Evidence`r`nEvidence`r`n## Human Disposition`r`nPending`r`n"
    $blankFindingInfo=[pscustomobject]@{FullPath=$blankFindingPath;RelativePath='drafts/blank-finding-review.md';Hash=(Get-ComplianceHash $blankFindingPath)}
    $blankFinding=Invoke-TeamBobMachineCheck (@($allDefinitions|Where-Object{$_.id -ceq 'REV-M-001'})[0]) $chainPacket $chainContext $blankFindingInfo $reviewPrerequisite $chainGovernance
    Assert-ComplianceEqual $blankFinding.status 'FAIL' 'REV-M-001 rejects whitespace-only mandatory finding text'

    $japanese=([string][char]0x65e5)+([char]0x672c)+([char]0x8a9e)
    $cp932=[System.Text.Encoding]::GetEncoding(932);[System.IO.File]::WriteAllBytes((Join-Path $bazaarRoot 'src/example.cpp'),$cp932.GetBytes("// $japanese`r`nint main() { return 0; }`r`n"))
    foreach($cp932LineCase in @([pscustomobject]@{Line=2;Expected='PASS'},[pscustomobject]@{Line=3;Expected='FAIL'})){
        $cp932ReviewPath=Join-Path $task.Root ("drafts/cp932-review-$($cp932LineCase.Line).md")
        Write-ComplianceUtf8 $cp932ReviewPath "# Code Review`r`n## ReqIDs`r`nREQ-100`r`n## Allowed Files`r`nsrc/example.cpp`r`n## Findings`r`n[WARNING] CheckId=REV-A-001; ReqID=REQ-100; Path=src/example.cpp; Line=$($cp932LineCase.Line); Evidence=source line; Rationale=review rationale; Action=fix; Disposition=OPEN`r`n## Evidence`r`nEvidence`r`n## Human Disposition`r`nPending`r`n"
        $cp932ReviewInfo=[pscustomobject]@{FullPath=$cp932ReviewPath;RelativePath=("drafts/cp932-review-$($cp932LineCase.Line).md");Hash=(Get-ComplianceHash $cp932ReviewPath)}
        $cp932Review=Invoke-TeamBobMachineCheck (@($allDefinitions|Where-Object{$_.id -ceq 'REV-M-001'})[0]) $chainPacket $chainContext $cp932ReviewInfo $reviewPrerequisite $chainGovernance
        Assert-ComplianceEqual $cp932Review.status $cp932LineCase.Expected "REV-M-001 handles CP932 source line $($cp932LineCase.Line): $($cp932Review.message)"
    }
    Assert-ComplianceTrue $forgedAssessmentRejected 'Prior PASS rejects a packet masquerading as its assessment'
    Assert-ComplianceTrue $arbitraryApprovalRejected 'Prior PASS rejects arbitrary bytes masquerading as approval'
    Assert-ComplianceTrue $replayedApprovalRejected 'Prior PASS rejects cross-phase approval replay even when bytes and hash exist'

    foreach ($entryViolation in @(
        [pscustomobject]@{Field='Risk';Value='Amber'},
        [pscustomobject]@{Field='Open QA';Value=@('QA-OPEN')},
        [pscustomobject]@{Field='RT Impact Clear';Value='NO'}
    )) {
        $badEntry=($chainPacket|ConvertTo-Json -Depth 30|ConvertFrom-Json)
        $badEntry.PSObject.Properties[$entryViolation.Field].Value=$entryViolation.Value
        $entryResult=Invoke-TeamBobMachineCheck (@($allDefinitions|Where-Object{$_.id -ceq 'IMPL-M-001'})[0]) $badEntry $chainContext ([pscustomobject]@{FullPath=(Join-Path $task.Root 'results/build-result-fixture.json');RelativePath='results/build-result-fixture.json';Hash='0'}) $ledgerPrerequisite $chainGovernance
        Assert-ComplianceEqual $entryResult.status 'FAIL' "IMPL-M-001 blocks $($entryViolation.Field) as a trusted failure"
    }

    # Role selection is conservative for scope, expiry, and case-only principal reuse.
    $caseRoles=($roles|ConvertTo-Json -Depth 30|ConvertFrom-Json);$caseRoles.assignments[1].principalId='PRINCIPAL-SPEC'
    $caseRejected=$false;try{[void](Get-TeamBobSelectedAssignments $chainPacket $caseRoles 'CHAIN-1' -RequireActive)}catch{$caseRejected=$true}
    Assert-ComplianceTrue $caseRejected 'Role separation rejects case-only principal reuse'
    $scopeRoles=($roles|ConvertTo-Json -Depth 30|ConvertFrom-Json);$scopeRoles.assignments[0].scope.phases=@('specification')
    $scopeRejected=$false;try{[void](Get-TeamBobSelectedAssignments $chainPacket $scopeRoles 'CHAIN-1' -RequireActive)}catch{$scopeRejected=$true}
    Assert-ComplianceTrue $scopeRejected 'Specification assignment must cover specification and test phases'
    $expiredRoles=($roles|ConvertTo-Json -Depth 30|ConvertFrom-Json);$expiredRoles.assignments[2].validFromUtc=$now.AddDays(-2).ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ');$expiredRoles.assignments[2].validUntilUtc=$now.AddDays(-1).ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')
    $expiryRejected=$false;try{[void](Get-TeamBobSelectedAssignments $chainPacket $expiredRoles 'CHAIN-1' -RequireActive)}catch{$expiryRejected=$true}
    Assert-ComplianceTrue $expiryRejected 'Start-time role selection rejects expired assignments'

    $rolesPath=Join-Path $governanceRoot 'roles.json';$rolesBytes=[System.IO.File]::ReadAllBytes($rolesPath)
    try {
        $allExpiredRoles=($roles|ConvertTo-Json -Depth 30|ConvertFrom-Json)
        foreach($assignment in @($allExpiredRoles.assignments)){$assignment.validFromUtc=$now.AddDays(-2).ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ');$assignment.validUntilUtc=$now.AddDays(-1).ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')}
        Write-ComplianceJson $rolesPath $allExpiredRoles
        $expiredRoleHash=Get-TeamBobRoleLedgerHash $governanceRoot
        $expiredEvaluationTask=New-ComplianceTaskFixture 'EXPIRED-EVAL-1' $bazaarRoot $policyHash $expiredRoleHash
        $expiredArtifact=Join-Path $expiredEvaluationTask.Root 'drafts/requirement-ledger.csv';Write-ComplianceUtf8 $expiredArtifact $phaseData[0].Text
        $expiredAssessment=Join-Path $expiredEvaluationTask.Root 'drafts/assessment-requirements.json'
        New-ComplianceAssessment $expiredAssessment 'EXPIRED-EVAL-1' 'requirements' (Get-ComplianceHash $expiredEvaluationTask.Packet) $policyHash $expiredRoleHash 'drafts/requirement-ledger.csv' (Get-ComplianceHash $expiredArtifact) $phaseData[0].Ai
        $expiredEvaluation=Invoke-ComplianceScript $compliancePath @('-WorkPacket',$expiredEvaluationTask.Packet,'-Phase','requirements','-ArtifactPath',$expiredArtifact,'-AssessmentPath',$expiredAssessment)
        Assert-ComplianceEqual $expiredEvaluation.ExitCode 20 'Compliance rejects packet-selected assignments that are no longer active'
        Assert-ComplianceEqual @(Get-ChildItem -LiteralPath (Join-Path $expiredEvaluationTask.Root 'results') -File).Count 0 'Expired assignment rejection creates no result'
    } finally { [System.IO.File]::WriteAllBytes($rolesPath,$rolesBytes) }

    # A trusted AI failure creates FAIL evidence and never advances state.
    $failTask = New-ComplianceTaskFixture 'FAIL-1' $bazaarRoot $policyHash $roleHash
    $failArtifact = Join-Path $failTask.Root 'drafts/requirement-ledger.csv'
    Write-ComplianceUtf8 $failArtifact $phaseData[0].Text
    $failAssessment = Join-Path $failTask.Root 'drafts/assessment-requirements.json'
    New-ComplianceAssessment $failAssessment 'FAIL-1' 'requirements' (Get-ComplianceHash $failTask.Packet) $policyHash $roleHash 'drafts/requirement-ledger.csv' (Get-ComplianceHash $failArtifact) $phaseData[0].Ai 'FAIL'
    $failResult = Invoke-ComplianceScript $compliancePath @('-WorkPacket',$failTask.Packet,'-Phase','requirements','-ArtifactPath',$failArtifact,'-AssessmentPath',$failAssessment)
    Assert-ComplianceEqual $failResult.ExitCode 10 'Required FAIL uses exit code 10'
    Assert-ComplianceEqual ((Get-Content -Raw -LiteralPath (Get-LatestComplianceResult $failTask.Root 'requirements').FullName | ConvertFrom-Json).status) 'FAIL' 'Trusted FAIL emits a result'
    Assert-ComplianceEqual ((Get-Content -Raw -LiteralPath (Join-Path $failTask.Root 'state/phase-state.json') | ConvertFrom-Json).currentPhase) 'requirements' 'FAIL does not advance state'

    # Missing required evidence is unresolved and creates evidence, but invalid cross references do not.
    $unresolvedTask = New-ComplianceTaskFixture 'UNRESOLVED-1' $bazaarRoot $policyHash $roleHash
    $unresolvedArtifact = Join-Path $unresolvedTask.Root 'drafts/requirement-ledger.csv'
    Write-ComplianceUtf8 $unresolvedArtifact $phaseData[0].Text
    $unresolvedAssessment = Join-Path $unresolvedTask.Root 'drafts/assessment-requirements.json'
    New-ComplianceAssessment $unresolvedAssessment 'UNRESOLVED-1' 'requirements' (Get-ComplianceHash $unresolvedTask.Packet) $policyHash $roleHash 'drafts/requirement-ledger.csv' (Get-ComplianceHash $unresolvedArtifact) $phaseData[0].Ai -MissingRationaleEvidence
    $unresolvedResult = Invoke-ComplianceScript $compliancePath @('-WorkPacket',$unresolvedTask.Packet,'-Phase','requirements','-ArtifactPath',$unresolvedArtifact,'-AssessmentPath',$unresolvedAssessment)
    Assert-ComplianceEqual $unresolvedResult.ExitCode 11 'Missing required evidence uses exit code 11'
    Assert-ComplianceEqual ((Get-Content -Raw -LiteralPath (Get-LatestComplianceResult $unresolvedTask.Root 'requirements').FullName | ConvertFrom-Json).status) 'UNRESOLVED' 'Trusted unresolved input emits a result'

    $unsupportedEvidenceTask=New-ComplianceTaskFixture 'UNSUPPORTED-EVIDENCE-1' $bazaarRoot $policyHash $roleHash
    $unsupportedEvidenceArtifact=Join-Path $unsupportedEvidenceTask.Root 'drafts/requirement-ledger.csv';Write-ComplianceUtf8 $unsupportedEvidenceArtifact $phaseData[0].Text
    $unsupportedEvidenceAssessment=Join-Path $unsupportedEvidenceTask.Root 'drafts/assessment-requirements.json'
    New-ComplianceAssessment $unsupportedEvidenceAssessment 'UNSUPPORTED-EVIDENCE-1' 'requirements' (Get-ComplianceHash $unsupportedEvidenceTask.Packet) $policyHash $roleHash 'drafts/requirement-ledger.csv' (Get-ComplianceHash $unsupportedEvidenceArtifact) $phaseData[0].Ai
    $unsupportedDocument=Get-Content -Raw -LiteralPath $unsupportedEvidenceAssessment|ConvertFrom-Json
    foreach($check in @($unsupportedDocument.checks)){$check.evidence[0].value='work-packet.md';$check.evidence[1].value='999'}
    Write-ComplianceJson $unsupportedEvidenceAssessment $unsupportedDocument
    $unsupportedEvidenceResult=Invoke-ComplianceScript $compliancePath @('-WorkPacket',$unsupportedEvidenceTask.Packet,'-Phase','requirements','-ArtifactPath',$unsupportedEvidenceArtifact,'-AssessmentPath',$unsupportedEvidenceAssessment)
    Assert-ComplianceEqual $unsupportedEvidenceResult.ExitCode 11 'Safe but unverifiable AI path/line support yields NEEDS_HUMAN_REVIEW'
    Assert-ComplianceEqual @(Get-ChildItem -LiteralPath (Join-Path $unsupportedEvidenceTask.Root 'results') -File).Count 1 'Unverifiable AI support still writes one audit result'

    foreach($evidenceAttack in @('line-zero','sha-mismatch','path-traversal')){
        $attackId=('AI-'+$evidenceAttack.ToUpperInvariant().Replace('-','')+'-1');$attackTask=New-ComplianceTaskFixture $attackId $bazaarRoot $policyHash $roleHash
        $attackArtifact=Join-Path $attackTask.Root 'drafts/requirement-ledger.csv';Write-ComplianceUtf8 $attackArtifact $phaseData[0].Text
        $attackAssessment=Join-Path $attackTask.Root 'drafts/assessment-requirements.json';New-ComplianceAssessment $attackAssessment $attackId 'requirements' (Get-ComplianceHash $attackTask.Packet) $policyHash $roleHash 'drafts/requirement-ledger.csv' (Get-ComplianceHash $attackArtifact) $phaseData[0].Ai
        $attackDocument=Get-Content -Raw -LiteralPath $attackAssessment|ConvertFrom-Json
        if($evidenceAttack -ceq 'line-zero'){$attackDocument.checks[0].evidence[1].value='0';$expectedAttackCode=20}
        elseif($evidenceAttack -ceq 'sha-mismatch'){$attackDocument.checks[0].evidence+=@([pscustomobject]@{type='sha256';value=('0'*64)});$expectedAttackCode=30}
        else{$escapePath=Join-Path (Split-Path -Parent $attackTask.Root) 'escape.txt';Write-ComplianceUtf8 $escapePath 'escape';$attackDocument.checks[0].evidence[0].value='../escape.txt';$expectedAttackCode=30}
        Write-ComplianceJson $attackAssessment $attackDocument
        $attackResult=Invoke-ComplianceScript $compliancePath @('-WorkPacket',$attackTask.Packet,'-Phase','requirements','-ArtifactPath',$attackArtifact,'-AssessmentPath',$attackAssessment)
        Assert-ComplianceEqual $attackResult.ExitCode $expectedAttackCode "AI evidence $evidenceAttack is classified fail-closed"
        Assert-ComplianceEqual @(Get-ChildItem -LiteralPath (Join-Path $attackTask.Root 'results') -File).Count 0 "AI evidence $evidenceAttack creates no audit result"
    }

    $naTask=New-ComplianceTaskFixture 'NA-1' $bazaarRoot $policyHash $roleHash;$naArtifact=Join-Path $naTask.Root 'drafts/requirement-ledger.csv';Write-ComplianceUtf8 $naArtifact $phaseData[0].Text;$naAssessment=Join-Path $naTask.Root 'drafts/assessment-requirements.json'
    New-ComplianceAssessment $naAssessment 'NA-1' 'requirements' (Get-ComplianceHash $naTask.Packet) $policyHash $roleHash 'drafts/requirement-ledger.csv' (Get-ComplianceHash $naArtifact) $phaseData[0].Ai 'NOT_APPLICABLE'
    $naResult=Invoke-ComplianceScript $compliancePath @('-WorkPacket',$naTask.Packet,'-Phase','requirements','-ArtifactPath',$naArtifact,'-AssessmentPath',$naAssessment)
    Assert-ComplianceEqual $naResult.ExitCode 10 'Shipped NOT_APPLICABLE on required checks is a trusted FAIL'

    $orderedTask = New-ComplianceTaskFixture 'ORDER-1' $bazaarRoot $policyHash $roleHash
    $orderedArtifact = Join-Path $orderedTask.Root 'drafts/external-spec.md'
    Write-ComplianceUtf8 $orderedArtifact $phaseData[1].Text
    $orderedAssessment = Join-Path $orderedTask.Root 'drafts/assessment-specification.json'
    New-ComplianceAssessment $orderedAssessment 'ORDER-1' 'specification' (Get-ComplianceHash $orderedTask.Packet) $policyHash $roleHash 'drafts/external-spec.md' (Get-ComplianceHash $orderedArtifact) $phaseData[1].Ai
    $beforeOrderResults = @(Get-ChildItem -LiteralPath (Join-Path $orderedTask.Root 'results') -File).Count
    $orderResult = Invoke-ComplianceScript $compliancePath @('-WorkPacket',$orderedTask.Packet,'-Phase','specification','-ArtifactPath',$orderedArtifact,'-AssessmentPath',$orderedAssessment)
    Assert-ComplianceEqual $orderResult.ExitCode 20 'Out-of-order phase is an invalid cross-reference'
    Assert-ComplianceEqual @(Get-ChildItem -LiteralPath (Join-Path $orderedTask.Root 'results') -File).Count $beforeOrderResults 'Exit 20 creates no task result'

    $tamperTask = New-ComplianceTaskFixture 'TAMPER-1' $bazaarRoot $policyHash $roleHash
    $tamperArtifact = Join-Path $tamperTask.Root 'drafts/requirement-ledger.csv'
    Write-ComplianceUtf8 $tamperArtifact $phaseData[0].Text
    $tamperAssessment = Join-Path $tamperTask.Root 'drafts/assessment-requirements.json'
    New-ComplianceAssessment $tamperAssessment 'TAMPER-1' 'requirements' (Get-ComplianceHash $tamperTask.Packet) $policyHash $roleHash 'drafts/requirement-ledger.csv' (Get-ComplianceHash $tamperArtifact) $phaseData[0].Ai
    Add-Content -LiteralPath $tamperTask.Packet -Value 'tampered'
    $tamperResult = Invoke-ComplianceScript $compliancePath @('-WorkPacket',$tamperTask.Packet,'-Phase','requirements','-ArtifactPath',$tamperArtifact,'-AssessmentPath',$tamperAssessment)
    Assert-ComplianceEqual $tamperResult.ExitCode 30 'Packet hash tampering uses exit code 30'
    Assert-ComplianceEqual @(Get-ChildItem -LiteralPath (Join-Path $tamperTask.Root 'results') -File).Count 0 'Exit 30 creates no task result'

    # Version is checked before packet shape and exposes the fixed diagnostic.
    $versionTask = New-ComplianceTaskFixture 'VERSION-1' $bazaarRoot $policyHash $roleHash
    $versionPacket = Get-CanonicalPacketObject $versionTask.Packet
    $versionPacket.PSObject.Properties['Profile Version'].Value = '0.1.0-poc'
    $versionPacket.PSObject.Properties.Remove('Task ID')
    Write-CanonicalPacketObject $versionTask.Packet $versionPacket
    $versionResult = Invoke-ComplianceScript $compliancePath @('-WorkPacket',$versionTask.Packet,'-Phase','requirements','-ArtifactPath',(Join-Path $versionTask.Root 'drafts/missing.csv'),'-AssessmentPath',(Join-Path $versionTask.Root 'drafts/missing.json'))
    Assert-ComplianceEqual $versionResult.ExitCode 20 'Unsupported packet version uses exit code 20'
    Assert-ComplianceTrue ($versionResult.Output -match 'PACKET_VERSION_UNSUPPORTED') 'Unsupported packet version wins before shape/path diagnostics'

    $duplicateVersionTask=New-ComplianceTaskFixture 'DUPVERSION-1' $bazaarRoot $policyHash $roleHash
    $duplicateVersionText=[System.IO.File]::ReadAllText($duplicateVersionTask.Packet)
    $duplicateVersionText=[regex]::Replace($duplicateVersionText,'("Profile Version"\s*:\s*"0\.2\.0-poc"\s*,)','$1 "Profile\u0020Version": "0.2.0-poc",',1)
    Assert-ComplianceEqual ([regex]::Matches($duplicateVersionText,'Profile\\u0020Version').Count) 1 'Duplicate-version fixture injects the escaped duplicate member exactly once'
    Write-ComplianceUtf8 $duplicateVersionTask.Packet $duplicateVersionText
    $duplicateVersionResult=Invoke-ComplianceScript $compliancePath @('-WorkPacket',$duplicateVersionTask.Packet,'-Phase','requirements','-ArtifactPath',(Join-Path $duplicateVersionTask.Root 'drafts/missing.csv'),'-AssessmentPath',(Join-Path $duplicateVersionTask.Root 'drafts/missing.json'))
    Assert-ComplianceEqual $duplicateVersionResult.ExitCode 20 "Decoded duplicate Profile Version is rejected before other validation; output: $($duplicateVersionResult.Output.Trim())"
    Assert-ComplianceTrue ($duplicateVersionResult.Output -match 'PACKET_VERSION_UNSUPPORTED') 'Decoded duplicate Profile Version has the fixed diagnostic'

    $duplicateOtherTask=New-ComplianceTaskFixture 'DUPOTHER-1' $bazaarRoot $policyHash $roleHash
    $duplicateOtherText=[System.IO.File]::ReadAllText($duplicateOtherTask.Packet)
    $duplicateOtherText=[regex]::Replace($duplicateOtherText,'("Task ID"\s*:\s*"DUPOTHER-1"\s*,)','$1 "Task ID": "OTHER",',1)
    Write-ComplianceUtf8 $duplicateOtherTask.Packet $duplicateOtherText
    $duplicateOtherResult=Invoke-ComplianceScript $compliancePath @('-WorkPacket',$duplicateOtherTask.Packet,'-Phase','requirements','-ArtifactPath',(Join-Path $duplicateOtherTask.Root 'drafts/missing.csv'),'-AssessmentPath',(Join-Path $duplicateOtherTask.Root 'drafts/missing.json'))
    Assert-ComplianceEqual $duplicateOtherResult.ExitCode 20 'Duplicate non-version JSON member is contract-invalid'
    Assert-ComplianceTrue ($duplicateOtherResult.Output -notmatch 'PACKET_VERSION_UNSUPPORTED') 'Non-version duplicate is not misreported as packet version failure'
    Assert-ComplianceEqual @(Get-ChildItem -LiteralPath (Join-Path $duplicateOtherTask.Root 'results') -File).Count 0 'Duplicate governed JSON creates no result'

    $versionPrecedenceTask=New-ComplianceTaskFixture 'VERSION-PRECEDENCE-1' $bazaarRoot $policyHash $roleHash
    $versionPrecedenceText=[System.IO.File]::ReadAllText($versionPrecedenceTask.Packet)
    $versionPrecedenceText=[regex]::Replace($versionPrecedenceText,'("Profile Version"\s*:\s*)"0\.2\.0-poc"','$1"9.9.9"',1)
    $versionPrecedenceText=[regex]::Replace($versionPrecedenceText,'("Task ID"\s*:\s*"VERSION-PRECEDENCE-1"\s*,)','$1 "Task ID": "OTHER",',1)
    Assert-ComplianceEqual ([regex]::Matches($versionPrecedenceText,'"Task ID"').Count) 2 'Version-precedence fixture injects exactly one duplicate non-version member'
    Assert-ComplianceEqual ([regex]::Matches($versionPrecedenceText,'"9\.9\.9"').Count) 1 'Version-precedence fixture replaces the profile version exactly once'
    Write-ComplianceUtf8 $versionPrecedenceTask.Packet $versionPrecedenceText
    $readerStatus=$null;try{[void](Read-TeamBobCanonicalPacket $versionPrecedenceTask.Packet)}catch{$readerStatus=$_.Exception.Data['TeamBobStatus']}
    Assert-ComplianceEqual $readerStatus 'PACKET_VERSION_UNSUPPORTED' 'Shared packet reader gives version failure precedence over a duplicate non-version member'
    $versionPrecedenceResult=Invoke-ComplianceScript $compliancePath @('-WorkPacket',$versionPrecedenceTask.Packet,'-Phase','requirements','-ArtifactPath',(Join-Path $versionPrecedenceTask.Root 'drafts/missing.csv'),'-AssessmentPath',(Join-Path $versionPrecedenceTask.Root 'drafts/missing.json'))
    Assert-ComplianceEqual $versionPrecedenceResult.ExitCode 20 'Consumer returns exit 20 for unknown version plus duplicate other member'
    Assert-ComplianceTrue ($versionPrecedenceResult.Output -match 'PACKET_VERSION_UNSUPPORTED') 'Consumer preserves version-first diagnostic with duplicate other member'
    Assert-ComplianceEqual @(Get-ChildItem -LiteralPath (Join-Path $versionPrecedenceTask.Root 'results') -File).Count 0 'Version-first rejection creates no result'

    $duplicateAssessmentTask=New-ComplianceTaskFixture 'DUPASSESS-1' $bazaarRoot $policyHash $roleHash;$duplicateAssessmentArtifact=Join-Path $duplicateAssessmentTask.Root 'drafts/requirement-ledger.csv';Write-ComplianceUtf8 $duplicateAssessmentArtifact $phaseData[0].Text;$duplicateAssessmentPath=Join-Path $duplicateAssessmentTask.Root 'drafts/assessment-requirements.json'
    New-ComplianceAssessment $duplicateAssessmentPath 'DUPASSESS-1' 'requirements' (Get-ComplianceHash $duplicateAssessmentTask.Packet) $policyHash $roleHash 'drafts/requirement-ledger.csv' (Get-ComplianceHash $duplicateAssessmentArtifact) $phaseData[0].Ai
    $duplicateAssessmentText=[System.IO.File]::ReadAllText($duplicateAssessmentPath);$duplicateAssessmentText=[regex]::Replace($duplicateAssessmentText,'("taskId"\s*:\s*"DUPASSESS-1"\s*,)','$1 "taskId":"DUPASSESS-1",',1);Assert-ComplianceEqual ([regex]::Matches($duplicateAssessmentText,'"taskId"').Count) 2 'Duplicate-assessment fixture injects one duplicate member';Write-ComplianceUtf8 $duplicateAssessmentPath $duplicateAssessmentText
    $duplicateAssessmentResult=Invoke-ComplianceScript $compliancePath @('-WorkPacket',$duplicateAssessmentTask.Packet,'-Phase','requirements','-ArtifactPath',$duplicateAssessmentArtifact,'-AssessmentPath',$duplicateAssessmentPath)
    Assert-ComplianceEqual $duplicateAssessmentResult.ExitCode 20 'Duplicate assessment member is contract-invalid'
    Assert-ComplianceEqual @(Get-ChildItem -LiteralPath (Join-Path $duplicateAssessmentTask.Root 'results') -File).Count 0 'Duplicate assessment creates no result'

    # Missing human approval is unresolved; a cross-task replay is invalid and creates no additional result.
    $humanTask=New-ComplianceTaskFixture 'HUMAN-1' $bazaarRoot $policyHash $roleHash;$humanReqArtifact=Join-Path $humanTask.Root 'drafts/requirement-ledger.csv';Write-ComplianceUtf8 $humanReqArtifact $phaseData[0].Text;$humanReqAssessment=Join-Path $humanTask.Root 'drafts/assessment-requirements.json'
    New-ComplianceAssessment $humanReqAssessment 'HUMAN-1' 'requirements' (Get-ComplianceHash $humanTask.Packet) $policyHash $roleHash 'drafts/requirement-ledger.csv' (Get-ComplianceHash $humanReqArtifact) $phaseData[0].Ai
    Assert-ComplianceEqual (Invoke-ComplianceScript $compliancePath @('-WorkPacket',$humanTask.Packet,'-Phase','requirements','-ArtifactPath',$humanReqArtifact,'-AssessmentPath',$humanReqAssessment)).ExitCode 0 'Human fixture reaches specification'
    $humanSpecArtifact=Join-Path $humanTask.Root 'drafts/external-spec.md';Write-ComplianceUtf8 $humanSpecArtifact $phaseData[1].Text;$humanSpecAssessment=Join-Path $humanTask.Root 'drafts/assessment-specification.json'
    New-ComplianceAssessment $humanSpecAssessment 'HUMAN-1' 'specification' (Get-ComplianceHash $humanTask.Packet) $policyHash $roleHash 'drafts/external-spec.md' (Get-ComplianceHash $humanSpecArtifact) $phaseData[1].Ai
    $missingHuman=Invoke-ComplianceScript $compliancePath @('-WorkPacket',$humanTask.Packet,'-Phase','specification','-ArtifactPath',$humanSpecArtifact,'-AssessmentPath',$humanSpecAssessment)
    Assert-ComplianceEqual $missingHuman.ExitCode 11 'Missing required approval uses exit code 11'
    $beforeReplay=@(Get-ChildItem -LiteralPath (Join-Path $humanTask.Root 'results') -File).Count
    $foreignApprovalSource=(Get-ChildItem -LiteralPath (Join-Path $task.Root 'approvals') -Filter 'approval-specification-*.json' -File|Select-Object -First 1).FullName
    $foreignApproval=Join-Path $humanTask.Root 'approvals/replayed-specification.json';Copy-Item -LiteralPath $foreignApprovalSource -Destination $foreignApproval
    $replay=Invoke-ComplianceScript $compliancePath @('-WorkPacket',$humanTask.Packet,'-Phase','specification','-ArtifactPath',$humanSpecArtifact,'-AssessmentPath',$humanSpecAssessment,'-ApprovalRecordPath',$foreignApproval)
    Assert-ComplianceEqual $replay.ExitCode 20 'Approval record from another task is a cross-reference failure'
    Assert-ComplianceEqual @(Get-ChildItem -LiteralPath (Join-Path $humanTask.Root 'results') -File).Count $beforeReplay 'Cross-task approval replay creates no additional result'

    $approvalCountBefore=@(Get-ChildItem -LiteralPath (Join-Path $humanTask.Root 'approvals') -File).Count
    $nonHuman=Invoke-ComplianceScript $approvalPath @('-WorkPacket',$humanTask.Packet,'-Phase','specification','-AssignmentId','ASSIGN-SPEC','-ArtifactPath',$humanSpecArtifact,'-EvidencePath',$humanSpecArtifact,'-ExpiresAtUtc',$now.AddHours(1).ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ'))
    Assert-ComplianceEqual $nonHuman.ExitCode 20 'Approval generator requires explicit human-terminal invocation'
    $tooLong=Invoke-ComplianceScript $approvalPath @('-WorkPacket',$humanTask.Packet,'-Phase','specification','-AssignmentId','ASSIGN-SPEC','-ArtifactPath',$humanSpecArtifact,'-EvidencePath',$humanSpecArtifact,'-ExpiresAtUtc',$now.AddHours(169).ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ'),'-HumanTerminal')
    Assert-ComplianceEqual $tooLong.ExitCode 20 'Approval validity may not exceed 168 hours'
    Assert-ComplianceEqual @(Get-ChildItem -LiteralPath (Join-Path $humanTask.Root 'approvals') -File).Count $approvalCountBefore 'Rejected approval attempts create no record'
} finally {
    if (Test-Path -LiteralPath $fixtureRoot) {
        $resolved = [System.IO.Path]::GetFullPath($fixtureRoot)
        $temp = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
        if (-not $resolved.StartsWith($temp, [System.StringComparison]::OrdinalIgnoreCase)) { throw "Refusing to remove fixture outside temp: $resolved" }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}

Write-Host "PASS: $script:ComplianceAssertions compliance assertions succeeded."
