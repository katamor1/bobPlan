[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$AdapterPath,
    [Parameter(Mandatory = $true)][string]$BuildManifestPath,
    [Parameter(Mandatory = $true)][string]$DistributionRoot,
    [Parameter(Mandatory = $true)][string]$SandboxRoot,
    [Parameter(Mandatory = $true)][string]$LogRoot,
    [Parameter(Mandatory = $true)][string]$EvidenceRoot
)

$ErrorActionPreference = 'Stop'

function Get-FixtureHash {
    param([string]$Path)
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Write-FixtureText {
    param([string]$Path, [string]$Text)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { [void][System.IO.Directory]::CreateDirectory($parent) }
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function ConvertTo-FixtureRelativePath {
    param([string]$Path, [string]$Root)
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $pathFull = [System.IO.Path]::GetFullPath($Path)
    if (-not $pathFull.StartsWith($rootFull + '\', [System.StringComparison]::OrdinalIgnoreCase)) { throw 'Fixture path escaped its root.' }
    return $pathFull.Substring($rootFull.Length + 1).Replace('\', '/')
}

function New-FixtureProbe {
    param(
        [string]$Id, [string]$Class, [object]$ExpectedExit, [object]$ObservedExit,
        [bool]$NativeLaunchObserved, [bool]$Passed,
        [string]$LogPath = '', [string]$EvidencePath = '', [string]$ArtifactPath = ''
    )
    return [pscustomobject][ordered]@{
        id = $Id
        class = $Class
        expectedExit = $ExpectedExit
        observedExit = $ObservedExit
        nativeLaunchObserved = $NativeLaunchObserved
        passed = $Passed
        relativeLogPath = $(if ([string]::IsNullOrWhiteSpace($LogPath)) { $null } else { ConvertTo-FixtureRelativePath $LogPath $LogRoot })
        logSha256 = $(if ([string]::IsNullOrWhiteSpace($LogPath)) { $null } else { Get-FixtureHash $LogPath })
        relativeEvidencePath = $(if ([string]::IsNullOrWhiteSpace($EvidencePath)) { $null } else { ConvertTo-FixtureRelativePath $EvidencePath $LogRoot })
        evidenceSha256 = $(if ([string]::IsNullOrWhiteSpace($EvidencePath)) { $null } else { Get-FixtureHash $EvidencePath })
        relativeArtifactPath = $(if ([string]::IsNullOrWhiteSpace($ArtifactPath)) { $null } else { ConvertTo-FixtureRelativePath $ArtifactPath $SandboxRoot })
        artifactSha256 = $(if ([string]::IsNullOrWhiteSpace($ArtifactPath)) { $null } else { Get-FixtureHash $ArtifactPath })
    }
}

try {
    if ($env:TEAM_BOB_DEMO_TEST_QUALIFICATION_MODE -ceq 'fail') { throw 'Intentional fixture qualification failure.' }
    $manifest = [System.IO.File]::ReadAllText($BuildManifestPath, (New-Object System.Text.UTF8Encoding($false, $true))) | ConvertFrom-Json
    $task = 'QUAL-FIXTURE'
    $makeRoot = Join-Path $SandboxRoot "$task\attempt-1-make-10000000000000000000000000000001"
    $rebuildRoot = Join-Path $SandboxRoot "$task\attempt-0-rebuild-20000000000000000000000000000002"
    $artifact = Join-Path $makeRoot 'demo\CycleWatch\bin\Release\CycleWatchTests.exe'
    $rebuildArtifact = Join-Path $rebuildRoot 'demo\CycleWatch\bin\Release\CycleWatchTests.exe'
    Write-FixtureText $artifact "synthetic artifact`r`n"
    Write-FixtureText $rebuildArtifact "synthetic rebuild artifact`r`n"

    $probeData = @{}
    foreach ($name in @('normal-make', 'normal-rebuild', 'compiler-failure', 'linker-failure')) {
        $base = Join-Path $LogRoot "$task\$name"
        $log = Join-Path $base 'build.log'
        $evidence = Join-Path $base 'build.log.evidence.json'
        Write-FixtureText $log "MSBUILD DEMO ADAPTER - NOT VC6 QUALIFICATION`r`nTEAM_BOB_ADAPTER_STATUS=$(if ($name -match 'failure') { 'FAILED' } else { 'SUCCEEDED' })`r`n"
        Write-FixtureText $evidence (([ordered]@{ schemaVersion = '1.0'; banner = 'MSBUILD DEMO ADAPTER ' + [char]0x2014 + ' NOT VC6 QUALIFICATION'; fixture = $name } | ConvertTo-Json) + "`r`n")
        $probeData[$name] = [pscustomobject]@{ Log = $log; Evidence = $evidence }
    }

    $passed = $env:TEAM_BOB_DEMO_TEST_QUALIFICATION_MODE -cne 'probe-fail'
    $eligible = $passed -and $env:TEAM_BOB_DEMO_TEST_QUALIFICATION_MODE -cne 'incomplete'
    $probes = @(
        New-FixtureProbe 'help' 'protocol' 0 0 $false $passed
        New-FixtureProbe 'msbuild-hash' 'integrity' 0 0 $false $passed
        New-FixtureProbe 'normal-make' 'build' 0 0 $true $passed $probeData['normal-make'].Log $probeData['normal-make'].Evidence $artifact
        New-FixtureProbe 'normal-rebuild' 'build' 0 0 $true $passed $probeData['normal-rebuild'].Log $probeData['normal-rebuild'].Evidence $rebuildArtifact
        New-FixtureProbe 'compiler-failure' 'compiler' 1 1 $true $passed $probeData['compiler-failure'].Log $probeData['compiler-failure'].Evidence
        New-FixtureProbe 'linker-failure' 'linker' 1 1 $true $passed $probeData['linker-failure'].Log $probeData['linker-failure'].Evidence
        New-FixtureProbe 'artifact-presence' 'artifact' 0 0 $false $passed $probeData['normal-make'].Log $probeData['normal-make'].Evidence $artifact
        New-FixtureProbe 'invalid-target-no-launch' 'allowlist' 20 20 $false $passed
        New-FixtureProbe 'invalid-input-no-launch' 'allowlist' 20 20 $false $passed
    )
    $now = [DateTimeOffset]::UtcNow.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
    $record = [ordered]@{
        schemaVersion = '1.0'
        banner = 'MSBUILD DEMO ADAPTER ' + [char]0x2014 + ' NOT VC6 QUALIFICATION'
        recordType = 'RAW_PROTOCOL_EVIDENCE_ONLY'
        qualificationEligible = $eligible
        approved = $false
        vc6Qualified = $false
        pcId = [Environment]::MachineName
        visualStudio = [ordered]@{ isComplete = $eligible; isLaunchable = $eligible }
        adapterPath = [System.IO.Path]::GetFullPath($AdapterPath).TrimEnd('\', '/')
        buildManifestPath = [System.IO.Path]::GetFullPath($BuildManifestPath).TrimEnd('\', '/')
        adapterSha256 = Get-FixtureHash $AdapterPath
        msBuildPath = [string]$manifest.msBuildPath
        msBuildSha256 = [string]$manifest.msBuildSha256
        projectSha256 = [string]$manifest.projectSha256
        vcxProjectSha256 = [string]$manifest.vcxProjectSha256
        cycleWatchHeaderSha256 = [string]$manifest.cycleWatchHeaderSha256
        cycleWatchTestsSha256 = [string]$manifest.cycleWatchTestsSha256
        cycleWatchTestsLinkerProbeSha256 = [string]$manifest.cycleWatchTestsLinkerProbeSha256
        cycleWatchSourceBaselineSha256 = [string]$manifest.cycleWatchSourceBaselineSha256
        cycleWatchSourceThreshold3ErrorSha256 = [string]$manifest.cycleWatchSourceThreshold3ErrorSha256
        cycleWatchSourceThreshold3FixedSha256 = [string]$manifest.cycleWatchSourceThreshold3FixedSha256
        sandboxRoot = [System.IO.Path]::GetFullPath($SandboxRoot).TrimEnd('\', '/')
        logRoot = [System.IO.Path]::GetFullPath($LogRoot).TrimEnd('\', '/')
        evidenceRoot = [System.IO.Path]::GetFullPath($EvidenceRoot).TrimEnd('\', '/')
        startedAt = $now
        finishedAt = $now
        passed = $passed
        probes = $probes
    }
    $recordPath = Join-Path $EvidenceRoot 'demo-adapter-qualification.json'
    Write-FixtureText $recordPath (($record | ConvertTo-Json -Depth 20) + "`r`n")
    if ($env:TEAM_BOB_DEMO_TEST_QUALIFICATION_MODE -ceq 'mutate-distribution-bzr') {
        [System.IO.File]::AppendAllText(
            (Join-Path $DistributionRoot '.bzr\sentinel'),
            "INTENTIONAL DISTRIBUTION MUTATION`r`n",
            (New-Object System.Text.UTF8Encoding($false))
        )
    }
    Write-Output 'MSBUILD DEMO ADAPTER - NOT VC6 QUALIFICATION'
    if ($passed) { exit 0 }
    exit 1
} catch {
    Write-Error $_.Exception.Message
    exit 2
}
