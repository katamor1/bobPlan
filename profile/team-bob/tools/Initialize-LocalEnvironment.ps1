[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$MsdevPath,
    [Parameter(Mandatory = $true)][string]$BazaarPath,
    [Parameter(Mandatory = $true)][string]$SandboxRoot,
    [Parameter(Mandatory = $true)][string]$LogRoot,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TeamBob-BuildCommon.ps1')
. (Join-Path $PSScriptRoot 'TeamBob-GovernanceCommon.ps1')

try {
    foreach ($entry in @(
        @{ Name = 'MsdevPath'; Value = $MsdevPath }, @{ Name = 'BazaarPath'; Value = $BazaarPath },
        @{ Name = 'SandboxRoot'; Value = $SandboxRoot }, @{ Name = 'LogRoot'; Value = $LogRoot }
    )) { if (-not (Test-TeamBobAbsolutePath $entry.Value)) { throw "$($entry.Name) must be an absolute local drive path." } }
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA) -or -not (Test-TeamBobAbsolutePath $env:LOCALAPPDATA)) { throw 'LOCALAPPDATA must be an absolute path.' }

    $msdevFull = Get-TeamBobCanonicalPath $MsdevPath 'MsdevPath' 'ENVIRONMENT_FAILED'
    $bazaarFull = Get-TeamBobCanonicalPath $BazaarPath 'BazaarPath' 'ENVIRONMENT_FAILED'
    [void](Get-TeamBobPhysicalPath $msdevFull 'MsdevPath' 'Leaf' 'ENVIRONMENT_FAILED')
    [void](Get-TeamBobPhysicalPath $bazaarFull 'BazaarPath' 'Leaf' 'ENVIRONMENT_FAILED')

    $profileRoot = Split-Path -Parent $PSScriptRoot
    $installationRoot = Split-Path -Parent $profileRoot
    $repositoryRoot = $installationRoot
    $sourceRepositoryCandidate = Split-Path -Parent $installationRoot
    $sourceInstaller = Join-Path $sourceRepositoryCandidate 'scripts/Install-TeamBobProfile.ps1'
    $sourceProfile = Join-Path $sourceRepositoryCandidate 'profile/team-bob/profile-manifest.json'
    if ((Split-Path -Leaf $installationRoot) -eq 'profile' -and
        (Test-Path -LiteralPath $sourceInstaller -PathType Leaf) -and
        (Test-Path -LiteralPath $sourceProfile -PathType Leaf)) {
        $repositoryRoot = $sourceRepositoryCandidate
    }
    $manifestPath = Join-Path $profileRoot 'profile-manifest.json'
    $workSchemaPath = Join-Path $profileRoot 'config/work-packet.schema.json'
    $buildSchemaPath = Join-Path $profileRoot 'config/vc6-build-targets.schema.json'
    $governanceRoot = Join-Path (Split-Path -Parent $profileRoot) '.bob\governance'
    $policyPath = Join-Path $governanceRoot 'policy-manifest.json'
    $policySchemaPath = Join-Path $governanceRoot 'schemas\policy-manifest.schema.json'
    foreach ($required in @($manifestPath, $workSchemaPath, $buildSchemaPath, $policyPath, $policySchemaPath)) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Required profile identity file is missing: $required" }
        [void](Get-TeamBobPhysicalPath $required 'Required profile identity file' 'Leaf' 'ENVIRONMENT_FAILED')
    }
    $manifest = Read-TeamBobJsonFile $manifestPath 'Profile manifest' 'ENVIRONMENT_FAILED'
    $workSchema = Read-TeamBobJsonFile $workSchemaPath 'Work-packet schema' 'ENVIRONMENT_FAILED'
    $buildSchema = Read-TeamBobJsonFile $buildSchemaPath 'Build-target schema' 'ENVIRONMENT_FAILED'
    $governanceErrors = @(Test-TeamBobGovernancePackage -GovernanceRoot $governanceRoot)
    if ($governanceErrors.Count -gt 0) { throw ('Installed governance package is invalid: ' + ($governanceErrors -join '; ')) }
    $policy = Read-TeamBobJsonFile $policyPath 'Policy manifest' 'ENVIRONMENT_FAILED'
    $policySchema = Read-TeamBobJsonFile $policySchemaPath 'Policy-manifest schema' 'ENVIRONMENT_FAILED'
    if ([string]::IsNullOrWhiteSpace($manifest.profile.id) -or [string]::IsNullOrWhiteSpace($manifest.version)) { throw 'Profile manifest identity is incomplete.' }
    if ([string]::IsNullOrWhiteSpace($workSchema.'$id') -or [string]::IsNullOrWhiteSpace($buildSchema.'$id')) { throw 'Profile schema identity is incomplete.' }

    $registration = [ordered]@{
        schemaVersion = '1.0'
        profileId = [string]$manifest.profile.id
        profileVersion = [string]$manifest.version
        policyVersion = [string]$policy.policyVersion
        policyBundleSha256 = Get-TeamBobPolicyBundleHash $governanceRoot
        policyManifestSchemaId = [string]$policySchema.'$id'
        pcId = [Environment]::MachineName
        workPacketSchemaId = [string]$workSchema.'$id'
        buildTargetSchemaId = [string]$buildSchema.'$id'
        msdevPath = $msdevFull
        msdevSha256 = Get-TeamBobFileHash $msdevFull
        bazaarPath = $bazaarFull
        bazaarSha256 = Get-TeamBobFileHash $bazaarFull
        sandboxRoot = Get-TeamBobCanonicalPath $SandboxRoot 'SandboxRoot' 'ENVIRONMENT_FAILED'
        logRoot = Get-TeamBobCanonicalPath $LogRoot 'LogRoot' 'ENVIRONMENT_FAILED'
    }
    $repositoryFull = Get-TeamBobCanonicalPath $repositoryRoot 'Repository root' 'ENVIRONMENT_FAILED'
    Assert-TeamBobNotVolumeRoot $repositoryFull 'Repository root' 'ENVIRONMENT_FAILED'
    $repositoryPhysical = Get-TeamBobPhysicalPath $repositoryFull 'Repository root' 'Container' 'ENVIRONMENT_FAILED'
    $sandboxInfo = Get-TeamBobProspectiveDirectory $registration.sandboxRoot 'SandboxRoot' 'ENVIRONMENT_FAILED' -RejectVolumeRoot
    $logInfo = Get-TeamBobProspectiveDirectory $registration.logRoot 'LogRoot' 'ENVIRONMENT_FAILED' -RejectVolumeRoot
    Assert-TeamBobPhysicalSeparation $sandboxInfo.PhysicalPath $repositoryPhysical 'SandboxRoot and repository root' 'ENVIRONMENT_FAILED'
    Assert-TeamBobPhysicalSeparation $logInfo.PhysicalPath $repositoryPhysical 'LogRoot and repository root' 'ENVIRONMENT_FAILED'
    Assert-TeamBobPhysicalSeparation $sandboxInfo.PhysicalPath $logInfo.PhysicalPath 'SandboxRoot and LogRoot' 'ENVIRONMENT_FAILED'
    $json = ($registration | ConvertTo-Json -Depth 5) + [Environment]::NewLine
    $environmentParent = Join-Path (Get-TeamBobCanonicalPath $env:LOCALAPPDATA 'LOCALAPPDATA' 'ENVIRONMENT_FAILED') 'IBM/BobTeamProfile/vc6-machine-control-poc/v0.2.0-poc'
    $environmentParentInfo = Get-TeamBobProspectiveDirectory $environmentParent 'Environment registration parent' 'ENVIRONMENT_FAILED' -RejectVolumeRoot
    $environmentPath = Join-Path $environmentParentInfo.FullPath 'environment.json'

    if (Test-Path -LiteralPath $environmentPath -PathType Container) { throw "Environment registration path is an existing directory: $environmentPath" }
    $identicalRegistration = $false
    if (Test-Path -LiteralPath $environmentPath -PathType Leaf) {
        [void](Get-TeamBobPhysicalPath $environmentPath 'Environment registration' 'Leaf' 'ENVIRONMENT_FAILED')
        $existing = Read-TeamBobUtf8File $environmentPath 'Environment registration' 'ENVIRONMENT_FAILED'
        if ($existing -eq $json) {
            $identicalRegistration = $true
        } elseif (-not $Force) { throw 'A different local environment registration already exists; use -Force to replace it.' }
    }

    $sandboxCreated = Get-TeamBobProspectiveDirectory $registration.sandboxRoot 'SandboxRoot' 'ENVIRONMENT_FAILED' -RejectVolumeRoot -Create
    $logCreated = Get-TeamBobProspectiveDirectory $registration.logRoot 'LogRoot' 'ENVIRONMENT_FAILED' -RejectVolumeRoot -Create
    $environmentParentCreated = Get-TeamBobProspectiveDirectory $environmentParentInfo.FullPath 'Environment registration parent' 'ENVIRONMENT_FAILED' -RejectVolumeRoot -Create
    Assert-TeamBobPhysicalSeparation $sandboxCreated.PhysicalPath $repositoryPhysical 'SandboxRoot and repository root' 'ENVIRONMENT_FAILED'
    Assert-TeamBobPhysicalSeparation $logCreated.PhysicalPath $repositoryPhysical 'LogRoot and repository root' 'ENVIRONMENT_FAILED'
    Assert-TeamBobPhysicalSeparation $sandboxCreated.PhysicalPath $logCreated.PhysicalPath 'SandboxRoot and LogRoot' 'ENVIRONMENT_FAILED'
    if ($identicalRegistration) {
        Write-Output "IDENTICAL $environmentPath"
        exit 0
    }
    Write-TeamBobUtf8File $environmentPath $json
    Write-Output "WROTE $environmentPath"
    exit 0
} catch {
    Write-Error $_.Exception.Message
    exit 1
}
