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

function Get-DemoQualificationFullLocalPath {
    param([string]$Value, [string]$Label)
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value.StartsWith('\\') -or $Value.StartsWith('//') -or
        $Value.IndexOfAny([char[]]@([char]0, [char]13, [char]10)) -ge 0 -or
        -not [regex]::IsMatch($Value, '^[A-Za-z]:[\\/]')) { throw "$Label must be an absolute non-UNC local-drive path." }
    $full = [System.IO.Path]::GetFullPath($Value).TrimEnd('\', '/')
    $root = [System.IO.Path]::GetPathRoot($full)
    if ($full.Equals($root.TrimEnd('\', '/'), [System.StringComparison]::OrdinalIgnoreCase)) { throw "$Label must not be a volume root." }
    $drive = New-Object System.IO.DriveInfo($root)
    if (-not $drive.IsReady -or $drive.DriveType -ne [System.IO.DriveType]::Fixed) { throw "$Label must use a ready fixed local drive." }
    return $full
}

function Assert-DemoQualificationNoReparse {
    param([string]$Path, [string]$Label)
    $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $root = [System.IO.Path]::GetPathRoot($full)
    $current = $root
    foreach ($component in $full.Substring($root.Length).Split([char[]]@('\', '/'), [System.StringSplitOptions]::RemoveEmptyEntries)) {
        $current = Join-Path $current $component
        if (Test-Path -LiteralPath $current) {
            if (([System.IO.File]::GetAttributes($current) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw "$Label contains a reparse point: $current" }
        }
    }
}

function Assert-DemoQualificationFile {
    param([string]$Path, [string]$Label)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "$Label is missing: $Path" }
    Assert-DemoQualificationNoReparse $Path $Label
}

function Assert-DemoQualificationDirectory {
    param([string]$Path, [string]$Label)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "$Label is missing: $Path" }
    Assert-DemoQualificationNoReparse $Path $Label
}

function Test-DemoQualificationAtOrBelow {
    param([string]$Path, [string]$Root)
    return $Path.Equals($Root, [System.StringComparison]::OrdinalIgnoreCase) -or
        $Path.StartsWith($Root + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)
}

function Assert-DemoQualificationSeparate {
    param([string]$Left, [string]$Right, [string]$Label)
    if ((Test-DemoQualificationAtOrBelow $Left $Right) -or (Test-DemoQualificationAtOrBelow $Right $Left)) { throw "$Label must not overlap." }
}

function Get-DemoQualificationHash {
    param([string]$Path)
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Get-DemoQualificationSourceVariant {
    param([string]$Hash, [object]$Manifest)
    if ($Hash -ceq [string]$Manifest.cycleWatchSourceBaselineSha256) { return 'baseline-error' }
    if ($Hash -ceq [string]$Manifest.cycleWatchSourceThreshold3ErrorSha256) { return 'threshold3-error' }
    if ($Hash -ceq [string]$Manifest.cycleWatchSourceThreshold3FixedSha256) { return 'threshold3-fixed' }
    return $null
}

function Assert-DemoQualificationProperties {
    param([object]$Value, [string[]]$Expected, [string]$Label)
    $actual = @($Value.PSObject.Properties.Name | Sort-Object)
    $wanted = @($Expected | Sort-Object)
    if (($actual -join ',') -cne ($wanted -join ',')) { throw "$Label has an unexpected field set." }
}

function Copy-DemoQualificationTree {
    param([string]$Source, [string]$Destination)
    if (Test-Path -LiteralPath $Destination) { throw "Qualification destination already exists: $Destination" }
    [void][System.IO.Directory]::CreateDirectory($Destination)
    $sourceFull = [System.IO.Path]::GetFullPath($Source).TrimEnd('\', '/')
    $pending = New-Object System.Collections.ArrayList
    [void]$pending.Add($sourceFull)
    while ($pending.Count -gt 0) {
        $directory = [string]$pending[0]
        $pending.RemoveAt(0)
        foreach ($item in @(Get-ChildItem -LiteralPath $directory -Force | Sort-Object Name)) {
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Qualification source contains a reparse point: $($item.FullName)" }
            $relative = $item.FullName.Substring($sourceFull.Length).TrimStart('\', '/')
            $target = Join-Path $Destination $relative
            if ($item.PSIsContainer) {
                [void][System.IO.Directory]::CreateDirectory($target)
                [void]$pending.Add($item.FullName)
            } else {
                [System.IO.File]::Copy($item.FullName, $target, $false)
            }
        }
    }
}

function New-DemoQualificationInvocation {
    param([string]$Id, [int]$Attempt, [string]$Action, [string]$Token)
    $taskId = 'ADAPTER-QUALIFY'
    $invocationId = "attempt-$Attempt-$Action-$Token"
    $invocationRoot = Join-Path (Join-Path $script:QualificationSandboxRoot $taskId) $invocationId
    $projectDirectory = Join-Path $invocationRoot 'demo\CycleWatch'
    $logDirectory = Join-Path (Join-Path $script:QualificationLogRoot $taskId) $invocationId
    if (Test-Path -LiteralPath $invocationRoot) { throw "Qualification sandbox invocation already exists: $invocationId" }
    if (Test-Path -LiteralPath $logDirectory) { throw "Qualification log invocation already exists: $invocationId" }
    [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $invocationRoot))
    [void][System.IO.Directory]::CreateDirectory($logDirectory)
    Copy-DemoQualificationTree (Join-Path $script:QualificationDistributionRoot 'demo\CycleWatch') $projectDirectory
    return [pscustomobject]@{
        Id = $Id; TaskId = $taskId; InvocationId = $invocationId; Root = $invocationRoot
        ProjectDirectory = $projectDirectory; ProjectPath = (Join-Path $projectDirectory 'CycleWatch.dsp')
        LogPath = (Join-Path $logDirectory 'build.log'); EvidencePath = (Join-Path $logDirectory 'build.log.evidence.json')
        ArtifactPath = (Join-Path $projectDirectory 'bin\Release\CycleWatchTests.exe')
    }
}

function Invoke-DemoQualificationAdapter {
    param([string[]]$Arguments)
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $script:QualificationAdapterPath @Arguments 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $savedPreference }
    return [pscustomobject]@{ ExitCode = $exitCode; Output = $output }
}

function ConvertTo-DemoQualificationRelativePath {
    param([string]$Path, [string]$Root)
    $full = [System.IO.Path]::GetFullPath($Path)
    if (-not $full.StartsWith($Root + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) { throw "Evidence path escaped its root: $full" }
    return $full.Substring($Root.Length).TrimStart('\', '/').Replace('\', '/')
}

function Get-DemoQualificationEvidenceState {
    param([object]$Invocation)
    if (-not (Test-Path -LiteralPath $Invocation.EvidencePath -PathType Leaf)) { return $null }
    return ([System.IO.File]::ReadAllText($Invocation.EvidencePath, (New-Object System.Text.UTF8Encoding($false, $true))) | ConvertFrom-Json)
}

function Get-DemoQualificationValidatedEvidence {
    param(
        [object]$Invocation, [string]$Action, [int]$Attempt, [bool]$FaultInjected,
        [string]$Status, [int]$NativeExitCode, [object]$Manifest, [string]$AdapterHash,
        [switch]$RequireArtifact
    )
    try {
        $evidence = Get-DemoQualificationEvidenceState $Invocation
        if ($null -eq $evidence) { return $null }
        $fields = @(
            'schemaVersion', 'banner', 'taskId', 'invocationId', 'action', 'attempt', 'faultInjected',
            'adapterSha256', 'msBuildPath', 'msBuildSha256', 'sandboxRoot', 'logRoot', 'projectRelativePath',
            'projectSha256', 'vcxProjectSha256', 'target', 'expectedArtifactRelativePath', 'expectedArtifactSha256',
            'cycleWatchSourceSha256', 'cycleWatchSourceVariant', 'cycleWatchHeaderSha256', 'cycleWatchTestsSha256',
            'nativeExitCode', 'startedAt', 'finishedAt', 'status', 'environmentError'
        )
        Assert-DemoQualificationProperties $evidence $fields 'Adapter evidence sidecar'
        $unicodeBanner = 'MSBUILD DEMO ADAPTER ' + [char]0x2014 + ' NOT VC6 QUALIFICATION'
        if ($evidence.schemaVersion -cne '1.0' -or $evidence.banner -cne $unicodeBanner -or
            $evidence.taskId -cne $Invocation.TaskId -or $evidence.invocationId -cne $Invocation.InvocationId -or
            $evidence.action -cne $Action -or [int]$evidence.attempt -ne $Attempt -or [bool]$evidence.faultInjected -ne $FaultInjected -or
            $evidence.adapterSha256 -cne $AdapterHash -or $evidence.msBuildPath -cne [string]$Manifest.msBuildPath -or
            $evidence.msBuildSha256 -cne [string]$Manifest.msBuildSha256 -or
            $evidence.sandboxRoot -cne $script:QualificationSandboxRoot -or $evidence.logRoot -cne $script:QualificationLogRoot -or
            $evidence.projectRelativePath -cne [string]$Manifest.projectRelativePath -or $evidence.projectSha256 -cne [string]$Manifest.projectSha256 -or
            $evidence.vcxProjectSha256 -cne [string]$Manifest.vcxProjectSha256 -or $evidence.target -cne [string]$Manifest.target -or
            $evidence.expectedArtifactRelativePath -cne [string]$Manifest.expectedArtifactRelativePath -or
            [int]$evidence.nativeExitCode -ne $NativeExitCode -or $evidence.status -cne $Status -or $null -ne $evidence.environmentError) { return $null }
        $sourceHash = Get-DemoQualificationHash (Join-Path $Invocation.ProjectDirectory 'src\CycleWatch.cpp')
        $headerHash = Get-DemoQualificationHash (Join-Path $Invocation.ProjectDirectory 'include\CycleWatch.h')
        $testsHash = Get-DemoQualificationHash (Join-Path $Invocation.ProjectDirectory 'tests\CycleWatchTests.cpp')
        $sourceVariant = Get-DemoQualificationSourceVariant $sourceHash $Manifest
        if ($null -eq $sourceVariant -or $evidence.cycleWatchSourceSha256 -cne $sourceHash -or
            $evidence.cycleWatchSourceVariant -cne $sourceVariant -or
            $evidence.cycleWatchHeaderSha256 -cne $headerHash -or $headerHash -cne [string]$Manifest.cycleWatchHeaderSha256 -or
            $evidence.cycleWatchTestsSha256 -cne $testsHash -or
            ($testsHash -cne [string]$Manifest.cycleWatchTestsSha256 -and $testsHash -cne [string]$Manifest.cycleWatchTestsLinkerProbeSha256)) { return $null }
        $started = [DateTimeOffset]::Parse([string]$evidence.startedAt, [System.Globalization.CultureInfo]::InvariantCulture)
        $finished = [DateTimeOffset]::Parse([string]$evidence.finishedAt, [System.Globalization.CultureInfo]::InvariantCulture)
        if ($finished -lt $started) { return $null }
        if ($RequireArtifact) {
            if (-not (Test-Path -LiteralPath $Invocation.ArtifactPath -PathType Leaf) -or
                $evidence.expectedArtifactSha256 -cne (Get-DemoQualificationHash $Invocation.ArtifactPath)) { return $null }
        } elseif ($null -ne $evidence.expectedArtifactSha256) { return $null }
        return $evidence
    } catch { return $null }
}

function Get-DemoQualificationValidatedLog {
    param([object]$Invocation, [string]$Status, [string]$RequiredPattern)
    try {
        if (-not (Test-Path -LiteralPath $Invocation.LogPath -PathType Leaf)) { return $null }
        $encoding = [System.Text.Encoding]::GetEncoding(932, (New-Object System.Text.EncoderExceptionFallback), (New-Object System.Text.DecoderExceptionFallback))
        $text = $encoding.GetString([System.IO.File]::ReadAllBytes($Invocation.LogPath))
        if (-not $text.StartsWith("MSBUILD DEMO ADAPTER - NOT VC6 QUALIFICATION`r`n", [System.StringComparison]::Ordinal) -or
            -not $text.Contains("TEAM_BOB_ADAPTER_STATUS=$Status`r`n") -or $text -match '(?<!\r)\n|\r(?!\n)') { return $null }
        if (-not [string]::IsNullOrEmpty($RequiredPattern) -and $text -notmatch $RequiredPattern) { return $null }
        return $text
    } catch { return $null }
}

function Get-DemoQualificationVisualStudioState {
    param([string]$MsBuildPath)
    $state = [ordered]@{ isComplete = $false; isLaunchable = $false }
    $vswherePath = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path -LiteralPath $vswherePath -PathType Leaf)) { return $state }
    try {
        Assert-DemoQualificationNoReparse $vswherePath 'vswhere'
        $output = & $vswherePath -all -products * -format json -utf8 2>$null | Out-String
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($output)) { return $state }
        $instances = @($output | ConvertFrom-Json)
        $matches = @()
        foreach ($instance in $instances) {
            if ([string]::IsNullOrWhiteSpace([string]$instance.installationPath)) { continue }
            $candidate = [System.IO.Path]::GetFullPath((Join-Path ([string]$instance.installationPath) 'MSBuild\Current\Bin\MSBuild.exe'))
            if ($candidate.Equals($MsBuildPath, [System.StringComparison]::OrdinalIgnoreCase)) { $matches += $instance }
        }
        if ($matches.Count -eq 1) {
            $state.isComplete = $matches[0].isComplete -eq $true
            $state.isLaunchable = $matches[0].isLaunchable -eq $true
        }
    } catch { return [ordered]@{ isComplete = $false; isLaunchable = $false } }
    return $state
}

function New-DemoQualificationProbe {
    param(
        [string]$Id, [string]$Class, [object]$ExpectedExit, [object]$ObservedExit,
        [bool]$NativeLaunchObserved, [bool]$Passed, [object]$Invocation = $null, [switch]$UseArtifact
    )
    $relativeLog = $null; $logHash = $null; $relativeEvidence = $null; $evidenceHash = $null; $relativeArtifact = $null; $artifactHash = $null
    if ($null -ne $Invocation) {
        if (Test-Path -LiteralPath $Invocation.LogPath -PathType Leaf) {
            $relativeLog = ConvertTo-DemoQualificationRelativePath $Invocation.LogPath $script:QualificationLogRoot
            $logHash = Get-DemoQualificationHash $Invocation.LogPath
        }
        if (Test-Path -LiteralPath $Invocation.EvidencePath -PathType Leaf) {
            $relativeEvidence = ConvertTo-DemoQualificationRelativePath $Invocation.EvidencePath $script:QualificationLogRoot
            $evidenceHash = Get-DemoQualificationHash $Invocation.EvidencePath
        }
        if ($UseArtifact -and (Test-Path -LiteralPath $Invocation.ArtifactPath -PathType Leaf)) {
            $relativeArtifact = ConvertTo-DemoQualificationRelativePath $Invocation.ArtifactPath $script:QualificationSandboxRoot
            $artifactHash = Get-DemoQualificationHash $Invocation.ArtifactPath
        }
    }
    return [pscustomobject][ordered]@{
        id = $Id; class = $Class; expectedExit = $ExpectedExit; observedExit = $ObservedExit
        nativeLaunchObserved = $NativeLaunchObserved; passed = $Passed
        relativeLogPath = $relativeLog; logSha256 = $logHash
        relativeEvidencePath = $relativeEvidence; evidenceSha256 = $evidenceHash
        relativeArtifactPath = $relativeArtifact; artifactSha256 = $artifactHash
    }
}

function Set-DemoQualificationLinkFault {
    param([string]$Path)
    $encoding = [System.Text.Encoding]::GetEncoding(932, (New-Object System.Text.EncoderExceptionFallback), (New-Object System.Text.DecoderExceptionFallback))
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $text = $encoding.GetString($bytes)
    $withoutCrLf = $text.Replace("`r`n", '')
    if ($withoutCrLf.Contains("`r") -or $withoutCrLf.Contains("`n")) { throw 'Link probe source is not strict CRLF.' }
    $needle = 'int main() {'
    if ([regex]::Matches($text, [regex]::Escape($needle)).Count -ne 1) { throw 'Link probe could not locate the unique main function.' }
    $replacement = 'extern "C" void TEAM_BOB_DEMO_MISSING_LINK_SYMBOL();' + "`r`n`r`n" + $needle + "`r`n    TEAM_BOB_DEMO_MISSING_LINK_SYMBOL();"
    $modified = $text.Replace($needle, $replacement)
    [System.IO.File]::WriteAllBytes($Path, $encoding.GetBytes($modified))
}

function Write-DemoQualificationRecord {
    param([string]$Path, [object]$Value)
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes(($Value | ConvertTo-Json -Depth 20) + "`r`n")
    $stream = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush() } finally { $stream.Dispose() }
}

try {
    $script:QualificationAdapterPath = Get-DemoQualificationFullLocalPath $AdapterPath 'AdapterPath'
    $manifestFull = Get-DemoQualificationFullLocalPath $BuildManifestPath 'BuildManifestPath'
    $script:QualificationDistributionRoot = Get-DemoQualificationFullLocalPath $DistributionRoot 'DistributionRoot'
    $script:QualificationSandboxRoot = Get-DemoQualificationFullLocalPath $SandboxRoot 'SandboxRoot'
    $script:QualificationLogRoot = Get-DemoQualificationFullLocalPath $LogRoot 'LogRoot'
    $evidenceFull = Get-DemoQualificationFullLocalPath $EvidenceRoot 'EvidenceRoot'
    Assert-DemoQualificationFile $script:QualificationAdapterPath 'AdapterPath'
    Assert-DemoQualificationFile $manifestFull 'BuildManifestPath'
    foreach ($entry in @(
        @{ Path = $script:QualificationDistributionRoot; Label = 'DistributionRoot' }, @{ Path = $script:QualificationSandboxRoot; Label = 'SandboxRoot' },
        @{ Path = $script:QualificationLogRoot; Label = 'LogRoot' }, @{ Path = $evidenceFull; Label = 'EvidenceRoot' }
    )) { Assert-DemoQualificationDirectory $entry.Path $entry.Label }
    $roots = @($script:QualificationDistributionRoot, $script:QualificationSandboxRoot, $script:QualificationLogRoot, $evidenceFull)
    for ($leftIndex = 0; $leftIndex -lt $roots.Count; $leftIndex++) {
        for ($rightIndex = $leftIndex + 1; $rightIndex -lt $roots.Count; $rightIndex++) { Assert-DemoQualificationSeparate $roots[$leftIndex] $roots[$rightIndex] 'Qualification roots' }
    }

    $manifest = [System.IO.File]::ReadAllText($manifestFull, (New-Object System.Text.UTF8Encoding($false, $true))) | ConvertFrom-Json
    $manifestFields = @(
        'schemaVersion', 'banner', 'adapterSourceRelativePath', 'adapterSourceSha256', 'generatedConfigurationSha256',
        'msBuildPath', 'msBuildSha256', 'cscPath', 'cscSha256', 'distributionRoot', 'sandboxRoot', 'logRoot',
        'projectRelativePath', 'projectSha256', 'vcxProjectSha256', 'target', 'expectedArtifactRelativePath',
        'cycleWatchHeaderSha256', 'cycleWatchTestsSha256', 'cycleWatchTestsLinkerProbeSha256',
        'cycleWatchSourceBaselineSha256', 'cycleWatchSourceThreshold3ErrorSha256', 'cycleWatchSourceThreshold3FixedSha256',
        'outputFileName', 'outputSha256'
    )
    Assert-DemoQualificationProperties $manifest $manifestFields 'Build manifest'
    $unicodeBanner = 'MSBUILD DEMO ADAPTER ' + [char]0x2014 + ' NOT VC6 QUALIFICATION'
    if ($manifest.schemaVersion -cne '1.0' -or $manifest.banner -cne $unicodeBanner) { throw 'Build manifest identity is invalid.' }
    if (-not ([System.IO.Path]::GetFullPath([string]$manifest.distributionRoot).Equals($script:QualificationDistributionRoot, [System.StringComparison]::OrdinalIgnoreCase)) -or
        -not ([System.IO.Path]::GetFullPath([string]$manifest.sandboxRoot).Equals($script:QualificationSandboxRoot, [System.StringComparison]::OrdinalIgnoreCase)) -or
        -not ([System.IO.Path]::GetFullPath([string]$manifest.logRoot).Equals($script:QualificationLogRoot, [System.StringComparison]::OrdinalIgnoreCase))) { throw 'Qualification roots do not match the baked build manifest.' }
    if ((Split-Path -Parent $script:QualificationAdapterPath) -ne (Split-Path -Parent $manifestFull) -or [System.IO.Path]::GetFileName($script:QualificationAdapterPath) -cne [string]$manifest.outputFileName) { throw 'Adapter and build manifest are not adjacent identities.' }
    if ((Get-DemoQualificationHash $script:QualificationAdapterPath) -cne [string]$manifest.outputSha256) { throw 'Adapter hash does not match build manifest.' }
    $msBuildFull = Get-DemoQualificationFullLocalPath ([string]$manifest.msBuildPath) 'Manifest MSBuild path'
    Assert-DemoQualificationFile $msBuildFull 'Manifest MSBuild path'
    if ((Get-DemoQualificationHash $msBuildFull) -cne [string]$manifest.msBuildSha256) { throw 'MSBuild hash does not match build manifest.' }
    $projectSource = Join-Path $script:QualificationDistributionRoot 'demo\CycleWatch\CycleWatch.dsp'
    $vcxSource = Join-Path $script:QualificationDistributionRoot 'demo\CycleWatch\CycleWatch.vcxproj'
    Assert-DemoQualificationFile $projectSource 'Distribution DSP'
    Assert-DemoQualificationFile $vcxSource 'Distribution VCX project'
    if ((Get-DemoQualificationHash $projectSource) -cne [string]$manifest.projectSha256 -or (Get-DemoQualificationHash $vcxSource) -cne [string]$manifest.vcxProjectSha256) { throw 'Distribution project hashes do not match build manifest.' }
    $sourceBaseline = Join-Path $script:QualificationDistributionRoot 'demo\CycleWatch\src\CycleWatch.cpp'
    $headerBaseline = Join-Path $script:QualificationDistributionRoot 'demo\CycleWatch\include\CycleWatch.h'
    $testsBaseline = Join-Path $script:QualificationDistributionRoot 'demo\CycleWatch\tests\CycleWatchTests.cpp'
    foreach ($entry in @(
        @{ Path = $sourceBaseline; Label = 'Distribution CycleWatch source' },
        @{ Path = $headerBaseline; Label = 'Distribution CycleWatch header' },
        @{ Path = $testsBaseline; Label = 'Distribution CycleWatch tests' }
    )) { Assert-DemoQualificationFile $entry.Path $entry.Label }
    if ((Get-DemoQualificationHash $sourceBaseline) -cne [string]$manifest.cycleWatchSourceBaselineSha256 -or
        (Get-DemoQualificationHash $headerBaseline) -cne [string]$manifest.cycleWatchHeaderSha256 -or
        (Get-DemoQualificationHash $testsBaseline) -cne [string]$manifest.cycleWatchTestsSha256) { throw 'Distribution compiler-input hashes do not match build manifest.' }

    $recordPath = Join-Path $evidenceFull 'demo-adapter-qualification.json'
    if (Test-Path -LiteralPath $recordPath) { throw "Qualification record already exists: $recordPath" }
    $startedAt = [DateTimeOffset]::UtcNow.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
    $adapterHash = Get-DemoQualificationHash $script:QualificationAdapterPath
    $visualStudioState = Get-DemoQualificationVisualStudioState $msBuildFull
    $probes = New-Object System.Collections.Generic.List[object]

    $help = Invoke-DemoQualificationAdapter @('/?')
    $helpPassed = $help.ExitCode -eq 0 -and $help.Output.Contains($unicodeBanner) -and $help.Output.Contains('Usage: DemoMsdevAdapter.exe <sandbox-project.dsp> /MAKE|/REBUILD "CycleWatch - Win32 Release" /OUT <log-path>')
    $probes.Add((New-DemoQualificationProbe 'help' 'protocol' 0 $help.ExitCode $false $helpPassed))

    $hashPassed = (Get-DemoQualificationHash $msBuildFull) -ceq [string]$manifest.msBuildSha256
    $probes.Add((New-DemoQualificationProbe 'msbuild-hash' 'integrity' 0 $(if ($hashPassed) { 0 } else { 1 }) $false $hashPassed))

    $makeInvocation = New-DemoQualificationInvocation 'normal-make' 1 'make' '10000000000000000000000000000001'
    $make = Invoke-DemoQualificationAdapter @($makeInvocation.ProjectPath, '/MAKE', [string]$manifest.target, '/OUT', $makeInvocation.LogPath)
    $makeEvidence = Get-DemoQualificationValidatedEvidence $makeInvocation 'Make' 1 $false 'SUCCEEDED' 0 $manifest $adapterHash -RequireArtifact
    $makeLog = Get-DemoQualificationValidatedLog $makeInvocation 'SUCCEEDED' ''
    $makeLaunch = $null -ne $makeEvidence -and $null -ne $makeEvidence.nativeExitCode
    $makePassed = $make.ExitCode -eq 0 -and $makeLaunch -and $null -ne $makeLog
    $probes.Add((New-DemoQualificationProbe 'normal-make' 'build' 0 $make.ExitCode $makeLaunch $makePassed $makeInvocation -UseArtifact))

    $rebuildInvocation = New-DemoQualificationInvocation 'normal-rebuild' 0 'rebuild' '20000000000000000000000000000002'
    $rebuild = Invoke-DemoQualificationAdapter @($rebuildInvocation.ProjectPath, '/REBUILD', [string]$manifest.target, '/OUT', $rebuildInvocation.LogPath)
    $rebuildEvidence = Get-DemoQualificationValidatedEvidence $rebuildInvocation 'Rebuild' 0 $false 'SUCCEEDED' 0 $manifest $adapterHash -RequireArtifact
    $rebuildLog = Get-DemoQualificationValidatedLog $rebuildInvocation 'SUCCEEDED' ''
    $rebuildLaunch = $null -ne $rebuildEvidence -and $null -ne $rebuildEvidence.nativeExitCode
    $rebuildPassed = $rebuild.ExitCode -eq 0 -and $rebuildLaunch -and $null -ne $rebuildLog
    $probes.Add((New-DemoQualificationProbe 'normal-rebuild' 'build' 0 $rebuild.ExitCode $rebuildLaunch $rebuildPassed $rebuildInvocation -UseArtifact))

    $compilerInvocation = New-DemoQualificationInvocation 'compiler-failure' 0 'make' '30000000000000000000000000000003'
    $compiler = Invoke-DemoQualificationAdapter @($compilerInvocation.ProjectPath, '/MAKE', [string]$manifest.target, '/OUT', $compilerInvocation.LogPath)
    $compilerEvidence = Get-DemoQualificationValidatedEvidence $compilerInvocation 'Make' 0 $true 'FAILED' 1 $manifest $adapterHash
    $compilerLaunch = $null -ne $compilerEvidence -and $null -ne $compilerEvidence.nativeExitCode
    $compilerText = Get-DemoQualificationValidatedLog $compilerInvocation 'FAILED' 'error C[0-9]+'
    $compilerPassed = $compiler.ExitCode -eq 1 -and $compilerLaunch -and $null -ne $compilerText
    $probes.Add((New-DemoQualificationProbe 'compiler-failure' 'compiler' 1 $compiler.ExitCode $compilerLaunch $compilerPassed $compilerInvocation))

    $linkerInvocation = New-DemoQualificationInvocation 'linker-failure' 1 'make' '40000000000000000000000000000004'
    Set-DemoQualificationLinkFault (Join-Path $linkerInvocation.ProjectDirectory 'tests\CycleWatchTests.cpp')
    if ((Get-DemoQualificationHash (Join-Path $linkerInvocation.ProjectDirectory 'tests\CycleWatchTests.cpp')) -cne [string]$manifest.cycleWatchTestsLinkerProbeSha256) { throw 'Linker probe did not produce the single known tests variant.' }
    $linker = Invoke-DemoQualificationAdapter @($linkerInvocation.ProjectPath, '/MAKE', [string]$manifest.target, '/OUT', $linkerInvocation.LogPath)
    $linkerEvidence = Get-DemoQualificationValidatedEvidence $linkerInvocation 'Make' 1 $false 'FAILED' 1 $manifest $adapterHash
    $linkerLaunch = $null -ne $linkerEvidence -and $null -ne $linkerEvidence.nativeExitCode
    $linkerText = Get-DemoQualificationValidatedLog $linkerInvocation 'FAILED' 'LNK[0-9]+'
    $linkerPassed = $linker.ExitCode -eq 1 -and $linkerLaunch -and $null -ne $linkerText
    $probes.Add((New-DemoQualificationProbe 'linker-failure' 'linker' 1 $linker.ExitCode $linkerLaunch $linkerPassed $linkerInvocation))

    $artifactPassed = Test-Path -LiteralPath $makeInvocation.ArtifactPath -PathType Leaf
    $probes.Add((New-DemoQualificationProbe 'artifact-presence' 'artifact' 0 $(if ($artifactPassed) { 0 } else { 1 }) $false $artifactPassed $makeInvocation -UseArtifact))

    $invalidTargetInvocation = New-DemoQualificationInvocation 'invalid-target-no-launch' 1 'make' '50000000000000000000000000000005'
    $invalidTarget = Invoke-DemoQualificationAdapter @($invalidTargetInvocation.ProjectPath, '/MAKE', 'CycleWatch - Win32 Debug', '/OUT', $invalidTargetInvocation.LogPath)
    $invalidTargetPassed = $invalidTarget.ExitCode -eq 20 -and -not (Test-Path -LiteralPath $invalidTargetInvocation.LogPath) -and -not (Test-Path -LiteralPath $invalidTargetInvocation.EvidencePath) -and -not (Test-Path -LiteralPath $invalidTargetInvocation.ArtifactPath)
    $probes.Add((New-DemoQualificationProbe 'invalid-target-no-launch' 'allowlist' 20 $invalidTarget.ExitCode $false $invalidTargetPassed))

    $invalidInputInvocation = New-DemoQualificationInvocation 'invalid-input-no-launch' 1 'make' '60000000000000000000000000000006'
    $invalidInput = Invoke-DemoQualificationAdapter @($projectSource, '/MAKE', [string]$manifest.target, '/OUT', $invalidInputInvocation.LogPath)
    $invalidInputPassed = $invalidInput.ExitCode -eq 20 -and -not (Test-Path -LiteralPath $invalidInputInvocation.LogPath) -and -not (Test-Path -LiteralPath $invalidInputInvocation.EvidencePath) -and -not (Test-Path -LiteralPath $invalidInputInvocation.ArtifactPath)
    $probes.Add((New-DemoQualificationProbe 'invalid-input-no-launch' 'allowlist' 20 $invalidInput.ExitCode $false $invalidInputPassed))

    $passed = @($probes | Where-Object { -not $_.passed }).Count -eq 0
    $qualificationEligible = $passed -and $visualStudioState.isComplete -and $visualStudioState.isLaunchable
    $record = [ordered]@{
        schemaVersion = '1.0'; banner = $unicodeBanner; recordType = 'RAW_PROTOCOL_EVIDENCE_ONLY'
        qualificationEligible = $qualificationEligible; approved = $false; vc6Qualified = $false; pcId = [Environment]::MachineName
        visualStudio = $visualStudioState
        adapterPath = $script:QualificationAdapterPath; buildManifestPath = $manifestFull
        adapterSha256 = $adapterHash
        msBuildPath = $msBuildFull; msBuildSha256 = Get-DemoQualificationHash $msBuildFull
        projectSha256 = [string]$manifest.projectSha256; vcxProjectSha256 = [string]$manifest.vcxProjectSha256
        cycleWatchHeaderSha256 = [string]$manifest.cycleWatchHeaderSha256
        cycleWatchTestsSha256 = [string]$manifest.cycleWatchTestsSha256
        cycleWatchTestsLinkerProbeSha256 = [string]$manifest.cycleWatchTestsLinkerProbeSha256
        cycleWatchSourceBaselineSha256 = [string]$manifest.cycleWatchSourceBaselineSha256
        cycleWatchSourceThreshold3ErrorSha256 = [string]$manifest.cycleWatchSourceThreshold3ErrorSha256
        cycleWatchSourceThreshold3FixedSha256 = [string]$manifest.cycleWatchSourceThreshold3FixedSha256
        sandboxRoot = $script:QualificationSandboxRoot; logRoot = $script:QualificationLogRoot; evidenceRoot = $evidenceFull
        startedAt = $startedAt; finishedAt = [DateTimeOffset]::UtcNow.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
        passed = $passed; probes = @($probes.ToArray())
    }
    Write-DemoQualificationRecord $recordPath $record
    Write-Output "RAW_PROTOCOL_EVIDENCE $recordPath"
    if ($passed) { exit 0 }
    exit 1
} catch {
    Write-Error $_.Exception.Message
    exit 2
}
