$ErrorActionPreference = 'Stop'

function Invoke-TestScript {
    param([string]$Path, [string[]]$Arguments = @())
    $powerShell = (Get-Process -Id $PID).Path
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $powerShell -NoLogo -NoProfile -NonInteractive -File $Path @Arguments 2>&1 | Out-String
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
    $env:LOCALAPPDATA = Join-Path $fixtureRoot 'localappdata'

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

    $catalogProfileRoot = Join-Path $fixtureRoot 'catalog-profile'
    $catalogInstallResult = Invoke-TestScript $installerPath @('-TargetPath', $catalogProfileRoot)
    Assert-Equal $catalogInstallResult.ExitCode 0 'Installer still accepts a normal external profile target'

    # Fixed local environment: isolated LOCALAPPDATA, real file hashing, force-only replacement.
    $fakeBin = Join-Path $fixtureRoot 'fake-bin'
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
    $sandboxRoot = Join-Path $fixtureRoot 'sandboxes'
    $logRoot = Join-Path $fixtureRoot 'logs'
    $initializeArguments = @('-MsdevPath', $msdevPath, '-BazaarPath', $bazaarPath, '-SandboxRoot', $sandboxRoot, '-LogRoot', $logRoot)
    $initializeResult = Invoke-TestScript $initializePath $initializeArguments
    Assert-Equal $initializeResult.ExitCode 0 'Environment initializer writes a valid fixed local registration'
    $environmentPath = Join-Path $env:LOCALAPPDATA 'IBM/BobTeamProfile/vc6-machine-control-poc/environment.json'
    Assert-True (Test-Path -LiteralPath $environmentPath -PathType Leaf) 'Environment registration uses the fixed LOCALAPPDATA path'
    $environment = Get-Content -Raw -LiteralPath $environmentPath | ConvertFrom-Json
    Assert-Equal $environment.schemaVersion '1.0' 'Environment registration has a stable schema version'
    Assert-Equal $environment.profileId 'team-bob-vc6-bazaar' 'Environment registration records profile identity'
    Assert-Equal $environment.profileVersion '0.1.0-poc' 'Environment registration records profile version'
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

    Write-Utf8NoBomFixture $environmentPath '{"different":true}'
    $noForceResult = Invoke-TestScript $initializePath $initializeArguments
    Assert-True ($noForceResult.ExitCode -ne 0) 'Environment initializer refuses a different existing registration without Force'
    Assert-Equal ([System.IO.File]::ReadAllText($environmentPath)) '{"different":true}' 'Environment initializer preserves conflicting registration without Force'
    $forceResult = Invoke-TestScript $initializePath ($initializeArguments + '-Force')
    Assert-Equal $forceResult.ExitCode 0 'Environment initializer replaces a different registration with Force'
    $environment = Get-Content -Raw -LiteralPath $environmentPath | ConvertFrom-Json
    Assert-Equal $environment.bazaarPath ([System.IO.Path]::GetFullPath($bazaarPath)) 'Environment initializer records canonical Bazaar path after Force'

    # Strict validator accepts the complete source profile and rejects environment/hash/profile selection failures.
    $strictResult = Invoke-TestScript $validatorPath @('-RepositoryRoot', $toolsProfileRoot, '-Strict')
    Assert-Equal $strictResult.ExitCode 0 'Strict profile validation succeeds with registered tools and external roots'
    Assert-True ($strictResult.Output -match 'SUMMARY.*Failed=0') 'Strict validator emits a zero-failure summary'

    $environment = Get-Content -Raw -LiteralPath $environmentPath | ConvertFrom-Json
    $environment.msdevPath = 'scripts/Install-TeamBobProfile.ps1'
    $environment.msdevSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $toolsRepoRoot 'scripts/Install-TeamBobProfile.ps1')).Hash.ToLowerInvariant()
    Write-JsonFixture $environmentPath $environment
    $relativeToolResult = Invoke-TestScript $validatorPath @('-RepositoryRoot', $toolsProfileRoot, '-Strict')
    Assert-True ($relativeToolResult.ExitCode -ne 0) 'Strict validator rejects relative tool paths even when they resolve and hash-match'
    $forceResult = Invoke-TestScript $initializePath ($initializeArguments + '-Force')
    Assert-Equal $forceResult.ExitCode 0 'Environment is restored after relative-tool validation test'

    $environment = Get-Content -Raw -LiteralPath $environmentPath | ConvertFrom-Json
    $environment.sandboxRoot = 'tests'
    Write-JsonFixture $environmentPath $environment
    $relativeRootResult = Invoke-TestScript $validatorPath @('-RepositoryRoot', $toolsProfileRoot, '-Strict')
    Assert-True ($relativeRootResult.ExitCode -ne 0) 'Strict validator rejects relative sandbox and log root registrations'
    $forceResult = Invoke-TestScript $initializePath ($initializeArguments + '-Force')
    Assert-Equal $forceResult.ExitCode 0 'Environment is restored after relative-root validation test'

    $environment = Get-Content -Raw -LiteralPath $environmentPath | ConvertFrom-Json
    $environment.pcId = 'different-machine'
    Write-JsonFixture $environmentPath $environment
    $machineIdentityResult = Invoke-TestScript $validatorPath @('-RepositoryRoot', $toolsProfileRoot, '-Strict')
    Assert-True ($machineIdentityResult.ExitCode -ne 0) 'Strict validator rejects an environment registered for another machine'
    $forceResult = Invoke-TestScript $initializePath ($initializeArguments + '-Force')
    Assert-Equal $forceResult.ExitCode 0 'Environment is restored after machine-identity validation test'

    Write-Utf8NoBomFixture $msdevPath 'fixture-msdev-tampered'
    $hashFailure = Invoke-TestScript $validatorPath @('-RepositoryRoot', $toolsProfileRoot, '-Strict')
    Assert-True ($hashFailure.ExitCode -ne 0) 'Strict validator rejects a mismatched tool hash'
    Assert-True ($hashFailure.Output -match 'FAIL.*MSDEV hash') 'Strict validator emits a failed hash check record'
    Write-Utf8NoBomFixture $msdevPath 'fixture-msdev-v1'
    $forceResult = Invoke-TestScript $initializePath ($initializeArguments + '-Force')
    Assert-Equal $forceResult.ExitCode 0 'Environment hash is restored for task tests'

    $missingProfileResult = Invoke-TestScript $validatorPath @('-RepositoryRoot', $toolsProfileRoot, '-BuildProfileId', 'missing-profile', '-Strict')
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
    Assert-Equal $qualifiedProfileResult.ExitCode 0 'Validator accepts one complete enabled qualification for the registered PC'

    # Start task: fake Bazaar observes only the allowed read-only command set.
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
        '-SpecificationApprover', 'Spec Approver', '-ImplementationApprover', 'Implementation Approver',
        '-RTImpactClear', 'YES', '-SafetyImpactClear', 'YES', '-BoardImpactClear', 'YES', '-DriverImpactClear', 'YES',
        '-ABIImpactClear', 'YES', '-BuildImpactClear', 'YES', '-CustomerBranchImpactClear', 'YES',
        '-AutonomousEditBuildApproved', 'YES', '-SoftExecuteRiskAccepted', 'YES'
    )
    $startResult = Invoke-TestScript $startTaskPath $greenArguments
    Assert-Equal $startResult.ExitCode 0 'Start task creates a work packet for a clean fully approved Green task'
    $workPacketPath = Join-Path $bazaarRoot 'team-bob-work/GREEN-0001/work-packet.md'
    Assert-True (Test-Path -LiteralPath (Join-Path $bazaarRoot 'team-bob-work/GREEN-0001/drafts') -PathType Container) 'Start task creates drafts directory'
    Assert-True (Test-Path -LiteralPath (Join-Path $bazaarRoot 'team-bob-work/GREEN-0001/results') -PathType Container) 'Start task creates results directory'
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

    $metacharArguments = @($greenArguments)
    $metacharArguments[1] = 'GREEN-METACHAR'
    $customerIndex = [array]::IndexOf($metacharArguments, '-Customer')
    $metacharCustomer = 'Customer $1 ${2} $&'
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
    $missingApprovalArguments[1] = 'GREEN-NO-APPROVAL'
    $approvalIndex = [array]::IndexOf($missingApprovalArguments, '-AutonomousEditBuildApproved')
    $missingApprovalArguments[$approvalIndex + 1] = 'NO'
    $missingApprovalResult = Invoke-TestScript $startTaskPath $missingApprovalArguments
    Assert-True ($missingApprovalResult.ExitCode -ne 0) 'Start task refuses Green classification without explicit YES approval'

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

    Remove-Item -LiteralPath $environmentPath
    $missingEnvironmentResult = Invoke-TestScript $validatorPath @('-RepositoryRoot', $toolsProfileRoot, '-Strict')
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
