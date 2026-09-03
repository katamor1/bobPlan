[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$WorkPacket)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TeamBob-BuildCommon.ps1')
. (Join-Path $PSScriptRoot 'TeamBob-GovernanceCommon.ps1')
. (Join-Path $PSScriptRoot 'TeamBob-ComplianceCommon.ps1')

$nativeExitCode = 1
try {
    $workPacketFull = Get-TeamBobCanonicalPath $WorkPacket 'Work packet' 'INTEGRITY_FAILED'
    if (-not (Test-Path -LiteralPath $workPacketFull -PathType Leaf)) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' "Work packet does not exist: $workPacketFull") }
    [void](Get-TeamBobPhysicalPath $workPacketFull 'Work packet' 'Leaf' 'INTEGRITY_FAILED')
    $packet = Read-TeamBobCanonicalPacket $workPacketFull
    $executionGate = Get-TeamBobImplementationExecutionGate $PSScriptRoot $workPacketFull $packet
    $context = $executionGate.Context
    $profileRoot = Split-Path -Parent $PSScriptRoot
    $manifestPath = Join-Path $profileRoot 'profile-manifest.json'
    $workSchemaPath = Join-Path $profileRoot 'config/work-packet.schema.json'
    $buildSchemaPath = Join-Path $profileRoot 'config/vc6-build-targets.schema.json'
    foreach ($path in @($manifestPath, $workSchemaPath, $buildSchemaPath)) { [void](Get-TeamBobPhysicalPath $path 'Installed profile contract' 'Leaf' 'ENVIRONMENT_FAILED') }
    $environment = Get-TeamBobLocalEnvironment $manifestPath $workSchemaPath $buildSchemaPath -BazaarOnly

    $baseline = Get-TeamBobProtectedSnapshot $context
    $queries = @(
        [pscustomobject]@{ Name = 'status'; Arguments = @('status', '--short'); AllowedExitCodes = @(0); File = 'bazaar-status.txt' },
        [pscustomobject]@{ Name = 'diff'; Arguments = @('diff'); AllowedExitCodes = @(0, 1); File = 'bazaar-diff.patch' },
        [pscustomobject]@{ Name = 'nick'; Arguments = @('nick'); AllowedExitCodes = @(0); File = 'bazaar-nick.txt' },
        [pscustomobject]@{ Name = 'revision'; Arguments = @('version-info', '--custom', '--template={revision_id}'); AllowedExitCodes = @(0); File = 'bazaar-revision-id.txt' }
    )
    $outputs = @{}
    $commandRecords = @()
    $operationFailure = $null
    $integrityFailure = $null
    try {
        foreach ($query in $queries) {
            try { $queryResult = Invoke-TeamBobBazaarQuery $environment.bazaarPath $context.BazaarRoot $query.Arguments $query.AllowedExitCodes } catch {
                if ($null -ne $_.Exception.Data['NativeExitCode'] -and [int]$_.Exception.Data['NativeExitCode'] -gt 0) { $nativeExitCode = [int]$_.Exception.Data['NativeExitCode'] }
                $operationFailure = $_.Exception
                break
            }
            $outputs[$query.Name] = $queryResult.Output
            $commandRecords += [pscustomobject]@{ command = ($query.Arguments -join ' '); exitCode = $queryResult.ExitCode }
            if ($query.Name -eq 'status') {
                Assert-TeamBobBazaarStatus (Get-TeamBobNormalizedProcessText ([string]$queryResult.Output)) $context.AllowedFiles
            }
        }
        if ($null -eq $operationFailure) {
            $nick = Get-TeamBobNormalizedProcessText ([string]$outputs['nick'])
            $revision = Get-TeamBobNormalizedProcessText ([string]$outputs['revision'])
            if ([string]::IsNullOrWhiteSpace($nick) -or [string]::IsNullOrWhiteSpace($revision)) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Bazaar nick or full revision id evidence is empty.') }
            if (-not $nick.Equals($context.BazaarBranch, [System.StringComparison]::Ordinal) -or -not $revision.Equals($context.BazaarRevision, [System.StringComparison]::Ordinal)) {
                throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Current Bazaar branch nick or full revision id does not match the Work Packet baseline.')
            }
        }
    } catch {
        $operationFailure = $_.Exception
    } finally {
        try { Assert-TeamBobProtectedSnapshot $baseline (Get-TeamBobProtectedSnapshot $context) 'Bazaar evidence queries' } catch { $integrityFailure = $_.Exception }
    }
    if ($null -ne $integrityFailure) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' ("Evidence postflight integrity proof failed: " + $integrityFailure.Message) 30) }
    if ($null -ne $operationFailure) { throw $operationFailure }

    try {
        $postExecutionGate=Get-TeamBobImplementationExecutionGate $PSScriptRoot $workPacketFull $packet
        Assert-TeamBobExecutionGateUnchanged $executionGate $postExecutionGate
    } catch {
        throw (New-TeamBobFailure 'INTEGRITY_FAILED' ("Evidence governance postflight proof failed: " + $_.Exception.Message) 30)
    }
    $resultsInfo = Get-TeamBobTaskResultsContext $context -Create

    $resultDirectory = $resultsInfo.FullPath
    foreach ($query in $queries) { Write-TeamBobUtf8File (Join-Path $resultDirectory $query.File) ([string]$outputs[$query.Name]) $context.TaskPhysical }
    $manifest = [ordered]@{
        schemaVersion = '1.0'; taskId = $context.TaskId; bazaarRoot = $context.BazaarRoot; bazaarPath = $environment.bazaarPath
        bazaarSha256 = Get-TeamBobFileHash $environment.bazaarPath; branchNick = (Get-TeamBobNormalizedProcessText ([string]$outputs['nick']))
        revisionId = (Get-TeamBobNormalizedProcessText ([string]$outputs['revision'])); commands = @($queries | ForEach-Object { $_.Arguments -join ' ' })
        commandResults = @($commandRecords); files = @($queries.File); exportedAt = [DateTimeOffset]::UtcNow.ToString('o')
        workPacketPath=$executionGate.WorkPacketPath;workPacketSha256=$executionGate.WorkPacketSha256;policyVersion=$executionGate.PolicyVersion
        policyBundleSha256=$executionGate.PolicyBundleSha256;roleLedgerSha256=$executionGate.RoleLedgerSha256
        phaseStatePath=$executionGate.PhaseStatePath;phaseStateSha256=$executionGate.PhaseStateSha256;phaseStateSemanticSha256=$executionGate.PhaseStateSemanticSha256
        prerequisiteImpactResultPath=$executionGate.ImpactResultPath;prerequisiteImpactResultSha256=$executionGate.ImpactResultSha256
        implementationApprovalPath=$executionGate.ImplementationApprovalPath;implementationApprovalSha256=$executionGate.ImplementationApprovalSha256;finalIntegrityVerified=$true
    }
    $manifestPath = Join-Path $resultDirectory 'bazaar-evidence-manifest.json'
    Write-TeamBobUtf8File $manifestPath (($manifest | ConvertTo-Json -Depth 10) + [Environment]::NewLine) $context.TaskPhysical
    Assert-TeamBobProtectedSnapshot $baseline (Get-TeamBobProtectedSnapshot $context) 'Bazaar evidence publication'
    Write-Output "EXPORTED $manifestPath"
    exit 0
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    if ($null -ne $_.Exception.Data['TeamBobStatus'] -and [string]$_.Exception.Data['TeamBobStatus'] -eq 'INTEGRITY_FAILED') { $nativeExitCode = 30 }
    if ($_.Exception.Data['TeamBobStatus'] -eq 'GATE_FAILED') { $nativeExitCode = 10 }
    if ($_.Exception.Data['TeamBobStatus'] -eq 'GATE_UNRESOLVED') { $nativeExitCode = 11 }
    if ($_.Exception.Data['TeamBobStatus'] -in @('PACKET_VERSION_UNSUPPORTED','PACKET_SCHEMA_INVALID','CONTRACT_INVALID')) { $nativeExitCode = 20 }
    if ($null -ne $_.Exception.Data['NativeExitCode'] -and [int]$_.Exception.Data['NativeExitCode'] -gt 0) { $nativeExitCode = [int]$_.Exception.Data['NativeExitCode'] }
    if ($nativeExitCode -lt 1 -or $nativeExitCode -gt 255) { $nativeExitCode = 1 }
    exit $nativeExitCode
}
