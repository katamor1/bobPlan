[CmdletBinding()]
param([switch]$StaticOnly)

$ErrorActionPreference = 'Stop'

$demoAdapterStandalone = $null -eq (Get-Command Assert-True -ErrorAction SilentlyContinue)
if ($demoAdapterStandalone) {
    $script:Assertions = 0

    function Assert-True {
        param([bool]$Condition, [string]$Message)
        $script:Assertions++
        if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
    }

    function Assert-Equal {
        param([object]$Actual, [object]$Expected, [string]$Message)
        Assert-True ($Actual -eq $Expected) "$Message (expected '$Expected', got '$Actual')"
    }
}

function Assert-DemoAdapterRequiredFile {
    param([string]$RepoRoot, [string]$RelativePath)

    $path = Join-Path $RepoRoot ($RelativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
    Assert-True (Test-Path -LiteralPath $path -PathType Leaf) "Required demo adapter file is missing: $RelativePath"
    return $path
}

function Assert-DemoAdapterPropertySet {
    param([object]$Value, [string[]]$Expected, [string]$Message)
    Assert-Equal (@($Value.PSObject.Properties.Name | Sort-Object) -join ',') (@($Expected | Sort-Object) -join ',') $Message
}

function Write-DemoAdapterUtf8NoBom {
    param([string]$Path, [string]$Text)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { [void][System.IO.Directory]::CreateDirectory($parent) }
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Write-DemoAdapterJson {
    param([string]$Path, [object]$Value)
    Write-DemoAdapterUtf8NoBom $Path (($Value | ConvertTo-Json -Depth 20) + "`r`n")
}

function Get-DemoAdapterHash {
    param([string]$Path)
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Set-DemoAdapterFileBytesWithRetry {
    param([string]$Path, [byte[]]$Bytes)
    $lastError = $null
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        try {
            [System.IO.File]::WriteAllBytes($Path, $Bytes)
            return
        } catch [System.IO.IOException] {
            $lastError = $_
            Start-Sleep -Milliseconds 50
        }
    }
    throw $lastError
}

function Get-DemoAdapterTreeFingerprint {
    param([string]$Root)
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    return ((Get-ChildItem -LiteralPath $rootFull -File -Force -Recurse | Sort-Object FullName | ForEach-Object {
        $_.FullName.Substring($rootFull.Length).TrimStart('\', '/') + ':' + (Get-DemoAdapterHash $_.FullName)
    }) -join "`n")
}

function Invoke-DemoAdapterScript {
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

function Invoke-DemoAdapterExecutable {
    param([string]$Path, [string[]]$Arguments = @())
    $argumentText = @($Arguments | ForEach-Object {
        if ($_ -notmatch '[\s"]') { $_ } else { '"' + $_.Replace('\\', '\\').Replace('"', '\\"') + '"' }
    }) -join ' '
    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = $Path
    $start.Arguments = $argumentText
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false, $true)
    $start.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false, $true)
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $start
    [void]$process.Start()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    $exitCode = $process.ExitCode
    $process.Dispose()
    return [pscustomobject]@{ ExitCode = $exitCode; Output = ($stdout + $stderr) }
}

function Get-DemoAdapterUtf8Text {
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    Assert-True (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) "UTF-8 evidence is BOM-free: $Path"
    return (New-Object System.Text.UTF8Encoding($false, $true)).GetString($bytes)
}

function Get-DemoAdapterCp932Text {
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    Assert-True (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) "CP932 log has no UTF-8 BOM: $Path"
    Assert-True (-not ($bytes.Length -ge 2 -and (($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) -or ($bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF)))) "CP932 log has no UTF-16 BOM: $Path"
    $encoding = [System.Text.Encoding]::GetEncoding(932, (New-Object System.Text.EncoderExceptionFallback), (New-Object System.Text.DecoderExceptionFallback))
    $text = $encoding.GetString($bytes)
    Assert-True ($text -notmatch '(?<!\r)\n|\r(?!\n)') "CP932 log uses CRLF only: $Path"
    Assert-True ($text.EndsWith("`r`n", [System.StringComparison]::Ordinal)) "CP932 log ends with CRLF: $Path"
    return $text
}

function Get-DemoAdapterRoslynDirectory {
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
    if ($candidates.Count -eq 0) {
        foreach ($root in @("$env:ProgramFiles\Microsoft Visual Studio", "${env:ProgramFiles(x86)}\Microsoft Visual Studio")) {
            if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
            foreach ($versionDirectory in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
                foreach ($editionDirectory in @(Get-ChildItem -LiteralPath $versionDirectory.FullName -Directory -ErrorAction SilentlyContinue)) {
                    $candidate = Join-Path $editionDirectory.FullName 'MSBuild\Current\Bin\Roslyn\csc.exe'
                    if (Test-Path -LiteralPath $candidate -PathType Leaf) { $candidates += Get-Item -LiteralPath $candidate }
                }
            }
        }
    }
    $selected = @($candidates | Sort-Object FullName -Descending | Select-Object -First 1)
    Assert-Equal $selected.Count 1 'A local Roslyn compiler is available for adapter fixture compilation'
    return (Split-Path -Parent $selected[0].FullName)
}

function New-DemoAdapterFakeTools {
    param([string]$Directory)
    [void][System.IO.Directory]::CreateDirectory($Directory)
    $msBuildPath = Join-Path $Directory 'MSBuild.exe'
    $bazaarPath = Join-Path $Directory 'BZR.EXE'
    $msBuildSourcePath = Join-Path $Directory 'FakeMsBuild.cs'
    $bazaarSourcePath = Join-Path $Directory 'FakeBazaar.cs'
    $compilerPath = Join-Path $Directory 'Compile-Fakes.ps1'
    Write-DemoAdapterUtf8NoBom $msBuildSourcePath @'
using System;
using System.IO;
using System.Text;
using System.Threading;

public static class FakeMsBuild {
    private static string Encode(string value) {
        if (value == null) return "~";
        return Convert.ToBase64String(Encoding.UTF8.GetBytes(value));
    }

    public static int Main(string[] args) {
        string trace = Environment.GetEnvironmentVariable("TEAM_BOB_FAKE_MSBUILD_TRACE");
        string mode = Environment.GetEnvironmentVariable("TEAM_BOB_FAKE_MSBUILD_MODE") ?? String.Empty;
        if (!String.IsNullOrEmpty(trace)) {
            string[] fields = new string[] {
                Encode(String.Join("\u001f", args)), Encode(Environment.GetEnvironmentVariable("CL")),
                Encode(Environment.GetEnvironmentVariable("_CL_")), Encode(Environment.GetEnvironmentVariable("LINK")),
                Encode(Environment.GetEnvironmentVariable("_LINK_")),
                Encode(Environment.GetEnvironmentVariable("VCTargetsPath")),
                Encode(Environment.GetEnvironmentVariable("MSBuildExtensionsPath")),
                Encode(Environment.GetEnvironmentVariable("MSBuildExtensionsPath32")),
                Encode(Environment.GetEnvironmentVariable("MSBuildExtensionsPath64")),
                Encode(Environment.GetEnvironmentVariable("MSBuildSDKsPath")),
                Encode(Environment.GetEnvironmentVariable("MSBuildToolsPath")),
                Encode(Environment.GetEnvironmentVariable("PATH")), Encode(Environment.GetEnvironmentVariable("INCLUDE")),
                Encode(Environment.GetEnvironmentVariable("LIB")), Encode(Environment.GetEnvironmentVariable("LIBPATH")),
                Encode(Environment.GetEnvironmentVariable("TEMP")), Encode(Environment.GetEnvironmentVariable("TMP")),
                Encode(Environment.GetEnvironmentVariable("COR_ENABLE_PROFILING")), Encode(Environment.GetEnvironmentVariable("COR_PROFILER")),
                Encode(Environment.GetEnvironmentVariable("CORECLR_ENABLE_PROFILING")), Encode(Environment.GetEnvironmentVariable("COMPLUS_TEST_POISON")),
                Encode(Environment.GetEnvironmentVariable("DOTNET_STARTUP_HOOKS")), Encode(Environment.GetEnvironmentVariable("__COMPAT_LAYER")),
                Encode(mode)
            };
            File.AppendAllText(trace, String.Join("|", fields) + "\r\n", new UTF8Encoding(false));
        }
        if (String.Equals(mode, "timeout", StringComparison.Ordinal)) { Thread.Sleep(30000); return 9; }
        if (args.Length != 10) { Console.WriteLine("FAKE_MSBUILD_INVALID_ARG_COUNT=" + args.Length); return 8; }
        string projectDirectory = Path.GetDirectoryName(args[0]);
        string testSource = Path.Combine(projectDirectory, @"tests\CycleWatchTests.cpp");
        if (String.Equals(Environment.GetEnvironmentVariable("CL"), "/DTEAM_BOB_DEMO_FAULT", StringComparison.Ordinal)) {
            Console.WriteLine(@"src\CycleWatch.cpp(9) : error C1189: MSBUILD_DEMO_ADAPTER_INTENTIONAL_COMPILER_FAULT ""demo/CycleWatch/src/CycleWatch.cpp"" AFTER_EVIDENCE_REPLACE_THIS_EXACT_LINE_WITH: #pragma message(""MSBUILD_DEMO_ADAPTER_INTENTIONAL_FAULT_REPAIRED demo/CycleWatch/src/CycleWatch.cpp"")");
            return 1;
        }
        if (File.Exists(testSource)) {
            string sourceText = Encoding.GetEncoding(932).GetString(File.ReadAllBytes(testSource));
            if (sourceText.IndexOf("TEAM_BOB_DEMO_MISSING_LINK_SYMBOL", StringComparison.Ordinal) >= 0) {
                Console.WriteLine(@"tests\CycleWatchTests.obj : error LNK2019: unresolved external symbol TEAM_BOB_DEMO_MISSING_LINK_SYMBOL");
                return 1;
            }
        }
        if (String.Equals(mode, "native-failure", StringComparison.Ordinal)) { Console.WriteLine("FAKE_MSBUILD_NATIVE_FAILURE"); return 3; }
        byte[] localized = new UTF8Encoding(false, true).GetBytes("FAKE_MSBUILD_LOCALIZED_SUCCESS_\u65e5\u672c\u8a9e\r\n");
        using (Stream output = Console.OpenStandardOutput()) { output.Write(localized, 0, localized.Length); output.Flush(); }
        if (!String.Equals(mode, "missing-artifact", StringComparison.Ordinal)) {
            string artifact = Path.Combine(projectDirectory, @"bin\Release\CycleWatchTests.exe");
            Directory.CreateDirectory(Path.GetDirectoryName(artifact));
            File.WriteAllBytes(artifact, Encoding.ASCII.GetBytes("synthetic-adapter-artifact\r\n"));
        }
        if (String.Equals(mode, "evidence-collision", StringComparison.Ordinal)) {
            string blockerPath = Environment.GetEnvironmentVariable("TEAM_BOB_FAKE_EVIDENCE_BLOCK_PATH");
            File.WriteAllText(blockerPath, "foreign-evidence-blocker\r\n", Encoding.ASCII);
        }
        return 0;
    }
}

'@
    Write-DemoAdapterUtf8NoBom $bazaarSourcePath @'
using System;
public static class FakeBazaar {
    public static int Main(string[] args) {
        if (args.Length == 0) return 2;
        if (String.Equals(args[0], "status", StringComparison.Ordinal)) return 0;
        if (String.Equals(args[0], "nick", StringComparison.Ordinal)) { Console.WriteLine("fixture-branch"); return 0; }
        if (String.Equals(args[0], "version-info", StringComparison.Ordinal)) { Console.WriteLine("fixture-revision-id-full-123"); return 0; }
        if (String.Equals(args[0], "diff", StringComparison.Ordinal)) return 1;
        return 2;
    }
}
'@
    Write-DemoAdapterUtf8NoBom $compilerPath @'
param([string]$MsBuildSource, [string]$MsBuildOutput, [string]$BazaarSource, [string]$BazaarOutput)
$ErrorActionPreference = 'Stop'
Add-Type -Path $MsBuildSource -OutputAssembly $MsBuildOutput -OutputType ConsoleApplication
Add-Type -Path $BazaarSource -OutputAssembly $BazaarOutput -OutputType ConsoleApplication
'@
    $windowsPowerShell = (Get-Command powershell.exe -ErrorAction Stop).Source
    & $windowsPowerShell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $compilerPath -MsBuildSource $msBuildSourcePath -MsBuildOutput $msBuildPath -BazaarSource $bazaarSourcePath -BazaarOutput $bazaarPath
    if ($LASTEXITCODE -ne 0) { throw "Fake tool compilation failed with exit code $LASTEXITCODE." }
    $roslynDestination = Join-Path $Directory 'Roslyn'
    Copy-Item -LiteralPath (Get-DemoAdapterRoslynDirectory) -Destination $roslynDestination -Recurse
    Assert-True (Test-Path -LiteralPath (Join-Path $roslynDestination 'csc.exe') -PathType Leaf) 'Fake MSBuild has an adjacent Roslyn csc.exe'
    return [pscustomobject]@{ MsBuildPath = $msBuildPath; BazaarPath = $bazaarPath; CscPath = (Join-Path $roslynDestination 'csc.exe') }
}

function New-DemoAdapterManifestCollisionTools {
    param([string]$Directory, [string]$MsBuildSeed)
    [void][System.IO.Directory]::CreateDirectory($Directory)
    $msBuildPath = Join-Path $Directory 'MSBuild.exe'
    Copy-Item -LiteralPath $MsBuildSeed -Destination $msBuildPath
    $roslynDirectory = Join-Path $Directory 'Roslyn'
    [void][System.IO.Directory]::CreateDirectory($roslynDirectory)
    $sourcePath = Join-Path $Directory 'ManifestCollisionCsc.cs'
    $cscPath = Join-Path $roslynDirectory 'csc.exe'
    Write-DemoAdapterUtf8NoBom $sourcePath @'
using System;
using System.IO;

public static class ManifestCollisionCsc {
    public static int Main(string[] args) {
        string outputPath = null;
        foreach (string argument in args) {
            if (argument.StartsWith("/out:", StringComparison.OrdinalIgnoreCase)) outputPath = argument.Substring(5);
        }
        string seedPath = Environment.GetEnvironmentVariable("TEAM_BOB_TEST_ADAPTER_SEED");
        string blockerPath = Environment.GetEnvironmentVariable("TEAM_BOB_TEST_MANIFEST_BLOCK");
        if (String.IsNullOrEmpty(outputPath) || String.IsNullOrEmpty(seedPath) || String.IsNullOrEmpty(blockerPath)) return 91;
        File.Copy(seedPath, outputPath, false);
        Directory.CreateDirectory(blockerPath);
        return 0;
    }
}
'@
    $realCsc = Join-Path (Get-DemoAdapterRoslynDirectory) 'csc.exe'
    & $realCsc /nologo /noconfig /target:exe /reference:System.dll ('/out:' + $cscPath) $sourcePath
    if ($LASTEXITCODE -ne 0) { throw "Manifest-collision compiler fixture failed with exit code $LASTEXITCODE." }
    return [pscustomobject]@{ MsBuildPath = $msBuildPath; CscPath = $cscPath }
}

function ConvertFrom-DemoAdapterTraceValue {
    param([string]$Value)
    if ($Value -eq '~') { return $null }
    return [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Value))
}

function Read-DemoAdapterTrace {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    $records = @()
    foreach ($line in [System.IO.File]::ReadAllLines($Path, (New-Object System.Text.UTF8Encoding($false, $true)))) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $fields = $line.Split('|')
        Assert-Equal $fields.Length 24 'Fake MSBuild trace has a closed field count'
        $argumentText = ConvertFrom-DemoAdapterTraceValue $fields[0]
        $records += [pscustomobject]@{
            Arguments = if ([string]::IsNullOrEmpty($argumentText)) { @() } else { @($argumentText.Split([char]0x1F)) }
            CL = ConvertFrom-DemoAdapterTraceValue $fields[1]
            UnderCl = ConvertFrom-DemoAdapterTraceValue $fields[2]
            Link = ConvertFrom-DemoAdapterTraceValue $fields[3]
            UnderLink = ConvertFrom-DemoAdapterTraceValue $fields[4]
            VcTargetsPath = ConvertFrom-DemoAdapterTraceValue $fields[5]
            MsBuildExtensionsPath = ConvertFrom-DemoAdapterTraceValue $fields[6]
            MsBuildExtensionsPath32 = ConvertFrom-DemoAdapterTraceValue $fields[7]
            MsBuildExtensionsPath64 = ConvertFrom-DemoAdapterTraceValue $fields[8]
            MsBuildSdksPath = ConvertFrom-DemoAdapterTraceValue $fields[9]
            MsBuildToolsPath = ConvertFrom-DemoAdapterTraceValue $fields[10]
            Path = ConvertFrom-DemoAdapterTraceValue $fields[11]
            Include = ConvertFrom-DemoAdapterTraceValue $fields[12]
            Lib = ConvertFrom-DemoAdapterTraceValue $fields[13]
            LibPath = ConvertFrom-DemoAdapterTraceValue $fields[14]
            Temp = ConvertFrom-DemoAdapterTraceValue $fields[15]
            Tmp = ConvertFrom-DemoAdapterTraceValue $fields[16]
            CorEnableProfiling = ConvertFrom-DemoAdapterTraceValue $fields[17]
            CorProfiler = ConvertFrom-DemoAdapterTraceValue $fields[18]
            CoreClrEnableProfiling = ConvertFrom-DemoAdapterTraceValue $fields[19]
            ComPlusPoison = ConvertFrom-DemoAdapterTraceValue $fields[20]
            DotNetStartupHooks = ConvertFrom-DemoAdapterTraceValue $fields[21]
            CompatLayer = ConvertFrom-DemoAdapterTraceValue $fields[22]
            Mode = ConvertFrom-DemoAdapterTraceValue $fields[23]
        }
    }
    return @($records)
}

function New-DemoAdapterInvocation {
    param(
        [string]$DistributionRoot, [string]$SandboxRoot, [string]$LogRoot, [string]$TaskId,
        [int]$Attempt, [ValidateSet('make', 'rebuild')][string]$Action,
        [string]$Token = '0123456789abcdef0123456789abcdef'
    )
    $invocationId = "attempt-$Attempt-$Action-$Token"
    $projectDirectory = Join-Path (Join-Path (Join-Path $SandboxRoot $TaskId) $invocationId) 'demo\CycleWatch'
    $logDirectory = Join-Path (Join-Path $LogRoot $TaskId) $invocationId
    [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $projectDirectory))
    [void][System.IO.Directory]::CreateDirectory($logDirectory)
    Copy-Item -LiteralPath (Join-Path $DistributionRoot 'demo\CycleWatch') -Destination $projectDirectory -Recurse
    return [pscustomobject]@{
        TaskId = $TaskId; Attempt = $Attempt; Action = $Action; InvocationId = $invocationId
        ProjectDirectory = $projectDirectory; ProjectPath = (Join-Path $projectDirectory 'CycleWatch.dsp')
        VcxProjectPath = (Join-Path $projectDirectory 'CycleWatch.vcxproj'); LogDirectory = $logDirectory
        LogPath = (Join-Path $logDirectory 'build.log'); EvidencePath = (Join-Path $logDirectory 'build.log.evidence.json')
        ArtifactPath = (Join-Path $projectDirectory 'bin\Release\CycleWatchTests.exe')
    }
}

function Clear-DemoAdapterTrace {
    param([string]$Path)
    [System.IO.File]::WriteAllText($Path, '', (New-Object System.Text.UTF8Encoding($false)))
}

function Set-DemoAdapterKnownSourceVariant {
    param([string]$Path, [ValidateSet('threshold3-error', 'threshold3-fixed')][string]$Variant)
    $encoding = [System.Text.Encoding]::GetEncoding(932, (New-Object System.Text.EncoderExceptionFallback), (New-Object System.Text.DecoderExceptionFallback))
    $text = $encoding.GetString([System.IO.File]::ReadAllBytes($Path))
    $text = $text.Replace('if (consecutiveOverruns_ >= 1U) {', 'if (consecutiveOverruns_ >= 3U) {')
    if ($Variant -eq 'threshold3-fixed') {
        $faultLine = '#error MSBUILD_DEMO_ADAPTER_INTENTIONAL_COMPILER_FAULT "demo/CycleWatch/src/CycleWatch.cpp" AFTER_EVIDENCE_REPLACE_THIS_EXACT_LINE_WITH: #pragma message("MSBUILD_DEMO_ADAPTER_INTENTIONAL_FAULT_REPAIRED demo/CycleWatch/src/CycleWatch.cpp")'
        $fixedLine = '#pragma message("MSBUILD_DEMO_ADAPTER_INTENTIONAL_FAULT_REPAIRED demo/CycleWatch/src/CycleWatch.cpp")'
        $text = $text.Replace($faultLine, $fixedLine)
    }
    [System.IO.File]::WriteAllBytes($Path, $encoding.GetBytes($text))
}

function Set-DemoAdapterKnownLinkerTestsVariant {
    param([string]$Path)
    $encoding = [System.Text.Encoding]::GetEncoding(932, (New-Object System.Text.EncoderExceptionFallback), (New-Object System.Text.DecoderExceptionFallback))
    $text = $encoding.GetString([System.IO.File]::ReadAllBytes($Path))
    $needle = 'int main() {'
    $replacement = 'extern "C" void TEAM_BOB_DEMO_MISSING_LINK_SYMBOL();' + "`r`n`r`n" + $needle + "`r`n    TEAM_BOB_DEMO_MISSING_LINK_SYMBOL();"
    [System.IO.File]::WriteAllBytes($Path, $encoding.GetBytes($text.Replace($needle, $replacement)))
}

function Assert-DemoAdapterEnvironmentFailure {
    param([object]$Result, [string]$Reason, [string]$Message)
    Assert-Equal $Result.ExitCode 20 "$Message returns adapter environment exit 20"
    Assert-True ($Result.Output -match '(?m)^MSBUILD DEMO ADAPTER - NOT VC6 QUALIFICATION\r?$') "$Message always displays the fixed non-qualification banner; output: $($Result.Output.Trim())"
    Assert-True ($Result.Output -match ('TEAM_BOB_ADAPTER_ENVIRONMENT_ERROR=' + [regex]::Escape($Reason))) "$Message emits stable reason '$Reason'; output: $($Result.Output.Trim())"
}

$demoAdapterAssertionsBefore = $script:Assertions
$demoAdapterRepoRoot = Split-Path -Parent $PSScriptRoot

$adapterSourcePath = Assert-DemoAdapterRequiredFile $demoAdapterRepoRoot 'demo/adapter/DemoMsdevAdapter.cs'
$adapterBuildPath = Assert-DemoAdapterRequiredFile $demoAdapterRepoRoot 'demo/tools/Build-DemoMsdevAdapter.ps1'
$adapterQualificationPath = Assert-DemoAdapterRequiredFile $demoAdapterRepoRoot 'demo/tools/Invoke-DemoAdapterQualification.ps1'

$adapterSourceContract = [System.IO.File]::ReadAllText($adapterSourcePath)
$adapterBuildContract = [System.IO.File]::ReadAllText($adapterBuildPath)
$adapterQualificationContract = [System.IO.File]::ReadAllText($adapterQualificationPath)
foreach ($requiredConfigurationField in @(
    'CycleWatchHeaderSha256', 'CycleWatchTestsSha256', 'CycleWatchTestsLinkerProbeSha256',
    'CycleWatchSourceBaselineSha256', 'CycleWatchSourceThreshold3ErrorSha256', 'CycleWatchSourceThreshold3FixedSha256'
)) {
    Assert-True ($adapterSourceContract.Contains('DemoAdapterConfiguration.' + $requiredConfigurationField)) "Adapter consumes fixed compiler-input field '$requiredConfigurationField'"
    Assert-True ($adapterBuildContract.Contains($requiredConfigurationField)) "Build configuration emits fixed compiler-input field '$requiredConfigurationField'"
    $qualificationField = $requiredConfigurationField.Substring(0, 1).ToLowerInvariant() + $requiredConfigurationField.Substring(1)
    Assert-True ($adapterQualificationContract.Contains($qualificationField)) "Qualification manifest validates fixed compiler-input field '$qualificationField'"
}
foreach ($requiredEvidenceField in @('cycleWatchSourceSha256', 'cycleWatchSourceVariant', 'cycleWatchHeaderSha256', 'cycleWatchTestsSha256')) {
    Assert-True ($adapterSourceContract.Contains('"' + $requiredEvidenceField + '"')) "Adapter evidence emits observed compiler-input field '$requiredEvidenceField'"
    Assert-True ($adapterQualificationContract.Contains("'$requiredEvidenceField'")) "Qualification validates observed compiler-input field '$requiredEvidenceField'"
}
foreach ($requiredFailure in @('OUTPUT_BIN_EXISTS', 'OUTPUT_OBJ_EXISTS', 'SOURCE_HASH', 'HEADER_HASH', 'TESTS_HASH')) {
    Assert-True ($adapterSourceContract.Contains('"' + $requiredFailure + '"')) "Adapter has stable failure '$requiredFailure'"
}
Assert-True ($adapterSourceContract.Contains('PrepareOwnedOutputDirectories')) 'Adapter owns empty bin/Release and obj/Release directories before launch'
Assert-True ($adapterSourceContract.Contains('ValidateOwnedOutputDirectories')) 'Adapter revalidates owned output directories around native execution'
Assert-True ($adapterSourceContract.Contains('ValidateCompilerInputs')) 'Adapter validates every compiled input before launch'
Assert-True ($adapterBuildContract.Contains('MSBUILD_DEMO_ADAPTER_INTENTIONAL_FAULT_REPAIRED')) 'Build derives the exact repaired source variant from distribution baseline'
Assert-True ($adapterBuildContract.Contains('TEAM_BOB_DEMO_MISSING_LINK_SYMBOL')) 'Build derives the exact qualification linker-probe variant from distribution baseline'

if ($StaticOnly) {
    Write-Host "PASS: $script:Assertions static demo adapter contract assertions succeeded."
    exit 0
}

$profileFingerprintBefore = Get-DemoAdapterTreeFingerprint (Join-Path $demoAdapterRepoRoot 'profile')
$demoSourceFingerprintBefore = Get-DemoAdapterTreeFingerprint (Join-Path $demoAdapterRepoRoot 'demo\CycleWatch')
$demoAdapterFixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('team-bob-demo-adapter-' + [guid]::NewGuid().ToString('N'))
$demoAdapterFixtureFull = [System.IO.Path]::GetFullPath($demoAdapterFixtureRoot)
$demoAdapterTempFull = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\', '/')
Assert-True ($demoAdapterFixtureFull.StartsWith($demoAdapterTempFull + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) 'Adapter fixture is a verified child of the system temporary root'
Assert-True ((New-Object System.IO.DriveInfo([System.IO.Path]::GetPathRoot($demoAdapterFixtureFull))).DriveType -eq [System.IO.DriveType]::Fixed) 'Adapter fixture uses a fixed local drive'
[void][System.IO.Directory]::CreateDirectory($demoAdapterFixtureFull)

$savedEnvironment = @{}
$environmentNames = @(
    'TEAM_BOB_FAKE_MSBUILD_TRACE', 'TEAM_BOB_FAKE_MSBUILD_MODE', 'CL', '_CL_', 'LINK', '_LINK_',
    'VCTargetsPath', 'MSBuildExtensionsPath', 'MSBuildExtensionsPath32', 'MSBuildExtensionsPath64', 'MSBuildSDKsPath', 'MSBuildToolsPath',
    'TEAM_BOB_TEST_ADAPTER_SEED', 'TEAM_BOB_TEST_MANIFEST_BLOCK', 'TEAM_BOB_FAKE_EVIDENCE_BLOCK_PATH'
)
foreach ($name in $environmentNames) { $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }

try {
    $distributionRoot = Join-Path $demoAdapterFixtureFull 'distribution'
    $sandboxRoot = Join-Path $demoAdapterFixtureFull 'sandboxes'
    $logRoot = Join-Path $demoAdapterFixtureFull 'logs'
    $toolsRoot = Join-Path $demoAdapterFixtureFull 'tools'
    $secondToolsRoot = Join-Path $demoAdapterFixtureFull 'tools-second'
    $buildTempRoot = Join-Path $demoAdapterFixtureFull 'build-temp'
    $fakeToolsRoot = Join-Path $demoAdapterFixtureFull 'fake-msbuild'
    foreach ($directory in @($distributionRoot, $sandboxRoot, $logRoot, $toolsRoot, $secondToolsRoot, $buildTempRoot, $fakeToolsRoot)) {
        [void][System.IO.Directory]::CreateDirectory($directory)
    }
    [void][System.IO.Directory]::CreateDirectory((Join-Path $distributionRoot 'demo\adapter'))
    Copy-Item -LiteralPath (Join-Path $demoAdapterRepoRoot 'demo\CycleWatch') -Destination (Join-Path $distributionRoot 'demo\CycleWatch') -Recurse
    Copy-Item -LiteralPath $adapterSourcePath -Destination (Join-Path $distributionRoot 'demo\adapter\DemoMsdevAdapter.cs')
    $distributionFingerprint = Get-DemoAdapterTreeFingerprint $distributionRoot
    $fakeTools = New-DemoAdapterFakeTools $fakeToolsRoot
    $tracePath = Join-Path $demoAdapterFixtureFull 'msbuild-trace.log'
    Clear-DemoAdapterTrace $tracePath
    $env:TEAM_BOB_FAKE_MSBUILD_TRACE = $tracePath
    $env:TEAM_BOB_FAKE_MSBUILD_MODE = ''

    $build = Invoke-DemoAdapterScript $adapterBuildPath @(
        '-MsBuildPath', $fakeTools.MsBuildPath, '-DistributionRoot', $distributionRoot,
        '-SandboxRoot', $sandboxRoot, '-LogRoot', $logRoot,
        '-OutputDirectory', $toolsRoot, '-TemporaryRoot', $buildTempRoot
    )
    Assert-Equal $build.ExitCode 0 "Adapter build succeeds with pinned fake MSBuild and adjacent Roslyn; output: $($build.Output.Trim())"
    $adapterPath = Join-Path $toolsRoot 'DemoMsdevAdapter.exe'
    $manifestPath = Join-Path $toolsRoot 'DemoMsdevAdapter.build-manifest.json'
    Assert-True (Test-Path -LiteralPath $adapterPath -PathType Leaf) 'Build emits the fixed adapter executable'
    Assert-True (Test-Path -LiteralPath $manifestPath -PathType Leaf) 'Build emits the adjacent closed manifest'
    $manifest = Get-DemoAdapterUtf8Text $manifestPath | ConvertFrom-Json
    $manifestFields = @(
        'schemaVersion', 'banner', 'adapterSourceRelativePath', 'adapterSourceSha256', 'generatedConfigurationSha256',
        'msBuildPath', 'msBuildSha256', 'cscPath', 'cscSha256', 'distributionRoot', 'sandboxRoot', 'logRoot',
        'projectRelativePath', 'projectSha256', 'vcxProjectSha256', 'target', 'expectedArtifactRelativePath',
        'cycleWatchHeaderSha256', 'cycleWatchTestsSha256', 'cycleWatchTestsLinkerProbeSha256',
        'cycleWatchSourceBaselineSha256', 'cycleWatchSourceThreshold3ErrorSha256', 'cycleWatchSourceThreshold3FixedSha256',
        'outputFileName', 'outputSha256'
    )
    Assert-DemoAdapterPropertySet $manifest $manifestFields 'Build manifest has a closed field set'
    $unicodeBanner = 'MSBUILD DEMO ADAPTER ' + [char]0x2014 + ' NOT VC6 QUALIFICATION'
    Assert-Equal $manifest.schemaVersion '1.0' 'Build manifest has fixed schema version'
    Assert-Equal $manifest.banner $unicodeBanner 'Build manifest carries exact Unicode banner'
    Assert-Equal $manifest.adapterSourceRelativePath 'demo/adapter/DemoMsdevAdapter.cs' 'Manifest uses distribution-relative adapter source identity'
    Assert-Equal $manifest.adapterSourceSha256 (Get-DemoAdapterHash $adapterSourcePath) 'Manifest records adapter source hash'
    Assert-Equal $manifest.msBuildPath ([System.IO.Path]::GetFullPath($fakeTools.MsBuildPath)) 'Manifest records absolute pinned MSBuild path'
    Assert-Equal $manifest.msBuildSha256 (Get-DemoAdapterHash $fakeTools.MsBuildPath) 'Manifest records pinned MSBuild hash'
    Assert-Equal $manifest.cscPath ([System.IO.Path]::GetFullPath($fakeTools.CscPath)) 'Manifest records adjacent Roslyn compiler path'
    Assert-Equal $manifest.cscSha256 (Get-DemoAdapterHash $fakeTools.CscPath) 'Manifest records compiler hash'
    Assert-Equal $manifest.projectRelativePath 'demo/CycleWatch/CycleWatch.dsp' 'Manifest fixes the project tail'
    Assert-Equal $manifest.expectedArtifactRelativePath 'demo/CycleWatch/bin/Release/CycleWatchTests.exe' 'Manifest fixes expected artifact tail'
    Assert-Equal $manifest.cycleWatchHeaderSha256 (Get-DemoAdapterHash (Join-Path $distributionRoot 'demo\CycleWatch\include\CycleWatch.h')) 'Manifest fixes the compiled header baseline'
    Assert-Equal $manifest.cycleWatchTestsSha256 (Get-DemoAdapterHash (Join-Path $distributionRoot 'demo\CycleWatch\tests\CycleWatchTests.cpp')) 'Manifest fixes the compiled tests baseline'
    Assert-Equal $manifest.cycleWatchSourceBaselineSha256 (Get-DemoAdapterHash (Join-Path $distributionRoot 'demo\CycleWatch\src\CycleWatch.cpp')) 'Manifest fixes the compiled source baseline'
    foreach ($compilerInputHash in @(
        $manifest.cycleWatchTestsLinkerProbeSha256, $manifest.cycleWatchSourceThreshold3ErrorSha256, $manifest.cycleWatchSourceThreshold3FixedSha256
    )) { Assert-True ([string]$compilerInputHash -match '^[0-9a-f]{64}$') 'Manifest derived compiler-input variants have canonical SHA-256 values' }
    Assert-Equal $manifest.outputFileName 'DemoMsdevAdapter.exe' 'Manifest fixes output name'
    Assert-Equal $manifest.outputSha256 (Get-DemoAdapterHash $adapterPath) 'Manifest records adapter output hash'
    Assert-Equal (@(Get-ChildItem -LiteralPath $buildTempRoot -Force).Count) 0 'Build removes generated config and compiler intermediates'

    $secondBuild = Invoke-DemoAdapterScript $adapterBuildPath @(
        '-MsBuildPath', $fakeTools.MsBuildPath, '-DistributionRoot', $distributionRoot,
        '-SandboxRoot', $sandboxRoot, '-LogRoot', $logRoot,
        '-OutputDirectory', $secondToolsRoot, '-TemporaryRoot', $buildTempRoot
    )
    Assert-Equal $secondBuild.ExitCode 0 'Second adapter build succeeds in distinct output directory'
    $secondManifest = Get-DemoAdapterUtf8Text (Join-Path $secondToolsRoot 'DemoMsdevAdapter.build-manifest.json') | ConvertFrom-Json
    Assert-Equal $secondManifest.generatedConfigurationSha256 $manifest.generatedConfigurationSha256 'Generated configuration is deterministic'
    Assert-Equal $secondManifest.outputSha256 $manifest.outputSha256 'Compiled adapter output is deterministic'
    Assert-Equal (@(Get-ChildItem -LiteralPath $buildTempRoot -Force).Count) 0 'Second build also cleans verified temp root'

    $overlapBuild = Invoke-DemoAdapterScript $adapterBuildPath @(
        '-MsBuildPath', $fakeTools.MsBuildPath, '-DistributionRoot', $distributionRoot,
        '-SandboxRoot', $sandboxRoot, '-LogRoot', $sandboxRoot,
        '-OutputDirectory', (Join-Path $demoAdapterFixtureFull 'invalid-output'), '-TemporaryRoot', $buildTempRoot
    )
    Assert-True ($overlapBuild.ExitCode -ne 0) 'Build rejects overlapping sandbox and log roots'

    $existingExeOutput = Join-Path $demoAdapterFixtureFull 'existing-exe-output'
    [void][System.IO.Directory]::CreateDirectory($existingExeOutput)
    $existingExePath = Join-Path $existingExeOutput 'DemoMsdevAdapter.exe'
    $existingExeBytes = [System.Text.Encoding]::ASCII.GetBytes("pre-existing-exe-sentinel`r`n")
    [System.IO.File]::WriteAllBytes($existingExePath, $existingExeBytes)
    $existingExeBuild = Invoke-DemoAdapterScript $adapterBuildPath @(
        '-MsBuildPath', $fakeTools.MsBuildPath, '-DistributionRoot', $distributionRoot,
        '-SandboxRoot', $sandboxRoot, '-LogRoot', $logRoot,
        '-OutputDirectory', $existingExeOutput, '-TemporaryRoot', $buildTempRoot
    )
    Assert-True ($existingExeBuild.ExitCode -ne 0) 'Build refuses to overwrite a pre-existing adapter executable'
    Assert-True (Test-Path -LiteralPath $existingExePath -PathType Leaf) 'Rejected build preserves pre-existing executable'
    Assert-Equal ([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($existingExePath))) ([Convert]::ToBase64String($existingExeBytes)) 'Rejected build preserves pre-existing executable bytes'

    $existingManifestOutput = Join-Path $demoAdapterFixtureFull 'existing-manifest-output'
    [void][System.IO.Directory]::CreateDirectory($existingManifestOutput)
    $existingManifestPath = Join-Path $existingManifestOutput 'DemoMsdevAdapter.build-manifest.json'
    $existingManifestBytes = [System.Text.Encoding]::ASCII.GetBytes("pre-existing-manifest-sentinel`r`n")
    [System.IO.File]::WriteAllBytes($existingManifestPath, $existingManifestBytes)
    $existingManifestBuild = Invoke-DemoAdapterScript $adapterBuildPath @(
        '-MsBuildPath', $fakeTools.MsBuildPath, '-DistributionRoot', $distributionRoot,
        '-SandboxRoot', $sandboxRoot, '-LogRoot', $logRoot,
        '-OutputDirectory', $existingManifestOutput, '-TemporaryRoot', $buildTempRoot
    )
    Assert-True ($existingManifestBuild.ExitCode -ne 0) 'Build refuses to overwrite a pre-existing manifest'
    Assert-True (Test-Path -LiteralPath $existingManifestPath -PathType Leaf) 'Rejected build preserves pre-existing manifest'
    Assert-Equal ([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($existingManifestPath))) ([Convert]::ToBase64String($existingManifestBytes)) 'Rejected build preserves pre-existing manifest bytes'

    $collisionToolsRoot = Join-Path $demoAdapterFixtureFull 'manifest-collision-tools'
    $collisionOutputRoot = Join-Path $demoAdapterFixtureFull 'manifest-collision-output'
    $collisionTempRoot = Join-Path $demoAdapterFixtureFull 'manifest-collision-temp'
    foreach ($directory in @($collisionOutputRoot, $collisionTempRoot)) { [void][System.IO.Directory]::CreateDirectory($directory) }
    $collisionTools = New-DemoAdapterManifestCollisionTools $collisionToolsRoot $fakeTools.MsBuildPath
    $collisionExePath = Join-Path $collisionOutputRoot 'DemoMsdevAdapter.exe'
    $collisionManifestPath = Join-Path $collisionOutputRoot 'DemoMsdevAdapter.build-manifest.json'
    $env:TEAM_BOB_TEST_ADAPTER_SEED = $adapterPath
    $env:TEAM_BOB_TEST_MANIFEST_BLOCK = $collisionManifestPath
    try {
        $collisionBuild = Invoke-DemoAdapterScript $adapterBuildPath @(
            '-MsBuildPath', $collisionTools.MsBuildPath, '-DistributionRoot', $distributionRoot,
            '-SandboxRoot', $sandboxRoot, '-LogRoot', $logRoot,
            '-OutputDirectory', $collisionOutputRoot, '-TemporaryRoot', $collisionTempRoot
        )
    } finally {
        $env:TEAM_BOB_TEST_ADAPTER_SEED = $null
        $env:TEAM_BOB_TEST_MANIFEST_BLOCK = $null
    }
    Assert-True ($collisionBuild.ExitCode -ne 0) 'Build fails closed when manifest completion path is occupied during compilation'
    Assert-True (-not (Test-Path -LiteralPath $collisionExePath)) 'Failed manifest publication rolls back only the executable created by this invocation'
    Assert-True (Test-Path -LiteralPath $collisionManifestPath -PathType Container) 'Failed manifest publication preserves the foreign manifest-path blocker'

    $invalidDistribution = Join-Path $demoAdapterFixtureFull 'invalid-distribution'
    [void][System.IO.Directory]::CreateDirectory((Join-Path $invalidDistribution 'demo'))
    Copy-Item -LiteralPath (Join-Path $distributionRoot 'demo\CycleWatch') -Destination (Join-Path $invalidDistribution 'demo\CycleWatch') -Recurse
    [System.IO.File]::WriteAllText((Join-Path $invalidDistribution 'demo\CycleWatch\CycleWatch.dsp'), "# Microsoft Developer Studio Project File - Name=CycleWatch`r`n", [System.Text.Encoding]::GetEncoding(932))
    $vc6SignatureBuild = Invoke-DemoAdapterScript $adapterBuildPath @(
        '-MsBuildPath', $fakeTools.MsBuildPath, '-DistributionRoot', $invalidDistribution,
        '-SandboxRoot', $sandboxRoot, '-LogRoot', $logRoot,
        '-OutputDirectory', (Join-Path $demoAdapterFixtureFull 'invalid-vc6-output'), '-TemporaryRoot', $buildTempRoot
    )
    Assert-True ($vc6SignatureBuild.ExitCode -ne 0) 'Build refuses a real VC6 signature'

    Clear-DemoAdapterTrace $tracePath
    $help = Invoke-DemoAdapterExecutable $adapterPath @('/?')
    Assert-Equal $help.ExitCode 0 'Single help probe succeeds'
    Assert-True ($help.Output.Contains($unicodeBanner)) 'Help prints exact Unicode NOT-VC6 banner'
    Assert-True ($help.Output -match [regex]::Escape('Usage: DemoMsdevAdapter.exe <sandbox-project.dsp> /MAKE|/REBUILD "CycleWatch - Win32 Release" /OUT <log-path>')) 'Help prints exact usage'
    Assert-Equal (@(Read-DemoAdapterTrace $tracePath).Count) 0 'Help launches no MSBuild process'

    $env:CL = 'INHERITED_CL'; $env:_CL_ = 'INHERITED_UNDER_CL'; $env:LINK = 'INHERITED_LINK'; $env:_LINK_ = 'INHERITED_UNDER_LINK'
    $env:VCTargetsPath = 'POISON_VCTARGETS'; $env:MSBuildExtensionsPath = 'POISON_EXTENSIONS'; $env:MSBuildExtensionsPath32 = 'POISON_EXTENSIONS32'
    $env:MSBuildExtensionsPath64 = 'POISON_EXTENSIONS64'; $env:MSBuildSDKsPath = 'POISON_SDKS'; $env:MSBuildToolsPath = 'POISON_TOOLS'
    $processPoison = [ordered]@{
        PATH = 'POISON_PATH'; INCLUDE = 'POISON_INCLUDE'; LIB = 'POISON_LIB'; LIBPATH = 'POISON_LIBPATH'; TEMP = 'POISON_TEMP'; TMP = 'POISON_TMP'
        COR_ENABLE_PROFILING = '0'; COR_PROFILER = 'POISON_PROFILER'; CORECLR_ENABLE_PROFILING = '0'; COMPLUS_TEST_POISON = 'POISON_RUNTIME'
        DOTNET_STARTUP_HOOKS = 'POISON_STARTUP_HOOK'; __COMPAT_LAYER = 'POISON_COMPAT_LAYER'
    }
    $savedProcessPoison = @{}
    foreach ($name in $processPoison.Keys) { $savedProcessPoison[$name] = [Environment]::GetEnvironmentVariable($name, 'Process'); [Environment]::SetEnvironmentVariable($name, $processPoison[$name], 'Process') }
    $compileCase = New-DemoAdapterInvocation $distributionRoot $sandboxRoot $logRoot 'ADAPTER-COMPILE' 0 'make'
    Clear-DemoAdapterTrace $tracePath
    try { $compile = Invoke-DemoAdapterExecutable $adapterPath @($compileCase.ProjectPath, '/MAKE', 'CycleWatch - Win32 Release', '/OUT', $compileCase.LogPath) }
    finally { foreach ($name in $processPoison.Keys) { [Environment]::SetEnvironmentVariable($name, $savedProcessPoison[$name], 'Process') } }
    Assert-Equal $compile.ExitCode 1 'Attempt 0 Make returns normalized native failure exit 1'
    $compileTrace = @(Read-DemoAdapterTrace $tracePath)
    Assert-Equal $compileTrace.Count 1 'Attempt 0 Make launches exactly one MSBuild process'
    $safeUserRoot = Join-Path $compileCase.ProjectDirectory '.team-bob-empty-user'
    $expectedBuildArguments = @(
        $compileCase.VcxProjectPath, '/t:Build', '/p:Configuration=Release', '/p:Platform=Win32', '/m:1', '/nodeReuse:false',
        '/noAutoResponse', '/p:ImportDirectoryBuildProps=false', '/p:ImportDirectoryBuildTargets=false', ('/p:UserRootDir=' + $safeUserRoot)
    )
    Assert-Equal ($compileTrace[0].Arguments -join '|') ($expectedBuildArguments -join '|') 'Make maps to exact fixed native argv'
    Assert-Equal $compileTrace[0].CL '/DTEAM_BOB_DEMO_FAULT' 'Only attempt 0 Make injects compiler fault'
    Assert-True ($null -eq $compileTrace[0].UnderCl -and $null -eq $compileTrace[0].Link -and $null -eq $compileTrace[0].UnderLink) 'Adapter removes inherited _CL_/LINK/_LINK_'
    Assert-True ($null -eq $compileTrace[0].VcTargetsPath -and $null -eq $compileTrace[0].MsBuildExtensionsPath -and
        $null -eq $compileTrace[0].MsBuildExtensionsPath32 -and $null -eq $compileTrace[0].MsBuildExtensionsPath64 -and
        $null -eq $compileTrace[0].MsBuildSdksPath -and $null -eq $compileTrace[0].MsBuildToolsPath) 'Adapter removes inherited MSBuild import override paths'
    $expectedNativeTemp = Join-Path (Split-Path -Parent (Split-Path -Parent $compileCase.ProjectDirectory)) '.team-bob-native-temp'
    $expectedNativePath = [Environment]::SystemDirectory + ';' + (Split-Path -Parent ([Environment]::SystemDirectory))
    Assert-Equal $compileTrace[0].Path $expectedNativePath 'Adapter replaces inherited PATH with the minimal OS path allowlist'
    Assert-True ($null -eq $compileTrace[0].Include -and $null -eq $compileTrace[0].Lib -and $null -eq $compileTrace[0].LibPath) 'Adapter removes inherited compiler and linker search paths'
    Assert-Equal $compileTrace[0].Temp $expectedNativeTemp 'Adapter fixes TEMP inside the verified invocation sandbox'
    Assert-Equal $compileTrace[0].Tmp $expectedNativeTemp 'Adapter fixes TMP inside the verified invocation sandbox'
    Assert-True ($null -eq $compileTrace[0].CorEnableProfiling -and $null -eq $compileTrace[0].CorProfiler -and
        $null -eq $compileTrace[0].CoreClrEnableProfiling -and $null -eq $compileTrace[0].ComPlusPoison -and
        $null -eq $compileTrace[0].DotNetStartupHooks -and $null -eq $compileTrace[0].CompatLayer) 'Adapter removes inherited runtime profiler, startup-hook, and compatibility injection variables'
    $compileLog = Get-DemoAdapterCp932Text $compileCase.LogPath
    foreach ($marker in @(
        'MSBUILD DEMO ADAPTER - NOT VC6 QUALIFICATION', 'TEAM_BOB_ADAPTER_SCHEMA=1.0',
        'TEAM_BOB_ADAPTER_TASK=ADAPTER-COMPILE', ('TEAM_BOB_ADAPTER_INVOCATION=' + $compileCase.InvocationId),
        'TEAM_BOB_ADAPTER_ACTION=Make', 'TEAM_BOB_ADAPTER_ATTEMPT=0', 'TEAM_BOB_ADAPTER_FAULT_INJECTED=true',
        'TEAM_BOB_ADAPTER_NATIVE_EXIT=1', 'TEAM_BOB_ADAPTER_STATUS=FAILED'
    )) { Assert-True ($compileLog.Contains($marker + "`r`n")) "CP932 compiler log contains '$marker'" }
    Assert-True ($compileLog -match 'TEAM_BOB_ADAPTER_ADAPTER_SHA256=[0-9a-f]{64}\r\n') 'CP932 log records adapter hash'
    Assert-True ($compileLog -match 'TEAM_BOB_ADAPTER_MSBUILD_SHA256=[0-9a-f]{64}\r\n') 'CP932 log records MSBuild hash'
    Assert-True ($compileLog -match 'src\\CycleWatch\.cpp\(9\) : error C1189') 'CP932 log preserves attributable compiler output'
    Assert-True ($compileLog.Contains('"demo/CycleWatch/src/CycleWatch.cpp"')) 'CP932 compiler log carries the stable quoted Allowed File token'
    Assert-True ($compileLog.Contains('AFTER_EVIDENCE_REPLACE_THIS_EXACT_LINE_WITH: #pragma message("MSBUILD_DEMO_ADAPTER_INTENTIONAL_FAULT_REPAIRED demo/CycleWatch/src/CycleWatch.cpp")')) 'CP932 compiler evidence names the exact one-time synthetic fault repair'
    $evidenceFields = @(
        'schemaVersion', 'banner', 'taskId', 'invocationId', 'action', 'attempt', 'faultInjected',
        'adapterSha256', 'msBuildPath', 'msBuildSha256', 'sandboxRoot', 'logRoot', 'projectRelativePath',
        'projectSha256', 'vcxProjectSha256', 'target', 'expectedArtifactRelativePath', 'expectedArtifactSha256',
        'cycleWatchSourceSha256', 'cycleWatchSourceVariant', 'cycleWatchHeaderSha256', 'cycleWatchTestsSha256',
        'nativeExitCode', 'startedAt', 'finishedAt', 'status', 'environmentError'
    )
    $compileEvidence = Get-DemoAdapterUtf8Text $compileCase.EvidencePath | ConvertFrom-Json
    Assert-DemoAdapterPropertySet $compileEvidence $evidenceFields 'Evidence sidecar has closed field set'
    Assert-Equal $compileEvidence.banner $unicodeBanner 'Evidence sidecar preserves Unicode banner'
    Assert-Equal $compileEvidence.taskId $compileCase.TaskId 'Evidence records task'
    Assert-Equal $compileEvidence.invocationId $compileCase.InvocationId 'Evidence records invocation'
    Assert-Equal $compileEvidence.action 'Make' 'Evidence records action'
    Assert-Equal $compileEvidence.attempt 0 'Evidence records attempt'
    Assert-Equal $compileEvidence.faultInjected $true 'Evidence records fault injection'
    Assert-Equal $compileEvidence.adapterSha256 (Get-DemoAdapterHash $adapterPath) 'Evidence hashes running adapter'
    Assert-Equal $compileEvidence.msBuildSha256 (Get-DemoAdapterHash $fakeTools.MsBuildPath) 'Evidence records rechecked MSBuild hash'
    Assert-Equal $compileEvidence.projectSha256 $manifest.projectSha256 'Evidence records DSP hash'
    Assert-Equal $compileEvidence.vcxProjectSha256 $manifest.vcxProjectSha256 'Evidence records VCX hash'
    Assert-Equal $compileEvidence.cycleWatchSourceSha256 $manifest.cycleWatchSourceBaselineSha256 'Evidence records observed baseline source hash'
    Assert-Equal $compileEvidence.cycleWatchSourceVariant 'baseline-error' 'Evidence names the observed source variant'
    Assert-Equal $compileEvidence.cycleWatchHeaderSha256 $manifest.cycleWatchHeaderSha256 'Evidence records observed header hash'
    Assert-Equal $compileEvidence.cycleWatchTestsSha256 $manifest.cycleWatchTestsSha256 'Evidence records observed tests hash'
    Assert-Equal $compileEvidence.nativeExitCode 1 'Evidence records native exit'
    Assert-Equal $compileEvidence.status 'FAILED' 'Evidence records native failure status'
    Assert-True ($null -eq $compileEvidence.expectedArtifactSha256 -and $null -eq $compileEvidence.environmentError) 'Native failure invents no artifact or environment error'
    Assert-True ([DateTimeOffset]::Parse([string]$compileEvidence.finishedAt) -ge [DateTimeOffset]::Parse([string]$compileEvidence.startedAt)) 'Evidence timestamps are ordered'

    $makeCase = New-DemoAdapterInvocation $distributionRoot $sandboxRoot $logRoot 'ADAPTER-MAKE' 1 'make' '11111111111111111111111111111111'
    Clear-DemoAdapterTrace $tracePath
    $make = Invoke-DemoAdapterExecutable $adapterPath @($makeCase.ProjectPath, '/MAKE', 'CycleWatch - Win32 Release', '/OUT', $makeCase.LogPath)
    Assert-Equal $make.ExitCode 0 'Attempt 1 Make succeeds with exact artifact'
    $makeTrace = @(Read-DemoAdapterTrace $tracePath)
    Assert-Equal $makeTrace.Count 1 'Attempt 1 Make launches one MSBuild process'
    Assert-True ($null -eq $makeTrace[0].CL -and $null -eq $makeTrace[0].UnderCl -and $null -eq $makeTrace[0].Link -and $null -eq $makeTrace[0].UnderLink) 'Attempt 1 Make clears all inherited tool injection variables'
    Assert-True (Test-Path -LiteralPath $makeCase.ArtifactPath -PathType Leaf) 'Successful Make produces exact artifact'
    Assert-True (Test-Path -LiteralPath (Join-Path $makeCase.ProjectDirectory 'bin\Release') -PathType Container) 'Adapter owns the fixed bin/Release directory'
    Assert-True (Test-Path -LiteralPath (Join-Path $makeCase.ProjectDirectory 'obj\Release') -PathType Container) 'Adapter owns the fixed obj/Release directory'
    $makeLog = Get-DemoAdapterCp932Text $makeCase.LogPath
    Assert-True ($makeLog.Contains("TEAM_BOB_ADAPTER_STATUS=SUCCEEDED`r`n")) 'Successful Make emits exact success marker'
    $localizedNativeMarker = 'FAKE_MSBUILD_LOCALIZED_SUCCESS_' + [char]0x65e5 + [char]0x672c + [char]0x8a9e
    Assert-True ($makeLog.Contains($localizedNativeMarker + "`r`n")) 'Adapter losslessly transcodes raw UTF-8 localized native output into CP932 evidence'
    $makeEvidence = Get-DemoAdapterUtf8Text $makeCase.EvidencePath | ConvertFrom-Json
    Assert-Equal $makeEvidence.status 'SUCCEEDED' 'Make evidence records success'
    Assert-Equal $makeEvidence.expectedArtifactSha256 (Get-DemoAdapterHash $makeCase.ArtifactPath) 'Make evidence records artifact hash'

    $rebuildCase = New-DemoAdapterInvocation $distributionRoot $sandboxRoot $logRoot 'ADAPTER-REBUILD' 0 'rebuild' '22222222222222222222222222222222'
    Clear-DemoAdapterTrace $tracePath
    $rebuild = Invoke-DemoAdapterExecutable $adapterPath @($rebuildCase.ProjectPath, '/REBUILD', 'CycleWatch - Win32 Release', '/OUT', $rebuildCase.LogPath)
    Assert-Equal $rebuild.ExitCode 0 'Rebuild succeeds without attempt-0 fault'
    $rebuildTrace = @(Read-DemoAdapterTrace $tracePath)
    $rebuildSafeUserRoot = Join-Path $rebuildCase.ProjectDirectory '.team-bob-empty-user'
    $expectedRebuildArguments = @(
        $rebuildCase.VcxProjectPath, '/t:Rebuild', '/p:Configuration=Release', '/p:Platform=Win32', '/m:1', '/nodeReuse:false',
        '/noAutoResponse', '/p:ImportDirectoryBuildProps=false', '/p:ImportDirectoryBuildTargets=false', ('/p:UserRootDir=' + $rebuildSafeUserRoot)
    )
    Assert-Equal ($rebuildTrace[0].Arguments -join '|') ($expectedRebuildArguments -join '|') 'Rebuild maps to exact fixed native argv'
    Assert-True ($null -eq $rebuildTrace[0].CL) 'Attempt 0 Rebuild never injects compiler fault'

    $attemptTwoCase = New-DemoAdapterInvocation $distributionRoot $sandboxRoot $logRoot 'ADAPTER-ATTEMPT2' 2 'make' '33333333333333333333333333333333'
    Clear-DemoAdapterTrace $tracePath
    $attemptTwo = Invoke-DemoAdapterExecutable $adapterPath @($attemptTwoCase.ProjectPath, '/MAKE', 'CycleWatch - Win32 Release', '/OUT', $attemptTwoCase.LogPath)
    Assert-Equal $attemptTwo.ExitCode 0 'Attempt 2 Make succeeds'
    $attemptTwoTrace = @(Read-DemoAdapterTrace $tracePath)
    Assert-True ($null -eq $attemptTwoTrace[0].CL) 'Attempt 2 Make never injects compiler fault'

    foreach ($knownSourceVariant in @('threshold3-error', 'threshold3-fixed')) {
        $knownSourceCase = New-DemoAdapterInvocation $distributionRoot $sandboxRoot $logRoot ('ADAPTER-SOURCE-' + $knownSourceVariant.ToUpperInvariant()) 1 'make'
        Set-DemoAdapterKnownSourceVariant (Join-Path $knownSourceCase.ProjectDirectory 'src\CycleWatch.cpp') $knownSourceVariant
        Clear-DemoAdapterTrace $tracePath
        $knownSourceResult = Invoke-DemoAdapterExecutable $adapterPath @($knownSourceCase.ProjectPath, '/MAKE', 'CycleWatch - Win32 Release', '/OUT', $knownSourceCase.LogPath)
        Assert-Equal $knownSourceResult.ExitCode 0 "Known source variant '$knownSourceVariant' is accepted"
        Assert-Equal (@(Read-DemoAdapterTrace $tracePath).Count) 1 "Known source variant '$knownSourceVariant' launches exactly once"
        $knownSourceEvidence = Get-DemoAdapterUtf8Text $knownSourceCase.EvidencePath | ConvertFrom-Json
        Assert-Equal $knownSourceEvidence.cycleWatchSourceVariant $knownSourceVariant "Evidence identifies known source variant '$knownSourceVariant'"
    }

    $missingCase = New-DemoAdapterInvocation $distributionRoot $sandboxRoot $logRoot 'ADAPTER-MISSING' 1 'make' '44444444444444444444444444444444'
    $env:TEAM_BOB_FAKE_MSBUILD_MODE = 'missing-artifact'
    Clear-DemoAdapterTrace $tracePath
    $missing = Invoke-DemoAdapterExecutable $adapterPath @($missingCase.ProjectPath, '/MAKE', 'CycleWatch - Win32 Release', '/OUT', $missingCase.LogPath)
    Assert-DemoAdapterEnvironmentFailure $missing 'MISSING_ARTIFACT' 'Native success without artifact'
    $missingLog = Get-DemoAdapterCp932Text $missingCase.LogPath
    Assert-True ($missingLog.Contains("TEAM_BOB_ADAPTER_NATIVE_EXIT=0`r`n")) 'Missing-artifact log preserves native success exit'
    Assert-True ($missingLog.Contains("TEAM_BOB_ADAPTER_STATUS=ENVIRONMENT_ERROR`r`n")) 'Missing artifact has environment status'
    $missingEvidence = Get-DemoAdapterUtf8Text $missingCase.EvidencePath | ConvertFrom-Json
    Assert-Equal $missingEvidence.environmentError 'MISSING_ARTIFACT' 'Missing-artifact evidence records stable reason'
    $env:TEAM_BOB_FAKE_MSBUILD_MODE = ''

    $evidenceCollisionCase = New-DemoAdapterInvocation $distributionRoot $sandboxRoot $logRoot 'ADAPTER-EVIDENCE-RACE' 1 'make' '45454545454545454545454545454545'
    $foreignEvidenceBytes = [System.Text.Encoding]::ASCII.GetBytes("foreign-evidence-blocker`r`n")
    $env:TEAM_BOB_FAKE_MSBUILD_MODE = 'evidence-collision'
    $env:TEAM_BOB_FAKE_EVIDENCE_BLOCK_PATH = $evidenceCollisionCase.EvidencePath
    Clear-DemoAdapterTrace $tracePath
    try {
        $evidenceCollision = Invoke-DemoAdapterExecutable $adapterPath @($evidenceCollisionCase.ProjectPath, '/MAKE', 'CycleWatch - Win32 Release', '/OUT', $evidenceCollisionCase.LogPath)
    } finally {
        $env:TEAM_BOB_FAKE_MSBUILD_MODE = ''
        $env:TEAM_BOB_FAKE_EVIDENCE_BLOCK_PATH = $null
    }
    Assert-DemoAdapterEnvironmentFailure $evidenceCollision 'EVIDENCE_WRITE' 'Evidence publication race'
    Assert-Equal (@(Read-DemoAdapterTrace $tracePath).Count) 1 'Evidence publication race occurs only after one native launch'
    Assert-True (-not (Test-Path -LiteralPath $evidenceCollisionCase.LogPath)) 'Evidence publication race leaves no unpaired completion log'
    Assert-Equal ([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($evidenceCollisionCase.EvidencePath))) ([Convert]::ToBase64String($foreignEvidenceBytes)) 'Evidence publication race preserves foreign sidecar bytes'

    $staleCase = New-DemoAdapterInvocation $distributionRoot $sandboxRoot $logRoot 'ADAPTER-STALE' 1 'make' '55555555555555555555555555555555'
    [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $staleCase.ArtifactPath))
    [System.IO.File]::WriteAllText($staleCase.ArtifactPath, 'stale')
    Clear-DemoAdapterTrace $tracePath
    $stale = Invoke-DemoAdapterExecutable $adapterPath @($staleCase.ProjectPath, '/MAKE', 'CycleWatch - Win32 Release', '/OUT', $staleCase.LogPath)
    Assert-DemoAdapterEnvironmentFailure $stale 'OUTPUT_BIN_EXISTS' 'Stale expected artifact inside a preexisting bin tree'
    Assert-Equal (@(Read-DemoAdapterTrace $tracePath).Count) 0 'Stale artifact is rejected before launch'

    $nativeCase = New-DemoAdapterInvocation $distributionRoot $sandboxRoot $logRoot 'ADAPTER-NATIVE' 1 'make' '66666666666666666666666666666666'
    $env:TEAM_BOB_FAKE_MSBUILD_MODE = 'native-failure'
    $native = Invoke-DemoAdapterExecutable $adapterPath @($nativeCase.ProjectPath, '/MAKE', 'CycleWatch - Win32 Release', '/OUT', $nativeCase.LogPath)
    Assert-Equal $native.ExitCode 1 'Nonzero native build exit is normalized to 1'
    $env:TEAM_BOB_FAKE_MSBUILD_MODE = ''

    $msBuildBytes = [System.IO.File]::ReadAllBytes($fakeTools.MsBuildPath)
    $tamperedBytes = New-Object byte[] ($msBuildBytes.Length + 1)
    [Array]::Copy($msBuildBytes, $tamperedBytes, $msBuildBytes.Length); $tamperedBytes[$tamperedBytes.Length - 1] = 0x7F
    [System.IO.File]::WriteAllBytes($fakeTools.MsBuildPath, $tamperedBytes)
    $hashCase = New-DemoAdapterInvocation $distributionRoot $sandboxRoot $logRoot 'ADAPTER-HASH' 1 'make' '77777777777777777777777777777777'
    Clear-DemoAdapterTrace $tracePath
    $hashFailure = Invoke-DemoAdapterExecutable $adapterPath @($hashCase.ProjectPath, '/MAKE', 'CycleWatch - Win32 Release', '/OUT', $hashCase.LogPath)
    Assert-DemoAdapterEnvironmentFailure $hashFailure 'MSBUILD_HASH' 'MSBuild hash tamper'
    Assert-Equal (@(Read-DemoAdapterTrace $tracePath).Count) 0 'MSBuild hash tamper launches nothing'
    Set-DemoAdapterFileBytesWithRetry $fakeTools.MsBuildPath $msBuildBytes

    $dspCase = New-DemoAdapterInvocation $distributionRoot $sandboxRoot $logRoot 'ADAPTER-DSP' 1 'make' '88888888888888888888888888888888'
    [System.IO.File]::AppendAllText($dspCase.ProjectPath, "TAMPER`r`n", [System.Text.Encoding]::GetEncoding(932))
    Clear-DemoAdapterTrace $tracePath
    $dspFailure = Invoke-DemoAdapterExecutable $adapterPath @($dspCase.ProjectPath, '/MAKE', 'CycleWatch - Win32 Release', '/OUT', $dspCase.LogPath)
    Assert-DemoAdapterEnvironmentFailure $dspFailure 'PROJECT_HASH' 'DSP hash tamper'
    Assert-Equal (@(Read-DemoAdapterTrace $tracePath).Count) 0 'DSP tamper launches nothing'

    $vcxCase = New-DemoAdapterInvocation $distributionRoot $sandboxRoot $logRoot 'ADAPTER-VCX' 1 'make' '99999999999999999999999999999999'
    [System.IO.File]::AppendAllText($vcxCase.VcxProjectPath, "<!-- TAMPER -->`r`n", (New-Object System.Text.UTF8Encoding($false)))
    Clear-DemoAdapterTrace $tracePath
    $vcxFailure = Invoke-DemoAdapterExecutable $adapterPath @($vcxCase.ProjectPath, '/MAKE', 'CycleWatch - Win32 Release', '/OUT', $vcxCase.LogPath)
    Assert-DemoAdapterEnvironmentFailure $vcxFailure 'VCXPROJECT_HASH' 'VCX hash tamper'
    Assert-Equal (@(Read-DemoAdapterTrace $tracePath).Count) 0 'VCX tamper launches nothing'

    foreach ($inputTamper in @(
        [pscustomobject]@{ Name = 'UNC include'; RelativePath = 'src\CycleWatch.cpp'; Reason = 'SOURCE_HASH'; Text = "`r`n#include `"\\\\attacker.invalid\\share\\probe.h`"`r`n" },
        [pscustomobject]@{ Name = 'MSVC pragma library'; RelativePath = 'src\CycleWatch.cpp'; Reason = 'SOURCE_HASH'; Text = "`r`n__pragma(comment(lib, `"\\\\attacker.invalid\\share\\probe.lib`"))`r`n" },
        [pscustomobject]@{ Name = 'extra source edit'; RelativePath = 'src\CycleWatch.cpp'; Reason = 'SOURCE_HASH'; Text = "`r`n// unapproved extra edit`r`n" },
        [pscustomobject]@{ Name = 'header edit'; RelativePath = 'include\CycleWatch.h'; Reason = 'HEADER_HASH'; Text = "`r`n// unapproved header edit`r`n" },
        [pscustomobject]@{ Name = 'tests edit'; RelativePath = 'tests\CycleWatchTests.cpp'; Reason = 'TESTS_HASH'; Text = "`r`n// unapproved tests edit`r`n" }
    )) {
        $inputCase = New-DemoAdapterInvocation $distributionRoot $sandboxRoot $logRoot ('ADAPTER-INPUT-' + ($inputTamper.Name -replace '[^A-Za-z]', '-').ToUpperInvariant()) 1 'make'
        [System.IO.File]::AppendAllText((Join-Path $inputCase.ProjectDirectory $inputTamper.RelativePath), $inputTamper.Text, [System.Text.Encoding]::GetEncoding(932))
        Clear-DemoAdapterTrace $tracePath
        $inputFailure = Invoke-DemoAdapterExecutable $adapterPath @($inputCase.ProjectPath, '/MAKE', 'CycleWatch - Win32 Release', '/OUT', $inputCase.LogPath)
        Assert-DemoAdapterEnvironmentFailure $inputFailure $inputTamper.Reason $inputTamper.Name
        Assert-Equal (@(Read-DemoAdapterTrace $tracePath).Count) 0 "$($inputTamper.Name) launches nothing"
    }

    $misScopedLinkerCase = New-DemoAdapterInvocation $distributionRoot $sandboxRoot $logRoot 'ADAPTER-LINKER-VARIANT-SCOPE' 1 'make'
    Set-DemoAdapterKnownLinkerTestsVariant (Join-Path $misScopedLinkerCase.ProjectDirectory 'tests\CycleWatchTests.cpp')
    Clear-DemoAdapterTrace $tracePath
    $misScopedLinkerFailure = Invoke-DemoAdapterExecutable $adapterPath @($misScopedLinkerCase.ProjectPath, '/MAKE', 'CycleWatch - Win32 Release', '/OUT', $misScopedLinkerCase.LogPath)
    Assert-DemoAdapterEnvironmentFailure $misScopedLinkerFailure 'TESTS_HASH' 'Qualification linker tests variant outside its fixed invocation'
    Assert-Equal (@(Read-DemoAdapterTrace $tracePath).Count) 0 'Mis-scoped linker tests variant launches nothing'

    foreach ($outputBlocker in @(
        [pscustomobject]@{ Name = 'bin file'; RelativePath = 'bin'; Reason = 'OUTPUT_BIN_EXISTS'; Kind = 'File' },
        [pscustomobject]@{ Name = 'obj file'; RelativePath = 'obj'; Reason = 'OUTPUT_OBJ_EXISTS'; Kind = 'File' },
        [pscustomobject]@{ Name = 'bin directory'; RelativePath = 'bin'; Reason = 'OUTPUT_BIN_EXISTS'; Kind = 'Directory' },
        [pscustomobject]@{ Name = 'obj directory'; RelativePath = 'obj'; Reason = 'OUTPUT_OBJ_EXISTS'; Kind = 'Directory' }
    )) {
        $outputCase = New-DemoAdapterInvocation $distributionRoot $sandboxRoot $logRoot ('ADAPTER-OUTPUT-' + ($outputBlocker.Name -replace '[^A-Za-z]', '-').ToUpperInvariant()) 1 'make'
        $blockerPath = Join-Path $outputCase.ProjectDirectory $outputBlocker.RelativePath
        if ($outputBlocker.Kind -eq 'File') { [System.IO.File]::WriteAllText($blockerPath, 'foreign output blocker') }
        else { [void][System.IO.Directory]::CreateDirectory($blockerPath) }
        Clear-DemoAdapterTrace $tracePath
        $outputFailure = Invoke-DemoAdapterExecutable $adapterPath @($outputCase.ProjectPath, '/MAKE', 'CycleWatch - Win32 Release', '/OUT', $outputCase.LogPath)
        Assert-DemoAdapterEnvironmentFailure $outputFailure $outputBlocker.Reason $outputBlocker.Name
        Assert-Equal (@(Read-DemoAdapterTrace $tracePath).Count) 0 "$($outputBlocker.Name) launches nothing"
    }

    foreach ($junctionName in @('bin', 'obj')) {
        $outputJunctionCase = New-DemoAdapterInvocation $distributionRoot $sandboxRoot $logRoot ('ADAPTER-OUTPUT-' + $junctionName.ToUpperInvariant() + '-JUNCTION') 1 'make'
        $outputJunctionTarget = Join-Path $demoAdapterFixtureFull ('foreign-' + $junctionName + '-target')
        [void][System.IO.Directory]::CreateDirectory($outputJunctionTarget)
        $outputJunctionCreated = $false
        try {
            [void](New-Item -ItemType Junction -Path (Join-Path $outputJunctionCase.ProjectDirectory $junctionName) -Target $outputJunctionTarget -ErrorAction Stop)
            $outputJunctionCreated = $true
        } catch { $outputJunctionCreated = $false }
        if ($outputJunctionCreated) {
            Clear-DemoAdapterTrace $tracePath
            $outputJunctionFailure = Invoke-DemoAdapterExecutable $adapterPath @($outputJunctionCase.ProjectPath, '/MAKE', 'CycleWatch - Win32 Release', '/OUT', $outputJunctionCase.LogPath)
            $junctionReason = if ($junctionName -eq 'bin') { 'OUTPUT_BIN_EXISTS' } else { 'OUTPUT_OBJ_EXISTS' }
            Assert-DemoAdapterEnvironmentFailure $outputJunctionFailure $junctionReason "Preexisting $junctionName junction"
            Assert-Equal (@(Read-DemoAdapterTrace $tracePath).Count) 0 "Preexisting $junctionName junction launches nothing"
            Assert-Equal (@(Get-ChildItem -LiteralPath $outputJunctionTarget -Force).Count) 0 "Rejected $junctionName junction receives no native output"
        } else { Write-Host "INFO: $junctionName output junction creation unavailable; output reparse probe skipped." }
    }

    $validationCase = New-DemoAdapterInvocation $distributionRoot $sandboxRoot $logRoot 'ADAPTER-VALIDATE' 1 'make' 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    $invalidCases = @(
        [pscustomobject]@{ Name = 'missing arguments'; Reason = 'ARGUMENT_COUNT'; Arguments = @() },
        [pscustomobject]@{ Name = 'extra argument'; Reason = 'ARGUMENT_COUNT'; Arguments = @($validationCase.ProjectPath, '/MAKE', 'CycleWatch - Win32 Release', '/OUT', $validationCase.LogPath, 'extra') },
        [pscustomobject]@{ Name = 'wrong action'; Reason = 'ACTION'; Arguments = @($validationCase.ProjectPath, '/BUILD', 'CycleWatch - Win32 Release', '/OUT', $validationCase.LogPath) },
        [pscustomobject]@{ Name = 'lowercase action'; Reason = 'ACTION'; Arguments = @($validationCase.ProjectPath, '/make', 'CycleWatch - Win32 Release', '/OUT', $validationCase.LogPath) },
        [pscustomobject]@{ Name = 'wrong target'; Reason = 'TARGET'; Arguments = @($validationCase.ProjectPath, '/MAKE', 'CycleWatch - Win32 Debug', '/OUT', $validationCase.LogPath) },
        [pscustomobject]@{ Name = 'wrong OUT switch'; Reason = 'OUT_SWITCH'; Arguments = @($validationCase.ProjectPath, '/MAKE', 'CycleWatch - Win32 Release', '/LOG', $validationCase.LogPath) },
        [pscustomobject]@{ Name = 'lowercase OUT switch'; Reason = 'OUT_SWITCH'; Arguments = @($validationCase.ProjectPath, '/MAKE', 'CycleWatch - Win32 Release', '/out', $validationCase.LogPath) },
        [pscustomobject]@{ Name = 'project outside root'; Reason = 'PROJECT_SCOPE'; Arguments = @((Join-Path $distributionRoot 'demo\CycleWatch\CycleWatch.dsp'), '/MAKE', 'CycleWatch - Win32 Release', '/OUT', $validationCase.LogPath) },
        [pscustomobject]@{ Name = 'log outside root'; Reason = 'LOG_SCOPE'; Arguments = @($validationCase.ProjectPath, '/MAKE', 'CycleWatch - Win32 Release', '/OUT', (Join-Path $demoAdapterFixtureFull 'outside.log')) },
        [pscustomobject]@{ Name = 'UNC project'; Reason = 'PROJECT_PATH'; Arguments = @('\\localhost\share\CycleWatch.dsp', '/MAKE', 'CycleWatch - Win32 Release', '/OUT', $validationCase.LogPath) },
        [pscustomobject]@{ Name = 'device project'; Reason = 'PROJECT_PATH'; Arguments = @(('\\?\' + $validationCase.ProjectPath), '/MAKE', 'CycleWatch - Win32 Release', '/OUT', $validationCase.LogPath) }
    )
    foreach ($invalidCase in $invalidCases) {
        Clear-DemoAdapterTrace $tracePath
        $invalid = Invoke-DemoAdapterExecutable $adapterPath $invalidCase.Arguments
        Assert-DemoAdapterEnvironmentFailure $invalid $invalidCase.Reason $invalidCase.Name
        Assert-Equal (@(Read-DemoAdapterTrace $tracePath).Count) 0 "$($invalidCase.Name) launches nothing"
    }

    $taskCase = New-DemoAdapterInvocation $distributionRoot $sandboxRoot $logRoot 'ADAPTER-TASK-A' 1 'make' 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
    $wrongTaskLogDirectory = Join-Path (Join-Path $logRoot 'ADAPTER-TASK-B') $taskCase.InvocationId
    [void][System.IO.Directory]::CreateDirectory($wrongTaskLogDirectory)
    Clear-DemoAdapterTrace $tracePath
    $taskFailure = Invoke-DemoAdapterExecutable $adapterPath @($taskCase.ProjectPath, '/MAKE', 'CycleWatch - Win32 Release', '/OUT', (Join-Path $wrongTaskLogDirectory 'build.log'))
    Assert-DemoAdapterEnvironmentFailure $taskFailure 'TASK_MISMATCH' 'Task/log mismatch'

    $invocationCase = New-DemoAdapterInvocation $distributionRoot $sandboxRoot $logRoot 'ADAPTER-INVOKE' 1 'make' 'cccccccccccccccccccccccccccccccc'
    $wrongInvocationLogDirectory = Join-Path (Join-Path $logRoot $invocationCase.TaskId) 'attempt-1-make-dddddddddddddddddddddddddddddddd'
    [void][System.IO.Directory]::CreateDirectory($wrongInvocationLogDirectory)
    Clear-DemoAdapterTrace $tracePath
    $invocationFailure = Invoke-DemoAdapterExecutable $adapterPath @($invocationCase.ProjectPath, '/MAKE', 'CycleWatch - Win32 Release', '/OUT', (Join-Path $wrongInvocationLogDirectory 'build.log'))
    Assert-DemoAdapterEnvironmentFailure $invocationFailure 'INVOCATION_MISMATCH' 'Invocation/log mismatch'

    $actionCase = New-DemoAdapterInvocation $distributionRoot $sandboxRoot $logRoot 'ADAPTER-ACTION' 1 'rebuild' 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee'
    Clear-DemoAdapterTrace $tracePath
    $actionFailure = Invoke-DemoAdapterExecutable $adapterPath @($actionCase.ProjectPath, '/MAKE', 'CycleWatch - Win32 Release', '/OUT', $actionCase.LogPath)
    Assert-DemoAdapterEnvironmentFailure $actionFailure 'ACTION_MISMATCH' 'Action/invocation mismatch'

    $existingLogCase = New-DemoAdapterInvocation $distributionRoot $sandboxRoot $logRoot 'ADAPTER-LOG-EXISTS' 1 'make' 'abababababababababababababababab'
    [System.IO.File]::WriteAllText($existingLogCase.LogPath, 'stale log')
    Clear-DemoAdapterTrace $tracePath
    $existingLogFailure = Invoke-DemoAdapterExecutable $adapterPath @($existingLogCase.ProjectPath, '/MAKE', 'CycleWatch - Win32 Release', '/OUT', $existingLogCase.LogPath)
    Assert-DemoAdapterEnvironmentFailure $existingLogFailure 'LOG_EXISTS' 'Existing output log'
    Assert-Equal (@(Read-DemoAdapterTrace $tracePath).Count) 0 'Existing log is rejected before MSBuild launch'

    $existingEvidenceCase = New-DemoAdapterInvocation $distributionRoot $sandboxRoot $logRoot 'ADAPTER-EVIDENCE-EXISTS' 1 'make' 'cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd'
    [System.IO.File]::WriteAllText($existingEvidenceCase.EvidencePath, 'stale evidence')
    Clear-DemoAdapterTrace $tracePath
    $existingEvidenceFailure = Invoke-DemoAdapterExecutable $adapterPath @($existingEvidenceCase.ProjectPath, '/MAKE', 'CycleWatch - Win32 Release', '/OUT', $existingEvidenceCase.LogPath)
    Assert-DemoAdapterEnvironmentFailure $existingEvidenceFailure 'EVIDENCE_EXISTS' 'Existing evidence sidecar'
    Assert-Equal (@(Read-DemoAdapterTrace $tracePath).Count) 0 'Existing sidecar is rejected before MSBuild launch'

    $invalidTaskCase = New-DemoAdapterInvocation $distributionRoot $sandboxRoot $logRoot 'BAD.TASK' 1 'make' 'dededededededededededededededede'
    Clear-DemoAdapterTrace $tracePath
    $invalidTaskFailure = Invoke-DemoAdapterExecutable $adapterPath @($invalidTaskCase.ProjectPath, '/MAKE', 'CycleWatch - Win32 Release', '/OUT', $invalidTaskCase.LogPath)
    Assert-DemoAdapterEnvironmentFailure $invalidTaskFailure 'TASK_ID' 'Unsafe TaskId shape'
    Assert-Equal (@(Read-DemoAdapterTrace $tracePath).Count) 0 'Unsafe TaskId launches nothing'

    $invalidAttemptCase = New-DemoAdapterInvocation $distributionRoot $sandboxRoot $logRoot 'ADAPTER-ATTEMPT3' 3 'make' 'efefefefefefefefefefefefefefefef'
    Clear-DemoAdapterTrace $tracePath
    $invalidAttemptFailure = Invoke-DemoAdapterExecutable $adapterPath @($invalidAttemptCase.ProjectPath, '/MAKE', 'CycleWatch - Win32 Release', '/OUT', $invalidAttemptCase.LogPath)
    Assert-DemoAdapterEnvironmentFailure $invalidAttemptFailure 'INVOCATION_ID' 'Attempt outside 0 through 2'
    Assert-Equal (@(Read-DemoAdapterTrace $tracePath).Count) 0 'Invalid attempt launches nothing'

    $uppercaseTokenCase = New-DemoAdapterInvocation $distributionRoot $sandboxRoot $logRoot 'ADAPTER-TOKEN' 1 'make' 'ABCDEFABCDEFABCDEFABCDEFABCDEFAB'
    Clear-DemoAdapterTrace $tracePath
    $uppercaseTokenFailure = Invoke-DemoAdapterExecutable $adapterPath @($uppercaseTokenCase.ProjectPath, '/MAKE', 'CycleWatch - Win32 Release', '/OUT', $uppercaseTokenCase.LogPath)
    Assert-DemoAdapterEnvironmentFailure $uppercaseTokenFailure 'INVOCATION_ID' 'Uppercase invocation token'
    Assert-Equal (@(Read-DemoAdapterTrace $tracePath).Count) 0 'Uppercase token launches nothing'

    $junctionTargetCase = New-DemoAdapterInvocation $distributionRoot $sandboxRoot $logRoot 'ADAPTER-JUNCTION-TARGET' 1 'make' 'fafafafafafafafafafafafafafafafa'
    $junctionTask = 'ADAPTER-JUNCTION'
    $junctionPath = Join-Path $sandboxRoot $junctionTask
    $junctionCreated = $false
    try {
        [void](New-Item -ItemType Junction -Path $junctionPath -Target (Join-Path $sandboxRoot $junctionTargetCase.TaskId) -ErrorAction Stop)
        $junctionCreated = $true
    } catch { $junctionCreated = $false }
    if ($junctionCreated) {
        try {
            $junctionProject = Join-Path (Join-Path $junctionPath $junctionTargetCase.InvocationId) 'demo\CycleWatch\CycleWatch.dsp'
            $junctionLogDirectory = Join-Path (Join-Path $logRoot $junctionTask) $junctionTargetCase.InvocationId
            [void][System.IO.Directory]::CreateDirectory($junctionLogDirectory)
            Clear-DemoAdapterTrace $tracePath
            $junctionFailure = Invoke-DemoAdapterExecutable $adapterPath @($junctionProject, '/MAKE', 'CycleWatch - Win32 Release', '/OUT', (Join-Path $junctionLogDirectory 'build.log'))
            Assert-DemoAdapterEnvironmentFailure $junctionFailure 'PROJECT_REPARSE' 'Project path containing junction'
            Assert-Equal (@(Read-DemoAdapterTrace $tracePath).Count) 0 'Reparse path launches nothing'
        } finally { [System.IO.Directory]::Delete($junctionPath, $false) }
    } else { Write-Host 'INFO: Junction creation unavailable; reparse probe skipped.' }

    $evidenceRoot = Join-Path $demoAdapterFixtureFull 'qualification-evidence'
    [void][System.IO.Directory]::CreateDirectory($evidenceRoot)
    $qualificationRecordPath = Join-Path $evidenceRoot 'demo-adapter-qualification.json'
    Clear-DemoAdapterTrace $tracePath
    $qualification = Invoke-DemoAdapterScript $adapterQualificationPath @(
        '-AdapterPath', $adapterPath, '-BuildManifestPath', $manifestPath, '-DistributionRoot', $distributionRoot,
        '-SandboxRoot', $sandboxRoot, '-LogRoot', $logRoot, '-EvidenceRoot', $evidenceRoot
    )
    Assert-Equal $qualification.ExitCode 0 "Hermetic raw qualification probes pass; output: $($qualification.Output.Trim())"
    Assert-True (Test-Path -LiteralPath $qualificationRecordPath -PathType Leaf) 'Qualification writes one fixed record under EvidenceRoot'
    $qualificationRecord = Get-DemoAdapterUtf8Text $qualificationRecordPath | ConvertFrom-Json
    $qualificationFields = @(
        'schemaVersion', 'banner', 'recordType', 'qualificationEligible', 'approved', 'vc6Qualified', 'pcId',
        'visualStudio', 'adapterPath', 'buildManifestPath', 'adapterSha256', 'msBuildPath', 'msBuildSha256',
        'projectSha256', 'vcxProjectSha256', 'sandboxRoot', 'logRoot', 'evidenceRoot',
        'cycleWatchHeaderSha256', 'cycleWatchTestsSha256', 'cycleWatchTestsLinkerProbeSha256',
        'cycleWatchSourceBaselineSha256', 'cycleWatchSourceThreshold3ErrorSha256', 'cycleWatchSourceThreshold3FixedSha256',
        'startedAt', 'finishedAt', 'passed', 'probes'
    )
    Assert-DemoAdapterPropertySet $qualificationRecord $qualificationFields 'Qualification record has closed top-level schema'
    Assert-DemoAdapterPropertySet $qualificationRecord.visualStudio @('isComplete', 'isLaunchable') 'Qualification record has closed Visual Studio gate state'
    Assert-Equal $qualificationRecord.schemaVersion '1.0' 'Qualification record has fixed schema version'
    Assert-Equal $qualificationRecord.banner $unicodeBanner 'Qualification record has exact Unicode banner'
    Assert-Equal $qualificationRecord.recordType 'RAW_PROTOCOL_EVIDENCE_ONLY' 'Qualification record labels raw protocol evidence'
    Assert-Equal $qualificationRecord.qualificationEligible $false 'Incomplete/unlaunchable VS cannot be qualification eligible'
    Assert-Equal $qualificationRecord.approved $false 'Raw driver never claims approval'
    Assert-Equal $qualificationRecord.vc6Qualified $false 'Raw driver never claims VC6 qualification'
    Assert-Equal $qualificationRecord.visualStudio.isComplete $false 'Raw record preserves incomplete VS gate'
    Assert-Equal $qualificationRecord.visualStudio.isLaunchable $false 'Raw record preserves unlaunchable VS gate'
    Assert-Equal $qualificationRecord.adapterSha256 (Get-DemoAdapterHash $adapterPath) 'Qualification record hashes adapter'
    Assert-Equal $qualificationRecord.msBuildSha256 (Get-DemoAdapterHash $fakeTools.MsBuildPath) 'Qualification record hashes MSBuild'
    Assert-Equal $qualificationRecord.projectSha256 $manifest.projectSha256 'Qualification record fixes DSP hash'
    Assert-Equal $qualificationRecord.vcxProjectSha256 $manifest.vcxProjectSha256 'Qualification record fixes VCX hash'
    foreach ($compilerInputField in @(
        'cycleWatchHeaderSha256', 'cycleWatchTestsSha256', 'cycleWatchTestsLinkerProbeSha256',
        'cycleWatchSourceBaselineSha256', 'cycleWatchSourceThreshold3ErrorSha256', 'cycleWatchSourceThreshold3FixedSha256'
    )) { Assert-Equal $qualificationRecord.$compilerInputField $manifest.$compilerInputField "Qualification record fixes compiler-input field '$compilerInputField'" }
    Assert-Equal $qualificationRecord.passed $true 'All deterministic raw probes pass'
    $probeIds = @($qualificationRecord.probes | ForEach-Object { $_.id })
    $expectedProbeIds = @('help', 'msbuild-hash', 'normal-make', 'normal-rebuild', 'compiler-failure', 'linker-failure', 'artifact-presence', 'invalid-target-no-launch', 'invalid-input-no-launch')
    Assert-Equal (@($qualificationRecord.probes).Count) $expectedProbeIds.Count 'Qualification record has fixed probe count'
    Assert-Equal (@($probeIds | Select-Object -Unique).Count) $probeIds.Count 'Qualification probe IDs are unique'
    Assert-Equal (@($probeIds | Sort-Object) -join ',') (@($expectedProbeIds | Sort-Object) -join ',') 'Qualification record has exact probe IDs'
    $probeFields = @(
        'id', 'class', 'expectedExit', 'observedExit', 'nativeLaunchObserved', 'passed',
        'relativeLogPath', 'logSha256', 'relativeEvidencePath', 'evidenceSha256', 'relativeArtifactPath', 'artifactSha256'
    )
    foreach ($probe in @($qualificationRecord.probes)) {
        Assert-DemoAdapterPropertySet $probe $probeFields "Probe '$($probe.id)' has closed schema"
        Assert-Equal $probe.passed $true "Probe '$($probe.id)' passes"
        foreach ($pathField in @('relativeLogPath', 'relativeEvidencePath', 'relativeArtifactPath')) {
            if ($null -ne $probe.$pathField) {
                Assert-True (-not [System.IO.Path]::IsPathRooted([string]$probe.$pathField)) "Probe '$($probe.id)' stores relative $pathField"
                Assert-True ([string]$probe.$pathField -notmatch '(^|[\\/])\.\.([\\/]|$)') "Probe '$($probe.id)' $pathField cannot escape"
            }
        }
    }
    foreach ($noLaunchId in @('help', 'msbuild-hash', 'artifact-presence', 'invalid-target-no-launch', 'invalid-input-no-launch')) {
        $noLaunchProbe = @($qualificationRecord.probes | Where-Object { $_.id -eq $noLaunchId })[0]
        Assert-Equal $noLaunchProbe.nativeLaunchObserved $false "Probe '$noLaunchId' records no native launch"
    }
    Assert-Equal (@(Read-DemoAdapterTrace $tracePath).Count) 4 'Qualification launches MSBuild only for Make, Rebuild, compiler, and linker probes'
    Assert-Equal (Get-DemoAdapterTreeFingerprint $distributionRoot) $distributionFingerprint 'Qualification never mutates source distribution'
    $qualificationSandboxRoot = Join-Path $sandboxRoot 'ADAPTER-QUALIFY'
    $retainedLinkSources = @(Get-ChildItem -LiteralPath $qualificationSandboxRoot -Filter 'CycleWatchTests.cpp' -File -Recurse | Where-Object {
        [System.Text.Encoding]::GetEncoding(932).GetString([System.IO.File]::ReadAllBytes($_.FullName)).Contains('TEAM_BOB_DEMO_MISSING_LINK_SYMBOL')
    })
    Assert-Equal $retainedLinkSources.Count 1 'Link probe modifies exactly one retained sandbox source'
    $retainedLinkText = [System.Text.Encoding]::GetEncoding(932).GetString([System.IO.File]::ReadAllBytes($retainedLinkSources[0].FullName))
    Assert-True ($retainedLinkText -notmatch '(?<!\r)\n|\r(?!\n)') 'Link probe preserves CP932 CRLF'
    Assert-True ($retainedLinkText.Contains('extern "C" void TEAM_BOB_DEMO_MISSING_LINK_SYMBOL();')) 'Link probe adds a valid C-linkage declaration rather than a compiler fault'
    Assert-True (-not ([System.Text.Encoding]::GetEncoding(932).GetString([System.IO.File]::ReadAllBytes((Join-Path $distributionRoot 'demo\CycleWatch\tests\CycleWatchTests.cpp'))).Contains('TEAM_BOB_DEMO_MISSING_LINK_SYMBOL'))) 'Link marker never reaches distribution source'

    Assert-Equal (Get-DemoAdapterTreeFingerprint $distributionRoot) $distributionFingerprint 'Core adapter tests leave distribution unchanged'
    Assert-Equal (Get-DemoAdapterTreeFingerprint (Join-Path $demoAdapterRepoRoot 'profile')) $profileFingerprintBefore 'Core adapter tests leave production profile byte-identical'
    Assert-Equal (Get-DemoAdapterTreeFingerprint (Join-Path $demoAdapterRepoRoot 'demo\CycleWatch')) $demoSourceFingerprintBefore 'Core adapter tests leave tracked synthetic source byte-identical'
} finally {
    foreach ($name in $environmentNames) { [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process') }
    if (Test-Path -LiteralPath $demoAdapterFixtureFull) {
        $verifiedFixture = [System.IO.Path]::GetFullPath($demoAdapterFixtureFull)
        if (-not $verifiedFixture.StartsWith($demoAdapterTempFull + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove unverified adapter fixture root: $verifiedFixture"
        }
        Remove-Item -LiteralPath $verifiedFixture -Recurse -Force
    }
}

$demoAdapterAssertionCount = $script:Assertions - $demoAdapterAssertionsBefore
Write-Host "PASS: $demoAdapterAssertionCount demo adapter contract assertions succeeded."

if ($demoAdapterStandalone) { exit 0 }
