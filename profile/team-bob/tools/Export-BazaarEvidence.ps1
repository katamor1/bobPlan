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
    $environment = Get-TeamBobLocalEnvironment $manifestPath $workSchemaPath $buildSchemaPath

    $preSource = @(Get-TeamBobInventory $context.BazaarRoot @('.bzr', 'team-bob-work'))
    $preBzr = @(Get-TeamBobInventory (Join-Path $context.BazaarRoot '.bzr'))
    $queries = @(
        [pscustomobject]@{ Name = 'status'; Arguments = @('status', '--short'); File = 'bazaar-status.txt' },
        [pscustomobject]@{ Name = 'diff'; Arguments = @('diff'); File = 'bazaar-diff.patch' },
        [pscustomobject]@{ Name = 'nick'; Arguments = @('nick'); File = 'bazaar-nick.txt' },
        [pscustomobject]@{ Name = 'revision'; Arguments = @('version-info', '--custom', '--template={revision_id}'); File = 'bazaar-revision-id.txt' }
    )
    $outputs = @{}
    $commandRecords = @()
    foreach ($query in $queries) {
        try { $queryResult = Invoke-TeamBobBazaarQuery $environment.bazaarPath $context.BazaarRoot $query.Arguments } catch {
            if ($null -ne $_.Exception.Data['NativeExitCode'] -and [int]$_.Exception.Data['NativeExitCode'] -gt 0) { $nativeExitCode = [int]$_.Exception.Data['NativeExitCode'] }
            throw
        }
        $outputs[$query.Name] = $queryResult.Output
        $commandRecords += [pscustomobject]@{ command = ($query.Arguments -join ' '); exitCode = $queryResult.ExitCode }
    }
    if ([string]::IsNullOrWhiteSpace([string]$outputs['nick']) -or [string]::IsNullOrWhiteSpace([string]$outputs['revision'])) { throw (New-TeamBobFailure 'ENVIRONMENT_FAILED' 'Bazaar nick or full revision id evidence is empty.') }
    $postSource = @(Get-TeamBobInventory $context.BazaarRoot @('.bzr', 'team-bob-work'))
    $postBzr = @(Get-TeamBobInventory (Join-Path $context.BazaarRoot '.bzr'))
    if (($preSource -join "`n") -cne ($postSource -join "`n") -or ($preBzr -join "`n") -cne ($postBzr -join "`n")) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Bazaar evidence queries changed source or .bzr state.') }

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
    if ($nativeExitCode -lt 1 -or $nativeExitCode -gt 255) { $nativeExitCode = 1 }
    exit $nativeExitCode
}
