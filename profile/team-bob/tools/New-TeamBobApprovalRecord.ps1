[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$WorkPacket,
    [Parameter(Mandatory=$true)][ValidateSet('specification','impact','review','test')][string]$Phase,
    [Parameter(Mandatory=$true)][string]$AssignmentId,
    [Parameter(Mandatory=$true)][string]$ArtifactPath,
    [Parameter(Mandatory=$true)][string[]]$EvidencePath,
    [Parameter(Mandatory=$true)][string]$ExpiresAtUtc,
    [switch]$HumanTerminal
)

$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'TeamBob-BuildCommon.ps1')
. (Join-Path $PSScriptRoot 'TeamBob-GovernanceCommon.ps1')
. (Join-Path $PSScriptRoot 'TeamBob-ComplianceCommon.ps1')

try {
    if (-not $HumanTerminal) { throw (New-TeamBobComplianceFailure 20 'Approval creation is human-terminal only; -HumanTerminal is required.') }
    $packetFull=Get-TeamBobCanonicalPath $WorkPacket 'Work packet' 'INTEGRITY_FAILED'
    $packet=Read-TeamBobCanonicalPacket $packetFull
    $governance=Get-TeamBobCurrentGovernance $PSScriptRoot $packet
    $context=Get-TeamBobTaskGovernanceContext $packetFull $packet
    $assignments=Get-TeamBobSelectedAssignments $packet $governance.Roles $context.TaskId -RequireActive
    $phasePolicy=Get-TeamBobPhasePolicy $governance.Policy $Phase
    if ($null -eq $phasePolicy.completionApprovalRole) { throw (New-TeamBobComplianceFailure 20 'This phase has no human-terminal completion approval.') }
    $role=[string]$phasePolicy.completionApprovalRole
    if ($AssignmentId -cne $assignments[$role].assignmentId) { throw (New-TeamBobComplianceFailure 20 'AssignmentId does not match the packet-selected phase role.') }
    $artifact=Get-TeamBobGovernedRelativeFile $context $ArtifactPath 'Artifact'
    if (-not ($artifact.RelativePath -clike ([string]$phasePolicy.artifact).Replace('\','/'))) { throw (New-TeamBobComplianceFailure 20 'Artifact does not match the policy phase artifact.') }
    $state=Read-TeamBobComplianceJson $context.StatePath 'Phase state'
    $prerequisite=Assert-TeamBobPhaseState $state $context $governance $Phase
    $now=[datetimeoffset]::UtcNow
    $expires=ConvertFrom-TeamBobGovernanceUtcInstant $ExpiresAtUtc
    $roleUntil=ConvertFrom-TeamBobGovernanceUtcInstant $assignments[$role].validUntilUtc
    if ($null -eq $expires -or $expires -le $now -or $expires -gt $now.AddHours([int]$governance.Policy.maxApprovalValidityHours) -or $expires -gt $roleUntil) { throw (New-TeamBobComplianceFailure 20 'Approval expiry must be future UTC, at most 168 hours, and no later than role expiry.') }
    if (@($EvidencePath).Count -eq 0) { throw (New-TeamBobComplianceFailure 20 'At least one evidence path is required.') }
    $evidence=@(); $seen=New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($path in @($EvidencePath)) {
        $item=Get-TeamBobGovernedRelativeFile $context $path 'Approval evidence'
        if (-not $seen.Add($item.FullPath)) { throw (New-TeamBobComplianceFailure 20 'Approval evidence paths must be unique.') }
        $evidence += [ordered]@{path=$item.RelativePath;sha256=$item.Hash}
    }
    $approvalId='APPROVAL-'+$now.ToString('yyyyMMddTHHmmssfffffffZ')+'-'+[guid]::NewGuid().ToString('N').ToUpperInvariant()
    $record=[ordered]@{
        schemaVersion='1.0';profileVersion='0.2.0-poc';policyVersion='0.2.0-poc';approvalId=$approvalId;decision='APPROVED';taskId=$context.TaskId;phase=$Phase
        assignmentId=[string]$assignments[$role].assignmentId;role=$role;principalId=[string]$assignments[$role].principalId;approvedAtUtc=$now.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ');expiresAtUtc=$expires.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')
        workPacketPath=$context.PacketPath;workPacketSha256=$context.PacketHash;policyBundleSha256=$governance.PolicyHash;roleLedgerSha256=$governance.RoleHash;artifactPath=$artifact.RelativePath;artifactSha256=$artifact.Hash
        prerequisiteResultPath=$(if($null -eq $prerequisite){$null}else{$prerequisite.Path});prerequisiteResultSha256=$(if($null -eq $prerequisite){$null}else{$prerequisite.Hash});evidence=@($evidence)
    }
    $approvalDirectory=Join-Path $context.TaskRoot 'approvals'
    $recordPath=Join-Path $approvalDirectory (('approval-'+$Phase+'-'+$now.ToString('yyyyMMddTHHmmssfffffffZ')+'-'+[guid]::NewGuid().ToString('N')+'.json'))
    Write-TeamBobCreateOnlyJson $recordPath $record
    [Console]::Out.WriteLine("CREATED $recordPath")
    exit 0
} catch {
    $code=20
    if ($null -ne $_.Exception.Data['NativeExitCode'] -and [int]$_.Exception.Data['NativeExitCode'] -in @(20,30)) { $code=[int]$_.Exception.Data['NativeExitCode'] }
    elseif ($_.Exception.Data['TeamBobStatus'] -eq 'INTEGRITY_FAILED') { $code=30 }
    [Console]::Error.WriteLine($_.Exception.Message)
    exit $code
}
