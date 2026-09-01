[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$WorkPacket)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TeamBob-BuildCommon.ps1')

$nativeExitCode = 1
try {
    $workPacketFull = Get-TeamBobCanonicalPath $WorkPacket
    $packet = Read-TeamBobCanonicalPacket $workPacketFull
    $context = Get-TeamBobPacketContext $packet $workPacketFull
    $profileRoot = Split-Path -Parent $PSScriptRoot
    $manifestPath = Join-Path $profileRoot 'profile-manifest.json'
    $workSchemaPath = Join-Path $profileRoot 'config/work-packet.schema.json'
    $buildSchemaPath = Join-Path $profileRoot 'config/vc6-build-targets.schema.json'
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

    $resultDirectory = Join-Path (Split-Path -Parent $workPacketFull) 'results'
    if (Test-Path -LiteralPath $resultDirectory -PathType Leaf) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Task results path is an existing file.') }
    if (-not (Test-Path -LiteralPath $resultDirectory -PathType Container)) { [System.IO.Directory]::CreateDirectory($resultDirectory) | Out-Null }
    foreach ($query in $queries) { Write-TeamBobUtf8File (Join-Path $resultDirectory $query.File) ([string]$outputs[$query.Name]) }
    $manifest = [ordered]@{
        schemaVersion = '1.0'; taskId = $context.TaskId; bazaarRoot = $context.BazaarRoot; bazaarPath = $environment.bazaarPath
        bazaarSha256 = Get-TeamBobFileHash $environment.bazaarPath; branchNick = (Get-TeamBobNormalizedProcessText ([string]$outputs['nick']))
        revisionId = (Get-TeamBobNormalizedProcessText ([string]$outputs['revision'])); commands = @($queries | ForEach-Object { $_.Arguments -join ' ' })
        commandResults = @($commandRecords); files = @($queries.File); exportedAt = [DateTimeOffset]::UtcNow.ToString('o')
    }
    $manifestPath = Join-Path $resultDirectory 'bazaar-evidence-manifest.json'
    Write-TeamBobUtf8File $manifestPath (($manifest | ConvertTo-Json -Depth 10) + [Environment]::NewLine)
    Write-Output "EXPORTED $manifestPath"
    exit 0
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    if ($null -ne $_.Exception.Data['TeamBobStatus'] -and [string]$_.Exception.Data['TeamBobStatus'] -eq 'INTEGRITY_FAILED') { $nativeExitCode = 30 }
    if ($null -ne $_.Exception.Data['NativeExitCode'] -and [int]$_.Exception.Data['NativeExitCode'] -gt 0) { $nativeExitCode = [int]$_.Exception.Data['NativeExitCode'] }
    if ($nativeExitCode -lt 1 -or $nativeExitCode -gt 255) { $nativeExitCode = 1 }
    exit $nativeExitCode
}
