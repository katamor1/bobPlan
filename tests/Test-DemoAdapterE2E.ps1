$ErrorActionPreference = 'Stop'

$demoE2EStandalone = $null -eq (Get-Command Assert-True -ErrorAction SilentlyContinue)
if ($demoE2EStandalone) {
    $script:Assertions = 0
    function Assert-True { param([bool]$Condition, [string]$Message); $script:Assertions++; if (-not $Condition) { throw "ASSERTION FAILED: $Message" } }
    function Assert-Equal { param([object]$Actual, [object]$Expected, [string]$Message); Assert-True ($Actual -eq $Expected) "$Message (expected '$Expected', got '$Actual')" }
}

function Write-DemoE2EUtf8NoBom {
    param([string]$Path, [string]$Text)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { [void][System.IO.Directory]::CreateDirectory($parent) }
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Write-DemoE2EJson {
    param([string]$Path, [object]$Value)
    Write-DemoE2EUtf8NoBom $Path (($Value | ConvertTo-Json -Depth 20) + "`r`n")
}

function Get-DemoE2EHash {
    param([string]$Path)
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Get-DemoE2ETreeFingerprint {
    param([string]$Root)
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    return ((Get-ChildItem -LiteralPath $rootFull -File -Force -Recurse | Sort-Object FullName | ForEach-Object {
        $_.FullName.Substring($rootFull.Length).TrimStart('\', '/') + ':' + (Get-DemoE2EHash $_.FullName)
    }) -join "`n")
}

function Invoke-DemoE2EScript {
    param([string]$Path, [string[]]$Arguments = @())
    $powerShell = (Get-Process -Id $PID).Path
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $powerShell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Path @Arguments 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $savedPreference }
    return [pscustomobject]@{ ExitCode = $exitCode; Output = $output }
}

function Get-DemoE2ERoslynDirectory {
    $candidates = @()
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path -LiteralPath $vswhere -PathType Leaf) {
        foreach ($installation in @(& $vswhere -all -products * -property installationPath 2>$null)) {
            if (-not [string]::IsNullOrWhiteSpace($installation)) {
                $candidate = Join-Path $installation 'MSBuild\Current\Bin\Roslyn\csc.exe'
                if (Test-Path -LiteralPath $candidate -PathType Leaf) { $candidates += Get-Item -LiteralPath $candidate }
            }
        }
    }
    $selected = @($candidates | Sort-Object FullName -Descending | Select-Object -First 1)
    Assert-Equal $selected.Count 1 'E2E fixture has one selected local Roslyn compiler'
    return (Split-Path -Parent $selected[0].FullName)
}

function New-DemoE2EFakeTools {
    param([string]$Directory)
    [void][System.IO.Directory]::CreateDirectory($Directory)
    $msBuildPath = Join-Path $Directory 'MSBuild.exe'
    $bazaarPath = Join-Path $Directory 'BZR.EXE'
    $msBuildSource = Join-Path $Directory 'FakeMsBuild.cs'
    $bazaarSource = Join-Path $Directory 'FakeBazaar.cs'
    Write-DemoE2EUtf8NoBom $msBuildSource @'
using System;
using System.IO;
using System.Text;
using System.Threading;

public static class FakeMsBuild {
    public static int Main(string[] args) {
        string mode = Environment.GetEnvironmentVariable("TEAM_BOB_FAKE_MSBUILD_MODE") ?? String.Empty;
        string trace = Environment.GetEnvironmentVariable("TEAM_BOB_FAKE_MSBUILD_TRACE");
        if (!String.IsNullOrEmpty(trace)) File.AppendAllText(trace, mode + "|" + String.Join("\t", args) + "\r\n", new UTF8Encoding(false));
        if (String.Equals(mode, "timeout", StringComparison.Ordinal)) { Thread.Sleep(30000); return 9; }
        if (args.Length != 10) return 8;
        if (String.Equals(Environment.GetEnvironmentVariable("CL"), "/DTEAM_BOB_DEMO_FAULT", StringComparison.Ordinal)) {
            Console.WriteLine(@"src\CycleWatch.cpp(9) : error C1189: MSBUILD_DEMO_ADAPTER_INTENTIONAL_COMPILER_FAULT ""demo/CycleWatch/src/CycleWatch.cpp"" AFTER_EVIDENCE_REPLACE_THIS_EXACT_LINE_WITH: #pragma message(""MSBUILD_DEMO_ADAPTER_INTENTIONAL_FAULT_REPAIRED demo/CycleWatch/src/CycleWatch.cpp"")");
            return 1;
        }
        byte[] localized = new UTF8Encoding(false, true).GetBytes("FAKE_MSBUILD_LOCALIZED_SUCCESS_\u65e5\u672c\u8a9e\r\n");
        using (Stream output = Console.OpenStandardOutput()) { output.Write(localized, 0, localized.Length); output.Flush(); }
        if (!String.Equals(mode, "missing-artifact", StringComparison.Ordinal)) {
            string projectDirectory = Path.GetDirectoryName(args[0]);
            string artifact = Path.Combine(projectDirectory, @"bin\Release\CycleWatchTests.exe");
            Directory.CreateDirectory(Path.GetDirectoryName(artifact));
            File.WriteAllBytes(artifact, Encoding.ASCII.GetBytes("synthetic-adapter-artifact\r\n"));
        }
        return 0;
    }
}
'@
    Write-DemoE2EUtf8NoBom $bazaarSource @'
using System;
public static class FakeBazaar {
    public static int Main(string[] args) {
        if (args.Length == 0) return 2;
        if (String.Equals(args[0], "status", StringComparison.Ordinal)) return 0;
        if (String.Equals(args[0], "nick", StringComparison.Ordinal)) { Console.WriteLine("fixture-branch"); return 0; }
        if (String.Equals(args[0], "version-info", StringComparison.Ordinal)) { Console.WriteLine("fixture-revision-id-full-123"); return 0; }
        return 2;
    }
}
'@
    $roslynSource = Get-DemoE2ERoslynDirectory
    $csc = Join-Path $roslynSource 'csc.exe'
    & $csc /nologo /noconfig /target:exe /reference:System.dll ('/out:' + $msBuildPath) $msBuildSource
    if ($LASTEXITCODE -ne 0) { throw "E2E fake MSBuild compilation failed with exit code $LASTEXITCODE." }
    & $csc /nologo /noconfig /target:exe /reference:System.dll ('/out:' + $bazaarPath) $bazaarSource
    if ($LASTEXITCODE -ne 0) { throw "E2E fake Bazaar compilation failed with exit code $LASTEXITCODE." }
    $roslynDestination = Join-Path $Directory 'Roslyn'
    [void][System.IO.Directory]::CreateDirectory($roslynDestination)
    foreach ($file in @(Get-ChildItem -LiteralPath $roslynSource -File)) { Copy-Item -LiteralPath $file.FullName -Destination $roslynDestination }
    Assert-True (Test-Path -LiteralPath (Join-Path $roslynDestination 'csc.exe') -PathType Leaf) 'E2E fake MSBuild has an adjacent non-reparse Roslyn compiler copy'
    return [pscustomobject]@{ MsBuildPath = $msBuildPath; BazaarPath = $bazaarPath }
}

function Write-DemoE2EWorkPacket {
    param([string]$Path, [string]$BazaarRoot, [string]$TaskId, [string]$ProfileId)
    $packet = [ordered]@{
        'Profile Version' = '0.1.0-poc'; 'Task ID' = $TaskId; 'Difficulty' = 'Small'; 'Risk' = 'Green'; 'Customer' = 'Demo fixture'
        'ReqIDs' = @('REQ-DEMO-ADAPTER-E2E'); 'Word Baseline' = 'WORD-1'; 'QA Baseline' = 'QA-1'; 'Spec Baseline' = 'SPEC-1'
        'Bazaar Root' = [System.IO.Path]::GetFullPath($BazaarRoot); 'Bazaar Branch' = 'fixture-branch'; 'Bazaar Full Revision ID' = 'fixture-revision-id-full-123'
        'Allowed Files' = @('demo/CycleWatch/src/CycleWatch.cpp'); 'Forbidden Areas' = @('actual-machine', 'control-network', 'mainline', 'secrets')
        'RT Impact' = 'None'; 'Safety Impact' = 'None'; 'Board Impact' = 'None'; 'Driver Impact' = 'None'; 'ABI Impact' = 'None'; 'Build Impact' = 'Fixture'; 'Customer Branch Impact' = 'None'
        'RT Impact Clear' = 'YES'; 'Safety Impact Clear' = 'YES'; 'Board Impact Clear' = 'YES'; 'Driver Impact Clear' = 'YES'; 'ABI Impact Clear' = 'YES'; 'Build Impact Clear' = 'YES'; 'Customer Branch Impact Clear' = 'YES'
        'Clean Working Copy' = 'YES'; 'Open QA' = @(); 'Build Profile ID' = $ProfileId
        'Autonomous-Edit-Build-Approved' = 'YES'; 'Soft-Execute-Risk-Accepted' = 'YES'; 'Max-Repair-Cycles' = 2
        'Specification Approver' = 'Fixture Approver'; 'Implementation Approver' = 'Fixture Approver'
    }
    $json = $packet | ConvertTo-Json -Depth 20
    Write-DemoE2EUtf8NoBom $Path ("# Work Packet`r`n`r`n<!-- canonical-work-packet-json:start -->`r`n``````json`r`n$json`r`n```````r`n<!-- canonical-work-packet-json:end -->`r`n")
}

function Invoke-DemoE2EBuild {
    param([string]$ScriptPath, [string]$WorkPacketPath, [string]$Action, [int]$Attempt)
    $resultDirectory = Join-Path (Split-Path -Parent $WorkPacketPath) 'results'
    $before = @(Get-ChildItem -LiteralPath $resultDirectory -Filter 'build-result-*.json' -File | ForEach-Object FullName)
    $invocation = Invoke-DemoE2EScript $ScriptPath @('-WorkPacket', $WorkPacketPath, '-Action', $Action, '-Attempt', ([string]$Attempt))
    $created = @(Get-ChildItem -LiteralPath $resultDirectory -Filter 'build-result-*.json' -File | Where-Object { $before -notcontains $_.FullName })
    Assert-Equal $created.Count 1 "E2E $Action attempt $Attempt writes exactly one durable result; output: $($invocation.Output.Trim())"
    $json = [System.IO.File]::ReadAllText($created[0].FullName, (New-Object System.Text.UTF8Encoding($false, $true))) | ConvertFrom-Json
    return [pscustomobject]@{ ExitCode = $invocation.ExitCode; Output = $invocation.Output; Json = $json }
}

function Assert-DemoE2EOutcome {
    param([object]$Result, [string]$Status, [int]$ExitCode, [string]$Message)
    Assert-Equal $Result.ExitCode $ExitCode "$Message uses fixed wrapper exit; result: $($Result.Json.message)"
    Assert-Equal $Result.Json.status $Status "$Message persists fixed status"
    Assert-Equal $Result.Json.exitCode $ExitCode "$Message persists mapped exit"
    Assert-True ($Result.Output -match ('(?m)^' + [regex]::Escape($Status) + '\s*$')) "$Message emits fixed status"
    Assert-Equal ($Result.Json.preSourceInventory -join "`n") ($Result.Json.postSourceInventory -join "`n") "$Message proves source inventory unchanged"
    Assert-Equal ($Result.Json.preBzrInventory -join "`n") ($Result.Json.postBzrInventory -join "`n") "$Message proves .bzr inventory unchanged"
}

$demoE2EAssertionsBefore = $script:Assertions
$demoE2ERepoRoot = Split-Path -Parent $PSScriptRoot
$demoE2EFixture = [System.IO.Path]::GetFullPath((Join-Path ([System.IO.Path]::GetTempPath()) ('team-bob-demo-e2e-' + [guid]::NewGuid().ToString('N'))))
$temporaryRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\', '/')
Assert-True ($demoE2EFixture.StartsWith($temporaryRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) 'E2E fixture is a verified child of the system temporary root'
$savedEnvironment = @{}
foreach ($name in @('LOCALAPPDATA', 'TEAM_BOB_FAKE_MSBUILD_MODE', 'TEAM_BOB_FAKE_MSBUILD_TRACE', 'CL', '_CL_', 'LINK', '_LINK_')) {
    $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
$productionProfileBefore = Get-DemoE2ETreeFingerprint (Join-Path $demoE2ERepoRoot 'profile')
$productionCatalogPath = Join-Path $demoE2ERepoRoot 'profile\team-bob\config\vc6-build-targets.json'
$productionCatalogHashBefore = Get-DemoE2EHash $productionCatalogPath

try {
    [void][System.IO.Directory]::CreateDirectory($demoE2EFixture)
    $workingTree = Join-Path $demoE2EFixture 'working-tree'
    $adapterTools = Join-Path $demoE2EFixture 'adapter-tools'
    $fakeToolsRoot = Join-Path $demoE2EFixture 'fake-tools'
    $sandboxRoot = Join-Path $demoE2EFixture 'sandboxes'
    $logRoot = Join-Path $demoE2EFixture 'logs'
    $buildTempRoot = Join-Path $demoE2EFixture 'build-temp'
    foreach ($directory in @($workingTree, $adapterTools, $sandboxRoot, $logRoot, $buildTempRoot)) { [void][System.IO.Directory]::CreateDirectory($directory) }
    [void][System.IO.Directory]::CreateDirectory((Join-Path $workingTree '.bzr'))
    Write-DemoE2EUtf8NoBom (Join-Path $workingTree '.bzr\branch.conf') 'fixture branch metadata'
    [void][System.IO.Directory]::CreateDirectory((Join-Path $workingTree 'demo\adapter'))
    Copy-Item -LiteralPath (Join-Path $demoE2ERepoRoot 'demo\CycleWatch') -Destination (Join-Path $workingTree 'demo\CycleWatch') -Recurse
    Copy-Item -LiteralPath (Join-Path $demoE2ERepoRoot 'demo\adapter\DemoMsdevAdapter.cs') -Destination (Join-Path $workingTree 'demo\adapter\DemoMsdevAdapter.cs')

    $installer = Invoke-DemoE2EScript (Join-Path $demoE2ERepoRoot 'scripts\Install-TeamBobProfile.ps1') @('-TargetPath', $workingTree)
    Assert-Equal $installer.ExitCode 0 "E2E uses a temporary byte-identical installed production profile; output: $($installer.Output.Trim())"
    $installedWrapper = Join-Path $workingTree 'team-bob\tools\Invoke-Vc6Build.ps1'
    Assert-Equal (Get-DemoE2EHash $installedWrapper) (Get-DemoE2EHash (Join-Path $demoE2ERepoRoot 'profile\team-bob\tools\Invoke-Vc6Build.ps1')) 'E2E wrapper is byte-identical to production'

    $fakeTools = New-DemoE2EFakeTools $fakeToolsRoot
    $adapterBuild = Invoke-DemoE2EScript (Join-Path $demoE2ERepoRoot 'demo\tools\Build-DemoMsdevAdapter.ps1') @(
        '-MsBuildPath', $fakeTools.MsBuildPath, '-DistributionRoot', $workingTree,
        '-SandboxRoot', $sandboxRoot, '-LogRoot', $logRoot, '-OutputDirectory', $adapterTools, '-TemporaryRoot', $buildTempRoot
    )
    Assert-Equal $adapterBuild.ExitCode 0 "E2E adapter build succeeds; output: $($adapterBuild.Output.Trim())"
    $adapterPath = Join-Path $adapterTools 'DemoMsdevAdapter.exe'
    Assert-True (Test-Path -LiteralPath $adapterPath -PathType Leaf) 'E2E runs the generated adapter executable'

    $env:LOCALAPPDATA = Join-Path $demoE2EFixture 'local-appdata'
    $initialize = Invoke-DemoE2EScript (Join-Path $workingTree 'team-bob\tools\Initialize-LocalEnvironment.ps1') @(
        '-MsdevPath', $adapterPath, '-BazaarPath', $fakeTools.BazaarPath, '-SandboxRoot', $sandboxRoot, '-LogRoot', $logRoot
    )
    Assert-Equal $initialize.ExitCode 0 "E2E registers adapter and fake Bazaar only in fixture LOCALAPPDATA; output: $($initialize.Output.Trim())"

    $profileId = 'demo-adapter-e2e-fixture'
    $profile = [pscustomobject]@{
        id = $profileId; enabled = $true; projectFile = 'demo/CycleWatch/CycleWatch.dsp'; target = 'CycleWatch - Win32 Release'; timeoutSeconds = 30
        expectedArtifacts = @('demo/CycleWatch/bin/Release/CycleWatchTests.exe'); excludePatterns = @('*.pdb', '**/*.obj')
        outputLogPattern = 'build\.log$'; successPattern = 'TEAM_BOB_ADAPTER_STATUS=SUCCEEDED'
        compilerErrorPattern = 'error C[0-9]+'; linkerErrorPattern = 'LNK[0-9]+'; environmentErrorPattern = 'TEAM_BOB_ADAPTER_ENVIRONMENT_ERROR='
        qualification = [pscustomobject]@{
            msdevHelp = $true; makeSucceeded = $true; rebuildSucceeded = $true; compileFailureObserved = $true; linkFailureObserved = $true
            pcId = [Environment]::MachineName; recordId = 'fixture-only-not-qualification'; recordedAt = '2026-09-03T00:00:00Z'
        }
    }
    $catalogPath = Join-Path $workingTree 'team-bob\config\vc6-build-targets.json'
    Write-DemoE2EJson $catalogPath ([pscustomobject]@{ profiles = @($profile) })
    $taskId = 'ADAPTER-E2E'
    $taskDirectory = Join-Path $workingTree ('team-bob-work\' + $taskId)
    [void][System.IO.Directory]::CreateDirectory((Join-Path $taskDirectory 'results'))
    $workPacket = Join-Path $taskDirectory 'work-packet.md'
    Write-DemoE2EWorkPacket $workPacket $workingTree $taskId $profileId
    $tracePath = Join-Path $demoE2EFixture 'msbuild-trace.log'
    Write-DemoE2EUtf8NoBom $tracePath ''
    $env:TEAM_BOB_FAKE_MSBUILD_TRACE = $tracePath
    $env:TEAM_BOB_FAKE_MSBUILD_MODE = ''
    $sourceRoot = Join-Path $workingTree 'demo\CycleWatch'
    $bzrRoot = Join-Path $workingTree '.bzr'
    $sourceFingerprint = Get-DemoE2ETreeFingerprint $sourceRoot
    $bzrFingerprint = Get-DemoE2ETreeFingerprint $bzrRoot

    $compile = Invoke-DemoE2EBuild $installedWrapper $workPacket 'Make' 0
    Assert-DemoE2EOutcome $compile 'CODE_FAILED_RETRYABLE' 10 'Attempt 0 compiler failure through unchanged wrapper'
    Assert-Equal $compile.Json.invokedArguments[1] '/MAKE' 'Attempt 0 wrapper selects exact /MAKE adapter action'
    $compileLog = [System.IO.File]::ReadAllText([string]$compile.Json.outputLogPath, [System.Text.Encoding]::GetEncoding(932))
    Assert-True ($compileLog.Contains('AFTER_EVIDENCE_REPLACE_THIS_EXACT_LINE_WITH: #pragma message("MSBUILD_DEMO_ADAPTER_INTENTIONAL_FAULT_REPAIRED demo/CycleWatch/src/CycleWatch.cpp")')) 'Unchanged wrapper retains the exact evidence-based synthetic fault repair instruction'

    $make = Invoke-DemoE2EBuild $installedWrapper $workPacket 'Make' 1
    Assert-DemoE2EOutcome $make 'SUCCEEDED' 0 'Attempt 1 Make through unchanged wrapper'
    Assert-Equal $make.Json.invokedArguments[1] '/MAKE' 'Attempt 1 wrapper selects exact /MAKE adapter action'
    $localizedNativeMarker = 'FAKE_MSBUILD_LOCALIZED_SUCCESS_' + [char]0x65e5 + [char]0x672c + [char]0x8a9e
    Assert-True (([System.IO.File]::ReadAllText([string]$make.Json.outputLogPath, [System.Text.Encoding]::GetEncoding(932))).Contains($localizedNativeMarker)) 'Unchanged wrapper accepts localized native output after adapter CP932 transcoding'

    $rebuild = Invoke-DemoE2EBuild $installedWrapper $workPacket 'Rebuild' 1
    Assert-DemoE2EOutcome $rebuild 'SUCCEEDED' 0 'Rebuild through unchanged wrapper'
    Assert-Equal $rebuild.Json.invokedArguments[1] '/REBUILD' 'Wrapper selects exact /REBUILD adapter action'

    $dspPath = Join-Path $workingTree 'demo\CycleWatch\CycleWatch.dsp'
    $dspBytes = [System.IO.File]::ReadAllBytes($dspPath)
    [System.IO.File]::WriteAllBytes($dspPath, $dspBytes + [System.Text.Encoding]::ASCII.GetBytes("TAMPER`r`n"))
    $tamperedFingerprint = Get-DemoE2ETreeFingerprint $sourceRoot
    $traceCountBeforeRejection = @([System.IO.File]::ReadAllLines($tracePath)).Count
    try {
        $environmentFailure = Invoke-DemoE2EBuild $installedWrapper $workPacket 'Make' 1
        Assert-DemoE2EOutcome $environmentFailure 'ENVIRONMENT_FAILED' 20 'Adapter project-hash rejection through unchanged wrapper'
        Assert-Equal (Get-DemoE2ETreeFingerprint $sourceRoot) $tamperedFingerprint 'Environment rejection does not mutate the source presented to the wrapper'
        Assert-Equal @([System.IO.File]::ReadAllLines($tracePath)).Count $traceCountBeforeRejection 'Adapter environment rejection launches no native MSBuild'
    } finally { [System.IO.File]::WriteAllBytes($dspPath, $dspBytes) }

    $env:TEAM_BOB_FAKE_MSBUILD_MODE = 'missing-artifact'
    $missingArtifact = Invoke-DemoE2EBuild $installedWrapper $workPacket 'Make' 1
    Assert-DemoE2EOutcome $missingArtifact 'ENVIRONMENT_FAILED' 20 'Missing exact artifact through unchanged wrapper'
    $env:TEAM_BOB_FAKE_MSBUILD_MODE = ''

    $profile.timeoutSeconds = 2
    Write-DemoE2EJson $catalogPath ([pscustomobject]@{ profiles = @($profile) })
    $env:TEAM_BOB_FAKE_MSBUILD_MODE = 'timeout'
    $timeout = Invoke-DemoE2EBuild $installedWrapper $workPacket 'Make' 1
    Assert-DemoE2EOutcome $timeout 'TIMED_OUT' 21 'Outer wrapper timeout of adapter-owned process tree'
    Assert-Equal $timeout.Json.terminationComplete $true 'Outer wrapper records completed adapter process-tree termination'
    $env:TEAM_BOB_FAKE_MSBUILD_MODE = ''

    Assert-Equal (Get-DemoE2ETreeFingerprint $sourceRoot) $sourceFingerprint 'All wrapper E2E probes leave original CycleWatch source byte-identical'
    Assert-Equal (Get-DemoE2ETreeFingerprint $bzrRoot) $bzrFingerprint 'All wrapper E2E probes leave every original .bzr byte unchanged'
    Assert-Equal (Get-DemoE2EHash $installedWrapper) (Get-DemoE2EHash (Join-Path $demoE2ERepoRoot 'profile\team-bob\tools\Invoke-Vc6Build.ps1')) 'E2E leaves installed production wrapper byte-identical'
    Assert-Equal (Get-DemoE2ETreeFingerprint (Join-Path $demoE2ERepoRoot 'profile')) $productionProfileBefore 'E2E leaves production profile tree byte-identical'
    Assert-Equal (Get-DemoE2EHash $productionCatalogPath) $productionCatalogHashBefore 'E2E leaves shipped empty production catalog byte-identical'
} finally {
    foreach ($name in $savedEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process') }
    if (Test-Path -LiteralPath $demoE2EFixture -PathType Container) {
        $verifiedFixture = [System.IO.Path]::GetFullPath($demoE2EFixture)
        if (-not $verifiedFixture.StartsWith($temporaryRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) { throw 'Refusing to remove an unverified E2E fixture root.' }
        Remove-Item -LiteralPath $verifiedFixture -Recurse -Force
    }
}

$demoE2ECount = $script:Assertions - $demoE2EAssertionsBefore
Write-Host "PASS: $demoE2ECount unchanged-wrapper demo adapter E2E assertions succeeded."
