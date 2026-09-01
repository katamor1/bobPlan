[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$MsdevPath,
    [Parameter(Mandatory = $true)][string]$BazaarPath,
    [Parameter(Mandatory = $true)][string]$SandboxRoot,
    [Parameter(Mandatory = $true)][string]$LogRoot,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

function Get-TeamBobSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try { $stream = [System.IO.File]::OpenRead($Path); try { return ([BitConverter]::ToString($sha256.ComputeHash($stream)).Replace('-', '').ToLowerInvariant()) } finally { $stream.Dispose() } } finally { $sha256.Dispose() }
}

function Test-TeamBobAbsolutePath {
    param([string]$Path)
    return $Path -match '^(?:[A-Za-z]:[\\/]|\\\\[^\\/]+[\\/][^\\/]+)'
}

function Get-TeamBobCanonicalPath {
    param([string]$Path)
    return [System.IO.Path]::GetFullPath($Path)
}

function Test-TeamBobPathAtOrBelow {
    param([string]$Candidate, [string]$Root)
    $candidateFull = Get-TeamBobCanonicalPath $Candidate
    $rootFull = Get-TeamBobCanonicalPath $Root
    if ($candidateFull.Equals($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    $rootPrefix = $rootFull.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    return $candidateFull.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)
}

try {
    foreach ($entry in @(
        @{ Name = 'MsdevPath'; Value = $MsdevPath }, @{ Name = 'BazaarPath'; Value = $BazaarPath },
        @{ Name = 'SandboxRoot'; Value = $SandboxRoot }, @{ Name = 'LogRoot'; Value = $LogRoot }
    )) {
        if (-not (Test-TeamBobAbsolutePath $entry.Value)) { throw "$($entry.Name) must be an absolute path." }
    }
    if (-not (Test-Path -LiteralPath $MsdevPath -PathType Leaf)) { throw "MsdevPath must name an existing file: $MsdevPath" }
    if (-not (Test-Path -LiteralPath $BazaarPath -PathType Leaf)) { throw "BazaarPath must name an existing file: $BazaarPath" }
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA) -or -not (Test-TeamBobAbsolutePath $env:LOCALAPPDATA)) { throw 'LOCALAPPDATA must be an absolute path.' }

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
    foreach ($required in @($manifestPath, $workSchemaPath, $buildSchemaPath)) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Required profile identity file is missing: $required" }
    }
    $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
    $workSchema = Get-Content -Raw -LiteralPath $workSchemaPath | ConvertFrom-Json
    $buildSchema = Get-Content -Raw -LiteralPath $buildSchemaPath | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace($manifest.profile.id) -or [string]::IsNullOrWhiteSpace($manifest.version)) { throw 'Profile manifest identity is incomplete.' }
    if ([string]::IsNullOrWhiteSpace($workSchema.'$id') -or [string]::IsNullOrWhiteSpace($buildSchema.'$id')) { throw 'Profile schema identity is incomplete.' }

    $registration = [ordered]@{
        schemaVersion = '1.0'
        profileId = [string]$manifest.profile.id
        profileVersion = [string]$manifest.version
        pcId = [Environment]::MachineName
        workPacketSchemaId = [string]$workSchema.'$id'
        buildTargetSchemaId = [string]$buildSchema.'$id'
        msdevPath = Get-TeamBobCanonicalPath $MsdevPath
        msdevSha256 = Get-TeamBobSha256 $MsdevPath
        bazaarPath = Get-TeamBobCanonicalPath $BazaarPath
        bazaarSha256 = Get-TeamBobSha256 $BazaarPath
        sandboxRoot = Get-TeamBobCanonicalPath $SandboxRoot
        logRoot = Get-TeamBobCanonicalPath $LogRoot
    }
    if (Test-TeamBobPathAtOrBelow $registration.sandboxRoot $repositoryRoot) { throw 'SandboxRoot must be outside the repository root.' }
    if (Test-TeamBobPathAtOrBelow $registration.logRoot $repositoryRoot) { throw 'LogRoot must be outside the repository root.' }
    if ((Test-TeamBobPathAtOrBelow $registration.sandboxRoot $registration.logRoot) -or
        (Test-TeamBobPathAtOrBelow $registration.logRoot $registration.sandboxRoot)) {
        throw 'SandboxRoot and LogRoot must be separate and must not contain each other.'
    }
    $json = ($registration | ConvertTo-Json -Depth 5) + [Environment]::NewLine
    $environmentPath = Join-Path $env:LOCALAPPDATA 'IBM/BobTeamProfile/vc6-machine-control-poc/environment.json'

    if (Test-Path -LiteralPath $environmentPath -PathType Container) { throw "Environment registration path is an existing directory: $environmentPath" }
    $identicalRegistration = $false
    if (Test-Path -LiteralPath $environmentPath -PathType Leaf) {
        $existing = [System.IO.File]::ReadAllText($environmentPath)
        if ($existing -eq $json) {
            $identicalRegistration = $true
        } elseif (-not $Force) { throw 'A different local environment registration already exists; use -Force to replace it.' }
    }

    foreach ($directory in @($registration.sandboxRoot, $registration.logRoot, (Split-Path -Parent $environmentPath))) {
        if (Test-Path -LiteralPath $directory -PathType Leaf) { throw "Required directory path is an existing file: $directory" }
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    }
    if ($identicalRegistration) {
        Write-Output "IDENTICAL $environmentPath"
        exit 0
    }

    $temporaryPath = Join-Path (Split-Path -Parent $environmentPath) ('.environment.' + [guid]::NewGuid().ToString('N') + '.tmp')
    $backupPath = Join-Path (Split-Path -Parent $environmentPath) ('.environment.' + [guid]::NewGuid().ToString('N') + '.bak')
    try {
        [System.IO.File]::WriteAllText($temporaryPath, $json, (New-Object System.Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $environmentPath -PathType Leaf) {
            [System.IO.File]::Replace($temporaryPath, $environmentPath, $backupPath)
        } else {
            [System.IO.File]::Move($temporaryPath, $environmentPath)
        }
    } finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) { Remove-Item -LiteralPath $temporaryPath -Force }
        if (Test-Path -LiteralPath $backupPath -PathType Leaf) { Remove-Item -LiteralPath $backupPath -Force }
    }
    Write-Output "WROTE $environmentPath"
    exit 0
} catch {
    Write-Error $_.Exception.Message
    exit 1
}
