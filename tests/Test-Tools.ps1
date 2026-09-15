$ErrorActionPreference = 'Stop'
Import-Module Microsoft.PowerShell.Utility -ErrorAction Stop

if ($null -eq (Get-Command Assert-True -ErrorAction SilentlyContinue)) {
    $script:Assertions = 0
    function Assert-True { param([bool]$Condition, [string]$Message); $script:Assertions++; if (-not $Condition) { throw "ASSERTION FAILED: $Message" } }
    function Assert-Equal { param([object]$Actual, [object]$Expected, [string]$Message); Assert-True ($Actual -eq $Expected) "$Message (expected '$Expected', got '$Actual')" }
}

function Get-FileHash {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('SHA256')][string]$Algorithm,
        [Parameter(Mandatory = $true)][string]$LiteralPath
    )

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $stream = [System.IO.File]::OpenRead($LiteralPath)
        try {
            $hash = $sha256.ComputeHash($stream)
        } finally {
            $stream.Dispose()
        }
    } finally {
        $sha256.Dispose()
    }
    return [pscustomobject]@{ Hash = ([BitConverter]::ToString($hash).Replace('-', '')) }
}

function Invoke-TestScript {
    param([string]$Path, [string[]]$Arguments = @())
    $powerShell = (Get-Process -Id $PID).Path
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $powerShell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Path @Arguments 2>&1 | Out-String
    } finally {
        $ErrorActionPreference = $savedPreference
    }
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
}

function Write-Utf8NoBomFixture {
    param([string]$Path, [string]$Text)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-CanonicalPacketFixture {
    param([string]$Path)
    $text = [System.IO.File]::ReadAllText($Path)
    $match = [regex]::Match($text, '(?s)<!-- canonical-work-packet-json:start -->\s*```json\s*(?<json>\{.*?\})\s*```\s*<!-- canonical-work-packet-json:end -->')
    Assert-True $match.Success 'Created task has a canonical work-packet JSON block'
    return ($match.Groups['json'].Value | ConvertFrom-Json)
}

function Get-TreeFingerprintFixture {
    param([string]$Root)
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    return ((Get-ChildItem -LiteralPath $rootFull -File -Force -Recurse | Sort-Object FullName | ForEach-Object {
        $relative = $_.FullName.Substring($rootFull.Length).TrimStart('\', '/')
        $relative + ':' + (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash
    }) -join "`n")
}

function Write-JsonFixture {
    param([string]$Path, [object]$Value)
    Write-Utf8NoBomFixture $Path (($Value | ConvertTo-Json -Depth 20) + [Environment]::NewLine)
}

$toolsRepoRoot = Split-Path -Parent $PSScriptRoot
$installerPath = Join-Path $toolsRepoRoot 'scripts/Install-TeamBobProfile.ps1'
$toolsProfileRoot = Join-Path $toolsRepoRoot 'profile'
$toolsRoot = Join-Path $toolsProfileRoot 'team-bob/tools'
$initializePath = Join-Path $toolsRoot 'Initialize-LocalEnvironment.ps1'
$startTaskPath = Join-Path $toolsRoot 'Start-TeamBobTask.ps1'
$validatorPath = Join-Path $toolsRoot 'Test-TeamBobProfile.ps1'

$fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('team-bob-task2-' + [guid]::NewGuid().ToString('N'))
$originalLocalAppData = $env:LOCALAPPDATA
$originalStatus = $env:BOB_TEST_BZR_STATUS
$originalBzrLog = $env:BOB_TEST_BZR_LOG

try {
    New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
    $env:LOCALAPPDATA = Join-Path $fixtureRoot 'ローカル-日本'

    # Installer: WhatIf is a complete preflight and never writes.
    $installTarget = Join-Path $fixtureRoot 'installed-profile'
    $whatIfResult = Invoke-TestScript $installerPath @('-TargetPath', $installTarget, '-WhatIf')
    Assert-Equal $whatIfResult.ExitCode 0 'Installer WhatIf succeeds for a new absolute target'
    Assert-True ($whatIfResult.Output -match 'CREATE') 'Installer WhatIf reports planned creates'
    Assert-True (-not (Test-Path -LiteralPath $installTarget)) 'Installer WhatIf creates no target directory'

    New-Item -ItemType Directory -Path $installTarget | Out-Null
    Write-Utf8NoBomFixture (Join-Path $installTarget 'profile/unrelated.txt') 'unrelated-profile-directory'
    $targetBzr = Join-Path $installTarget '.bzr'
    New-Item -ItemType Directory -Path $targetBzr | Out-Null
    $targetBzrMarker = Join-Path $targetBzr 'branch.conf'
    Write-Utf8NoBomFixture $targetBzrMarker 'fixture-bzr-metadata'
    $sourceBzrExisted = Test-Path -LiteralPath (Join-Path $toolsProfileRoot '.bzr')

    $installResult = Invoke-TestScript $installerPath @('-TargetPath', $installTarget)
    Assert-Equal $installResult.ExitCode 0 'Installer copies the profile into an existing target'
    Assert-True (Test-Path -LiteralPath (Join-Path $installTarget '.bob/custom_modes.yaml')) 'Installer copies hidden Bob profile files'
    Assert-True (Test-Path -LiteralPath (Join-Path $installTarget '.bobignore.base')) 'Installer copies the Bob ignore snippet by its snippet name'
    Assert-True (Test-Path -LiteralPath (Join-Path $installTarget '.bzrignore.snippet')) 'Installer copies the Bazaar ignore snippet by its snippet name'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $installTarget '.bobignore'))) 'Installer does not merge or create .bobignore'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $installTarget '.bzrignore'))) 'Installer does not merge or create .bzrignore'
    Assert-Equal ([System.IO.File]::ReadAllText($targetBzrMarker)) 'fixture-bzr-metadata' 'Installer leaves target .bzr metadata unchanged'
    Assert-Equal ([System.IO.File]::ReadAllText((Join-Path $installTarget 'profile/unrelated.txt'))) 'unrelated-profile-directory' 'Installer accepts an ordinary target containing an unrelated profile directory'

    $rerunResult = Invoke-TestScript $installerPath @('-TargetPath', $installTarget)
    Assert-Equal $rerunResult.ExitCode 0 'Installer identical rerun is idempotent'
    Assert-True ($rerunResult.Output -match 'IDENTICAL') 'Installer reports identical files on rerun'

    $legacyUpgradeTarget = Join-Path $fixtureRoot 'legacy-v01-target'
    New-Item -ItemType Directory -Path (Join-Path $legacyUpgradeTarget 'team-bob'), (Join-Path $legacyUpgradeTarget '.bzr') -Force | Out-Null
    Write-JsonFixture (Join-Path $legacyUpgradeTarget 'team-bob/profile-manifest.json') ([pscustomobject][ordered]@{
        version = '0.1.0-poc'
        profile = [pscustomobject][ordered]@{ id = 'team-bob-vc6-bazaar'; name = 'Team Bob VC6 Bazaar Profile' }
        compatibility = [pscustomobject][ordered]@{ operatingSystem = 'Windows'; ide = 'IBM Bob IDE 2.1.x'; toolchain = 'Visual C++ 6.0'; vcs = 'Bazaar' }
        contracts = [pscustomobject][ordered]@{ workPacketSchema = 'config/work-packet.schema.json'; buildTargetSchema = 'config/vc6-build-targets.schema.json'; buildTargets = 'config/vc6-build-targets.json'; modes = '../.bob/custom_modes.yaml'; rules = '../.bob/rules/' }
    })
    Write-Utf8NoBomFixture (Join-Path $legacyUpgradeTarget '.bzr/branch.conf') 'legacy-upgrade-bzr'
    Write-Utf8NoBomFixture (Join-Path $legacyUpgradeTarget 'untouched.txt') 'legacy-upgrade-target'
    $legacyUpgradeFingerprint = Get-TreeFingerprintFixture $legacyUpgradeTarget
    $legacyUpgradeSourceFingerprint = Get-TreeFingerprintFixture $toolsRepoRoot
    $legacyUpgradeRegistration = Join-Path $env:LOCALAPPDATA 'IBM/BobTeamProfile/vc6-machine-control-poc/environment.json'
    $v02UpgradeRegistration = Join-Path $env:LOCALAPPDATA 'IBM/BobTeamProfile/vc6-machine-control-poc/v0.2.0-poc/environment.json'
    Write-Utf8NoBomFixture $legacyUpgradeRegistration 'LEGACY-UPGRADE-REGISTRATION'
    Write-Utf8NoBomFixture $v02UpgradeRegistration 'V02-UPGRADE-REGISTRATION'
    foreach ($upgradeMode in @('WhatIf', 'Apply')) {
        $upgradeArguments = @('-TargetPath', $legacyUpgradeTarget)
        if ($upgradeMode -eq 'WhatIf') { $upgradeArguments += '-WhatIf' }
        $legacyUpgradeResult = Invoke-TestScript $installerPath $upgradeArguments
        Assert-True ($legacyUpgradeResult.ExitCode -ne 0) "Installer rejects an in-place v0.1 upgrade in $upgradeMode mode"
        Assert-True ($legacyUpgradeResult.Output -match 'UPGRADE_REQUIRES_FRESH_TARGET') "v0.1 $upgradeMode refusal emits the fixed migration token"
        Assert-Equal (Get-TreeFingerprintFixture $legacyUpgradeTarget) $legacyUpgradeFingerprint "v0.1 $upgradeMode refusal preserves target and .bzr bytes"
        Assert-Equal (Get-TreeFingerprintFixture $toolsRepoRoot) $legacyUpgradeSourceFingerprint "v0.1 $upgradeMode refusal preserves distribution source bytes"
        Assert-Equal ([System.IO.File]::ReadAllText($legacyUpgradeRegistration)) 'LEGACY-UPGRADE-REGISTRATION' "v0.1 $upgradeMode refusal preserves legacy registration"
        Assert-Equal ([System.IO.File]::ReadAllText($v02UpgradeRegistration)) 'V02-UPGRADE-REGISTRATION' "v0.1 $upgradeMode refusal preserves v0.2 registration"
    }
    foreach ($markerCase in @(
        [pscustomobject]@{ Name = 'spoofed'; Value = [pscustomobject][ordered]@{ version = '0.1.0-poc'; profile = [pscustomobject][ordered]@{ id = 'team-bob-vc6-bazaar' }; extra = 'spoof' } },
        [pscustomobject]@{ Name = 'unknown'; Value = [pscustomobject][ordered]@{ version = '9.9.9'; profile = [pscustomobject][ordered]@{ id = 'team-bob-vc6-bazaar' } } }
    )) {
        $markerTarget = Join-Path $fixtureRoot ('marker-' + $markerCase.Name)
        Write-JsonFixture (Join-Path $markerTarget 'team-bob/profile-manifest.json') $markerCase.Value
        $markerFingerprint = Get-TreeFingerprintFixture $markerTarget
        $markerResult = Invoke-TestScript $installerPath @('-TargetPath', $markerTarget, '-WhatIf')
        Assert-True ($markerResult.ExitCode -ne 0) "Installer rejects $($markerCase.Name) marker as a normal conflict"
        Assert-True ($markerResult.Output -match 'CONFLICT' -and $markerResult.Output -notmatch 'UPGRADE_REQUIRES_FRESH_TARGET') "Installer does not grant the v0.1 token to a $($markerCase.Name) marker"
        Assert-Equal (Get-TreeFingerprintFixture $markerTarget) $markerFingerprint "Installer preserves $($markerCase.Name) conflict bytes"
    }
    Remove-Item -LiteralPath $legacyUpgradeRegistration, $v02UpgradeRegistration -Force

    $conflictPath = Join-Path $installTarget 'AGENTS.md'
    Write-Utf8NoBomFixture $conflictPath 'local-conflict'
    $missingBeforeConflict = Join-Path $installTarget 'team-bob/templates/test-spec.md'
    Remove-Item -LiteralPath $missingBeforeConflict
    $conflictResult = Invoke-TestScript $installerPath @('-TargetPath', $installTarget)
    Assert-True ($conflictResult.ExitCode -ne 0) 'Installer returns nonzero when any destination conflicts'
    Assert-True ($conflictResult.Output -match 'CONFLICT') 'Installer reports the conflict during preflight'
    Assert-Equal ([System.IO.File]::ReadAllText($conflictPath)) 'local-conflict' 'Installer never overwrites a conflicting file'
    Assert-True (-not (Test-Path -LiteralPath $missingBeforeConflict)) 'Installer conflict stops all writes, including otherwise missing files'
    Assert-Equal ([System.IO.File]::ReadAllText($targetBzrMarker)) 'fixture-bzr-metadata' 'Installer conflict leaves target .bzr metadata unchanged'
    Assert-Equal (Test-Path -LiteralPath (Join-Path $toolsProfileRoot '.bzr')) $sourceBzrExisted 'Installer leaves source .bzr state unchanged'

    $sourceFingerprint = Get-TreeFingerprintFixture $toolsProfileRoot
    $selfInstallResult = Invoke-TestScript $installerPath @('-TargetPath', $toolsProfileRoot, '-WhatIf')
    Assert-True ($selfInstallResult.ExitCode -ne 0) 'Installer rejects its own profile source directory as TargetPath'
    Assert-Equal (Get-TreeFingerprintFixture $toolsProfileRoot) $sourceFingerprint 'Rejected source-directory install leaves every source file unchanged'
    $sourceDescendant = Join-Path $toolsProfileRoot 'team-bob/self-install'
    $descendantInstallResult = Invoke-TestScript $installerPath @('-TargetPath', $sourceDescendant, '-WhatIf')
    Assert-True ($descendantInstallResult.ExitCode -ne 0) 'Installer rejects a TargetPath beneath its profile source directory'
    Assert-True (-not (Test-Path -LiteralPath $sourceDescendant)) 'Rejected source-descendant install creates no directory'
    Assert-Equal (Get-TreeFingerprintFixture $toolsProfileRoot) $sourceFingerprint 'Rejected source-descendant install leaves the source tree unchanged'

    $distributionFingerprint = Get-TreeFingerprintFixture $toolsRepoRoot
    $distributionRootInstall = Invoke-TestScript $installerPath @('-TargetPath', $toolsRepoRoot, '-WhatIf')
    Assert-True ($distributionRootInstall.ExitCode -ne 0) 'Installer rejects the protected distribution repository root as TargetPath'
    Assert-True ($distributionRootInstall.Output -match 'protected|source|ancestor') 'Distribution-root rejection identifies the protected source boundary'
    Assert-Equal (Get-TreeFingerprintFixture $toolsRepoRoot) $distributionFingerprint 'Rejected distribution-root install preserves the complete source repository fingerprint'

    $distributionAncestor = Split-Path -Parent $toolsRepoRoot
    $distributionAncestorInstall = Invoke-TestScript $installerPath @('-TargetPath', $distributionAncestor, '-WhatIf')
    Assert-True ($distributionAncestorInstall.ExitCode -ne 0) 'Installer rejects a TargetPath that is an ancestor of the distribution repository'
    Assert-True ($distributionAncestorInstall.Output -match 'protected|source|ancestor') 'Distribution-ancestor rejection identifies the protected source boundary'
    Assert-Equal (Get-TreeFingerprintFixture $toolsRepoRoot) $distributionFingerprint 'Rejected distribution-ancestor install preserves the complete source repository fingerprint'

    $sourceAlias = Join-Path $fixtureRoot 'installer-source-alias'
    New-Item -ItemType Junction -Path $sourceAlias -Target $toolsRepoRoot -ErrorAction Stop | Out-Null
    $sourceAliasInstall = Invoke-TestScript $installerPath @('-TargetPath', $sourceAlias, '-WhatIf')
    Assert-True ($sourceAliasInstall.ExitCode -ne 0) 'Installer rejects a target junction that physically aliases the protected source repository'
    Assert-True ($sourceAliasInstall.Output -match 'reparse|alias|physical|protected') 'Source-alias rejection identifies the physical/reparse boundary'
    Assert-Equal (Get-TreeFingerprintFixture $toolsRepoRoot) $distributionFingerprint 'Rejected source-alias install preserves the source repository fingerprint'
    [System.IO.Directory]::Delete($sourceAlias)

    $junctionTarget = Join-Path $fixtureRoot 'installer-junction-target'
    New-Item -ItemType Directory -Path (Join-Path $junctionTarget 'code') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $junctionTarget '.bzr') -Force | Out-Null
    Write-Utf8NoBomFixture (Join-Path $junctionTarget 'code/source.cpp') "int untouched = 1;`r`n"
    Write-Utf8NoBomFixture (Join-Path $junctionTarget '.bzr/branch.conf') 'junction-target-bzr'
    $junctionTargetFingerprint = Get-TreeFingerprintFixture $junctionTarget
    $targetAlias = Join-Path $fixtureRoot 'installer-target-alias'
    New-Item -ItemType Junction -Path $targetAlias -Target $junctionTarget -ErrorAction Stop | Out-Null
    $targetAliasInstall = Invoke-TestScript $installerPath @('-TargetPath', $targetAlias)
    Assert-True ($targetAliasInstall.ExitCode -ne 0) 'Installer rejects an existing destination root junction before publication'
    Assert-True ($targetAliasInstall.Output -match 'reparse|alias|physical') 'Destination-junction rejection identifies the physical/reparse boundary'
    Assert-Equal (Get-TreeFingerprintFixture $junctionTarget) $junctionTargetFingerprint 'Rejected target junction preserves target code and .bzr fingerprints'
    Assert-Equal ([System.IO.File]::ReadAllText((Join-Path $junctionTarget 'code/source.cpp'))) "int untouched = 1;`r`n" 'Rejected target junction preserves target code bytes'
    Assert-Equal ([System.IO.File]::ReadAllText((Join-Path $junctionTarget '.bzr/branch.conf'))) 'junction-target-bzr' 'Rejected target junction preserves target .bzr bytes'
    [System.IO.Directory]::Delete($targetAlias)

    $raceTarget = Join-Path $fixtureRoot 'installer-create-new-race'
    $raceSentinel = 'TOCTOU-CREATE-ONLY-SENTINEL-91af'
    $raceDestination = Join-Path $raceTarget 'team-bob/USAGE.md'
    $raceJob = Start-Job -ScriptBlock {
        param($Parent, $Destination, $Sentinel)
        $deadline = [DateTime]::UtcNow.AddSeconds(10)
        while (-not [System.IO.Directory]::Exists($Parent) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 1 }
        if (-not [System.IO.Directory]::Exists($Parent)) { throw 'Timed out waiting for installer destination parent.' }
        [System.IO.File]::WriteAllText($Destination, $Sentinel, (New-Object System.Text.UTF8Encoding($false)))
    } -ArgumentList (Split-Path -Parent $raceDestination), $raceDestination, $raceSentinel
    try {
        $raceInstall = Invoke-TestScript $installerPath @('-TargetPath', $raceTarget)
        Wait-Job -Job $raceJob -Timeout 10 | Out-Null
        Receive-Job -Job $raceJob -ErrorAction Stop | Out-Null
        Assert-True ($raceInstall.ExitCode -ne 0) 'Installer aborts when a destination appears after complete preflight'
        Assert-Equal ([System.IO.File]::ReadAllText($raceDestination)) $raceSentinel 'Installer create-only publication never overwrites a TOCTOU destination'
    } finally {
        Remove-Job -Job $raceJob -Force -ErrorAction SilentlyContinue
    }

    $catalogProfileRoot = Join-Path $fixtureRoot 'catalog-profile'
    $catalogInstallResult = Invoke-TestScript $installerPath @('-TargetPath', $catalogProfileRoot)
    Assert-Equal $catalogInstallResult.ExitCode 0 'Installer still accepts a normal external profile target'

    # Fixed local environment: isolated LOCALAPPDATA, real file hashing, force-only replacement.
    $fakeBin = Join-Path $fixtureRoot '道具-日本'
    New-Item -ItemType Directory -Path $fakeBin | Out-Null
    $msdevPath = Join-Path $fakeBin 'MSDEV.COM'
    Write-Utf8NoBomFixture $msdevPath 'fixture-msdev-v1'
    $bazaarPath = Join-Path $fakeBin 'bzr.cmd'
    $fakeBazaar = @'
@echo off
if not "%BOB_TEST_BZR_LOG%"=="" echo %*>>"%BOB_TEST_BZR_LOG%"
if "%1"=="status" (
  if not "%BOB_TEST_BZR_STATUS%"=="" echo %BOB_TEST_BZR_STATUS%
  exit /b 0
)
if "%1"=="nick" (
  echo fixture-branch
  exit /b 0
)
if "%1"=="version-info" (
  echo fixture-revision-id
  exit /b 0
)
exit /b 41
'@
    Write-Utf8NoBomFixture $bazaarPath $fakeBazaar
    $sandboxRoot = Join-Path $fixtureRoot 'サンドボックス-日本'
    $logRoot = Join-Path $fixtureRoot 'ログ-日本'
    $initializeArguments = @('-MsdevPath', $msdevPath, '-BazaarPath', $bazaarPath, '-SandboxRoot', $sandboxRoot, '-LogRoot', $logRoot)
    $legacyEnvironmentPath = Join-Path $env:LOCALAPPDATA 'IBM/BobTeamProfile/vc6-machine-control-poc/environment.json'
    Write-Utf8NoBomFixture $legacyEnvironmentPath 'LEGACY-V0.1-SENTINEL'
    $initializeResult = Invoke-TestScript $initializePath $initializeArguments
    Assert-Equal $initializeResult.ExitCode 0 'Environment initializer writes a valid fixed local registration'
    $environmentPath = Join-Path $env:LOCALAPPDATA 'IBM/BobTeamProfile/vc6-machine-control-poc/v0.2.0-poc/environment.json'
    Assert-True (Test-Path -LiteralPath $environmentPath -PathType Leaf) 'Environment registration uses the isolated v0.2 LOCALAPPDATA path'
    Assert-Equal ([System.IO.File]::ReadAllText($legacyEnvironmentPath)) 'LEGACY-V0.1-SENTINEL' 'v0.2 initialization does not reuse or overwrite the v0.1 registration'
    $environment = [System.IO.File]::ReadAllText($environmentPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    Assert-Equal $environment.schemaVersion '1.0' 'Environment registration has a stable schema version'
    Assert-Equal $environment.profileId 'team-bob-vc6-bazaar' 'Environment registration records profile identity'
    Assert-Equal $environment.profileVersion '0.2.0-poc' 'Environment registration records profile version'
    Assert-Equal $environment.policyVersion '0.2.0-poc' 'Environment registration records policy version'
    Assert-True ([string]$environment.policyBundleSha256 -match '^[0-9a-f]{64}$') 'Environment registration records the installed policy bundle hash'
    Assert-Equal $environment.policyManifestSchemaId 'https://team-bob.local/schemas/policy-manifest.schema.json' 'Environment registration records the policy-manifest schema identity'
    Assert-Equal $environment.pcId ([Environment]::MachineName) 'Environment registration records stable machine identity'
    Assert-Equal $environment.msdevSha256 (Get-FileHash -Algorithm SHA256 -LiteralPath $msdevPath).Hash.ToLowerInvariant() 'Environment registration hashes MSDEV'
    Assert-Equal $environment.bazaarSha256 (Get-FileHash -Algorithm SHA256 -LiteralPath $bazaarPath).Hash.ToLowerInvariant() 'Environment registration hashes Bazaar'
    Assert-True (Test-Path -LiteralPath $environment.sandboxRoot -PathType Container) 'Environment initializer creates sandbox root'
    Assert-True (Test-Path -LiteralPath $environment.logRoot -PathType Container) 'Environment initializer creates log root'
    $environmentText = [System.IO.File]::ReadAllText($environmentPath)

    $identicalEnvironmentResult = Invoke-TestScript $initializePath $initializeArguments
    Assert-Equal $identicalEnvironmentResult.ExitCode 0 'Environment initializer identical rerun is harmless'
    Assert-Equal ([System.IO.File]::ReadAllText($environmentPath)) $environmentText 'Environment initializer preserves identical configuration bytes'

    Remove-Item -LiteralPath $sandboxRoot -Recurse
    $recreateRootResult = Invoke-TestScript $initializePath $initializeArguments
    Assert-Equal $recreateRootResult.ExitCode 0 'Identical environment rerun recreates a deleted sandbox root'
    Assert-True (Test-Path -LiteralPath $sandboxRoot -PathType Container) 'Identical environment rerun restores the sandbox directory'
    Remove-Item -LiteralPath $logRoot -Recurse
    Write-Utf8NoBomFixture $logRoot 'not-a-directory'
    $rootBecameFileResult = Invoke-TestScript $initializePath $initializeArguments
    Assert-True ($rootBecameFileResult.ExitCode -ne 0) 'Identical environment rerun rejects a log root replaced by a file'
    Remove-Item -LiteralPath $logRoot
    New-Item -ItemType Directory -Path $logRoot | Out-Null

    $insideRepositoryResult = Invoke-TestScript $initializePath @(
        '-MsdevPath', $msdevPath, '-BazaarPath', $bazaarPath, '-SandboxRoot', (Join-Path $toolsRepoRoot 'tests'), '-LogRoot', $logRoot, '-Force'
    )
    Assert-True ($insideRepositoryResult.ExitCode -ne 0) 'Environment initializer rejects roots inside the whole source repository'
    $nestedRootsResult = Invoke-TestScript $initializePath @(
        '-MsdevPath', $msdevPath, '-BazaarPath', $bazaarPath, '-SandboxRoot', $sandboxRoot, '-LogRoot', (Join-Path $sandboxRoot 'nested-logs'), '-Force'
    )
    Assert-True ($nestedRootsResult.ExitCode -ne 0) 'Environment initializer rejects sandbox and log roots nested beneath each other'

    $repositoryAncestorResult = Invoke-TestScript $initializePath @(
        '-MsdevPath', $msdevPath, '-BazaarPath', $bazaarPath, '-SandboxRoot', (Split-Path -Parent $toolsRepoRoot), '-LogRoot', $logRoot, '-Force'
    )
    Assert-True ($repositoryAncestorResult.ExitCode -ne 0) 'Environment initializer rejects a sandbox root that is an ancestor of the source repository'
    $volumeRoot = [System.IO.Path]::GetPathRoot($fixtureRoot)
    $volumeRootResult = Invoke-TestScript $initializePath @(
        '-MsdevPath', $msdevPath, '-BazaarPath', $bazaarPath, '-SandboxRoot', $volumeRoot, '-LogRoot', $logRoot, '-Force'
    )
    Assert-True ($volumeRootResult.ExitCode -ne 0) 'Environment initializer rejects a drive-volume root as a sandbox root'

    $rootJunction = Join-Path $fixtureRoot 'initializer-root-junction'
    New-Item -ItemType Junction -Path $rootJunction -Target $toolsRepoRoot -ErrorAction Stop | Out-Null
    $rootJunctionResult = Invoke-TestScript $initializePath @(
        '-MsdevPath', $msdevPath, '-BazaarPath', $bazaarPath, '-SandboxRoot', $rootJunction, '-LogRoot', $logRoot, '-Force'
    )
    Assert-True ($rootJunctionResult.ExitCode -ne 0) 'Environment initializer rejects a sandbox root containing a junction or physical repository alias'
    Assert-True ($rootJunctionResult.Output -match 'reparse|alias|physical|repository') 'Initializer junction rejection identifies the physical boundary'
    [System.IO.Directory]::Delete($rootJunction)

    $toolJunction = Join-Path $fixtureRoot 'initializer-tool-junction'
    New-Item -ItemType Junction -Path $toolJunction -Target $fakeBin -ErrorAction Stop | Out-Null
    $toolJunctionResult = Invoke-TestScript $initializePath @(
        '-MsdevPath', (Join-Path $toolJunction 'MSDEV.COM'), '-BazaarPath', $bazaarPath, '-SandboxRoot', $sandboxRoot, '-LogRoot', $logRoot, '-Force'
    )
    Assert-True ($toolJunctionResult.ExitCode -ne 0) 'Environment initializer rejects a registered tool path through a junction component'
    Assert-True ($toolJunctionResult.Output -match 'reparse|alias|physical') 'Initializer tool-junction rejection identifies the physical boundary'
    [System.IO.Directory]::Delete($toolJunction)
    $forceResult = Invoke-TestScript $initializePath ($initializeArguments + '-Force')
    Assert-Equal $forceResult.ExitCode 0 'Environment is restored after initializer physical-boundary tests'

    Write-Utf8NoBomFixture $environmentPath '{"different":true}'
    $noForceResult = Invoke-TestScript $initializePath $initializeArguments
    Assert-True ($noForceResult.ExitCode -ne 0) 'Environment initializer refuses a different existing registration without Force'
    Assert-Equal ([System.IO.File]::ReadAllText($environmentPath)) '{"different":true}' 'Environment initializer preserves conflicting registration without Force'
    $forceResult = Invoke-TestScript $initializePath ($initializeArguments + '-Force')
    Assert-Equal $forceResult.ExitCode 0 'Environment initializer replaces a different registration with Force'
    $environment = [System.IO.File]::ReadAllText($environmentPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    Assert-Equal $environment.bazaarPath ([System.IO.Path]::GetFullPath($bazaarPath)) 'Environment initializer records canonical Bazaar path after Force'

    # Strict validator uses an isolated installed profile with active, scoped, unexpired, distinct role assignments.
    $strictRolesPath = Join-Path $catalogProfileRoot '.bob/governance/roles.json'
    $strictRoles = Get-Content -Raw -LiteralPath $strictRolesPath | ConvertFrom-Json
    $strictRolePhases = @('requirements', 'specification', 'impact', 'implementation', 'review', 'test')
    $strictRoles.assignments = @(
        [pscustomobject][ordered]@{ assignmentId = 'ASSIGN-SPEC-TEST'; role = 'SPECIFICATION_APPROVER'; principalId = 'fixture-spec'; scope = [pscustomobject][ordered]@{ allTasks = $true; taskIds = @(); phases = $strictRolePhases }; enabled = $true; validFromUtc = '2000-01-01T00:00:00Z'; validUntilUtc = '2099-01-01T00:00:00Z' },
        [pscustomobject][ordered]@{ assignmentId = 'ASSIGN-IMPL-TEST'; role = 'IMPLEMENTATION_APPROVER'; principalId = 'fixture-impl'; scope = [pscustomobject][ordered]@{ allTasks = $true; taskIds = @(); phases = $strictRolePhases }; enabled = $true; validFromUtc = '2000-01-01T00:00:00Z'; validUntilUtc = '2099-01-01T00:00:00Z' },
        [pscustomobject][ordered]@{ assignmentId = 'ASSIGN-REVIEW-TEST'; role = 'INDEPENDENT_REVIEWER'; principalId = 'fixture-review'; scope = [pscustomobject][ordered]@{ allTasks = $true; taskIds = @(); phases = $strictRolePhases }; enabled = $true; validFromUtc = '2000-01-01T00:00:00Z'; validUntilUtc = '2099-01-01T00:00:00Z' }
    )
    Write-JsonFixture $strictRolesPath $strictRoles
    $strictResult = Invoke-TestScript $validatorPath @('-RepositoryRoot', $catalogProfileRoot, '-Strict')
    Assert-Equal $strictResult.ExitCode 0 "Strict profile validation succeeds with registered tools and external roots; output: $($strictResult.Output.Trim())"
    Assert-True ($strictResult.Output -match 'SUMMARY.*Failed=0') 'Strict validator emits a zero-failure summary'

    $environmentBytesWithoutBom = [System.IO.File]::ReadAllBytes($environmentPath)
    $environmentBytesWithBom = New-Object byte[] ($environmentBytesWithoutBom.Length + 3)
    $environmentBytesWithBom[0] = 0xEF; $environmentBytesWithBom[1] = 0xBB; $environmentBytesWithBom[2] = 0xBF
    [Array]::Copy($environmentBytesWithoutBom, 0, $environmentBytesWithBom, 3, $environmentBytesWithoutBom.Length)
    [System.IO.File]::WriteAllBytes($environmentPath, $environmentBytesWithBom)
    $strictBomEnvironment = Invoke-TestScript $validatorPath @('-RepositoryRoot', $catalogProfileRoot, '-Strict')
    Assert-True ($strictBomEnvironment.ExitCode -ne 0) 'Strict validator rejects a BOM-bearing production environment JSON file'
    [System.IO.File]::WriteAllBytes($environmentPath, $environmentBytesWithoutBom)

    $strictToolAlias = Join-Path $fixtureRoot 'strict-tool-junction'
    New-Item -ItemType Junction -Path $strictToolAlias -Target $fakeBin -ErrorAction Stop | Out-Null
    $environment = [System.IO.File]::ReadAllText($environmentPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $environment.msdevPath = Join-Path $strictToolAlias 'MSDEV.COM'
    Write-JsonFixture $environmentPath $environment
    $strictToolAliasResult = Invoke-TestScript $validatorPath @('-RepositoryRoot', $catalogProfileRoot, '-Strict')
    Assert-True ($strictToolAliasResult.ExitCode -ne 0) 'Strict validator rejects a registered tool path through a junction component'
    Assert-True ($strictToolAliasResult.Output -match 'FAIL.*MSDEV|reparse|physical') 'Strict validator reports the tool physical-boundary failure'
    [System.IO.Directory]::Delete($strictToolAlias)
    $forceResult = Invoke-TestScript $initializePath ($initializeArguments + '-Force')
    Assert-Equal $forceResult.ExitCode 0 'Environment is restored after strict tool-junction validation test'

    $strictRootAlias = Join-Path $fixtureRoot 'strict-root-junction'
    New-Item -ItemType Junction -Path $strictRootAlias -Target $toolsRepoRoot -ErrorAction Stop | Out-Null
    $environment = [System.IO.File]::ReadAllText($environmentPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $environment.sandboxRoot = $strictRootAlias
    Write-JsonFixture $environmentPath $environment
    $strictRootAliasResult = Invoke-TestScript $validatorPath @('-RepositoryRoot', $catalogProfileRoot, '-Strict')
    Assert-True ($strictRootAliasResult.ExitCode -ne 0) 'Strict validator rejects a sandbox root junction that aliases the source repository'
    Assert-True ($strictRootAliasResult.Output -match 'FAIL.*Sandbox|reparse|physical') 'Strict validator reports the root physical-boundary failure'
    [System.IO.Directory]::Delete($strictRootAlias)
    $forceResult = Invoke-TestScript $initializePath ($initializeArguments + '-Force')
    Assert-Equal $forceResult.ExitCode 0 'Environment is restored after strict root-junction validation test'

    $environment = [System.IO.File]::ReadAllText($environmentPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $environment.msdevPath = 'scripts/Install-TeamBobProfile.ps1'
    $environment.msdevSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $toolsRepoRoot 'scripts/Install-TeamBobProfile.ps1')).Hash.ToLowerInvariant()
    Write-JsonFixture $environmentPath $environment
    $relativeToolResult = Invoke-TestScript $validatorPath @('-RepositoryRoot', $catalogProfileRoot, '-Strict')
    Assert-True ($relativeToolResult.ExitCode -ne 0) 'Strict validator rejects relative tool paths even when they resolve and hash-match'
    $forceResult = Invoke-TestScript $initializePath ($initializeArguments + '-Force')
    Assert-Equal $forceResult.ExitCode 0 'Environment is restored after relative-tool validation test'

    $environment = [System.IO.File]::ReadAllText($environmentPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $environment.sandboxRoot = 'tests'
    Write-JsonFixture $environmentPath $environment
    $relativeRootResult = Invoke-TestScript $validatorPath @('-RepositoryRoot', $catalogProfileRoot, '-Strict')
    Assert-True ($relativeRootResult.ExitCode -ne 0) 'Strict validator rejects relative sandbox and log root registrations'
    $forceResult = Invoke-TestScript $initializePath ($initializeArguments + '-Force')
    Assert-Equal $forceResult.ExitCode 0 'Environment is restored after relative-root validation test'

    $environment = [System.IO.File]::ReadAllText($environmentPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $environment.pcId = 'different-machine'
    Write-JsonFixture $environmentPath $environment
    $machineIdentityResult = Invoke-TestScript $validatorPath @('-RepositoryRoot', $catalogProfileRoot, '-Strict')
    Assert-True ($machineIdentityResult.ExitCode -ne 0) 'Strict validator rejects an environment registered for another machine'
    $forceResult = Invoke-TestScript $initializePath ($initializeArguments + '-Force')
    Assert-Equal $forceResult.ExitCode 0 'Environment is restored after machine-identity validation test'

    Write-Utf8NoBomFixture $msdevPath 'fixture-msdev-tampered'
    $hashFailure = Invoke-TestScript $validatorPath @('-RepositoryRoot', $catalogProfileRoot, '-Strict')
    Assert-True ($hashFailure.ExitCode -ne 0) 'Strict validator rejects a mismatched tool hash'
    Assert-True ($hashFailure.Output -match 'FAIL.*MSDEV hash') 'Strict validator emits a failed hash check record'
    Write-Utf8NoBomFixture $msdevPath 'fixture-msdev-v1'
    $forceResult = Invoke-TestScript $initializePath ($initializeArguments + '-Force')
    Assert-Equal $forceResult.ExitCode 0 'Environment hash is restored for task tests'

    $missingProfileResult = Invoke-TestScript $validatorPath @('-RepositoryRoot', $catalogProfileRoot, '-BuildProfileId', 'missing-profile', '-Strict')
    Assert-True ($missingProfileResult.ExitCode -ne 0) 'Validator rejects a requested build profile absent from the empty catalog'

    $targetSchemaFixture = Get-Content -Raw -LiteralPath (Join-Path $toolsProfileRoot 'team-bob/config/vc6-build-targets.schema.json') | ConvertFrom-Json
    Assert-Equal $targetSchemaFixture.properties.profiles.items.properties.expectedArtifacts.minItems 1 'Build-target schema requires at least one expected artifact'
    $catalogPath = Join-Path $catalogProfileRoot 'team-bob/config/vc6-build-targets.json'
    $malformedCatalog = [pscustomobject]@{ profiles = @([pscustomobject]@{
        id = 'malformed'; enabled = $true
        qualification = [pscustomobject]@{
            msdevHelp = $true; makeSucceeded = $true; rebuildSucceeded = $true; compileFailureObserved = $true; linkFailureObserved = $true
            pcId = [Environment]::MachineName; recordId = 'fixture-record'; recordedAt = '2026-09-02T00:00:00Z'
        }
    }) }
    Write-JsonFixture $catalogPath $malformedCatalog
    $malformedCatalogResult = Invoke-TestScript (Join-Path $catalogProfileRoot 'team-bob/tools/Test-TeamBobProfile.ps1') @('-RepositoryRoot', $catalogProfileRoot, '-Strict')
    Assert-True ($malformedCatalogResult.ExitCode -ne 0) 'Validator rejects malformed unselected catalog profiles'

    $qualifiedProfile = [pscustomobject]@{
        id = 'qualified-fixture'; enabled = $true; projectFile = 'project/fixture.dsp'; target = 'Win32 Release'; timeoutSeconds = 30
        expectedArtifacts = @('bin/fixture.exe'); excludePatterns = @('*.obj'); outputLogPattern = 'build\\.log$'; successPattern = '0 error';
        compilerErrorPattern = 'error C[0-9]+'; linkerErrorPattern = 'LNK[0-9]+'; environmentErrorPattern = 'MSDEV.*not found'
        qualification = [pscustomobject]@{
            msdevHelp = $true; makeSucceeded = $true; rebuildSucceeded = $true; compileFailureObserved = $true; linkFailureObserved = $true
            pcId = 'different-machine'; recordId = 'fixture-record'; recordedAt = '2026-09-02T00:00:00Z'
        }
    }
    Write-JsonFixture $catalogPath ([pscustomobject]@{ profiles = @($qualifiedProfile) })
    $wrongPcProfileResult = Invoke-TestScript (Join-Path $catalogProfileRoot 'team-bob/tools/Test-TeamBobProfile.ps1') @('-RepositoryRoot', $catalogProfileRoot, '-BuildProfileId', 'qualified-fixture', '-Strict')
    Assert-True ($wrongPcProfileResult.ExitCode -ne 0) 'Validator rejects a selected qualification recorded for another PC'
    $qualifiedProfile.qualification.pcId = [Environment]::MachineName
    Write-JsonFixture $catalogPath ([pscustomobject]@{ profiles = @($qualifiedProfile) })
    $qualifiedProfileResult = Invoke-TestScript (Join-Path $catalogProfileRoot 'team-bob/tools/Test-TeamBobProfile.ps1') @('-RepositoryRoot', $catalogProfileRoot, '-BuildProfileId', 'qualified-fixture', '-Strict')
    Assert-Equal $qualifiedProfileResult.ExitCode 0 "Validator accepts one complete enabled qualification for the registered PC; output: $($qualifiedProfileResult.Output.Trim())"

    # Start task: fake Bazaar observes only the allowed read-only command set.
    $startTaskPath = Join-Path $catalogProfileRoot 'team-bob/tools/Start-TeamBobTask.ps1'
    $roleNow = [DateTimeOffset]::UtcNow
    Write-JsonFixture (Join-Path $catalogProfileRoot '.bob/governance/roles.json') ([ordered]@{policyVersion='0.2.0-poc';assignments=@(
        [ordered]@{assignmentId='ASSIGN-SPEC';role='SPECIFICATION_APPROVER';principalId='principal-spec';scope=[ordered]@{allTasks=$true;taskIds=@();phases=@('specification','test')};enabled=$true;validFromUtc=$roleNow.AddHours(-1).ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ');validUntilUtc=$roleNow.AddDays(7).ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')},
        [ordered]@{assignmentId='ASSIGN-IMPL';role='IMPLEMENTATION_APPROVER';principalId='principal-impl';scope=[ordered]@{allTasks=$true;taskIds=@();phases=@('impact')};enabled=$true;validFromUtc=$roleNow.AddHours(-1).ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ');validUntilUtc=$roleNow.AddDays(7).ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')},
        [ordered]@{assignmentId='ASSIGN-REVIEW';role='INDEPENDENT_REVIEWER';principalId='principal-review';scope=[ordered]@{allTasks=$true;taskIds=@();phases=@('review')};enabled=$true;validFromUtc=$roleNow.AddHours(-1).ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ');validUntilUtc=$roleNow.AddDays(7).ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')}
    )})
    $bazaarRoot = Join-Path $fixtureRoot 'working-tree'
    New-Item -ItemType Directory -Path (Join-Path $bazaarRoot '.bzr') -Force | Out-Null
    Write-Utf8NoBomFixture (Join-Path $bazaarRoot '.bzr/branch.conf') 'working-tree-metadata'
    Write-Utf8NoBomFixture (Join-Path $bazaarRoot 'src/example.cpp') "int main() { return 0; }`r`n"
    $env:BOB_TEST_BZR_LOG = Join-Path $fixtureRoot 'bzr-commands.log'
    $env:BOB_TEST_BZR_STATUS = ''
    $greenArguments = @(
        '-TaskId', 'GREEN-0001', '-BazaarRoot', $bazaarRoot, '-Difficulty', 'Small', '-Classification', 'Green',
        '-Customer', 'Fixture Customer', '-ReqIds', 'REQ-100', '-WordBaseline', 'WORD-1', '-QaBaseline', 'QA-1',
        '-SpecBaseline', 'SPEC-1', '-AllowedFiles', 'src/example.cpp', '-BuildProfileId', 'fixture-vc6',
        '-SpecificationAssignmentId', 'ASSIGN-SPEC', '-ImplementationAssignmentId', 'ASSIGN-IMPL', '-IndependentReviewerAssignmentId', 'ASSIGN-REVIEW',
        '-RTImpactClear', 'YES', '-SafetyImpactClear', 'YES', '-BoardImpactClear', 'YES', '-DriverImpactClear', 'YES',
        '-ABIImpactClear', 'YES', '-BuildImpactClear', 'YES', '-CustomerBranchImpactClear', 'YES'
    )
    $startResult = Invoke-TestScript $startTaskPath $greenArguments
    Assert-Equal $startResult.ExitCode 0 'Start task creates a work packet for a clean fully approved Green task'
    $workPacketPath = Join-Path $bazaarRoot 'team-bob-work/GREEN-0001/work-packet.md'
    Assert-True (Test-Path -LiteralPath (Join-Path $bazaarRoot 'team-bob-work/GREEN-0001/drafts') -PathType Container) 'Start task creates drafts directory'
    Assert-True (Test-Path -LiteralPath (Join-Path $bazaarRoot 'team-bob-work/GREEN-0001/results') -PathType Container) 'Start task creates results directory'
    Assert-True (Test-Path -LiteralPath (Join-Path $bazaarRoot 'team-bob-work/GREEN-0001/approvals') -PathType Container) 'Start task creates approvals directory'
    Assert-True (Test-Path -LiteralPath (Join-Path $bazaarRoot 'team-bob-work/GREEN-0001/state/phase-state.json') -PathType Leaf) 'Start task atomically publishes initial phase state'
    $createdPacket = Get-CanonicalPacketFixture $workPacketPath
    Assert-Equal $createdPacket.'Task ID' 'GREEN-0001' 'Created work packet records Task ID'
    Assert-Equal $createdPacket.Risk 'Green' 'Created work packet records Green classification'
    Assert-Equal $createdPacket.'Bazaar Branch' 'fixture-branch' 'Created work packet records Bazaar nick'
    Assert-Equal $createdPacket.'Bazaar Full Revision ID' 'fixture-revision-id' 'Created work packet records full revision id'
    Assert-Equal $createdPacket.'Allowed Files'[0] 'src/example.cpp' 'Created work packet records normalized relative allowed file'
    Assert-Equal $createdPacket.'Clean Working Copy' 'YES' 'Created work packet records clean working copy'
    Assert-Equal $createdPacket.'Max-Repair-Cycles' 2 'Created work packet fixes repair cycles at two'
    Assert-Equal ([System.IO.File]::ReadAllText((Join-Path $bazaarRoot '.bzr/branch.conf'))) 'working-tree-metadata' 'Start task leaves .bzr metadata unchanged'
    $bazaarCommands = @(Get-Content -LiteralPath $env:BOB_TEST_BZR_LOG)
    Assert-Equal $bazaarCommands.Count 3 'Start task invokes exactly three Bazaar queries'
    Assert-Equal $bazaarCommands[0] 'status --short' 'Start task first checks short status'
    Assert-Equal $bazaarCommands[1] 'nick' 'Start task reads branch nick'
    Assert-Equal $bazaarCommands[2] 'version-info --custom --template={revision_id}' 'Start task reads the full revision id'

    $installedTemplatePath = Join-Path $catalogProfileRoot 'team-bob/templates/work-packet.md'
    $installedTemplateBytes = [System.IO.File]::ReadAllBytes($installedTemplatePath)
    $installedTemplateBomBytes = New-Object byte[] ($installedTemplateBytes.Length + 3)
    $installedTemplateBomBytes[0] = 0xEF; $installedTemplateBomBytes[1] = 0xBB; $installedTemplateBomBytes[2] = 0xBF
    [Array]::Copy($installedTemplateBytes, 0, $installedTemplateBomBytes, 3, $installedTemplateBytes.Length)
    [System.IO.File]::WriteAllBytes($installedTemplatePath, $installedTemplateBomBytes)
    $templateBomArguments = @($greenArguments)
    $templateBomArguments[1] = 'GREEN-TEMPLATE-BOM'
    $templateBomResult = Invoke-TestScript (Join-Path $catalogProfileRoot 'team-bob/tools/Start-TeamBobTask.ps1') $templateBomArguments
    Assert-True ($templateBomResult.ExitCode -ne 0) 'Start task rejects a BOM-bearing production work-packet template'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $bazaarRoot 'team-bob-work/GREEN-TEMPLATE-BOM'))) 'Template BOM rejection creates no task artifacts'
    [System.IO.File]::WriteAllBytes($installedTemplatePath, $installedTemplateBytes)

    $metacharArguments = @($greenArguments)
    $metacharArguments[1] = 'GREEN-METACHAR'
    $customerIndex = [array]::IndexOf($metacharArguments, '-Customer')
    $metacharCustomer = '顧客-日本 $1 ${2} $&'
    $metacharArguments[$customerIndex + 1] = $metacharCustomer
    $metacharResult = Invoke-TestScript $startTaskPath $metacharArguments
    Assert-Equal $metacharResult.ExitCode 0 'Start task safely inserts regex-replacement metacharacters from metadata'
    $metacharPacket = Get-CanonicalPacketFixture (Join-Path $bazaarRoot 'team-bob-work/GREEN-METACHAR/work-packet.md')
    Assert-Equal $metacharPacket.Customer $metacharCustomer 'Metacharacter-bearing metadata round-trips exactly in canonical JSON'

    $missingFileArguments = @($greenArguments)
    $missingFileArguments[1] = 'GREEN-MISSING-FILE'
    $allowedIndex = [array]::IndexOf($missingFileArguments, '-AllowedFiles')
    $missingFileArguments[$allowedIndex + 1] = 'src/missing.cpp'
    $missingFileResult = Invoke-TestScript $startTaskPath $missingFileArguments
    Assert-True ($missingFileResult.ExitCode -ne 0) 'Start task rejects an Allowed File that does not exist as a leaf'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $bazaarRoot 'team-bob-work/GREEN-MISSING-FILE'))) 'Missing Allowed File rejection creates no task directory'

    $nestedBazaarRoot = Join-Path $bazaarRoot 'nested-directory'
    Write-Utf8NoBomFixture (Join-Path $nestedBazaarRoot 'src/nested.cpp') "int nested = 1;`r`n"
    $nestedRootArguments = @($greenArguments)
    $nestedRootArguments[1] = 'GREEN-NESTED-ROOT'
    $bazaarRootIndex = [array]::IndexOf($nestedRootArguments, '-BazaarRoot')
    $nestedRootArguments[$bazaarRootIndex + 1] = $nestedBazaarRoot
    $nestedRootArguments[$allowedIndex + 1] = 'src/nested.cpp'
    $nestedRootResult = Invoke-TestScript $startTaskPath $nestedRootArguments
    Assert-True ($nestedRootResult.ExitCode -ne 0) 'Start task requires the supplied BazaarRoot itself to contain the .bzr root marker'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $nestedBazaarRoot 'team-bob-work/GREEN-NESTED-ROOT'))) 'Nested non-root rejection creates no task directory'

    $duplicateResult = Invoke-TestScript $startTaskPath $greenArguments
    Assert-True ($duplicateResult.ExitCode -ne 0) 'Start task refuses a duplicate task directory'

    $env:BOB_TEST_BZR_STATUS = ' M src/example.cpp'
    $dirtyArguments = @($greenArguments)
    $dirtyArguments[1] = 'GREEN-DIRTY'
    $dirtyResult = Invoke-TestScript $startTaskPath $dirtyArguments
    Assert-True ($dirtyResult.ExitCode -ne 0) 'Start task refuses a dirty Bazaar working tree'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $bazaarRoot 'team-bob-work/GREEN-DIRTY'))) 'Dirty-tree rejection creates no task directory'
    $env:BOB_TEST_BZR_STATUS = ''

    $openQaArguments = @($greenArguments)
    $openQaArguments[1] = 'GREEN-OPEN-QA'
    $openQaArguments += @('-OpenQa', 'QA-OPEN')
    $openQaResult = Invoke-TestScript $startTaskPath $openQaArguments
    Assert-True ($openQaResult.ExitCode -ne 0) 'Start task refuses Green classification with open QA'

    $missingApprovalArguments = @($greenArguments)
    $missingApprovalArguments[1] = 'GREEN-NO-ASSIGNMENT'
    $approvalIndex = [array]::IndexOf($missingApprovalArguments, '-SpecificationAssignmentId')
    $missingApprovalArguments[$approvalIndex + 1] = 'ASSIGN-MISSING'
    [System.IO.File]::WriteAllText($env:BOB_TEST_BZR_LOG, '')
    $missingApprovalResult = Invoke-TestScript $startTaskPath $missingApprovalArguments
    Assert-True ($missingApprovalResult.ExitCode -ne 0) 'Start task refuses an absent selected assignment'
    Assert-Equal ([System.IO.File]::ReadAllText($env:BOB_TEST_BZR_LOG)) '' 'Role rejection occurs before every Bazaar command'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $bazaarRoot 'team-bob-work/GREEN-NO-ASSIGNMENT'))) 'Role rejection creates no task tree'

    $outsideArguments = @($greenArguments)
    $outsideArguments[1] = 'GREEN-OUTSIDE'
    $allowedIndex = [array]::IndexOf($outsideArguments, '-AllowedFiles')
    $outsideArguments[$allowedIndex + 1] = '../outside.cpp'
    $outsideResult = Invoke-TestScript $startTaskPath $outsideArguments
    Assert-True ($outsideResult.ExitCode -ne 0) 'Start task refuses an allowed file outside Bazaar root'

    $unsupportedArguments = @($greenArguments)
    $unsupportedArguments[1] = 'GREEN-RC'
    $unsupportedArguments[$allowedIndex + 1] = 'src/resource.rc'
    $unsupportedResult = Invoke-TestScript $startTaskPath $unsupportedArguments
    Assert-True ($unsupportedResult.ExitCode -ne 0) 'Start task refuses unsupported legacy file extensions'

    Write-Utf8NoBomFixture (Join-Path $bazaarRoot 'secrets/allowed.cpp') "int secret_allowed = 1;`r`n"
    $forbiddenAllowedArguments = @($greenArguments)
    $forbiddenAllowedArguments[1] = 'GREEN-FORBIDDEN-ALLOWED'
    $forbiddenAllowedArguments[$allowedIndex + 1] = 'secrets/allowed.cpp'
    $forbiddenAllowedResult = Invoke-TestScript $startTaskPath $forbiddenAllowedArguments
    Assert-True ($forbiddenAllowedResult.ExitCode -ne 0) 'Start task refuses an Allowed File equal to or below a normalized Forbidden Areas prefix'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $bazaarRoot 'team-bob-work/GREEN-FORBIDDEN-ALLOWED'))) 'Forbidden Allowed File rejection creates no task artifacts'

    $emptyImpactArguments = @($greenArguments)
    $emptyImpactArguments[1] = 'GREEN-EMPTY-IMPACT'
    $emptyImpactArguments += @('-RTImpact', '')
    $emptyImpactResult = Invoke-TestScript $startTaskPath $emptyImpactArguments
    Assert-True ($emptyImpactResult.ExitCode -ne 0) 'Start task refuses empty required impact evidence that the schema consumer rejects'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $bazaarRoot 'team-bob-work/GREEN-EMPTY-IMPACT'))) 'Empty impact rejection creates no task artifacts'

    foreach ($unsafeForbiddenEntry in @('../unsafe', "unsafe`tpath", '/rooted', 'C:\rooted', 'secrets.', 'CON', 'nested /secret')) {
        $unsafeForbiddenArguments = @($greenArguments)
        $unsafeForbiddenArguments[1] = 'GREEN-UNSAFE-FORBIDDEN-' + ([guid]::NewGuid().ToString('N').Substring(0, 8))
        $unsafeForbiddenArguments += @('-ForbiddenAreas', $unsafeForbiddenEntry)
        $unsafeForbiddenResult = Invoke-TestScript $startTaskPath $unsafeForbiddenArguments
        Assert-True ($unsafeForbiddenResult.ExitCode -ne 0) "Start task rejects unsafe Forbidden Areas entry '$unsafeForbiddenEntry'"
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $bazaarRoot ('team-bob-work/' + $unsafeForbiddenArguments[1])))) "Unsafe Forbidden Areas rejection creates no task artifacts for '$unsafeForbiddenEntry'"
    }

    $bazaarAlias = Join-Path $fixtureRoot 'start-bazaar-root-junction'
    New-Item -ItemType Junction -Path $bazaarAlias -Target $bazaarRoot -ErrorAction Stop | Out-Null
    $bazaarAliasArguments = @($greenArguments)
    $bazaarAliasArguments[1] = 'GREEN-ROOT-ALIAS'
    $bazaarAliasArguments[$bazaarRootIndex + 1] = $bazaarAlias
    $bazaarAliasResult = Invoke-TestScript $startTaskPath $bazaarAliasArguments
    Assert-True ($bazaarAliasResult.ExitCode -ne 0) 'Start task rejects a Bazaar root containing a junction/reparse alias'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $bazaarRoot 'team-bob-work/GREEN-ROOT-ALIAS'))) 'Bazaar-root alias rejection creates no physical task artifacts'
    [System.IO.Directory]::Delete($bazaarAlias)

    $outsideAllowedRoot = Join-Path $fixtureRoot 'outside-allowed-root'
    Write-Utf8NoBomFixture (Join-Path $outsideAllowedRoot 'escaped.cpp') "int escaped = 1;`r`n"
    $allowedAlias = Join-Path $bazaarRoot 'allowed-junction'
    New-Item -ItemType Junction -Path $allowedAlias -Target $outsideAllowedRoot -ErrorAction Stop | Out-Null
    $allowedAliasArguments = @($greenArguments)
    $allowedAliasArguments[1] = 'GREEN-ALLOWED-ALIAS'
    $allowedAliasArguments[$allowedIndex + 1] = 'allowed-junction/escaped.cpp'
    $allowedAliasResult = Invoke-TestScript $startTaskPath $allowedAliasArguments
    Assert-True ($allowedAliasResult.ExitCode -ne 0) 'Start task rejects an Allowed File whose component is a junction/reparse escape'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $bazaarRoot 'team-bob-work/GREEN-ALLOWED-ALIAS'))) 'Allowed-file reparse rejection creates no task artifacts'

    $forbiddenAliasArguments = @($greenArguments)
    $forbiddenAliasArguments[1] = 'GREEN-FORBIDDEN-ALIAS'
    $forbiddenAliasArguments += @('-ForbiddenAreas', 'allowed-junction')
    $forbiddenAliasResult = Invoke-TestScript $startTaskPath $forbiddenAliasArguments
    Assert-True ($forbiddenAliasResult.ExitCode -ne 0) 'Start task fully validates and rejects a Forbidden Areas junction/reparse alias'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $bazaarRoot 'team-bob-work/GREEN-FORBIDDEN-ALIAS'))) 'Forbidden-area reparse rejection creates no task artifacts'
    [System.IO.Directory]::Delete($allowedAlias)

    $registeredToolAlias = Join-Path $fixtureRoot 'start-bazaar-tool-junction'
    New-Item -ItemType Junction -Path $registeredToolAlias -Target $fakeBin -ErrorAction Stop | Out-Null
    $environment = [System.IO.File]::ReadAllText($environmentPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $environment.bazaarPath = Join-Path $registeredToolAlias 'bzr.cmd'
    Write-JsonFixture $environmentPath $environment
    [System.IO.File]::WriteAllText($env:BOB_TEST_BZR_LOG, '')
    $registeredToolAliasArguments = @($greenArguments)
    $registeredToolAliasArguments[1] = 'GREEN-TOOL-ALIAS'
    $registeredToolAliasResult = Invoke-TestScript $startTaskPath $registeredToolAliasArguments
    Assert-True ($registeredToolAliasResult.ExitCode -ne 0) 'Start task physically validates the registered Bazaar tool before invocation'
    Assert-Equal ([System.IO.File]::ReadAllText($env:BOB_TEST_BZR_LOG)) '' 'Registered Bazaar tool reparse rejection invokes no Bazaar command'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $bazaarRoot 'team-bob-work/GREEN-TOOL-ALIAS'))) 'Registered Bazaar tool rejection creates no task artifacts'
    [System.IO.Directory]::Delete($registeredToolAlias)
    $forceResult = Invoke-TestScript $initializePath ($initializeArguments + '-Force')
    Assert-Equal $forceResult.ExitCode 0 'Environment is restored after Start registered-tool boundary test'

    $environment = [System.IO.File]::ReadAllText($environmentPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $environment.sandboxRoot = $bazaarRoot
    Write-JsonFixture $environmentPath $environment
    [System.IO.File]::WriteAllText($env:BOB_TEST_BZR_LOG, '')
    $startOverlapArguments = @($greenArguments)
    $startOverlapArguments[1] = 'GREEN-ROOT-OVERLAP'
    $startOverlapResult = Invoke-TestScript $startTaskPath $startOverlapArguments
    Assert-True ($startOverlapResult.ExitCode -ne 0) 'Start task rejects a registered sandbox root equal to the Bazaar source root'
    Assert-Equal ([System.IO.File]::ReadAllText($env:BOB_TEST_BZR_LOG)) '' 'Start root-overlap rejection occurs before every Bazaar command'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $bazaarRoot 'team-bob-work/GREEN-ROOT-OVERLAP'))) 'Start root-overlap rejection creates no task artifacts'
    $forceResult = Invoke-TestScript $initializePath ($initializeArguments + '-Force')
    Assert-Equal $forceResult.ExitCode 0 'Environment is restored after Start root-overlap boundary test'

    Remove-Item -LiteralPath $environmentPath
    $missingEnvironmentResult = Invoke-TestScript $validatorPath @('-RepositoryRoot', $catalogProfileRoot, '-Strict')
    Assert-True ($missingEnvironmentResult.ExitCode -ne 0) 'Strict validator requires the fixed local environment registration'
} finally {
    $env:LOCALAPPDATA = $originalLocalAppData
    $env:BOB_TEST_BZR_STATUS = $originalStatus
    $env:BOB_TEST_BZR_LOG = $originalBzrLog
    if (Test-Path -LiteralPath $fixtureRoot) {
        $resolvedFixture = [System.IO.Path]::GetFullPath($fixtureRoot)
        $resolvedTemp = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
        if (-not $resolvedFixture.StartsWith($resolvedTemp, [System.StringComparison]::OrdinalIgnoreCase)) { throw "Refusing to remove fixture outside temp root: $resolvedFixture" }
        Remove-Item -LiteralPath $resolvedFixture -Recurse -Force
    }
}

Write-Host "PASS: $script:Assertions total package and tool assertions succeeded."
