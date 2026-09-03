[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$WorkPacket,
    [Parameter(Mandatory=$true)][ValidateSet('requirements','specification','impact','implementation','review','test')][string]$Phase,
    [Parameter(Mandatory=$true)][string]$ArtifactPath,
    [Parameter(Mandatory=$true)][string]$AssessmentPath,
    [string]$ApprovalRecordPath
)

$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'TeamBob-BuildCommon.ps1')
. (Join-Path $PSScriptRoot 'TeamBob-GovernanceCommon.ps1')
. (Join-Path $PSScriptRoot 'TeamBob-ComplianceCommon.ps1')
$createdResultPath=$null

try {
    $packetFull=Get-TeamBobCanonicalPath $WorkPacket 'Work packet' 'INTEGRITY_FAILED'
    $packet=Read-TeamBobCanonicalPacket $packetFull
    $governance=Get-TeamBobCurrentGovernance $PSScriptRoot $packet
    $context=Get-TeamBobTaskGovernanceContext $packetFull $packet
    $assignments=Get-TeamBobSelectedAssignments $packet $governance.Roles $context.TaskId -RequireActive
    $phasePolicy=Get-TeamBobPhasePolicy $governance.Policy $Phase
    $artifact=Get-TeamBobGovernedRelativeFile $context $ArtifactPath 'Artifact'
    if (-not ($artifact.RelativePath -clike ([string]$phasePolicy.artifact).Replace('\','/'))) { throw (New-TeamBobComplianceFailure 20 'Artifact does not match the policy phase artifact.') }
    $state=Read-TeamBobComplianceJson $context.StatePath 'Phase state'
    $prerequisite=Assert-TeamBobPhaseState $state $context $governance $Phase
    $assessment=Read-TeamBobAssessment $context $governance $artifact $phasePolicy $Phase $AssessmentPath
    $now=[datetimeoffset]::UtcNow
    $approval=$null
    if ($null -ne $phasePolicy.completionApprovalRole) { $approval=Read-TeamBobApprovalForPhase $context $governance $artifact $prerequisite $phasePolicy $assignments $Phase $ApprovalRecordPath $now }
    elseif (-not [string]::IsNullOrWhiteSpace($ApprovalRecordPath)) { throw (New-TeamBobComplianceFailure 20 'ApprovalRecordPath is not permitted for this phase.') }

    $definitions=Get-TeamBobChecklistDefinitions $governance $phasePolicy
    $checks=@()
    foreach ($definition in $definitions) {
        if ($definition.kind -ceq 'machine') {
            $check=Invoke-TeamBobMachineCheck $definition $packet $context $artifact $prerequisite $governance
        } elseif ($definition.kind -ceq 'ai') {
            $input=$assessment.Checks[[string]$definition.id]
            $status=[string]$input.status; $message=[string]$input.message
            if ($status -ceq 'NOT_APPLICABLE' -and $definition.allowNotApplicable -ne $true) { $status='FAIL'; $message='NOT_APPLICABLE is forbidden for this required check.' }
            elseif (-not (Test-TeamBobEvidenceTypes @($input.evidence) @($definition.requiredEvidence))) { $status='NEEDS_HUMAN_REVIEW'; $message='Required evidence types are missing.' }
            $check=New-TeamBobCheckResult $definition $status @($input.evidence) $message
        } elseif ($definition.kind -ceq 'human') {
            if ($null -eq $approval -or -not $approval.IsCurrent) { $check=New-TeamBobCheckResult $definition 'NEEDS_HUMAN_REVIEW' @([ordered]@{type='approvalRecord';value='MISSING_OR_EXPIRED'}) 'A current approval record is required.' }
            else { $check=New-TeamBobCheckResult $definition 'PASS' @([ordered]@{type='approvalRecord';value=$approval.Info.RelativePath}) 'Current approval record verified.' }
        } else { throw (New-TeamBobComplianceFailure 20 "Unsupported checklist kind: $($definition.kind)") }
        if (-not (Test-TeamBobEvidenceTypes @($check.evidence) @($definition.requiredEvidence))) {
            if ($check.kind -ceq 'machine') { throw (New-TeamBobComplianceFailure 20 "Machine implementation omitted required evidence: $($check.id)") }
            $check.status='NEEDS_HUMAN_REVIEW';$check.message='Required evidence types are missing.'
        }
        $checks += $check
    }
    $status='PASS';$exitCode=0
    if (@($checks | Where-Object { $_.status -ceq 'FAIL' }).Count -gt 0) { $status='FAIL';$exitCode=10 }
    elseif (@($checks | Where-Object { $_.status -ceq 'NEEDS_HUMAN_REVIEW' }).Count -gt 0) { $status='UNRESOLVED';$exitCode=11 }
    $evaluated=$now.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')
    $result=[ordered]@{
        schemaVersion='1.0';profileVersion='0.2.0-poc';policyVersion='0.2.0-poc';taskId=$context.TaskId;phase=$Phase;evaluatedAtUtc=$evaluated;status=$status
        workPacketPath=$context.PacketPath;workPacketSha256=$context.PacketHash;policyBundleSha256=$governance.PolicyHash;roleLedgerSha256=$governance.RoleHash;artifactPath=$artifact.RelativePath;artifactSha256=$artifact.Hash
        assessmentPath=$assessment.Info.RelativePath;assessmentSha256=$assessment.Info.Hash;approvalRecordPath=$(if($null -eq $approval){$null}else{$approval.Info.RelativePath});approvalRecordSha256=$(if($null -eq $approval){$null}else{$approval.Info.Hash})
        prerequisiteResultPath=$(if($null -eq $prerequisite){$null}else{$prerequisite.Path});prerequisiteResultSha256=$(if($null -eq $prerequisite){$null}else{$prerequisite.Hash});checks=@($checks)
    }
    $resultName='compliance-'+$Phase+'-'+$now.ToString('yyyyMMddTHHmmssfffffffZ')+'-'+[guid]::NewGuid().ToString('N')+'.json'
    $createdResultPath=Join-Path (Join-Path $context.TaskRoot 'results') $resultName
    Write-TeamBobCreateOnlyJson $createdResultPath $result
    if ($exitCode -eq 0) {
        $phaseIndex=[array]::IndexOf($script:TeamBobPhaseOrder,$Phase)
        $nextPhase=if($phaseIndex -eq ($script:TeamBobPhaseOrder.Count-1)){'complete'}else{$script:TeamBobPhaseOrder[$phaseIndex+1]}
        $newState=[ordered]@{schemaVersion='1.0';profileVersion='0.2.0-poc';policyVersion='0.2.0-poc';taskId=$context.TaskId;currentPhase=$nextPhase;completedPhases=@($script:TeamBobPhaseOrder|Select-Object -First ($phaseIndex+1));workPacketPath=$context.PacketPath;workPacketSha256=$context.PacketHash;policyBundleSha256=$governance.PolicyHash;roleLedgerSha256=$governance.RoleHash;latestResultPath=(Get-TeamBobRelativePath $context.TaskRoot $createdResultPath);latestResultSha256=(Get-TeamBobGovernanceFileHash $createdResultPath);updatedAtUtc=$evaluated}
        try { Write-TeamBobAtomicStateJson $context.StatePath $newState }
        catch { [System.IO.File]::Delete($createdResultPath);$createdResultPath=$null;throw }
    }
    [Console]::Out.WriteLine($status)
    [Console]::Out.WriteLine("RESULT $createdResultPath")
    exit $exitCode
} catch {
    if ($null -ne $createdResultPath -and (Test-Path -LiteralPath $createdResultPath -PathType Leaf)) { [System.IO.File]::Delete($createdResultPath) }
    $code=20
    if ($null -ne $_.Exception.Data['NativeExitCode'] -and [int]$_.Exception.Data['NativeExitCode'] -in @(20,30)) { $code=[int]$_.Exception.Data['NativeExitCode'] }
    elseif ($_.Exception.Data['TeamBobStatus'] -eq 'INTEGRITY_FAILED') { $code=30 }
    [Console]::Error.WriteLine($_.Exception.Message)
    exit $code
}
