$ErrorActionPreference = 'Stop'

if ($null -eq (Get-Command Assert-True -ErrorAction SilentlyContinue)) {
    $script:Assertions = 0
    function Assert-True { param([bool]$Condition, [string]$Message); $script:Assertions++; if (-not $Condition) { throw "ASSERTION FAILED: $Message" } }
    function Assert-Equal { param([object]$Actual, [object]$Expected, [string]$Message); Assert-True ($Actual -eq $Expected) "$Message (expected '$Expected', got '$Actual')" }
    function Assert-SetEqual { param([object[]]$Actual, [object[]]$Expected, [string]$Message); Assert-Equal (($Actual | Sort-Object) -join ',') (($Expected | Sort-Object) -join ',') $Message }
    function Invoke-TestScript {
        param([string]$Path, [string[]]$Arguments = @())
        $powerShell = (Get-Process -Id $PID).Path
        $savedPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try { $output = & $powerShell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Path @Arguments 2>&1 | Out-String } finally { $ErrorActionPreference = $savedPreference }
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
    }
    function Write-Utf8NoBomFixture {
        param([string]$Path, [string]$Text)
        $parent = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
    }
    function Write-JsonFixture { param([string]$Path, [object]$Value); Write-Utf8NoBomFixture $Path (($Value | ConvertTo-Json -Depth 20) + [Environment]::NewLine) }
    function Get-TreeFingerprintFixture {
        param([string]$Root)
        $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
        return ((Get-ChildItem -LiteralPath $rootFull -File -Force -Recurse | Sort-Object FullName | ForEach-Object {
            $_.FullName.Substring($rootFull.Length).TrimStart('\', '/') + ':' + (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash
        }) -join "`n")
    }
}

function Write-Cp932Fixture {
    param([string]$Path, [string]$Text)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [System.IO.File]::WriteAllBytes($Path, [System.Text.Encoding]::GetEncoding(932).GetBytes($Text))
}

function Write-Task3PacketFixture {
    param(
        [string]$Path, [string]$BazaarRoot, [string]$TaskId, [string[]]$AllowedFiles, [string]$BuildProfileId,
        [string[]]$ForbiddenAreas = @('actual-machine', 'control-network', 'mainline', 'secrets')
    )
    $packet = [ordered]@{
        'Profile Version' = '0.1.0-poc'; 'Task ID' = $TaskId; 'Difficulty' = 'Small'; 'Risk' = 'Green'; 'Customer' = 'Fixture Customer'
        'ReqIDs' = @('REQ-TASK3-001'); 'Word Baseline' = 'WORD-1'; 'QA Baseline' = 'QA-1'; 'Spec Baseline' = 'SPEC-1'
        'Bazaar Root' = [System.IO.Path]::GetFullPath($BazaarRoot); 'Bazaar Branch' = 'fixture-branch'; 'Bazaar Full Revision ID' = 'fixture-revision-id-full-123'
        'Allowed Files' = @($AllowedFiles); 'Forbidden Areas' = @($ForbiddenAreas)
        'RT Impact' = 'None'; 'Safety Impact' = 'None'; 'Board Impact' = 'None'; 'Driver Impact' = 'None'; 'ABI Impact' = 'None'; 'Build Impact' = 'Fixture'; 'Customer Branch Impact' = 'None'
        'RT Impact Clear' = 'YES'; 'Safety Impact Clear' = 'YES'; 'Board Impact Clear' = 'YES'; 'Driver Impact Clear' = 'YES'; 'ABI Impact Clear' = 'YES'; 'Build Impact Clear' = 'YES'; 'Customer Branch Impact Clear' = 'YES'
        'Clean Working Copy' = 'YES'; 'Open QA' = @(); 'Build Profile ID' = $BuildProfileId
        'Autonomous-Edit-Build-Approved' = 'YES'; 'Soft-Execute-Risk-Accepted' = 'YES'; 'Max-Repair-Cycles' = 2
        'Specification Approver' = 'Spec Approver'; 'Implementation Approver' = 'Implementation Approver'
    }
    $json = $packet | ConvertTo-Json -Depth 20
    Write-Utf8NoBomFixture $Path ("# Work Packet`r`n`r`n<!-- canonical-work-packet-json:start -->`r`n``````json`r`n$json`r`n```````r`n<!-- canonical-work-packet-json:end -->`r`n")
}

function New-Task3FakeExecutables {
    param([string]$Directory)
    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    $msdevPath = Join-Path $Directory 'MSDEV.EXE'
    $bazaarPath = Join-Path $Directory 'BZR.EXE'
    $msdevSource = @'
using System;
using System.IO;
using System.Text;
using System.Threading;
using System.Diagnostics;
using System.Reflection;
public static class FakeMsdev {
    public static int Main(string[] args) {
        if (args.Length == 1 && args[0] == "--child") { Thread.Sleep(12000); return 0; }
        string commandLog = Environment.GetEnvironmentVariable("BOB3_MSDEV_COMMAND_LOG");
        if (!String.IsNullOrEmpty(commandLog)) File.AppendAllText(commandLog, String.Join("\t", args) + Environment.NewLine, new UTF8Encoding(false));
        string mode = Environment.GetEnvironmentVariable("BOB3_MSDEV_MODE") ?? "success";
        if (mode == "timeout-child") {
            ProcessStartInfo child = new ProcessStartInfo(Assembly.GetExecutingAssembly().Location, "--child");
            child.UseShellExecute = false;
            Process.Start(child);
            Thread.Sleep(12000);
        }
        int sleep;
        if (Int32.TryParse(Environment.GetEnvironmentVariable("BOB3_MSDEV_SLEEP_MS"), out sleep) && sleep > 0) Thread.Sleep(sleep);
        string mutation = Environment.GetEnvironmentVariable("BOB3_MSDEV_MUTATE_PATH");
        if (!String.IsNullOrEmpty(mutation)) File.WriteAllText(mutation, "mutated\r\n", Encoding.GetEncoding(932));
        string deletePath = Environment.GetEnvironmentVariable("BOB3_MSDEV_DELETE_PATH");
        if (!String.IsNullOrEmpty(deletePath) && File.Exists(deletePath)) File.Delete(deletePath);
        string outputLog = null;
        for (int index = 0; index + 1 < args.Length; index++) if (String.Equals(args[index], "/OUT", StringComparison.OrdinalIgnoreCase)) outputLog = args[index + 1];
        string message;
        int exitCode;
        if (mode == "compile") { message = "src\\example.cpp(3) : error C2143: fixture compile failure"; exitCode = 1; }
        else if (mode == "compile-bare") { message = "example.cpp(3) : error C2143: ambiguous compile failure"; exitCode = 1; }
        else if (mode == "compile-other") { message = "src\\other.cpp(3) : error C2143: unrelated compile failure"; exitCode = 1; }
        else if (mode == "link") { message = "src\\example.obj : error LNK2001: fixture unresolved external"; exitCode = 1; }
        else if (mode == "cp932-log") { message = "src\\日本.cpp(3) : error C2143: fixture compile failure"; exitCode = 1; }
        else if (mode == "invalid-log") { message = "invalid log"; exitCode = 1; }
        else if (mode == "environment") { message = "MSDEV fatal environment failure"; exitCode = 2; }
        else if (mode == "no-success") { message = "build ended without a success marker"; exitCode = 0; }
        else { message = "0 error(s), 0 warning(s)"; exitCode = 0; }
        if (!String.IsNullOrEmpty(outputLog)) {
            Directory.CreateDirectory(Path.GetDirectoryName(outputLog));
            if (mode == "invalid-log") File.WriteAllBytes(outputLog, new byte[] { 0x81 });
            else File.WriteAllText(outputLog, message + Environment.NewLine, Encoding.GetEncoding(932));
        }
        if ((mode == "success" || mode == "no-success") && mode != "artifact-missing") {
            string artifact = Path.Combine(Environment.CurrentDirectory, "bin", "fixture.exe");
            Directory.CreateDirectory(Path.GetDirectoryName(artifact));
            File.WriteAllText(artifact, "fixture artifact", new UTF8Encoding(false));
        }
        if (mode == "artifact-missing") { message = "0 error(s), 0 warning(s)"; exitCode = 0; }
        Console.Out.WriteLine(mode == "cp932-log" || mode == "invalid-log" ? "build failed; inspect /OUT" : message);
        Console.Error.WriteLine("fixture stderr");
        string blockResultDirectory = Environment.GetEnvironmentVariable("BOB3_MSDEV_BLOCK_RESULT_DIRECTORY");
        if (!String.IsNullOrEmpty(blockResultDirectory)) {
            if (Directory.Exists(blockResultDirectory)) Directory.Delete(blockResultDirectory, true);
            File.WriteAllText(blockResultDirectory, "blocked", new UTF8Encoding(false));
        }
        return exitCode;
    }
}
'@
    $bazaarSource = @'
using System;
using System.IO;
using System.Text;
public static class FakeBazaar {
    public static int Main(string[] args) {
        string commandLog = Environment.GetEnvironmentVariable("BOB3_BZR_COMMAND_LOG");
        string command = args.Length == 0 ? "" : args[0];
        int occurrence = 1;
        if (!String.IsNullOrEmpty(commandLog) && File.Exists(commandLog)) {
            foreach (string prior in File.ReadAllLines(commandLog)) if (prior == command || prior.StartsWith(command + " ", StringComparison.Ordinal)) occurrence++;
        }
        if (!String.IsNullOrEmpty(commandLog)) File.AppendAllText(commandLog, String.Join(" ", args) + Environment.NewLine, new UTF8Encoding(false));
        string mutateCommand = Environment.GetEnvironmentVariable("BOB3_BZR_MUTATE_COMMAND");
        int mutateOccurrence;
        if (!Int32.TryParse(Environment.GetEnvironmentVariable("BOB3_BZR_MUTATE_OCCURRENCE"), out mutateOccurrence)) mutateOccurrence = 1;
        if (String.Equals(command, mutateCommand, StringComparison.OrdinalIgnoreCase) && occurrence == mutateOccurrence) {
            string mutatePath = Environment.GetEnvironmentVariable("BOB3_BZR_MUTATE_PATH");
            if (!String.IsNullOrEmpty(mutatePath)) File.WriteAllText(mutatePath, "bazaar mutated", new UTF8Encoding(false));
        }
        string failCommand = Environment.GetEnvironmentVariable("BOB3_BZR_FAIL_COMMAND");
        int failOccurrence;
        if (!Int32.TryParse(Environment.GetEnvironmentVariable("BOB3_BZR_FAIL_OCCURRENCE"), out failOccurrence)) failOccurrence = 1;
        if (String.Equals(command, failCommand, StringComparison.OrdinalIgnoreCase) && occurrence == failOccurrence) {
            int failCode;
            if (!Int32.TryParse(Environment.GetEnvironmentVariable("BOB3_BZR_FAIL_CODE"), out failCode)) failCode = 41;
            Console.Error.WriteLine("fixture Bazaar failure " + failCode);
            return failCode;
        }
        string value;
        if (command == "status") value = Environment.GetEnvironmentVariable("BOB3_BZR_STATUS") ?? "";
        else if (command == "diff") value = Environment.GetEnvironmentVariable("BOB3_BZR_DIFF") ?? "";
        else if (command == "nick") value = occurrence > 1 && !String.IsNullOrEmpty(Environment.GetEnvironmentVariable("BOB3_BZR_NICK_SECOND")) ? Environment.GetEnvironmentVariable("BOB3_BZR_NICK_SECOND") : Environment.GetEnvironmentVariable("BOB3_BZR_NICK") ?? "fixture-branch";
        else if (command == "version-info") value = occurrence > 1 && !String.IsNullOrEmpty(Environment.GetEnvironmentVariable("BOB3_BZR_REVISION_SECOND")) ? Environment.GetEnvironmentVariable("BOB3_BZR_REVISION_SECOND") : Environment.GetEnvironmentVariable("BOB3_BZR_REVISION") ?? "fixture-revision-id-full-123";
        else { Console.Error.WriteLine("forbidden fixture command: " + command); return 42; }
        if (!String.IsNullOrEmpty(value)) Console.Out.Write(value.EndsWith("\n") ? value : value + Environment.NewLine);
        int diffExit;
        if (command == "diff" && Int32.TryParse(Environment.GetEnvironmentVariable("BOB3_BZR_DIFF_EXIT"), out diffExit)) return diffExit;
        return 0;
    }
}
'@
    $msdevSourcePath = Join-Path $Directory 'FakeMsdev.cs'
    $bazaarSourcePath = Join-Path $Directory 'FakeBazaar.cs'
    $compilerPath = Join-Path $Directory 'Compile-Fakes.ps1'
    Write-Utf8NoBomFixture $msdevSourcePath $msdevSource
    Write-Utf8NoBomFixture $bazaarSourcePath $bazaarSource
    Write-Utf8NoBomFixture $compilerPath @'
param([string]$MsdevSource, [string]$MsdevOutput, [string]$BazaarSource, [string]$BazaarOutput)
$ErrorActionPreference = 'Stop'
Add-Type -Path $MsdevSource -OutputAssembly $MsdevOutput -OutputType ConsoleApplication
Add-Type -Path $BazaarSource -OutputAssembly $BazaarOutput -OutputType ConsoleApplication
'@
    $windowsPowerShell = (Get-Command powershell.exe -ErrorAction Stop).Source
    & $windowsPowerShell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $compilerPath -MsdevSource $msdevSourcePath -MsdevOutput $msdevPath -BazaarSource $bazaarSourcePath -BazaarOutput $bazaarPath
    if ($LASTEXITCODE -ne 0) { throw "Runtime fake executable compilation failed with exit code $LASTEXITCODE." }
    return [pscustomobject]@{ MsdevPath = $msdevPath; BazaarPath = $bazaarPath }
}

function Invoke-Task3BuildFixture {
    param([string]$ScriptPath, [string]$WorkPacketPath, [string]$Action, [int]$Attempt)
    $resultDirectory = Join-Path (Split-Path -Parent $WorkPacketPath) 'results'
    $before = @()
    if (Test-Path -LiteralPath $resultDirectory) { $before = @(Get-ChildItem -LiteralPath $resultDirectory -Filter 'build-result-*.json' -File | ForEach-Object FullName) }
    $invocation = Invoke-TestScript $ScriptPath @('-WorkPacket', $WorkPacketPath, '-Action', $Action, '-Attempt', ([string]$Attempt))
    $created = @(Get-ChildItem -LiteralPath $resultDirectory -Filter 'build-result-*.json' -File | Where-Object { $before -notcontains $_.FullName })
    if ($created.Count -ne 1) {
        throw "ASSERTION FAILED: Build $Action attempt $Attempt persists exactly one new JSON result (expected '1', got '$($created.Count)'). Invocation output: $($invocation.Output.Trim())"
    }
    $script:Assertions++
    $json = Get-Content -Raw -Encoding UTF8 -LiteralPath $created[0].FullName | ConvertFrom-Json
    return [pscustomobject]@{ ExitCode = $invocation.ExitCode; Output = $invocation.Output; Json = $json; ResultPath = $created[0].FullName }
}

function Assert-Task3BuildOutcome {
    param([object]$Result, [string]$Status, [int]$ExitCode, [string]$Message)
    Assert-Equal $Result.ExitCode $ExitCode "$Message uses the fixed process exit code; result message: $($Result.Json.message)"
    Assert-Equal $Result.Json.status $Status "$Message persists the fixed status token"
    Assert-Equal $Result.Json.exitCode $ExitCode "$Message persists the mapped exit code"
    Assert-True ($Result.Output -match ('(?m)^' + [regex]::Escape($Status) + '\s*$')) "$Message emits the fixed status token"
}

$task3RepoRoot = Split-Path -Parent $PSScriptRoot
$task3Installer = Join-Path $task3RepoRoot 'scripts/Install-TeamBobProfile.ps1'
$task3FixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('team-bob-task3-' + [guid]::NewGuid().ToString('N'))
$task3SavedEnvironment = @{}
$task3EnvironmentNames = @(
    'LOCALAPPDATA', 'BOB3_MSDEV_COMMAND_LOG', 'BOB3_MSDEV_MODE', 'BOB3_MSDEV_SLEEP_MS', 'BOB3_MSDEV_MUTATE_PATH', 'BOB3_MSDEV_DELETE_PATH',
    'BOB3_MSDEV_BLOCK_RESULT_DIRECTORY', 'BOB3_BZR_COMMAND_LOG', 'BOB3_BZR_STATUS', 'BOB3_BZR_DIFF', 'BOB3_BZR_DIFF_EXIT',
    'BOB3_BZR_NICK', 'BOB3_BZR_NICK_SECOND', 'BOB3_BZR_REVISION', 'BOB3_BZR_REVISION_SECOND', 'BOB3_BZR_FAIL_COMMAND',
    'BOB3_BZR_FAIL_CODE', 'BOB3_BZR_FAIL_OCCURRENCE', 'BOB3_BZR_MUTATE_COMMAND', 'BOB3_BZR_MUTATE_OCCURRENCE', 'BOB3_BZR_MUTATE_PATH'
)
foreach ($name in $task3EnvironmentNames) { $task3SavedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
$task3Bob3EnvironmentNames = @($task3EnvironmentNames | Where-Object { $_ -like 'BOB3_*' })
foreach ($name in $task3Bob3EnvironmentNames) { [Environment]::SetEnvironmentVariable($name, $null, 'Process') }
foreach ($name in $task3Bob3EnvironmentNames) {
    Assert-True ([string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($name, 'Process'))) "Task 3 fixture neutralizes inherited hostile control '$name' before fixture setup"
}

try {
    New-Item -ItemType Directory -Path $task3FixtureRoot | Out-Null
    $workingTree = Join-Path $task3FixtureRoot 'working-tree'
    New-Item -ItemType Directory -Path (Join-Path $workingTree '.bzr') -Force | Out-Null
    Write-Utf8NoBomFixture (Join-Path $workingTree '.bzr/branch.conf') 'fixture branch metadata'
    Write-Cp932Fixture (Join-Path $workingTree 'src/example.cpp') "int main() { return 0; }`r`n"
    Write-Cp932Fixture (Join-Path $workingTree 'src/other.cpp') "int other() { return 0; }`r`n"
    Write-Cp932Fixture (Join-Path $workingTree 'alternate/example.cpp') "int duplicate_name() { return 0; }`r`n"
    Write-Cp932Fixture (Join-Path $workingTree 'src/日本.cpp') "int japanese() { return 0; }`r`n"
    Write-Cp932Fixture (Join-Path $workingTree 'project/fixture.dsp') "# Microsoft Developer Studio Project File`r`n"
    Write-Utf8NoBomFixture (Join-Path $workingTree 'generated.pdb') 'excluded pdb'
    Write-Utf8NoBomFixture (Join-Path $workingTree 'obj/old.obj') 'excluded obj'
    $install = Invoke-TestScript $task3Installer @('-TargetPath', $workingTree)
    Assert-Equal $install.ExitCode 0 'Task 3 tests use a temporary installed repository copy'

    $fakeTools = New-Task3FakeExecutables (Join-Path $task3FixtureRoot 'fake-bin')
    $env:LOCALAPPDATA = Join-Path $task3FixtureRoot 'localappdata'
    $sandboxRoot = Join-Path $task3FixtureRoot 'sandboxes'
    $logRoot = Join-Path $task3FixtureRoot 'logs'
    $initializePath = Join-Path $workingTree 'team-bob/tools/Initialize-LocalEnvironment.ps1'
    $initialize = Invoke-TestScript $initializePath @('-MsdevPath', $fakeTools.MsdevPath, '-BazaarPath', $fakeTools.BazaarPath, '-SandboxRoot', $sandboxRoot, '-LogRoot', $logRoot)
    Assert-Equal $initialize.ExitCode 0 'Task 3 fixture registers only runtime fake executables in isolated LOCALAPPDATA'

    $profile = [pscustomobject]@{
        id = 'qualified-task3-fixture'; enabled = $true; projectFile = 'project/fixture.dsp'; target = 'Fixture - Win32 Release'; timeoutSeconds = 2
        expectedArtifacts = @('bin/fixture.exe'); excludePatterns = @('*.pdb', '**/*.obj'); outputLogPattern = 'build\.log$'; successPattern = '0 error\(s\)'
        compilerErrorPattern = 'error C[0-9]+'; linkerErrorPattern = 'LNK[0-9]+'; environmentErrorPattern = 'MSDEV fatal environment'
        qualification = [pscustomobject]@{
            msdevHelp = $true; makeSucceeded = $true; rebuildSucceeded = $true; compileFailureObserved = $true; linkFailureObserved = $true
            pcId = [Environment]::MachineName; recordId = 'fixture-qualification'; recordedAt = '2026-09-02T00:00:00Z'
        }
    }
    $catalogPath = Join-Path $workingTree 'team-bob/config/vc6-build-targets.json'
    Write-JsonFixture $catalogPath ([pscustomobject]@{ profiles = @($profile) })
    $taskId = 'BUILD-0001'
    $taskDirectory = Join-Path $workingTree ('team-bob-work/' + $taskId)
    New-Item -ItemType Directory -Path (Join-Path $taskDirectory 'results') -Force | Out-Null
    $workPacketPath = Join-Path $taskDirectory 'work-packet.md'
    Write-Task3PacketFixture $workPacketPath $workingTree $taskId @('src/example.cpp', 'src/日本.cpp') $profile.id
    $buildPath = Join-Path $workingTree 'team-bob/tools/Invoke-Vc6Build.ps1'
    $evidencePath = Join-Path $workingTree 'team-bob/tools/Export-BazaarEvidence.ps1'
    $buildCommonPath = Join-Path $workingTree 'team-bob/tools/TeamBob-BuildCommon.ps1'
    $env:BOB3_MSDEV_COMMAND_LOG = Join-Path $task3FixtureRoot 'msdev-commands.log'
    $env:BOB3_BZR_COMMAND_LOG = Join-Path $task3FixtureRoot 'bzr-commands.log'
    $env:BOB3_BZR_STATUS = ' M  src/example.cpp'
    $env:BOB3_BZR_DIFF = "=== modified file 'src/example.cpp'`ndiff --git a/src/example.cpp b/src/example.cpp`n"
    $env:BOB3_BZR_NICK = 'fixture-branch'
    $env:BOB3_BZR_REVISION = 'fixture-revision-id-full-123'
    $env:BOB3_MSDEV_MODE = 'success'
    $sourceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $workingTree 'src/example.cpp')).Hash
    $bzrFingerprint = Get-TreeFingerprintFixture (Join-Path $workingTree '.bzr')

    $environmentPath = Join-Path $env:LOCALAPPDATA 'IBM/BobTeamProfile/vc6-machine-control-poc/environment.json'
    $registeredEnvironment = Get-Content -Raw -LiteralPath $environmentPath | ConvertFrom-Json

    $toolJunctionAlias = Join-Path $task3FixtureRoot 'registered-tool-junction-alias'
    New-Item -ItemType Junction -Path $toolJunctionAlias -Target (Split-Path -Parent $fakeTools.MsdevPath) -ErrorAction Stop | Out-Null
    $registeredEnvironment.msdevPath = Join-Path $toolJunctionAlias 'MSDEV.EXE'
    Write-JsonFixture $environmentPath $registeredEnvironment
    $reparseMsdev = Invoke-Task3BuildFixture $buildPath $workPacketPath 'Make' 0
    Assert-Task3BuildOutcome $reparseMsdev 'ENVIRONMENT_FAILED' 20 'Registered MSDEV path through a reparse component'
    Assert-True ($reparseMsdev.Json.message -match 'reparse|physical') 'Registered MSDEV reparse rejection reaches the physical-leaf boundary'
    $registeredEnvironment.msdevPath = $fakeTools.MsdevPath
    Write-JsonFixture $environmentPath $registeredEnvironment
    [System.IO.Directory]::Delete($toolJunctionAlias)

    . $buildCommonPath
    $unlistedDeviceRejected = $false
    $unlistedDeviceMessage = ''
    try { Assert-TeamBobLocalPathForm '\Device\ThirdPartyRedirector\fixture-server.invalid\fixture-share\root' 'Unlisted redirector fixture' 'INTEGRITY_FAILED' } catch { $unlistedDeviceRejected = $true; $unlistedDeviceMessage = $_.Exception.Message }
    Assert-True $unlistedDeviceRejected 'Common path boundary rejects an unlisted device-namespace redirector'
    Assert-True ($unlistedDeviceMessage -match 'local|device|network') 'Unlisted redirector rejection identifies the local-volume boundary'

    foreach ($unsupportedDriveType in @(0, 1, 2, 4, 5, 6)) {
        $unsupportedDriveRejected = $false
        $unsupportedDriveMessage = ''
        try { Assert-TeamBobSupportedLocalDriveType $unsupportedDriveType 'Unsupported drive fixture' 'INTEGRITY_FAILED' } catch { $unsupportedDriveRejected = $true; $unsupportedDriveMessage = $_.Exception.Message }
        Assert-True $unsupportedDriveRejected ("Common path boundary rejects drive type " + $unsupportedDriveType)
        Assert-True ($unsupportedDriveMessage -match 'fixed local drive') ("Drive type " + $unsupportedDriveType + ' rejection identifies the fixed-local requirement')
    }
    $fixedDriveAccepted = $true
    try { Assert-TeamBobSupportedLocalDriveType 3 'Fixed-drive fixture' 'INTEGRITY_FAILED' } catch { $fixedDriveAccepted = $false }
    Assert-True $fixedDriveAccepted 'Common path boundary accepts only the DRIVE_FIXED local drive type'

    $localVolumeAccepted = $true
    try { Assert-TeamBobLocalPhysicalPath '\Device\HarddiskVolume42\fixture-root' 'Local-volume fixture' 'INTEGRITY_FAILED' } catch { $localVolumeAccepted = $false }
    Assert-True $localVolumeAccepted 'Physical path boundary accepts the supported local hard-disk volume form'
    $unlistedPhysicalRejected = $false
    $unlistedPhysicalMessage = ''
    try { Assert-TeamBobLocalPhysicalPath '\Device\ThirdPartyRedirector\fixture-root' 'Unlisted physical redirector fixture' 'INTEGRITY_FAILED' } catch { $unlistedPhysicalRejected = $true; $unlistedPhysicalMessage = $_.Exception.Message }
    Assert-True $unlistedPhysicalRejected 'Physical path boundary rejects an unlisted redirector device form'
    Assert-True ($unlistedPhysicalMessage -match 'local hard-disk volume') 'Physical redirector rejection identifies the positive local-volume requirement'

    $networkPathCases = @(
        [pscustomobject]@{ Name = 'lexical UNC'; Path = '\\fixture-server.invalid\fixture-share\root' },
        [pscustomobject]@{ Name = 'extended UNC'; Path = '\\?\UNC\fixture-server.invalid\fixture-share\root' },
        [pscustomobject]@{ Name = 'MUP network device'; Path = '\Device\Mup\fixture-server.invalid\fixture-share\root' },
        [pscustomobject]@{ Name = 'Lanman redirector device'; Path = '\Device\LanmanRedirector\;Z:000000000000\fixture-server.invalid\fixture-share\root' }
    )
    foreach ($networkPathCase in $networkPathCases) {
        $networkPathRejected = $false
        $networkPathMessage = ''
        try { [void](Get-TeamBobCanonicalPath $networkPathCase.Path) } catch { $networkPathRejected = $true; $networkPathMessage = $_.Exception.Message }
        Assert-True $networkPathRejected ("Common path boundary rejects " + $networkPathCase.Name + ' without accessing a share')
        Assert-True ($networkPathMessage -match 'local non-UNC|network') ("Common path boundary identifies " + $networkPathCase.Name + ' as a network alias')
    }

    $registeredEnvironment.msdevPath = '\\fixture-server.invalid\fixture-share\MSDEV.EXE'
    Write-JsonFixture $environmentPath $registeredEnvironment
    $uncMsdev = Invoke-Task3BuildFixture $buildPath $workPacketPath 'Make' 0
    Assert-Task3BuildOutcome $uncMsdev 'ENVIRONMENT_FAILED' 20 'Registered UNC MSDEV path'
    Assert-True ($uncMsdev.Json.message -match 'local non-UNC|network') 'Registered UNC MSDEV rejection identifies the local-only boundary'
    $registeredEnvironment.msdevPath = $fakeTools.MsdevPath

    $registeredEnvironment.bazaarPath = '\\?\UNC\fixture-server.invalid\fixture-share\BZR.EXE'
    Write-JsonFixture $environmentPath $registeredEnvironment
    $uncBazaar = Invoke-Task3BuildFixture $buildPath $workPacketPath 'Make' 0
    Assert-Task3BuildOutcome $uncBazaar 'ENVIRONMENT_FAILED' 20 'Registered extended UNC Bazaar path'
    Assert-True ($uncBazaar.Json.message -match 'local non-UNC|network') 'Registered extended UNC Bazaar rejection identifies the local-only boundary'
    $registeredEnvironment.bazaarPath = $fakeTools.BazaarPath

    $registeredEnvironment.sandboxRoot = '\\fixture-server.invalid\fixture-share\sandbox'
    Write-JsonFixture $environmentPath $registeredEnvironment
    $uncSandbox = Invoke-Task3BuildFixture $buildPath $workPacketPath 'Make' 0
    Assert-Task3BuildOutcome $uncSandbox 'ENVIRONMENT_FAILED' 20 'Registered UNC sandbox root'
    Assert-True ($uncSandbox.Json.message -match 'local non-UNC|network') 'Registered UNC sandbox rejection identifies the local-only boundary'
    $registeredEnvironment.sandboxRoot = $sandboxRoot

    $registeredEnvironment.logRoot = '\\?\UNC\fixture-server.invalid\fixture-share\logs'
    Write-JsonFixture $environmentPath $registeredEnvironment
    $uncLog = Invoke-Task3BuildFixture $buildPath $workPacketPath 'Make' 0
    Assert-Task3BuildOutcome $uncLog 'ENVIRONMENT_FAILED' 20 'Registered extended UNC log root'
    Assert-True ($uncLog.Json.message -match 'local non-UNC|network') 'Registered extended UNC log rejection identifies the local-only boundary'
    $registeredEnvironment.logRoot = $logRoot
    Write-JsonFixture $environmentPath $registeredEnvironment

    Write-Task3PacketFixture $workPacketPath '\\fixture-server.invalid\fixture-share\working-tree' $taskId @('src/example.cpp', 'src/日本.cpp') $profile.id
    $uncBazaarRoot = Invoke-Task3BuildFixture $buildPath $workPacketPath 'Make' 0
    Assert-Task3BuildOutcome $uncBazaarRoot 'INTEGRITY_FAILED' 30 'Work Packet UNC Bazaar root'
    Assert-True ($uncBazaarRoot.Json.message -match 'local non-UNC|network') 'Work Packet UNC Bazaar root rejection identifies the local-only boundary'
    Write-Task3PacketFixture $workPacketPath $workingTree $taskId @('src/example.cpp', 'src/日本.cpp') $profile.id

    $profile.projectFile = '\\fixture-server.invalid\fixture-share\fixture.dsp'
    Write-JsonFixture $catalogPath ([pscustomobject]@{ profiles = @($profile) })
    $uncProject = Invoke-Task3BuildFixture $buildPath $workPacketPath 'Make' 0
    Assert-Task3BuildOutcome $uncProject 'ENVIRONMENT_FAILED' 20 'Qualified project UNC path'
    $profile.projectFile = 'project/fixture.dsp'

    $profile.expectedArtifacts = @('\\?\UNC\fixture-server.invalid\fixture-share\fixture.exe')
    Write-JsonFixture $catalogPath ([pscustomobject]@{ profiles = @($profile) })
    $uncArtifact = Invoke-Task3BuildFixture $buildPath $workPacketPath 'Make' 0
    Assert-Task3BuildOutcome $uncArtifact 'ENVIRONMENT_FAILED' 20 'Qualified artifact extended UNC path'
    $profile.expectedArtifacts = @('bin/fixture.exe')
    Write-JsonFixture $catalogPath ([pscustomobject]@{ profiles = @($profile) })

    $junctionAlias = Join-Path $task3FixtureRoot 'sandbox-junction-alias'
    $junctionCreated = $false
    try {
        New-Item -ItemType Junction -Path $junctionAlias -Target $logRoot -ErrorAction Stop | Out-Null
        $junctionCreated = $true
    } catch {
        Write-Host "SKIP: Junction alias creation is unavailable: $($_.Exception.Message)"
    }
    if ($junctionCreated) {
        $registeredEnvironment.sandboxRoot = $junctionAlias
        Write-JsonFixture $environmentPath $registeredEnvironment
        [System.IO.File]::WriteAllText($env:BOB3_MSDEV_COMMAND_LOG, '')
        $junctionResult = Invoke-Task3BuildFixture $buildPath $workPacketPath 'Make' 0
        Assert-Task3BuildOutcome $junctionResult 'INTEGRITY_FAILED' 30 'Physical sandbox/log alias overlap'
        Assert-True ($junctionResult.Json.message -match 'physical|reparse|alias') 'Physical alias rejection identifies the physical/reparse boundary'
        Assert-Equal ([System.IO.File]::ReadAllText($env:BOB3_MSDEV_COMMAND_LOG)) '' 'Physical alias rejection occurs before MSDEV launch'
        $registeredEnvironment.sandboxRoot = $sandboxRoot
        Write-JsonFixture $environmentPath $registeredEnvironment
        [System.IO.Directory]::Delete($junctionAlias)
    }
    [System.IO.File]::WriteAllText($env:BOB3_BZR_COMMAND_LOG, '')

    $make = Invoke-Task3BuildFixture $buildPath $workPacketPath 'Make' 0
    Assert-Task3BuildOutcome $make 'SUCCEEDED' 0 'Successful Make'
    Assert-Equal $make.Json.action 'Make' 'Build result records the requested Make action'
    Assert-Equal $make.Json.attempt 0 'Build result records attempt zero'
    Assert-True (Test-Path -LiteralPath $make.Json.sandboxPath -PathType Container) 'Build creates a new per-attempt sandbox'
    Assert-True (Test-Path -LiteralPath (Join-Path $make.Json.sandboxPath 'bin/fixture.exe') -PathType Leaf) 'Successful build verifies the expected sandbox artifact'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $workingTree 'bin/fixture.exe'))) 'Original tree receives no VC6 artifact'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $make.Json.sandboxPath '.bzr'))) 'Sandbox excludes Bazaar metadata'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $make.Json.sandboxPath 'team-bob-work'))) 'Sandbox excludes task work directories'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $make.Json.sandboxPath 'generated.pdb'))) 'Sandbox excludes configured generated files'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $make.Json.sandboxPath 'obj/old.obj'))) 'Sandbox applies recursive generated-output exclusions'
    Assert-Equal (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $workingTree 'src/example.cpp')).Hash $sourceHash 'Make preserves pre-existing Allowed File bytes'
    Assert-Equal (Get-TreeFingerprintFixture (Join-Path $workingTree '.bzr')) $bzrFingerprint 'Make preserves every .bzr byte'
    Assert-Equal $make.Json.preBazaarStatus $env:BOB3_BZR_STATUS 'Result records the pre-existing Allowed File status'
    Assert-Equal $make.Json.postBazaarStatus $env:BOB3_BZR_STATUS 'Result proves Bazaar status is unchanged after build'
    Assert-True ([System.IO.File]::ReadAllText($make.Json.stdoutPath) -match '0 error') 'Build captures stdout to the registered log root'
    Assert-True ([System.IO.File]::ReadAllText($make.Json.stderrPath) -match 'fixture stderr') 'Build captures stderr without deadlock'
    $makeCommands = @(Get-Content -LiteralPath $env:BOB3_MSDEV_COMMAND_LOG)
    Assert-Equal $makeCommands.Count 1 'Make invokes MSDEV exactly once'
    $makeArguments = @($makeCommands[0] -split "`t")
    Assert-Equal $makeArguments[1] '/MAKE' 'Make selects only the qualified /MAKE switch'
    Assert-Equal $makeArguments[2] $profile.target 'Make passes the configuration-only target as one argument'
    Assert-Equal $makeArguments[3] '/OUT' 'Make passes the fixed output-log switch directly'
    $makeBazaarCommands = @(Get-Content -LiteralPath $env:BOB3_BZR_COMMAND_LOG)
    Assert-Equal ($makeBazaarCommands -join '|') 'status --short|nick|version-info --custom --template={revision_id}|status --short|nick|version-info --custom --template={revision_id}' 'Build proves pre/post status, branch, and full revision using read-only queries'

    [System.IO.File]::WriteAllText($env:BOB3_MSDEV_COMMAND_LOG, '')
    [System.IO.File]::WriteAllText($env:BOB3_BZR_COMMAND_LOG, '')
    $rebuild = Invoke-Task3BuildFixture $buildPath $workPacketPath 'Rebuild' 1
    Assert-Task3BuildOutcome $rebuild 'SUCCEEDED' 0 'Successful Rebuild'
    $rebuildCommand = @(Get-Content -LiteralPath $env:BOB3_MSDEV_COMMAND_LOG)[0] -split "`t"
    Assert-Equal $rebuildCommand[1] '/REBUILD' 'Rebuild performs exactly the requested /REBUILD action'

    $env:BOB3_MSDEV_MODE = 'compile'
    $compileRetry = Invoke-Task3BuildFixture $buildPath $workPacketPath 'Make' 0
    Assert-Task3BuildOutcome $compileRetry 'CODE_FAILED_RETRYABLE' 10 'Allowed-file compile failure before the final attempt'
    $compileStop = Invoke-Task3BuildFixture $buildPath $workPacketPath 'Make' 2
    Assert-Task3BuildOutcome $compileStop 'CODE_FAILED_STOP' 11 'Allowed-file compile failure on attempt two'
    $env:BOB3_MSDEV_MODE = 'compile-bare'
    $ambiguousCompile = Invoke-Task3BuildFixture $buildPath $workPacketPath 'Make' 0
    Assert-Task3BuildOutcome $ambiguousCompile 'CODE_FAILED_STOP' 11 'Duplicate bare source basename is not attributable'

    $env:BOB3_MSDEV_MODE = 'link'
    $linkRetry = Invoke-Task3BuildFixture $buildPath $workPacketPath 'Rebuild' 1
    Assert-Task3BuildOutcome $linkRetry 'CODE_FAILED_RETRYABLE' 10 'Allowed-object link failure with remaining repair budget'
    $env:BOB3_MSDEV_MODE = 'compile-other'
    $unrelated = Invoke-Task3BuildFixture $buildPath $workPacketPath 'Make' 0
    Assert-Task3BuildOutcome $unrelated 'CODE_FAILED_STOP' 11 'Unrelated compile failure'
    $env:BOB3_MSDEV_MODE = 'cp932-log'
    $cp932LogFailure = Invoke-Task3BuildFixture $buildPath $workPacketPath 'Make' 0
    Assert-Task3BuildOutcome $cp932LogFailure 'CODE_FAILED_RETRYABLE' 10 'CP932 /OUT log attributes Japanese Allowed File compile error'
    $env:BOB3_MSDEV_MODE = 'invalid-log'
    $invalidLogFailure = Invoke-Task3BuildFixture $buildPath $workPacketPath 'Make' 0
    Assert-Task3BuildOutcome $invalidLogFailure 'ENVIRONMENT_FAILED' 20 'Undecodable CP932 /OUT log fails safely'
    Assert-Equal ([System.IO.File]::ReadAllBytes($invalidLogFailure.Json.outputLogPath)).Length 1 'Undecodable /OUT log remains raw evidence'

    $env:BOB3_MSDEV_MODE = 'environment'
    $environmentFailure = Invoke-Task3BuildFixture $buildPath $workPacketPath 'Make' 0
    Assert-Task3BuildOutcome $environmentFailure 'ENVIRONMENT_FAILED' 20 'Configured environment error'
    $env:BOB3_MSDEV_MODE = 'artifact-missing'
    $artifactFailure = Invoke-Task3BuildFixture $buildPath $workPacketPath 'Make' 0
    Assert-Task3BuildOutcome $artifactFailure 'ENVIRONMENT_FAILED' 20 'Missing expected artifact'
    $env:BOB3_MSDEV_MODE = 'no-success'
    $successEvidenceFailure = Invoke-Task3BuildFixture $buildPath $workPacketPath 'Make' 0
    Assert-Task3BuildOutcome $successEvidenceFailure 'ENVIRONMENT_FAILED' 20 'Missing qualified success evidence'

    $msdevBytes = [System.IO.File]::ReadAllBytes($fakeTools.MsdevPath)
    $tamperedMsdevBytes = New-Object byte[] ($msdevBytes.Length + 1)
    [Array]::Copy($msdevBytes, $tamperedMsdevBytes, $msdevBytes.Length)
    $tamperedMsdevBytes[$tamperedMsdevBytes.Length - 1] = 0x7F
    [System.IO.File]::WriteAllBytes($fakeTools.MsdevPath, $tamperedMsdevBytes)
    $msdevHashFailure = Invoke-Task3BuildFixture $buildPath $workPacketPath 'Make' 0
    Assert-Task3BuildOutcome $msdevHashFailure 'ENVIRONMENT_FAILED' 20 'Mismatched registered MSDEV hash'
    [System.IO.File]::WriteAllBytes($fakeTools.MsdevPath, $msdevBytes)

    $profile.projectFile = 'project/missing.dsp'
    Write-JsonFixture $catalogPath ([pscustomobject]@{ profiles = @($profile) })
    $targetFailure = Invoke-Task3BuildFixture $buildPath $workPacketPath 'Make' 0
    Assert-Task3BuildOutcome $targetFailure 'ENVIRONMENT_FAILED' 20 'Missing qualified project target'
    $profile.projectFile = 'project/fixture.dsp'
    $profile.qualification.pcId = 'different-machine'
    Write-JsonFixture $catalogPath ([pscustomobject]@{ profiles = @($profile) })
    $qualificationFailure = Invoke-Task3BuildFixture $buildPath $workPacketPath 'Make' 0
    Assert-Task3BuildOutcome $qualificationFailure 'ENVIRONMENT_FAILED' 20 'Qualification recorded for another PC'
    $profile.qualification.pcId = [Environment]::MachineName

    $registeredEnvironment.sandboxRoot = $workingTree
    Write-JsonFixture $environmentPath $registeredEnvironment
    Write-JsonFixture $catalogPath ([pscustomobject]@{ profiles = @($profile) })
    $overlapFailure = Invoke-Task3BuildFixture $buildPath $workPacketPath 'Make' 0
    Assert-Task3BuildOutcome $overlapFailure 'INTEGRITY_FAILED' 30 'Source/sandbox root overlap'
    $registeredEnvironment.sandboxRoot = $sandboxRoot
    Write-JsonFixture $environmentPath $registeredEnvironment

    $profile.excludePatterns = @('*.pdb', '**/*.obj', 'src/example.cpp')
    Write-JsonFixture $catalogPath ([pscustomobject]@{ profiles = @($profile) })
    [System.IO.File]::WriteAllText($env:BOB3_MSDEV_COMMAND_LOG, '')
    $allowedExcluded = Invoke-Task3BuildFixture $buildPath $workPacketPath 'Make' 0
    Assert-Task3BuildOutcome $allowedExcluded 'INTEGRITY_FAILED' 30 'Profile exclusion removes an Allowed File from sandbox'
    Assert-Equal ([System.IO.File]::ReadAllText($env:BOB3_MSDEV_COMMAND_LOG)) '' 'Sandbox copy verification fails before MSDEV launch'
    $profile.excludePatterns = @('*.pdb', '**/*.obj')

    $profile.timeoutSeconds = 1
    Write-JsonFixture $catalogPath ([pscustomobject]@{ profiles = @($profile) })
    $env:BOB3_MSDEV_MODE = 'timeout-child'
    $timeoutStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $timeout = Invoke-Task3BuildFixture $buildPath $workPacketPath 'Make' 0
    $timeoutStopwatch.Stop()
    Assert-Task3BuildOutcome $timeout 'TIMED_OUT' 21 'Bounded MSDEV timeout'
    Assert-True ($timeout.Json.processId -gt 0) 'Timeout result identifies only the spawned process'
    Assert-Equal $timeout.Json.terminationComplete $true 'Timeout records completed owned process-tree termination'
    Assert-True ($timeoutStopwatch.Elapsed.TotalSeconds -lt 8) 'Timeout and output capture remain bounded when a descendant holds redirected handles'
    $env:BOB3_MSDEV_MODE = 'success'
    $profile.timeoutSeconds = 2
    Write-JsonFixture $catalogPath ([pscustomobject]@{ profiles = @($profile) })

    [System.IO.File]::WriteAllBytes((Join-Path $workingTree 'src/example.cpp'), [byte[]](0xEF, 0xBB, 0xBF, 0x0A))
    $encodingFailure = Invoke-Task3BuildFixture $buildPath $workPacketPath 'Make' 0
    Assert-Task3BuildOutcome $encodingFailure 'INTEGRITY_FAILED' 30 'BOM/non-CRLF Allowed File'
    [System.IO.File]::WriteAllBytes((Join-Path $workingTree 'src/example.cpp'), [byte[]](0x81))
    $cp932Failure = Invoke-Task3BuildFixture $buildPath $workPacketPath 'Make' 0
    Assert-Task3BuildOutcome $cp932Failure 'INTEGRITY_FAILED' 30 'Non-decodable CP932 Allowed File'
    Write-Cp932Fixture (Join-Path $workingTree 'src/example.cpp') "int main() { return 0; }`r`n"
    $sourceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $workingTree 'src/example.cpp')).Hash

    $env:BOB3_BZR_STATUS = ' M  src/other.cpp'
    $outsideStatus = Invoke-Task3BuildFixture $buildPath $workPacketPath 'Make' 0
    Assert-Task3BuildOutcome $outsideStatus 'INTEGRITY_FAILED' 30 'Out-of-Allowed-Files Bazaar change'
    foreach ($unsafeStatus in @('+N  src/example.cpp', 'R   src/example.cpp => src/renamed.cpp', '?   src/example.cpp', ' C  src/example.cpp')) {
        $env:BOB3_BZR_STATUS = $unsafeStatus
        $unsafeStatusResult = Invoke-Task3BuildFixture $buildPath $workPacketPath 'Make' 0
        Assert-Task3BuildOutcome $unsafeStatusResult 'INTEGRITY_FAILED' 30 "Unsupported Bazaar status '$unsafeStatus'"
    }
    $env:BOB3_BZR_STATUS = ' M  src/example.cpp'

    [System.IO.File]::WriteAllText($env:BOB3_BZR_COMMAND_LOG, '')
    $env:BOB3_BZR_MUTATE_COMMAND = 'status'
    $env:BOB3_BZR_MUTATE_OCCURRENCE = '1'
    $env:BOB3_BZR_MUTATE_PATH = Join-Path $workingTree '.bzr/branch.conf'
    $firstQueryMutation = Invoke-Task3BuildFixture $buildPath $workPacketPath 'Make' 0
    Assert-Task3BuildOutcome $firstQueryMutation 'INTEGRITY_FAILED' 30 'First Bazaar preflight query mutation'
    $env:BOB3_BZR_MUTATE_COMMAND = $null
    $env:BOB3_BZR_MUTATE_OCCURRENCE = $null
    $env:BOB3_BZR_MUTATE_PATH = $null
    Write-Utf8NoBomFixture (Join-Path $workingTree '.bzr/branch.conf') 'fixture branch metadata'

    [System.IO.File]::WriteAllText($env:BOB3_BZR_COMMAND_LOG, '')
    $env:BOB3_BZR_NICK = 'wrong-branch'
    $branchMismatch = Invoke-Task3BuildFixture $buildPath $workPacketPath 'Make' 0
    Assert-Task3BuildOutcome $branchMismatch 'INTEGRITY_FAILED' 30 'Pre-build Bazaar branch mismatch'
    $env:BOB3_BZR_NICK = 'fixture-branch'
    [System.IO.File]::WriteAllText($env:BOB3_BZR_COMMAND_LOG, '')
    $env:BOB3_BZR_NICK_SECOND = 'changed-after-build'
    $postBranchMismatch = Invoke-Task3BuildFixture $buildPath $workPacketPath 'Make' 0
    Assert-Task3BuildOutcome $postBranchMismatch 'INTEGRITY_FAILED' 30 'Post-build Bazaar branch mismatch'
    $env:BOB3_BZR_NICK_SECOND = $null

    [System.IO.File]::WriteAllText($env:BOB3_BZR_COMMAND_LOG, '')
    $env:BOB3_BZR_FAIL_COMMAND = 'status'
    $env:BOB3_BZR_FAIL_OCCURRENCE = '2'
    $env:BOB3_BZR_FAIL_CODE = '48'
    $postQueryFailure = Invoke-Task3BuildFixture $buildPath $workPacketPath 'Make' 0
    Assert-Task3BuildOutcome $postQueryFailure 'INTEGRITY_FAILED' 30 'Post-build Bazaar query failure prevents integrity proof'
    $env:BOB3_BZR_FAIL_COMMAND = $null
    $env:BOB3_BZR_FAIL_OCCURRENCE = $null
    $env:BOB3_BZR_FAIL_CODE = $null

    $env:BOB3_MSDEV_MODE = 'success'
    $env:BOB3_MSDEV_MUTATE_PATH = Join-Path $workingTree 'src/example.cpp'
    $mutationFailure = Invoke-Task3BuildFixture $buildPath $workPacketPath 'Make' 0
    Assert-Task3BuildOutcome $mutationFailure 'INTEGRITY_FAILED' 30 'Original-tree mutation during sandbox build'
    $env:BOB3_MSDEV_MUTATE_PATH = $null
    Write-Cp932Fixture (Join-Path $workingTree 'src/example.cpp') "int main() { return 0; }`r`n"

    $env:BOB3_MSDEV_DELETE_PATH = Join-Path $workingTree 'src/example.cpp'
    $deletionFailure = Invoke-Task3BuildFixture $buildPath $workPacketPath 'Make' 0
    Assert-Task3BuildOutcome $deletionFailure 'INTEGRITY_FAILED' 30 'Allowed File deletion during build postflight'
    $env:BOB3_MSDEV_DELETE_PATH = $null
    Write-Cp932Fixture (Join-Path $workingTree 'src/example.cpp') "int main() { return 0; }`r`n"

    Write-Task3PacketFixture $workPacketPath $workingTree $taskId @('src/example.cpp', 'src/日本.cpp') $profile.id @('../unsafe')
    $unsafeForbidden = Invoke-Task3BuildFixture $buildPath $workPacketPath 'Make' 0
    Assert-Task3BuildOutcome $unsafeForbidden 'INTEGRITY_FAILED' 30 'Unsafe Forbidden Areas entry'
    Write-Task3PacketFixture $workPacketPath $workingTree $taskId @('src/example.cpp', 'src/日本.cpp') $profile.id @("unsafe`tpath")
    $controlForbidden = Invoke-Task3BuildFixture $buildPath $workPacketPath 'Make' 0
    Assert-Task3BuildOutcome $controlForbidden 'INTEGRITY_FAILED' 30 'Forbidden Areas control-character entry'
    Write-Task3PacketFixture $workPacketPath $workingTree $taskId @('src/example.cpp', 'src/日本.cpp') $profile.id

    $env:BOB3_MSDEV_MODE = 'success'
    $env:BOB3_MSDEV_BLOCK_RESULT_DIRECTORY = Join-Path $taskDirectory 'results'
    $resultPersistenceFailure = Invoke-TestScript $buildPath @('-WorkPacket', $workPacketPath, '-Action', 'Make', '-Attempt', '0')
    Assert-Equal $resultPersistenceFailure.ExitCode 30 'Result persistence failure cannot return successful exit code'
    Assert-True ($resultPersistenceFailure.Output -match '(?m)^INTEGRITY_FAILED\s*$') 'Result persistence failure emits only INTEGRITY_FAILED status'
    $env:BOB3_MSDEV_BLOCK_RESULT_DIRECTORY = $null
    Remove-Item -LiteralPath (Join-Path $taskDirectory 'results') -Force
    New-Item -ItemType Directory -Path (Join-Path $taskDirectory 'results') | Out-Null

    [System.IO.File]::WriteAllText($env:BOB3_BZR_COMMAND_LOG, '')
    $evidenceSourceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $workingTree 'src/example.cpp')).Hash
    $evidenceBzrFingerprint = Get-TreeFingerprintFixture (Join-Path $workingTree '.bzr')
    $evidence = Invoke-TestScript $evidencePath @('-WorkPacket', $workPacketPath)
    Assert-Equal $evidence.ExitCode 0 'Bazaar evidence export succeeds with the registered fake executable'
    $evidenceCommands = @(Get-Content -LiteralPath $env:BOB3_BZR_COMMAND_LOG)
    Assert-Equal ($evidenceCommands -join '|') 'status --short|diff|nick|version-info --custom --template={revision_id}' 'Evidence invokes exactly the four approved read-only Bazaar queries in order'
    $evidenceResults = Join-Path $taskDirectory 'results'
    foreach ($name in @('bazaar-status.txt', 'bazaar-diff.patch', 'bazaar-nick.txt', 'bazaar-revision-id.txt', 'bazaar-evidence-manifest.json')) {
        Assert-True (Test-Path -LiteralPath (Join-Path $evidenceResults $name) -PathType Leaf) "Evidence writes $name under task results"
        $bytes = [System.IO.File]::ReadAllBytes((Join-Path $evidenceResults $name))
        Assert-True (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) "Evidence file $name is UTF-8 without BOM"
    }
    $evidenceManifest = Get-Content -Raw -LiteralPath (Join-Path $evidenceResults 'bazaar-evidence-manifest.json') | ConvertFrom-Json
    Assert-Equal ([System.IO.File]::ReadAllText((Join-Path $evidenceResults 'bazaar-status.txt')).TrimEnd("`r", "`n")) $env:BOB3_BZR_STATUS 'Evidence status file preserves exact status content'
    Assert-Equal ([System.IO.File]::ReadAllText((Join-Path $evidenceResults 'bazaar-diff.patch')).Replace("`r`n", "`n")) $env:BOB3_BZR_DIFF 'Evidence diff file preserves exact diff content'
    Assert-Equal $evidenceManifest.revisionId 'fixture-revision-id-full-123' 'Evidence manifest contains the exact full revision id'
    Assert-SetEqual $evidenceManifest.commands @('status --short', 'diff', 'nick', 'version-info --custom --template={revision_id}') 'Evidence manifest records only read-only commands'
    Assert-Equal (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $workingTree 'src/example.cpp')).Hash $evidenceSourceHash 'Evidence export preserves source bytes'
    Assert-Equal (Get-TreeFingerprintFixture (Join-Path $workingTree '.bzr')) $evidenceBzrFingerprint 'Evidence export preserves .bzr bytes'

    [System.IO.File]::Move($fakeTools.MsdevPath, ($fakeTools.MsdevPath + '.missing'))
    [System.IO.File]::WriteAllText($env:BOB3_BZR_COMMAND_LOG, '')
    $bazaarOnlyEvidence = Invoke-TestScript $evidencePath @('-WorkPacket', $workPacketPath)
    Assert-Equal $bazaarOnlyEvidence.ExitCode 0 'Bazaar evidence does not depend on MSDEV existence or hash'
    [System.IO.File]::Move(($fakeTools.MsdevPath + '.missing'), $fakeTools.MsdevPath)

    $env:BOB3_BZR_DIFF_EXIT = '1'
    [System.IO.File]::WriteAllText($env:BOB3_BZR_COMMAND_LOG, '')
    $diffOneEvidence = Invoke-TestScript $evidencePath @('-WorkPacket', $workPacketPath)
    Assert-Equal $diffOneEvidence.ExitCode 0 'Bazaar evidence accepts diff exit code one when differences exist'
    $diffOneManifest = Get-Content -Raw -LiteralPath (Join-Path $evidenceResults 'bazaar-evidence-manifest.json') | ConvertFrom-Json
    Assert-Equal (@($diffOneManifest.commandResults | Where-Object { $_.command -eq 'diff' })[0].exitCode) 1 'Evidence manifest preserves accepted diff exit code one'
    $env:BOB3_BZR_DIFF_EXIT = $null

    $env:BOB3_BZR_NICK = 'wrong-evidence-branch'
    $identityEvidenceFailure = Invoke-TestScript $evidencePath @('-WorkPacket', $workPacketPath)
    Assert-Equal $identityEvidenceFailure.ExitCode 30 'Evidence rejects Bazaar branch identity mismatching the Work Packet'
    $env:BOB3_BZR_NICK = 'fixture-branch'

    [System.IO.File]::WriteAllText($env:BOB3_BZR_COMMAND_LOG, '')
    $env:BOB3_BZR_FAIL_COMMAND = 'diff'
    $env:BOB3_BZR_FAIL_CODE = '47'
    $evidenceFailure = Invoke-TestScript $evidencePath @('-WorkPacket', $workPacketPath)
    Assert-Equal $evidenceFailure.ExitCode 47 'Evidence preserves a Bazaar command exit code as the script error code'
    Assert-True ($evidenceFailure.Output -match 'diff.*47') 'Evidence reports the failed read-only command and exact exit code'
    $env:BOB3_BZR_FAIL_COMMAND = $null
    $env:BOB3_BZR_FAIL_CODE = $null

    [System.IO.File]::WriteAllText($env:BOB3_BZR_COMMAND_LOG, '')
    $env:BOB3_BZR_FAIL_COMMAND = 'diff'
    $env:BOB3_BZR_FAIL_CODE = '47'
    $env:BOB3_BZR_MUTATE_COMMAND = 'diff'
    $env:BOB3_BZR_MUTATE_PATH = Join-Path $workingTree 'src/example.cpp'
    $evidenceMutationFailure = Invoke-TestScript $evidencePath @('-WorkPacket', $workPacketPath)
    Assert-Equal $evidenceMutationFailure.ExitCode 30 'Evidence command failure still detects source mutation in postflight'
    $env:BOB3_BZR_FAIL_COMMAND = $null
    $env:BOB3_BZR_FAIL_CODE = $null
    $env:BOB3_BZR_MUTATE_COMMAND = $null
    $env:BOB3_BZR_MUTATE_PATH = $null
    Write-Cp932Fixture (Join-Path $workingTree 'src/example.cpp') "int main() { return 0; }`r`n"

    $bazaarBytes = [System.IO.File]::ReadAllBytes($fakeTools.BazaarPath)
    $tamperedBytes = New-Object byte[] ($bazaarBytes.Length + 1)
    [Array]::Copy($bazaarBytes, $tamperedBytes, $bazaarBytes.Length)
    $tamperedBytes[$tamperedBytes.Length - 1] = 0x7F
    [System.IO.File]::WriteAllBytes($fakeTools.BazaarPath, $tamperedBytes)
    [System.IO.File]::WriteAllText($env:BOB3_BZR_COMMAND_LOG, '')
    $hashFailure = Invoke-TestScript $evidencePath @('-WorkPacket', $workPacketPath)
    Assert-True ($hashFailure.ExitCode -ne 0) 'Evidence refuses a Bazaar executable whose registered hash changed'
    Assert-Equal ([System.IO.File]::ReadAllText($env:BOB3_BZR_COMMAND_LOG)) '' 'Hash failure invokes no Bazaar command'
    [System.IO.File]::WriteAllBytes($fakeTools.BazaarPath, $bazaarBytes)
} finally {
    foreach ($name in $task3EnvironmentNames) { [Environment]::SetEnvironmentVariable($name, $task3SavedEnvironment[$name], 'Process') }
    if (Test-Path -LiteralPath $task3FixtureRoot) {
        $resolvedTask3Fixture = [System.IO.Path]::GetFullPath($task3FixtureRoot)
        $resolvedTask3Temp = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
        if (-not $resolvedTask3Fixture.StartsWith($resolvedTask3Temp, [System.StringComparison]::OrdinalIgnoreCase)) { throw "Refusing to remove Task 3 fixture outside temp root: $resolvedTask3Fixture" }
        Remove-Item -LiteralPath $resolvedTask3Fixture -Recurse -Force
    }
}

Write-Host "PASS: $script:Assertions total package, tool, build, and evidence assertions succeeded."
