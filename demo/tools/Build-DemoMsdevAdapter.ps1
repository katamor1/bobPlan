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

function Get-DemoBuildFullLocalPath {
    param([string]$Value, [string]$Label)

    if ([string]::IsNullOrWhiteSpace($Value) -or $Value.StartsWith('\\') -or $Value.StartsWith('//') -or
        $Value.IndexOfAny([char[]]@([char]0, [char]13, [char]10)) -ge 0 -or
        -not [regex]::IsMatch($Value, '^[A-Za-z]:[\\/]')) {
        throw "$Label must be an absolute non-UNC local-drive path."
    }
    $full = [System.IO.Path]::GetFullPath($Value).TrimEnd('\', '/')
    $volumeRoot = [System.IO.Path]::GetPathRoot($full).TrimEnd('\', '/')
    if ($full.Equals($volumeRoot, [System.StringComparison]::OrdinalIgnoreCase)) { throw "$Label must not be a volume root." }
    $drive = New-Object System.IO.DriveInfo([System.IO.Path]::GetPathRoot($full))
    if (-not $drive.IsReady -or $drive.DriveType -ne [System.IO.DriveType]::Fixed) { throw "$Label must use a ready fixed local drive." }
    return $full
}

function Assert-DemoBuildNoReparse {
    param([string]$Path, [string]$Label)

    $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $root = [System.IO.Path]::GetPathRoot($full)
    $current = $root
    foreach ($component in $full.Substring($root.Length).Split([char[]]@('\', '/'), [System.StringSplitOptions]::RemoveEmptyEntries)) {
        $current = Join-Path $current $component
        if (Test-Path -LiteralPath $current) {
            $attributes = [System.IO.File]::GetAttributes($current)
            if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw "$Label contains a reparse point: $current" }
        }
    }
}

function Assert-DemoBuildDirectory {
    param([string]$Path, [string]$Label)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "$Label must be an existing directory: $Path" }
    Assert-DemoBuildNoReparse $Path $Label
}

function Assert-DemoBuildFile {
    param([string]$Path, [string]$Label)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "$Label must be an existing file: $Path" }
    Assert-DemoBuildNoReparse $Path $Label
}

function Test-DemoBuildAtOrBelow {
    param([string]$Path, [string]$Root)
    return $Path.Equals($Root, [System.StringComparison]::OrdinalIgnoreCase) -or
        $Path.StartsWith($Root + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)
}

function Assert-DemoBuildSeparate {
    param([string]$Left, [string]$Right, [string]$Label)
    if ((Test-DemoBuildAtOrBelow $Left $Right) -or (Test-DemoBuildAtOrBelow $Right $Left)) { throw "$Label must not overlap." }
}

function Get-DemoBuildSha256 {
    param([string]$Path)
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Get-DemoBuildBytesSha256 {
    param([byte[]]$Bytes)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha256.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha256.Dispose() }
}

function Replace-DemoBuildExactOnce {
    param([string]$Text, [string]$Needle, [string]$Replacement, [string]$Label)
    if ([regex]::Matches($Text, [regex]::Escape($Needle)).Count -ne 1) { throw "$Label must occur exactly once in the checked-in baseline." }
    return $Text.Replace($Needle, $Replacement)
}

function ConvertTo-DemoBuildCSharpLiteral {
    param([string]$Value)
    return '@"' + $Value.Replace('"', '""') + '"'
}

function Write-DemoBuildUtf8NoBom {
    param([string]$Path, [string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Write-DemoBuildUtf8NoBomCreateNew {
    param([string]$Path, [string]$Text, [ref]$Owned)
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($Text)
    $stream = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    $Owned.Value = $true
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush() } finally { $stream.Dispose() }
}

function Copy-DemoBuildFileCreateNew {
    param([string]$Source, [string]$Destination, [ref]$Owned)
    $sourceStream = New-Object System.IO.FileStream($Source, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    try {
        $destinationStream = New-Object System.IO.FileStream($Destination, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $Owned.Value = $true
        try { $sourceStream.CopyTo($destinationStream); $destinationStream.Flush() } finally { $destinationStream.Dispose() }
    } finally { $sourceStream.Dispose() }
}

function Remove-DemoBuildOwnedFile {
    param([string]$Path, [string]$Root, [string]$ExpectedHash, [string]$Label)
    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($Root)) { throw "$Label has no verified path or root." }
    if ([string]::IsNullOrWhiteSpace($ExpectedHash)) { throw "$Label has no expected hash; retaining it." }
    $pathFull = [System.IO.Path]::GetFullPath($Path)
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    if (-not ([System.IO.Path]::GetDirectoryName($pathFull).Equals($rootFull, [System.StringComparison]::OrdinalIgnoreCase))) {
        throw "$Label escaped its verified direct parent; retaining it: $pathFull"
    }
    Assert-DemoBuildNoReparse $rootFull "$Label parent before removal"
    if (Test-Path -LiteralPath $pathFull -PathType Leaf) {
        Assert-DemoBuildNoReparse $pathFull "$Label before removal"
        $observedHash = Get-DemoBuildSha256 $pathFull
        if ($observedHash -cne $ExpectedHash) { throw "$Label hash changed; retaining it: $pathFull" }
        [System.IO.File]::Delete($pathFull)
    } elseif (Test-Path -LiteralPath $pathFull) {
        throw "$Label changed type; retaining it: $pathFull"
    }
}

$buildDirectory = $null
$temporaryOutput = $null
$configurationPath = $null
$outputPath = $null
$manifestPath = $null
$outputTemporaryPath = $null
$manifestTemporaryPath = $null
$outputTemporaryOwned = $false
$manifestTemporaryOwned = $false
$outputPublishedByThisRun = $false
$manifestPublishedByThisRun = $false
$outputExpectedHash = $null
$manifestExpectedHash = $null
$temporaryFull = $null
$outputFull = $null
$failureMessage = $null
$preparationCompleted = $false
$buildCompleted = $false

try {
    $msBuildFull = Get-DemoBuildFullLocalPath $MsBuildPath 'MsBuildPath'
    $distributionFull = Get-DemoBuildFullLocalPath $DistributionRoot 'DistributionRoot'
    $sandboxFull = Get-DemoBuildFullLocalPath $SandboxRoot 'SandboxRoot'
    $logFull = Get-DemoBuildFullLocalPath $LogRoot 'LogRoot'
    $outputFull = Get-DemoBuildFullLocalPath $OutputDirectory 'OutputDirectory'
    $temporaryFull = Get-DemoBuildFullLocalPath $TemporaryRoot 'TemporaryRoot'

    Assert-DemoBuildFile $msBuildFull 'MsBuildPath'
    foreach ($entry in @(
        @{ Path = $distributionFull; Label = 'DistributionRoot' }, @{ Path = $sandboxFull; Label = 'SandboxRoot' },
        @{ Path = $logFull; Label = 'LogRoot' }, @{ Path = $outputFull; Label = 'OutputDirectory' },
        @{ Path = $temporaryFull; Label = 'TemporaryRoot' }
    )) { Assert-DemoBuildDirectory $entry.Path $entry.Label }

    $roots = @($distributionFull, $sandboxFull, $logFull, $outputFull, $temporaryFull)
    for ($leftIndex = 0; $leftIndex -lt $roots.Count; $leftIndex++) {
        for ($rightIndex = $leftIndex + 1; $rightIndex -lt $roots.Count; $rightIndex++) {
            Assert-DemoBuildSeparate $roots[$leftIndex] $roots[$rightIndex] 'Build roots'
        }
    }

    $cscFull = Join-Path (Split-Path -Parent $msBuildFull) 'Roslyn\csc.exe'
    Assert-DemoBuildFile $cscFull 'Roslyn compiler adjacent to selected MSBuild'

    $sourcePath = Join-Path $distributionFull 'demo\adapter\DemoMsdevAdapter.cs'
    $projectPath = Join-Path $distributionFull 'demo\CycleWatch\CycleWatch.dsp'
    $vcxProjectPath = Join-Path $distributionFull 'demo\CycleWatch\CycleWatch.vcxproj'
    Assert-DemoBuildFile $sourcePath 'Adapter source'
    Assert-DemoBuildFile $projectPath 'Synthetic DSP protocol token'
    Assert-DemoBuildFile $vcxProjectPath 'Synthetic VCX project'

    $cp932 = [System.Text.Encoding]::GetEncoding(932, (New-Object System.Text.EncoderExceptionFallback), (New-Object System.Text.DecoderExceptionFallback))
    $projectText = $cp932.GetString([System.IO.File]::ReadAllBytes($projectPath))
    if (-not $projectText.Contains('TEAM_BOB_MSBUILD_DEMO_PROTOCOL_V1_NOT_VC6')) { throw 'Synthetic DSP is missing the required adapter protocol marker.' }
    if ($projectText -match '(?i)Microsoft Developer Studio (?:Project|Workspace) File') { throw 'A real VC6 project/workspace signature is forbidden.' }

    $cycleWatchSourcePath = Join-Path $distributionFull 'demo\CycleWatch\src\CycleWatch.cpp'
    $headerPath = Join-Path $distributionFull 'demo\CycleWatch\include\CycleWatch.h'
    $testsPath = Join-Path $distributionFull 'demo\CycleWatch\tests\CycleWatchTests.cpp'
    Assert-DemoBuildFile $cycleWatchSourcePath 'CycleWatch source baseline'
    Assert-DemoBuildFile $headerPath 'CycleWatch header baseline'
    Assert-DemoBuildFile $testsPath 'CycleWatch tests baseline'
    $sourceText = $cp932.GetString([System.IO.File]::ReadAllBytes($cycleWatchSourcePath))
    $thresholdOne = 'if (consecutiveOverruns_ >= 1U) {'
    $thresholdThree = 'if (consecutiveOverruns_ >= 3U) {'
    $faultLine = '#error MSBUILD_DEMO_ADAPTER_INTENTIONAL_COMPILER_FAULT "demo/CycleWatch/src/CycleWatch.cpp" AFTER_EVIDENCE_REPLACE_THIS_EXACT_LINE_WITH: #pragma message("MSBUILD_DEMO_ADAPTER_INTENTIONAL_FAULT_REPAIRED demo/CycleWatch/src/CycleWatch.cpp")'
    $fixedLine = '#pragma message("MSBUILD_DEMO_ADAPTER_INTENTIONAL_FAULT_REPAIRED demo/CycleWatch/src/CycleWatch.cpp")'
    $thresholdThreeErrorText = Replace-DemoBuildExactOnce $sourceText $thresholdOne $thresholdThree 'CycleWatch threshold-one baseline'
    $thresholdThreeFixedText = Replace-DemoBuildExactOnce $thresholdThreeErrorText $faultLine $fixedLine 'CycleWatch artificial fault baseline'
    $testsText = $cp932.GetString([System.IO.File]::ReadAllBytes($testsPath))
    $linkNeedle = 'int main() {'
    $linkReplacement = 'extern "C" void TEAM_BOB_DEMO_MISSING_LINK_SYMBOL();' + "`r`n`r`n" + $linkNeedle + "`r`n    TEAM_BOB_DEMO_MISSING_LINK_SYMBOL();"
    $linkerProbeTestsText = Replace-DemoBuildExactOnce $testsText $linkNeedle $linkReplacement 'CycleWatch linker-probe main function'
    $sourceBaselineHash = Get-DemoBuildBytesSha256 ($cp932.GetBytes($sourceText))
    if ($sourceBaselineHash -cne (Get-DemoBuildSha256 $cycleWatchSourcePath)) { throw 'CycleWatch source baseline encoding round-trip changed bytes.' }
    $sourceThresholdThreeErrorHash = Get-DemoBuildBytesSha256 ($cp932.GetBytes($thresholdThreeErrorText))
    $sourceThresholdThreeFixedHash = Get-DemoBuildBytesSha256 ($cp932.GetBytes($thresholdThreeFixedText))
    $headerHash = Get-DemoBuildSha256 $headerPath
    $testsHash = Get-DemoBuildSha256 $testsPath
    $testsLinkerProbeHash = Get-DemoBuildBytesSha256 ($cp932.GetBytes($linkerProbeTestsText))

    $outputPath = Join-Path $outputFull 'DemoMsdevAdapter.exe'
    $manifestPath = Join-Path $outputFull 'DemoMsdevAdapter.build-manifest.json'
    if (Test-Path -LiteralPath $outputPath) { throw "Adapter output already exists: $outputPath" }
    if (Test-Path -LiteralPath $manifestPath) { throw "Adapter build manifest already exists: $manifestPath" }

    $configurationLines = @(
        'internal static class DemoAdapterConfiguration',
        '{',
        ('    internal const string MsBuildPath = ' + (ConvertTo-DemoBuildCSharpLiteral $msBuildFull) + ';'),
        ('    internal const string MsBuildSha256 = ' + (ConvertTo-DemoBuildCSharpLiteral (Get-DemoBuildSha256 $msBuildFull)) + ';'),
        ('    internal const string SandboxRoot = ' + (ConvertTo-DemoBuildCSharpLiteral $sandboxFull) + ';'),
        ('    internal const string LogRoot = ' + (ConvertTo-DemoBuildCSharpLiteral $logFull) + ';'),
        '    internal const string ProjectRelativePath = "demo/CycleWatch/CycleWatch.dsp";',
        ('    internal const string ProjectSha256 = ' + (ConvertTo-DemoBuildCSharpLiteral (Get-DemoBuildSha256 $projectPath)) + ';'),
        ('    internal const string VcxProjectSha256 = ' + (ConvertTo-DemoBuildCSharpLiteral (Get-DemoBuildSha256 $vcxProjectPath)) + ';'),
        ('    internal const string CycleWatchHeaderSha256 = ' + (ConvertTo-DemoBuildCSharpLiteral $headerHash) + ';'),
        ('    internal const string CycleWatchTestsSha256 = ' + (ConvertTo-DemoBuildCSharpLiteral $testsHash) + ';'),
        ('    internal const string CycleWatchTestsLinkerProbeSha256 = ' + (ConvertTo-DemoBuildCSharpLiteral $testsLinkerProbeHash) + ';'),
        ('    internal const string CycleWatchSourceBaselineSha256 = ' + (ConvertTo-DemoBuildCSharpLiteral $sourceBaselineHash) + ';'),
        ('    internal const string CycleWatchSourceThreshold3ErrorSha256 = ' + (ConvertTo-DemoBuildCSharpLiteral $sourceThresholdThreeErrorHash) + ';'),
        ('    internal const string CycleWatchSourceThreshold3FixedSha256 = ' + (ConvertTo-DemoBuildCSharpLiteral $sourceThresholdThreeFixedHash) + ';'),
        '    internal const string Target = "CycleWatch - Win32 Release";',
        '    internal const string ExpectedArtifactRelativePath = "demo/CycleWatch/bin/Release/CycleWatchTests.exe";',
        '}',
        ''
    )
    $configurationText = $configurationLines -join "`r`n"
    $configurationBytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($configurationText)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try { $configurationHash = ([BitConverter]::ToString($sha256.ComputeHash($configurationBytes))).Replace('-', '').ToLowerInvariant() } finally { $sha256.Dispose() }

    $buildDirectory = Join-Path $temporaryFull ('adapter-build-' + [guid]::NewGuid().ToString('N'))
    if (Test-Path -LiteralPath $buildDirectory) { throw "Compiler temporary directory unexpectedly exists: $buildDirectory" }
    [void][System.IO.Directory]::CreateDirectory($buildDirectory)
    Assert-DemoBuildNoReparse $buildDirectory 'Compiler temporary directory'
    if (-not (Test-DemoBuildAtOrBelow $buildDirectory $temporaryFull)) { throw 'Compiler temporary directory escaped TemporaryRoot.' }
    $configurationPath = Join-Path $buildDirectory 'DemoAdapterConfiguration.g.cs'
    $temporaryOutput = Join-Path $buildDirectory 'DemoMsdevAdapter.exe'
    Write-DemoBuildUtf8NoBom $configurationPath $configurationText

    $compilerArguments = @(
        '/nologo', '/noconfig', '/target:exe', '/optimize+', '/deterministic+', '/debug-', '/platform:anycpu',
        '/reference:System.dll', '/reference:System.Core.dll',
        ('/pathmap:' + $buildDirectory + '=/_generated'), ('/out:' + $temporaryOutput), $sourcePath, $configurationPath
    )
    $compilerOutput = & $cscFull @compilerArguments 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $temporaryOutput -PathType Leaf)) {
        throw "Roslyn adapter compilation failed with exit code $LASTEXITCODE. $($compilerOutput.Trim())"
    }
    Assert-DemoBuildNoReparse $temporaryOutput 'Compiled adapter output'
    $outputExpectedHash = Get-DemoBuildSha256 $temporaryOutput

    $outputTemporaryPath = Join-Path $outputFull ('.DemoMsdevAdapter.' + [guid]::NewGuid().ToString('N') + '.exe.tmp')
    if (Test-Path -LiteralPath $outputTemporaryPath) { throw "Adapter temporary path unexpectedly exists: $outputTemporaryPath" }
    Copy-DemoBuildFileCreateNew $temporaryOutput $outputTemporaryPath ([ref]$outputTemporaryOwned)
    Assert-DemoBuildFile $outputTemporaryPath 'Prepared adapter output'
    if ((Get-DemoBuildSha256 $outputTemporaryPath) -cne $outputExpectedHash) { throw 'Prepared adapter output hash changed.' }

    $unicodeBanner = 'MSBUILD DEMO ADAPTER ' + [char]0x2014 + ' NOT VC6 QUALIFICATION'
    $manifest = [ordered]@{
        schemaVersion = '1.0'
        banner = $unicodeBanner
        adapterSourceRelativePath = 'demo/adapter/DemoMsdevAdapter.cs'
        adapterSourceSha256 = Get-DemoBuildSha256 $sourcePath
        generatedConfigurationSha256 = $configurationHash
        msBuildPath = $msBuildFull
        msBuildSha256 = Get-DemoBuildSha256 $msBuildFull
        cscPath = $cscFull
        cscSha256 = Get-DemoBuildSha256 $cscFull
        distributionRoot = $distributionFull
        sandboxRoot = $sandboxFull
        logRoot = $logFull
        projectRelativePath = 'demo/CycleWatch/CycleWatch.dsp'
        projectSha256 = Get-DemoBuildSha256 $projectPath
        vcxProjectSha256 = Get-DemoBuildSha256 $vcxProjectPath
        cycleWatchHeaderSha256 = $headerHash
        cycleWatchTestsSha256 = $testsHash
        cycleWatchTestsLinkerProbeSha256 = $testsLinkerProbeHash
        cycleWatchSourceBaselineSha256 = $sourceBaselineHash
        cycleWatchSourceThreshold3ErrorSha256 = $sourceThresholdThreeErrorHash
        cycleWatchSourceThreshold3FixedSha256 = $sourceThresholdThreeFixedHash
        target = 'CycleWatch - Win32 Release'
        expectedArtifactRelativePath = 'demo/CycleWatch/bin/Release/CycleWatchTests.exe'
        outputFileName = 'DemoMsdevAdapter.exe'
        outputSha256 = $outputExpectedHash
    }
    $manifestTemporaryPath = Join-Path $outputFull ('.DemoMsdevAdapter.build-manifest.' + [guid]::NewGuid().ToString('N') + '.tmp')
    if (Test-Path -LiteralPath $manifestTemporaryPath) { throw "Manifest temporary path unexpectedly exists: $manifestTemporaryPath" }
    Write-DemoBuildUtf8NoBomCreateNew $manifestTemporaryPath (($manifest | ConvertTo-Json -Depth 4) + "`r`n") ([ref]$manifestTemporaryOwned)
    $manifestExpectedHash = Get-DemoBuildSha256 $manifestTemporaryPath
    $preparationCompleted = $true
} catch {
    $failureMessage = $_.Exception.Message
} finally {
    if ($null -ne $buildDirectory -and (Test-Path -LiteralPath $buildDirectory -PathType Container)) {
        try {
            $verifiedBuildDirectory = [System.IO.Path]::GetFullPath($buildDirectory).TrimEnd('\', '/')
            if ($null -eq $temporaryFull -or -not (Test-DemoBuildAtOrBelow $verifiedBuildDirectory $temporaryFull) -or $verifiedBuildDirectory.Equals($temporaryFull, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "Refusing to clean unverified compiler temporary directory: $verifiedBuildDirectory"
            }
            Assert-DemoBuildNoReparse $temporaryFull 'TemporaryRoot before cleanup'
            Assert-DemoBuildNoReparse $verifiedBuildDirectory 'Compiler temporary directory before cleanup'
            $knownPaths = @()
            foreach ($knownPath in @($configurationPath, $temporaryOutput)) {
                if ($null -ne $knownPath) { $knownPaths += [System.IO.Path]::GetFullPath($knownPath) }
            }
            $unknownEntries = @(Get-ChildItem -LiteralPath $verifiedBuildDirectory -Force | Where-Object { $knownPaths -notcontains [System.IO.Path]::GetFullPath($_.FullName) })
            foreach ($knownPath in $knownPaths) {
                if (Test-Path -LiteralPath $knownPath -PathType Leaf) {
                    Assert-DemoBuildNoReparse $knownPath 'Known compiler temporary file before cleanup'
                    [System.IO.File]::Delete($knownPath)
                } elseif (Test-Path -LiteralPath $knownPath) {
                    throw "Known compiler temporary path changed type; retained: $knownPath"
                }
            }
            if ($unknownEntries.Count -gt 0) {
                throw ('Unknown compiler temporary entries were retained: ' + (($unknownEntries | ForEach-Object Name) -join ', '))
            }
            if (@(Get-ChildItem -LiteralPath $verifiedBuildDirectory -Force).Count -eq 0) { [System.IO.Directory]::Delete($verifiedBuildDirectory, $false) }
        } catch {
            if ($null -eq $failureMessage) { $failureMessage = $_.Exception.Message }
            else { $failureMessage += ' Cleanup failure: ' + $_.Exception.Message }
            $preparationCompleted = $false
        }
    }
}

if (-not $preparationCompleted) {
    foreach ($ownedTemporary in @(
        @{ Owned = $manifestTemporaryOwned; Path = $manifestTemporaryPath; Hash = $manifestExpectedHash; Label = 'Owned manifest temporary file' },
        @{ Owned = $outputTemporaryOwned; Path = $outputTemporaryPath; Hash = $outputExpectedHash; Label = 'Owned adapter temporary file' }
    )) {
        if (-not $ownedTemporary.Owned) { continue }
        try {
            Remove-DemoBuildOwnedFile $ownedTemporary.Path $outputFull $ownedTemporary.Hash $ownedTemporary.Label
        } catch {
            if ($null -eq $failureMessage) { $failureMessage = $_.Exception.Message }
            else { $failureMessage += ' Temporary cleanup failure: ' + $_.Exception.Message }
        }
    }
    if ([string]::IsNullOrWhiteSpace($failureMessage)) { $failureMessage = 'Adapter build preparation did not complete.' }
    [Console]::Error.WriteLine($failureMessage)
    exit 1
}

try {
    Assert-DemoBuildDirectory $outputFull 'OutputDirectory before publication'
    Assert-DemoBuildFile $outputTemporaryPath 'Prepared adapter output before publication'
    Assert-DemoBuildFile $manifestTemporaryPath 'Prepared manifest before publication'
    if ((Get-DemoBuildSha256 $outputTemporaryPath) -cne $outputExpectedHash) { throw 'Prepared adapter output hash changed before publication.' }
    if ((Get-DemoBuildSha256 $manifestTemporaryPath) -cne $manifestExpectedHash) { throw 'Prepared manifest hash changed before publication.' }
    if (Test-Path -LiteralPath $outputPath) { throw "Adapter output appeared before publication: $outputPath" }

    [System.IO.File]::Move($outputTemporaryPath, $outputPath)
    $outputTemporaryOwned = $false
    $outputPublishedByThisRun = $true

    [System.IO.File]::Move($manifestTemporaryPath, $manifestPath)
    $manifestTemporaryOwned = $false
    $manifestPublishedByThisRun = $true
    $buildCompleted = $true
} catch {
    $failureMessage = $_.Exception.Message
} finally {
    if (-not $buildCompleted -and -not $manifestPublishedByThisRun -and $outputPublishedByThisRun) {
        try {
            Remove-DemoBuildOwnedFile $outputPath $outputFull $outputExpectedHash 'Owned published adapter output'
            $outputPublishedByThisRun = $false
        } catch {
            if ($null -eq $failureMessage) { $failureMessage = $_.Exception.Message }
            else { $failureMessage += ' Published-output rollback failure: ' + $_.Exception.Message }
        }
    }
    foreach ($ownedTemporary in @(
        @{ Owned = $manifestTemporaryOwned; Path = $manifestTemporaryPath; Hash = $manifestExpectedHash; Label = 'Owned manifest temporary file' },
        @{ Owned = $outputTemporaryOwned; Path = $outputTemporaryPath; Hash = $outputExpectedHash; Label = 'Owned adapter temporary file' }
    )) {
        if (-not $ownedTemporary.Owned) { continue }
        try {
            Remove-DemoBuildOwnedFile $ownedTemporary.Path $outputFull $ownedTemporary.Hash $ownedTemporary.Label
        } catch {
            if ($null -eq $failureMessage) { $failureMessage = $_.Exception.Message }
            else { $failureMessage += ' Temporary cleanup failure: ' + $_.Exception.Message }
        }
    }
}

if (-not $buildCompleted) {
    if ([string]::IsNullOrWhiteSpace($failureMessage)) { $failureMessage = 'Adapter build did not complete.' }
    [Console]::Error.WriteLine($failureMessage)
    exit 1
}
Write-Output "BUILT $outputPath"
Write-Output "MANIFEST $manifestPath"
exit 0
