[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$MsBuildPath,
    [Parameter(Mandatory = $true)][string]$DistributionRoot,
    [Parameter(Mandatory = $true)][string]$SandboxRoot,
    [Parameter(Mandatory = $true)][string]$LogRoot,
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [Parameter(Mandatory = $true)][string]$TemporaryRoot
)

$ErrorActionPreference = 'Stop'

function Get-FixtureHash {
    param([string]$Path)
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Write-FixtureCreateNew {
    param([string]$Path, [string]$Text)
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($Text)
    $stream = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush() } finally { $stream.Dispose() }
}

try {
    foreach ($path in @($MsBuildPath, $DistributionRoot, $SandboxRoot, $LogRoot, $OutputDirectory, $TemporaryRoot)) {
        if (-not [System.IO.Path]::IsPathRooted($path)) { throw "Fixture received a non-absolute path: $path" }
    }
    $sourcePath = Join-Path $DistributionRoot 'demo\adapter\DemoMsdevAdapter.cs'
    $projectPath = Join-Path $DistributionRoot 'demo\CycleWatch\CycleWatch.dsp'
    $vcxProjectPath = Join-Path $DistributionRoot 'demo\CycleWatch\CycleWatch.vcxproj'
    $cycleWatchSourcePath = Join-Path $DistributionRoot 'demo\CycleWatch\src\CycleWatch.cpp'
    $cycleWatchHeaderPath = Join-Path $DistributionRoot 'demo\CycleWatch\include\CycleWatch.h'
    $cycleWatchTestsPath = Join-Path $DistributionRoot 'demo\CycleWatch\tests\CycleWatchTests.cpp'
    foreach ($path in @($MsBuildPath, $sourcePath, $projectPath, $vcxProjectPath, $cycleWatchSourcePath, $cycleWatchHeaderPath, $cycleWatchTestsPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Fixture input is missing: $path" }
    }
    $adapterPath = Join-Path $OutputDirectory 'DemoMsdevAdapter.exe'
    $manifestPath = Join-Path $OutputDirectory 'DemoMsdevAdapter.build-manifest.json'
    Write-FixtureCreateNew $adapterPath "MSBUILD DEMO ADAPTER - NOT VC6 QUALIFICATION`r`nTEST FIXTURE ONLY`r`n"
    $manifest = [ordered]@{
        schemaVersion = '1.0'
        banner = 'MSBUILD DEMO ADAPTER ' + [char]0x2014 + ' NOT VC6 QUALIFICATION'
        adapterSourceRelativePath = 'demo/adapter/DemoMsdevAdapter.cs'
        adapterSourceSha256 = Get-FixtureHash $sourcePath
        generatedConfigurationSha256 = ('1' * 64)
        msBuildPath = [System.IO.Path]::GetFullPath($MsBuildPath).TrimEnd('\', '/')
        msBuildSha256 = Get-FixtureHash $MsBuildPath
        cscPath = [System.IO.Path]::GetFullPath($MsBuildPath).TrimEnd('\', '/')
        cscSha256 = Get-FixtureHash $MsBuildPath
        distributionRoot = [System.IO.Path]::GetFullPath($DistributionRoot).TrimEnd('\', '/')
        sandboxRoot = [System.IO.Path]::GetFullPath($SandboxRoot).TrimEnd('\', '/')
        logRoot = [System.IO.Path]::GetFullPath($LogRoot).TrimEnd('\', '/')
        projectRelativePath = 'demo/CycleWatch/CycleWatch.dsp'
        projectSha256 = Get-FixtureHash $projectPath
        vcxProjectSha256 = Get-FixtureHash $vcxProjectPath
        cycleWatchHeaderSha256 = Get-FixtureHash $cycleWatchHeaderPath
        cycleWatchTestsSha256 = Get-FixtureHash $cycleWatchTestsPath
        cycleWatchTestsLinkerProbeSha256 = ('2' * 64)
        cycleWatchSourceBaselineSha256 = Get-FixtureHash $cycleWatchSourcePath
        cycleWatchSourceThreshold3ErrorSha256 = ('3' * 64)
        cycleWatchSourceThreshold3FixedSha256 = ('4' * 64)
        target = 'CycleWatch - Win32 Release'
        expectedArtifactRelativePath = 'demo/CycleWatch/bin/Release/CycleWatchTests.exe'
        outputFileName = 'DemoMsdevAdapter.exe'
        outputSha256 = Get-FixtureHash $adapterPath
    }
    Write-FixtureCreateNew $manifestPath (($manifest | ConvertTo-Json -Depth 10) + "`r`n")
    Write-FixtureCreateNew (Join-Path $OutputDirectory 'fixture-build-invoked.txt') "MSBUILD DEMO ADAPTER - NOT VC6 QUALIFICATION`r`n"
    Write-Output "MSBUILD DEMO ADAPTER - NOT VC6 QUALIFICATION"
    exit 0
} catch {
    Write-Error $_.Exception.Message
    exit 1
}
