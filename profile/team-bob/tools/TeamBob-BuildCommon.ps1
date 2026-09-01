$ErrorActionPreference = 'Stop'

if ($null -eq ('TeamBobNativePath' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
public static class TeamBobNativePath {
    private const uint FILE_SHARE_READ = 0x00000001;
    private const uint FILE_SHARE_WRITE = 0x00000002;
    private const uint FILE_SHARE_DELETE = 0x00000004;
    private const uint OPEN_EXISTING = 3;
    private const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
    private const uint VOLUME_NAME_NT = 0x2;
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetFinalPathNameByHandleW(SafeFileHandle handle, StringBuilder path, uint length, uint flags);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern uint GetDriveTypeW(string rootPathName);
    public static bool IsRemoteDrive(string rootPath) { return GetDriveTypeW(rootPath) == 4; }
    public static string GetFinalDirectoryPath(string path) {
        using (SafeFileHandle handle = CreateFileW(path, 0, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, IntPtr.Zero, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, IntPtr.Zero)) {
            if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot open path for physical resolution: " + path);
            StringBuilder buffer = new StringBuilder(1024);
            uint length = GetFinalPathNameByHandleW(handle, buffer, (uint)buffer.Capacity, VOLUME_NAME_NT);
            if (length == 0) throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot resolve physical path: " + path);
            if (length >= buffer.Capacity) {
                buffer = new StringBuilder((int)length + 1);
                length = GetFinalPathNameByHandleW(handle, buffer, (uint)buffer.Capacity, VOLUME_NAME_NT);
                if (length == 0 || length >= buffer.Capacity) throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot resolve physical path: " + path);
            }
            return buffer.ToString();
        }
    }
}
'@
}

function New-TeamBobFailure {
    param([string]$Status, [string]$Message, [int]$NativeExitCode = 0)
    $exception = New-Object System.InvalidOperationException($Message)
    $exception.Data['TeamBobStatus'] = $Status
    $exception.Data['NativeExitCode'] = $NativeExitCode
    return $exception
}

function Test-TeamBobAbsolutePath {
    param([string]$Path)
    return -not [string]::IsNullOrWhiteSpace($Path) -and $Path -match '^(?:[A-Za-z]:[\\/]|\\\\[^\\/]+[\\/][^\\/]+)'
}

function Test-TeamBobNetworkPathForm {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $normalized = $Path.Replace('/', '\')
    if ($normalized.StartsWith('\\', [System.StringComparison]::Ordinal)) { return $true }
    foreach ($prefix in @('\??\UNC', '\GLOBAL??\UNC', '\Device\UNC', '\Device\Mup', '\Device\LanmanRedirector', '\Device\WebDavRedirector', '\Device\Rdr', '\Device\DfsClient')) {
        if ($normalized.Equals($prefix, [System.StringComparison]::OrdinalIgnoreCase) -or $normalized.StartsWith($prefix + '\', [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Assert-TeamBobLocalPathForm {
    param([string]$Path, [string]$Label = 'Path', [string]$FailureStatus = 'INTEGRITY_FAILED')
    if (Test-TeamBobNetworkPathForm $Path) {
        throw (New-TeamBobFailure $FailureStatus "$Label must resolve to a local non-UNC path; network paths and redirector aliases are forbidden.")
    }
}

function Get-TeamBobCanonicalPath {
    param([string]$Path, [string]$Label = 'Path', [string]$FailureStatus = 'INTEGRITY_FAILED')
    Assert-TeamBobLocalPathForm $Path $Label $FailureStatus
    try { $fullPath = [System.IO.Path]::GetFullPath($Path) } catch { throw (New-TeamBobFailure $FailureStatus "$Label is not a valid local path: $Path") }
    Assert-TeamBobLocalPathForm $fullPath $Label $FailureStatus
    $volumeRoot = [System.IO.Path]::GetPathRoot($fullPath)
    if ([string]::IsNullOrWhiteSpace($volumeRoot) -or $volumeRoot -notmatch '^[A-Za-z]:[\\/]$') { throw (New-TeamBobFailure $FailureStatus "$Label must resolve to a local drive path.") }
    try {
        if ([TeamBobNativePath]::IsRemoteDrive($volumeRoot)) { throw (New-TeamBobFailure $FailureStatus "$Label must resolve to a local non-UNC drive; mapped network drives are forbidden.") }
    } catch {
        if ($null -ne $_.Exception.Data['TeamBobStatus']) { throw }
        throw (New-TeamBobFailure $FailureStatus ("$Label drive locality could not be verified: " + $_.Exception.Message))
    }
    if ($fullPath.Equals($volumeRoot, [System.StringComparison]::OrdinalIgnoreCase)) { return $volumeRoot }
    return $fullPath.TrimEnd('\', '/')
}

function Get-TeamBobPhysicalPath {
    param([string]$Path, [string]$Label, [ValidateSet('Container', 'Leaf')][string]$PathType = 'Container')
    $fullPath = Get-TeamBobCanonicalPath $Path $Label 'INTEGRITY_FAILED'
    if (-not (Test-Path -LiteralPath $fullPath -PathType $PathType)) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' "$Label must be an existing $($PathType.ToLowerInvariant()) for physical path validation.") }
    $root = [System.IO.Path]::GetPathRoot($fullPath)
    $current = $root
    $remainder = $fullPath.Substring($root.Length)
    foreach ($component in @($remainder -split '[\\/]' | Where-Object { $_.Length -gt 0 })) {
        $current = Join-Path $current $component
        $attributes = [System.IO.File]::GetAttributes($current)
        if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' "$Label contains a forbidden reparse/alias component: $current") }
    }
    try { $physical = [TeamBobNativePath]::GetFinalDirectoryPath($fullPath) } catch { throw (New-TeamBobFailure 'INTEGRITY_FAILED' ("$Label physical path resolution failed: " + $_.Exception.Message)) }
    Assert-TeamBobLocalPathForm $physical $Label 'INTEGRITY_FAILED'
    if ($physical.StartsWith('\\?\UNC\', [System.StringComparison]::OrdinalIgnoreCase)) { $physical = '\\' + $physical.Substring(8) }
    elseif ($physical.StartsWith('\\?\', [System.StringComparison]::OrdinalIgnoreCase)) { $physical = $physical.Substring(4) }
    $physical = $physical.Replace('/', '\')
    if ($physical.Length -gt 1) { $physical = $physical.TrimEnd('\') }
    return $physical
}

function Test-TeamBobResolvedPathAtOrBelow {
    param([string]$Candidate, [string]$Root)
    $candidateValue = $Candidate.Replace('/', '\').TrimEnd('\')
    $rootValue = $Root.Replace('/', '\').TrimEnd('\')
    if ($candidateValue.Equals($rootValue, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $candidateValue.StartsWith($rootValue + '\', [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-TeamBobPathAtOrBelow {
    param([string]$Candidate, [string]$Root)
    $candidateFull = Get-TeamBobCanonicalPath $Candidate
    $rootFull = Get-TeamBobCanonicalPath $Root
    if ($candidateFull.Equals($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    $prefix = $rootFull
    if (-not ($prefix.EndsWith('\') -or $prefix.EndsWith('/'))) { $prefix += [System.IO.Path]::DirectorySeparatorChar }
    return $candidateFull.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-TeamBobRelativePath {
    param([string]$Root, [string]$Candidate)
    $rootFull = Get-TeamBobCanonicalPath $Root
    $candidateFull = Get-TeamBobCanonicalPath $Candidate
    if (-not (Test-TeamBobPathAtOrBelow $candidateFull $rootFull) -or $candidateFull.Equals($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw (New-TeamBobFailure 'INTEGRITY_FAILED' "Path is not a child of the expected root: $candidateFull")
    }
    $prefix = $rootFull
    if (-not ($prefix.EndsWith('\') -or $prefix.EndsWith('/'))) { $prefix += [System.IO.Path]::DirectorySeparatorChar }
    return $candidateFull.Substring($prefix.Length).Replace('\', '/')
}

function ConvertTo-TeamBobRelativePath {
    param([string]$Root, [string]$RelativePath, [string]$Label, [string]$FailureStatus = 'INTEGRITY_FAILED')
    if ([string]::IsNullOrWhiteSpace($RelativePath) -or $RelativePath -match '[\x00-\x1F\x7F]' -or (Test-TeamBobNetworkPathForm $RelativePath) -or [System.IO.Path]::IsPathRooted($RelativePath) -or $RelativePath -match '(^|[\\/])\.\.?([\\/]|$)') {
        throw (New-TeamBobFailure $FailureStatus "$Label must be a safe relative path: $RelativePath")
    }
    $candidate = Get-TeamBobCanonicalPath (Join-Path $Root $RelativePath) $Label $FailureStatus
    if (-not (Test-TeamBobPathAtOrBelow $candidate $Root) -or $candidate.Equals((Get-TeamBobCanonicalPath $Root), [System.StringComparison]::OrdinalIgnoreCase)) {
        throw (New-TeamBobFailure $FailureStatus "$Label resolves outside its root: $RelativePath")
    }
    return [pscustomobject]@{ FullPath = $candidate; RelativePath = (Get-TeamBobRelativePath $Root $candidate) }
}

function Assert-TeamBobExactProperties {
    param([object]$Object, [string[]]$Names, [string]$Label, [string]$FailureStatus = 'ENVIRONMENT_FAILED')
    if ($null -eq $Object -or -not ($Object -is [System.Management.Automation.PSCustomObject])) { throw (New-TeamBobFailure $FailureStatus "$Label must be a JSON object.") }
    $actual = @($Object.PSObject.Properties.Name | Sort-Object)
    $expected = @($Names | Sort-Object)
    if (($actual -join "`n") -ne ($expected -join "`n")) { throw (New-TeamBobFailure $FailureStatus "$Label has missing or unsupported fields.") }
}

function Test-TeamBobInteger {
    param([object]$Value)
    return $Value -is [sbyte] -or $Value -is [byte] -or $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int32] -or $Value -is [uint32] -or $Value -is [int64] -or $Value -is [uint64]
}

function Read-TeamBobCanonicalPacket {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' "Work packet does not exist: $Path") }
    $text = [System.IO.File]::ReadAllText($Path)
    $match = [regex]::Match($text, '(?s)<!-- canonical-work-packet-json:start -->\s*```json\s*(?<json>\{.*?\})\s*```\s*<!-- canonical-work-packet-json:end -->')
    if (-not $match.Success) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Work packet canonical JSON block is missing or malformed.') }
    try { $packet = $match.Groups['json'].Value | ConvertFrom-Json } catch { throw (New-TeamBobFailure 'INTEGRITY_FAILED' ('Work packet canonical JSON is invalid: ' + $_.Exception.Message)) }
    $fields = @(
        'Profile Version', 'Task ID', 'Difficulty', 'Risk', 'Customer', 'ReqIDs', 'Word Baseline', 'QA Baseline', 'Spec Baseline',
        'Bazaar Root', 'Bazaar Branch', 'Bazaar Full Revision ID', 'Allowed Files', 'Forbidden Areas', 'RT Impact', 'Safety Impact',
        'Board Impact', 'Driver Impact', 'ABI Impact', 'Build Impact', 'Customer Branch Impact', 'RT Impact Clear', 'Safety Impact Clear',
        'Board Impact Clear', 'Driver Impact Clear', 'ABI Impact Clear', 'Build Impact Clear', 'Customer Branch Impact Clear', 'Clean Working Copy',
        'Open QA', 'Build Profile ID', 'Autonomous-Edit-Build-Approved', 'Soft-Execute-Risk-Accepted', 'Max-Repair-Cycles',
        'Specification Approver', 'Implementation Approver'
    )
    Assert-TeamBobExactProperties $packet $fields 'Work packet' 'INTEGRITY_FAILED'
    return $packet
}

function Get-TeamBobPacketContext {
    param([object]$Packet, [string]$WorkPacketPath)
    if ($Packet.'Profile Version' -ne '0.1.0-poc' -or $Packet.Risk -ne 'Green' -or @($Packet.'Open QA').Count -ne 0 -or
        $Packet.'Autonomous-Edit-Build-Approved' -ne 'YES' -or $Packet.'Soft-Execute-Risk-Accepted' -ne 'YES' -or
        -not (Test-TeamBobInteger $Packet.'Max-Repair-Cycles') -or [int64]$Packet.'Max-Repair-Cycles' -ne 2) {
        throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Work packet does not satisfy the Green approval and repair-budget gates.')
    }
    foreach ($field in @('RT Impact Clear', 'Safety Impact Clear', 'Board Impact Clear', 'Driver Impact Clear', 'ABI Impact Clear', 'Build Impact Clear', 'Customer Branch Impact Clear', 'Clean Working Copy')) {
        if ($Packet.$field -ne 'YES') { throw (New-TeamBobFailure 'INTEGRITY_FAILED' "Work packet field '$field' must be YES.") }
    }
    foreach ($field in @('Task ID', 'Bazaar Root', 'Bazaar Branch', 'Bazaar Full Revision ID', 'Build Profile ID', 'Specification Approver', 'Implementation Approver')) {
        if ([string]::IsNullOrWhiteSpace([string]$Packet.$field)) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' "Work packet field '$field' is empty.") }
    }
    if ([string]$Packet.'Task ID' -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$') { throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Work packet Task ID is unsafe.') }
    if (-not (Test-TeamBobAbsolutePath ([string]$Packet.'Bazaar Root'))) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Bazaar Root must be absolute.') }
    $bazaarRoot = Get-TeamBobCanonicalPath ([string]$Packet.'Bazaar Root')
    if (-not (Test-Path -LiteralPath $bazaarRoot -PathType Container) -or -not (Test-Path -LiteralPath (Join-Path $bazaarRoot '.bzr') -PathType Container)) {
        throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Bazaar Root must be an existing Bazaar working-tree root.')
    }
    $expectedPacket = Get-TeamBobCanonicalPath (Join-Path $bazaarRoot (Join-Path (Join-Path 'team-bob-work' ([string]$Packet.'Task ID')) 'work-packet.md'))
    if (-not $expectedPacket.Equals((Get-TeamBobCanonicalPath $WorkPacketPath), [System.StringComparison]::OrdinalIgnoreCase)) {
        throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Work packet path does not match its Bazaar Root and Task ID.')
    }
    $forbiddenAreas = @()
    foreach ($forbidden in @($Packet.'Forbidden Areas')) {
        if (-not ($forbidden -is [string]) -or [string]::IsNullOrWhiteSpace($forbidden) -or $forbidden -match '[\x00-\x1F\x7F]' -or
            [System.IO.Path]::IsPathRooted($forbidden) -or $forbidden -match '(^|[\\/])\.\.?([\\/]|$)') {
            throw (New-TeamBobFailure 'INTEGRITY_FAILED' "Forbidden Areas contains an unsafe entry: $forbidden")
        }
        $normalizedForbidden = $forbidden.Replace('\', '/').Trim('/')
        if ([string]::IsNullOrWhiteSpace($normalizedForbidden)) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Forbidden Areas contains an empty normalized path.') }
        $forbiddenAreas += $normalizedForbidden
    }
    if ($forbiddenAreas.Count -eq 0) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Forbidden Areas must contain at least one safe entry.') }
    $supported = @('.c', '.cc', '.cpp', '.cxx', '.h', '.hh', '.hpp', '.hxx', '.inl')
    $allowed = @()
    $seen = @{}
    foreach ($entry in @($Packet.'Allowed Files')) {
        if (-not ($entry -is [string])) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Allowed Files must contain strings only.') }
        $resolved = ConvertTo-TeamBobRelativePath $bazaarRoot $entry 'Allowed File' 'INTEGRITY_FAILED'
        if (-not ($supported -contains [System.IO.Path]::GetExtension($resolved.FullPath).ToLowerInvariant())) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' "Allowed File extension is unsupported: $entry") }
        if (-not (Test-Path -LiteralPath $resolved.FullPath -PathType Leaf)) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' "Allowed File is missing: $entry") }
        $key = $resolved.RelativePath.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' "Allowed File is duplicated: $entry") }
        $seen[$key] = $true
        foreach ($forbiddenNormalized in $forbiddenAreas) {
            if ($resolved.RelativePath.Equals($forbiddenNormalized, [System.StringComparison]::OrdinalIgnoreCase) -or $resolved.RelativePath.StartsWith($forbiddenNormalized + '/', [System.StringComparison]::OrdinalIgnoreCase)) {
                throw (New-TeamBobFailure 'INTEGRITY_FAILED' "Allowed File is inside a forbidden area: $entry")
            }
        }
        $allowed += $resolved
    }
    if ($allowed.Count -eq 0) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'At least one Allowed File is required.') }
    return [pscustomobject]@{
        TaskId = [string]$Packet.'Task ID'; BazaarRoot = $bazaarRoot; AllowedFiles = @($allowed); ForbiddenAreas = @($forbiddenAreas)
        BuildProfileId = [string]$Packet.'Build Profile ID'; BazaarBranch = [string]$Packet.'Bazaar Branch'; BazaarRevision = [string]$Packet.'Bazaar Full Revision ID'
    }
}

function Get-TeamBobFileHash {
    param([string]$Path)
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Write-TeamBobUtf8File {
    param([string]$Path, [string]$Text)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { [System.IO.Directory]::CreateDirectory($parent) | Out-Null }
    $temporaryPath = Join-Path $parent ('.team-bob.' + [guid]::NewGuid().ToString('N') + '.tmp')
    $backupPath = Join-Path $parent ('.team-bob.' + [guid]::NewGuid().ToString('N') + '.bak')
    try {
        [System.IO.File]::WriteAllText($temporaryPath, $Text, (New-Object System.Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $Path -PathType Leaf) { [System.IO.File]::Replace($temporaryPath, $Path, $backupPath) } else { [System.IO.File]::Move($temporaryPath, $Path) }
    } finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) { Remove-Item -LiteralPath $temporaryPath -Force }
        if (Test-Path -LiteralPath $backupPath -PathType Leaf) { Remove-Item -LiteralPath $backupPath -Force }
    }
}

function ConvertTo-TeamBobCommandArgument {
    param([string]$Argument)
    if ($null -eq $Argument) { $Argument = '' }
    if ($Argument.Length -gt 0 -and $Argument -notmatch '[\s"]') { return $Argument }
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    $slashes = 0
    foreach ($character in $Argument.ToCharArray()) {
        if ($character -eq '\') { $slashes++; continue }
        if ($character -eq '"') {
            [void]$builder.Append(('\' * (($slashes * 2) + 1)))
            [void]$builder.Append('"')
        } else {
            if ($slashes -gt 0) { [void]$builder.Append(('\' * $slashes)) }
            [void]$builder.Append($character)
        }
        $slashes = 0
    }
    if ($slashes -gt 0) { [void]$builder.Append(('\' * ($slashes * 2))) }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Invoke-TeamBobTreeTermination {
    param([int]$ProcessId)
    $systemDirectory = [Environment]::GetFolderPath([Environment+SpecialFolder]::System)
    $taskKillPath = Join-Path $systemDirectory 'taskkill.exe'
    if (-not (Test-Path -LiteralPath $taskKillPath -PathType Leaf)) { return $false }
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $taskKillPath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.Arguments = (@('/PID', [string]$ProcessId, '/T', '/F') | ForEach-Object { ConvertTo-TeamBobCommandArgument $_ }) -join ' '
    $taskKill = New-Object System.Diagnostics.Process
    $taskKill.StartInfo = $startInfo
    try {
        if (-not $taskKill.Start()) { return $false }
        if (-not $taskKill.WaitForExit(5000)) {
            try { if (-not $taskKill.HasExited) { $taskKill.Kill() } } catch { }
            [void]$taskKill.WaitForExit(1000)
            return $false
        }
        return $taskKill.ExitCode -eq 0
    } catch {
        return $false
    } finally {
        $taskKill.Dispose()
    }
}

function Get-TeamBobCompletedTaskText {
    param([System.Threading.Tasks.Task[string]]$Task)
    try {
        if (-not $Task.IsCompleted) { [void]$Task.Wait(2000) }
    } catch { }
    if ($Task.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion) { return $Task.Result }
    return ''
}

function Invoke-TeamBobProcess {
    param([string]$FilePath, [string[]]$Arguments, [string]$WorkingDirectory, [int]$TimeoutSeconds)
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $cp932 = [System.Text.Encoding]::GetEncoding(932)
    try {
        $startInfo.StandardOutputEncoding = $cp932
        $startInfo.StandardErrorEncoding = $cp932
    } catch { }
    $encodedArguments = @($Arguments | ForEach-Object { ConvertTo-TeamBobCommandArgument ([string]$_) })
    $startInfo.Arguments = $encodedArguments -join ' '
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    $startedAt = [DateTimeOffset]::UtcNow
    try {
        if (-not $process.Start()) { throw 'Process.Start returned false.' }
        $processId = $process.Id
        $standardOutputTask = $process.StandardOutput.ReadToEndAsync()
        $standardErrorTask = $process.StandardError.ReadToEndAsync()
        $milliseconds = [long]$TimeoutSeconds * 1000
        if ($milliseconds -gt [int]::MaxValue) { $milliseconds = [int]::MaxValue }
        $completed = $process.WaitForExit([int]$milliseconds)
        $terminationComplete = $null
        if (-not $completed) {
            $treeTerminationSucceeded = Invoke-TeamBobTreeTermination $processId
            $parentExited = $process.WaitForExit(5000)
            $terminationComplete = $treeTerminationSucceeded -and $parentExited
            if (-not $parentExited) {
                try { if (-not $process.HasExited) { $process.Kill() } } catch { }
                [void]$process.WaitForExit(1000)
            }
        }
        $standardOutput = Get-TeamBobCompletedTaskText $standardOutputTask
        $standardError = Get-TeamBobCompletedTaskText $standardErrorTask
        $captureComplete = $standardOutputTask.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion -and $standardErrorTask.Status -eq [System.Threading.Tasks.TaskStatus]::RanToCompletion
        $exitCode = $null
        try { if ($process.HasExited) { $exitCode = $process.ExitCode } } catch { }
        return [pscustomobject]@{
            ProcessId = $processId; TimedOut = (-not $completed); ExitCode = $exitCode; StandardOutput = $standardOutput; StandardError = $standardError
            TerminationComplete = $terminationComplete; CaptureComplete = $captureComplete
            StartedAt = $startedAt.ToString('o'); FinishedAt = [DateTimeOffset]::UtcNow.ToString('o')
        }
    } finally {
        $process.Dispose()
    }
}

function Get-TeamBobLocalEnvironment {
    param([string]$ManifestPath, [string]$WorkSchemaPath, [string]$BuildSchemaPath, [switch]$BazaarOnly)
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA) -or -not (Test-TeamBobAbsolutePath $env:LOCALAPPDATA)) { throw (New-TeamBobFailure 'ENVIRONMENT_FAILED' 'LOCALAPPDATA must be an absolute path.') }
    $localAppData = Get-TeamBobCanonicalPath $env:LOCALAPPDATA 'LOCALAPPDATA' 'ENVIRONMENT_FAILED'
    $path = Join-Path $localAppData 'IBM/BobTeamProfile/vc6-machine-control-poc/environment.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw (New-TeamBobFailure 'ENVIRONMENT_FAILED' "Local environment registration is missing: $path") }
    try { $environment = Get-Content -Raw -LiteralPath $path | ConvertFrom-Json } catch { throw (New-TeamBobFailure 'ENVIRONMENT_FAILED' ('Local environment registration is invalid JSON: ' + $_.Exception.Message)) }
    $fields = @('schemaVersion', 'profileId', 'profileVersion', 'workPacketSchemaId', 'buildTargetSchemaId', 'pcId', 'msdevPath', 'msdevSha256', 'bazaarPath', 'bazaarSha256', 'sandboxRoot', 'logRoot')
    Assert-TeamBobExactProperties $environment $fields 'Local environment registration' 'ENVIRONMENT_FAILED'
    $manifest = Get-Content -Raw -LiteralPath $ManifestPath | ConvertFrom-Json
    $workSchema = Get-Content -Raw -LiteralPath $WorkSchemaPath | ConvertFrom-Json
    $buildSchema = Get-Content -Raw -LiteralPath $BuildSchemaPath | ConvertFrom-Json
    if ($environment.schemaVersion -ne '1.0' -or $environment.profileId -ne $manifest.profile.id -or $environment.profileVersion -ne $manifest.version -or
        $environment.workPacketSchemaId -ne $workSchema.'$id' -or $environment.buildTargetSchemaId -ne $buildSchema.'$id') {
        throw (New-TeamBobFailure 'ENVIRONMENT_FAILED' 'Local environment profile/schema identity does not match the installed profile.')
    }
    if ([string]::IsNullOrWhiteSpace([string]$environment.pcId) -or -not ([string]$environment.pcId).Equals([Environment]::MachineName, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw (New-TeamBobFailure 'ENVIRONMENT_FAILED' 'Local environment pcId does not match the current machine.')
    }
    foreach ($field in @('msdevPath', 'bazaarPath', 'sandboxRoot', 'logRoot')) {
        if (-not (Test-TeamBobAbsolutePath ([string]$environment.$field))) { throw (New-TeamBobFailure 'ENVIRONMENT_FAILED' "Local environment field '$field' must be absolute.") }
        $environment.PSObject.Properties[$field].Value = Get-TeamBobCanonicalPath ([string]$environment.$field) ("Local environment field '$field'") 'ENVIRONMENT_FAILED'
    }
    if (-not (Test-Path -LiteralPath $environment.bazaarPath -PathType Leaf)) { throw (New-TeamBobFailure 'ENVIRONMENT_FAILED' "Registered Bazaar tool is missing: $($environment.bazaarPath)") }
    [void](Get-TeamBobPhysicalPath $environment.bazaarPath 'Registered Bazaar tool' 'Leaf')
    if ((Get-TeamBobFileHash $environment.bazaarPath) -ne ([string]$environment.bazaarSha256).ToLowerInvariant()) { throw (New-TeamBobFailure 'ENVIRONMENT_FAILED' 'Registered Bazaar hash does not match.') }
    if (-not $BazaarOnly) {
        if (-not (Test-Path -LiteralPath $environment.msdevPath -PathType Leaf)) { throw (New-TeamBobFailure 'ENVIRONMENT_FAILED' "Registered MSDEV tool is missing: $($environment.msdevPath)") }
        [void](Get-TeamBobPhysicalPath $environment.msdevPath 'Registered MSDEV tool' 'Leaf')
        foreach ($field in @('sandboxRoot', 'logRoot')) { if (-not (Test-Path -LiteralPath $environment.$field -PathType Container)) { throw (New-TeamBobFailure 'ENVIRONMENT_FAILED' "Registered root is missing or not a directory: $($environment.$field)") } }
        if ((Get-TeamBobFileHash $environment.msdevPath) -ne ([string]$environment.msdevSha256).ToLowerInvariant()) { throw (New-TeamBobFailure 'ENVIRONMENT_FAILED' 'Registered MSDEV hash does not match.') }
    }
    return $environment
}

function Get-TeamBobBuildProfile {
    param([string]$CatalogPath, [string]$ProfileId, [string]$PcId)
    try { $catalog = Get-Content -Raw -LiteralPath $CatalogPath | ConvertFrom-Json } catch { throw (New-TeamBobFailure 'ENVIRONMENT_FAILED' ('Build target catalog is invalid JSON: ' + $_.Exception.Message)) }
    Assert-TeamBobExactProperties $catalog @('profiles') 'Build target catalog' 'ENVIRONMENT_FAILED'
    $profileFields = @('id', 'enabled', 'projectFile', 'target', 'timeoutSeconds', 'expectedArtifacts', 'excludePatterns', 'outputLogPattern', 'successPattern', 'compilerErrorPattern', 'linkerErrorPattern', 'environmentErrorPattern', 'qualification')
    $qualificationFields = @('msdevHelp', 'makeSucceeded', 'rebuildSucceeded', 'compileFailureObserved', 'linkFailureObserved', 'pcId', 'recordId', 'recordedAt')
    $selected = @()
    foreach ($profile in @($catalog.profiles)) {
        Assert-TeamBobExactProperties $profile $profileFields 'Build profile' 'ENVIRONMENT_FAILED'
        Assert-TeamBobExactProperties $profile.qualification $qualificationFields 'Build profile qualification' 'ENVIRONMENT_FAILED'
        if ($profile.id -eq $ProfileId) { $selected += $profile }
    }
    if ($selected.Count -ne 1) { throw (New-TeamBobFailure 'ENVIRONMENT_FAILED' "Build Profile ID must select exactly one profile: $ProfileId") }
    $profile = $selected[0]
    if ($profile.enabled -isnot [bool] -or -not $profile.enabled) { throw (New-TeamBobFailure 'ENVIRONMENT_FAILED' 'Selected build profile is not enabled.') }
    foreach ($flag in @('msdevHelp', 'makeSucceeded', 'rebuildSucceeded', 'compileFailureObserved', 'linkFailureObserved')) {
        if ($profile.qualification.$flag -isnot [bool] -or -not $profile.qualification.$flag) { throw (New-TeamBobFailure 'ENVIRONMENT_FAILED' "Build profile qualification flag '$flag' is incomplete.") }
    }
    if ([string]::IsNullOrWhiteSpace([string]$profile.qualification.pcId) -or -not ([string]$profile.qualification.pcId).Equals($PcId, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not ([string]$profile.qualification.pcId).Equals([Environment]::MachineName, [System.StringComparison]::OrdinalIgnoreCase) -or
        [string]::IsNullOrWhiteSpace([string]$profile.qualification.recordId) -or [string]::IsNullOrWhiteSpace([string]$profile.qualification.recordedAt)) {
        throw (New-TeamBobFailure 'ENVIRONMENT_FAILED' 'Build profile qualification PC/record metadata is incomplete or mismatched.')
    }
    if (-not (Test-TeamBobInteger $profile.timeoutSeconds) -or [int64]$profile.timeoutSeconds -lt 1) { throw (New-TeamBobFailure 'ENVIRONMENT_FAILED' 'Build profile timeoutSeconds must be a positive integer.') }
    if ([string]::IsNullOrWhiteSpace([string]$profile.target) -or ([string]$profile.target).IndexOfAny([char[]]@([char]0, [char]13, [char]10)) -ge 0) { throw (New-TeamBobFailure 'ENVIRONMENT_FAILED' 'Build profile target is invalid.') }
    if (@($profile.expectedArtifacts).Count -eq 0) { throw (New-TeamBobFailure 'ENVIRONMENT_FAILED' 'Build profile requires expected artifacts.') }
    foreach ($field in @('outputLogPattern', 'successPattern', 'compilerErrorPattern', 'linkerErrorPattern', 'environmentErrorPattern')) {
        if ([string]::IsNullOrWhiteSpace([string]$profile.$field)) { throw (New-TeamBobFailure 'ENVIRONMENT_FAILED' "Build profile regex '$field' is empty.") }
        try { [void](New-Object System.Text.RegularExpressions.Regex([string]$profile.$field)) } catch { throw (New-TeamBobFailure 'ENVIRONMENT_FAILED' "Build profile regex '$field' is invalid.") }
    }
    foreach ($pattern in @($profile.excludePatterns)) { if (-not ($pattern -is [string]) -or [string]::IsNullOrWhiteSpace($pattern) -or $pattern.IndexOfAny([char[]]@([char]0, [char]13, [char]10)) -ge 0) { throw (New-TeamBobFailure 'ENVIRONMENT_FAILED' 'Build profile exclusion pattern is invalid.') } }
    return $profile
}

function Get-TeamBobInventory {
    param([string]$Root, [string[]]$ExcludedTopNames = @())
    $rootFull = Get-TeamBobCanonicalPath $Root
    $records = @()
    $pending = New-Object System.Collections.ArrayList
    [void]$pending.Add($rootFull)
    while ($pending.Count -gt 0) {
        $directory = [string]$pending[0]
        $pending.RemoveAt(0)
        foreach ($item in @(Get-ChildItem -LiteralPath $directory -Force | Sort-Object Name)) {
            $relative = Get-TeamBobRelativePath $rootFull $item.FullName
            $top = ($relative -split '/')[0]
            if ($ExcludedTopNames -contains $top) { continue }
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' "Reparse points are forbidden in the protected tree: $relative") }
            if ($item.PSIsContainer) {
                $records += ('D|' + $relative)
                [void]$pending.Add($item.FullName)
            } else {
                $records += ('F|' + $relative + '|' + $item.Length + '|' + (Get-TeamBobFileHash $item.FullName))
            }
        }
    }
    return @($records | Sort-Object)
}

function Get-TeamBobAllowedHashes {
    param([object[]]$AllowedFiles)
    $records = @()
    foreach ($file in $AllowedFiles) { $records += ($file.RelativePath + '|' + (Get-TeamBobFileHash $file.FullPath)) }
    return @($records | Sort-Object)
}

function Get-TeamBobProtectedSnapshot {
    param([object]$Context)
    return [pscustomobject]@{
        SourceInventory = @(Get-TeamBobInventory $Context.BazaarRoot @('.bzr', 'team-bob-work'))
        BzrInventory = @(Get-TeamBobInventory (Join-Path $Context.BazaarRoot '.bzr'))
        AllowedHashes = @(Get-TeamBobAllowedHashes $Context.AllowedFiles)
    }
}

function Assert-TeamBobProtectedSnapshot {
    param([object]$Baseline, [object]$Current, [string]$Stage)
    if ((($Baseline.SourceInventory -join "`n") -cne ($Current.SourceInventory -join "`n")) -or
        (($Baseline.BzrInventory -join "`n") -cne ($Current.BzrInventory -join "`n")) -or
        (($Baseline.AllowedHashes -join "`n") -cne ($Current.AllowedHashes -join "`n"))) {
        throw (New-TeamBobFailure 'INTEGRITY_FAILED' "Protected source, Allowed File, or .bzr state changed during $Stage.")
    }
}

function Assert-TeamBobAllowedEncoding {
    param([object[]]$AllowedFiles)
    $encoding = [System.Text.Encoding]::GetEncoding(932, (New-Object System.Text.EncoderExceptionFallback), (New-Object System.Text.DecoderExceptionFallback))
    foreach ($file in $AllowedFiles) {
        $bytes = [System.IO.File]::ReadAllBytes($file.FullPath)
        if (($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) -or
            ($bytes.Length -ge 2 -and (($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) -or ($bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF)))) {
            throw (New-TeamBobFailure 'INTEGRITY_FAILED' "Allowed File has a forbidden BOM: $($file.RelativePath)")
        }
        try { $text = $encoding.GetString($bytes) } catch { throw (New-TeamBobFailure 'INTEGRITY_FAILED' "Allowed File is not CP932-decodable: $($file.RelativePath)") }
        $withoutCrLf = $text.Replace("`r`n", '')
        if ($withoutCrLf.Contains("`r") -or $withoutCrLf.Contains("`n")) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' "Allowed File must use CRLF with no lone newline: $($file.RelativePath)") }
    }
}

function Get-TeamBobNormalizedProcessText {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    return $Text.TrimEnd([char[]]@([char]13, [char]10))
}

function Read-TeamBobStrictCp932File {
    param([string]$Path)
    $encoding = [System.Text.Encoding]::GetEncoding(932, (New-Object System.Text.EncoderExceptionFallback), (New-Object System.Text.DecoderExceptionFallback))
    try { return $encoding.GetString([System.IO.File]::ReadAllBytes($Path)) } catch { throw (New-TeamBobFailure 'ENVIRONMENT_FAILED' ("VC6 /OUT log is not strict CP932: " + $_.Exception.Message)) }
}

function Invoke-TeamBobBazaarQuery {
    param(
        [string]$BazaarPath, [string]$BazaarRoot, [string[]]$Arguments,
        [int[]]$AllowedExitCodes = @(0), [string]$TimeoutStatus = 'ENVIRONMENT_FAILED'
    )
    $result = Invoke-TeamBobProcess $BazaarPath $Arguments $BazaarRoot 30
    if ($result.TimedOut) { throw (New-TeamBobFailure $TimeoutStatus ("Bazaar query timed out: " + ($Arguments -join ' ')) 21) }
    if (-not $result.CaptureComplete) { throw (New-TeamBobFailure $TimeoutStatus ("Bazaar query output capture did not complete: " + ($Arguments -join ' ')) 21) }
    if ($AllowedExitCodes -notcontains [int]$result.ExitCode) { throw (New-TeamBobFailure 'ENVIRONMENT_FAILED' ("Bazaar query failed: " + ($Arguments -join ' ') + " (exit $($result.ExitCode))") ([int]$result.ExitCode)) }
    return [pscustomobject]@{ Output = $result.StandardOutput; Error = $result.StandardError; ExitCode = [int]$result.ExitCode }
}

function Assert-TeamBobBazaarStatus {
    param([string]$Status, [object[]]$AllowedFiles)
    $allowed = @{}
    foreach ($file in $AllowedFiles) { $allowed[$file.RelativePath.ToLowerInvariant()] = $true }
    foreach ($line in @($Status -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $match = [regex]::Match($line, '^ M\s+(?<path>.+)$')
        if (-not $match.Success -or $match.Groups['path'].Value -match '\s=>\s') { throw (New-TeamBobFailure 'INTEGRITY_FAILED' "Bazaar status contains a non-modification or unsupported change: $line") }
        $path = $match.Groups['path'].Value.Trim().Trim('"').Replace('\', '/')
        if ([System.IO.Path]::IsPathRooted($path) -or $path -match '(^|/)\.\.?(?:/|$)' -or -not $allowed.ContainsKey($path.ToLowerInvariant())) {
            throw (New-TeamBobFailure 'INTEGRITY_FAILED' "Bazaar status contains a path outside Allowed Files: $path")
        }
    }
}

function Get-TeamBobBuildBazaarState {
    param([object]$Environment, [object]$Context)
    $statusResult = Invoke-TeamBobBazaarQuery $Environment.bazaarPath $Context.BazaarRoot @('status', '--short') @(0) 'TIMED_OUT'
    $nickResult = Invoke-TeamBobBazaarQuery $Environment.bazaarPath $Context.BazaarRoot @('nick') @(0) 'TIMED_OUT'
    $revisionResult = Invoke-TeamBobBazaarQuery $Environment.bazaarPath $Context.BazaarRoot @('version-info', '--custom', '--template={revision_id}') @(0) 'TIMED_OUT'
    $status = Get-TeamBobNormalizedProcessText $statusResult.Output
    $nick = Get-TeamBobNormalizedProcessText $nickResult.Output
    $revision = Get-TeamBobNormalizedProcessText $revisionResult.Output
    Assert-TeamBobBazaarStatus $status $Context.AllowedFiles
    if (-not $nick.Equals($Context.BazaarBranch, [System.StringComparison]::Ordinal) -or -not $revision.Equals($Context.BazaarRevision, [System.StringComparison]::Ordinal)) {
        throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Current Bazaar branch nick or full revision id does not match the Work Packet baseline.')
    }
    return [pscustomobject]@{ Status = $status; Branch = $nick; Revision = $revision }
}

function Test-TeamBobCopyExclusion {
    param([string]$RelativePath, [string[]]$Patterns, [string[]]$ExpectedArtifacts)
    $normalized = $RelativePath.Replace('\', '/')
    $top = ($normalized -split '/')[0]
    if ($top -ieq '.bzr' -or $top -ieq 'team-bob-work') { return $true }
    foreach ($artifact in $ExpectedArtifacts) { if ($normalized.Equals($artifact.Replace('\', '/'), [System.StringComparison]::OrdinalIgnoreCase)) { return $true } }
    foreach ($pattern in $Patterns) {
        $normalizedPattern = $pattern.Replace('\', '/')
        if ($normalized -like $normalizedPattern -or ([System.IO.Path]::GetFileName($normalized) -like $normalizedPattern)) { return $true }
        if ($normalizedPattern.StartsWith('**/')) {
            $shortPattern = $normalizedPattern.Substring(3)
            if ($normalized -like $shortPattern -or ([System.IO.Path]::GetFileName($normalized) -like $shortPattern)) { return $true }
        }
    }
    return $false
}

function Copy-TeamBobSandboxTree {
    param([string]$SourceRoot, [string]$DestinationRoot, [string[]]$Patterns, [string[]]$ExpectedArtifacts)
    if (Test-Path -LiteralPath $DestinationRoot) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' "Sandbox destination already exists: $DestinationRoot") }
    [System.IO.Directory]::CreateDirectory($DestinationRoot) | Out-Null
    $sourceFull = Get-TeamBobCanonicalPath $SourceRoot
    $pending = New-Object System.Collections.ArrayList
    [void]$pending.Add($sourceFull)
    while ($pending.Count -gt 0) {
        $directory = [string]$pending[0]
        $pending.RemoveAt(0)
        foreach ($item in @(Get-ChildItem -LiteralPath $directory -Force | Sort-Object Name)) {
            $relative = Get-TeamBobRelativePath $sourceFull $item.FullName
            if (Test-TeamBobCopyExclusion $relative $Patterns $ExpectedArtifacts) { continue }
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' "Reparse points are forbidden during sandbox copy: $relative") }
            $destination = Join-Path $DestinationRoot ($relative.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
            if ($item.PSIsContainer) {
                [System.IO.Directory]::CreateDirectory($destination) | Out-Null
                [void]$pending.Add($item.FullName)
            } else {
                $destinationParent = Split-Path -Parent $destination
                if (-not (Test-Path -LiteralPath $destinationParent -PathType Container)) { [System.IO.Directory]::CreateDirectory($destinationParent) | Out-Null }
                [System.IO.File]::Copy($item.FullName, $destination, $false)
            }
        }
    }
}

function Test-TeamBobOutputPathToken {
    param([string]$Line, [string]$Path)
    $normalizedLine = $Line.Replace('\', '/')
    $escaped = [regex]::Escape($Path.Replace('\', '/'))
    return [regex]::IsMatch($normalizedLine, '(?i)(?:^|[^A-Za-z0-9_./-])' + $escaped + '(?=$|[:(\s"''])')
}

function Test-TeamBobFailureAttribution {
    param([string]$Output, [string]$Pattern, [object[]]$AllowedFiles, [string[]]$SourceInventory)
    $baseNameCounts = @{}
    $objectNameCounts = @{}
    foreach ($record in $SourceInventory) {
        if ($record -notmatch '^F\|(?<path>[^|]+)\|') { continue }
        $relative = $Matches['path']
        $baseName = [System.IO.Path]::GetFileName($relative).ToLowerInvariant()
        if (-not $baseNameCounts.ContainsKey($baseName)) { $baseNameCounts[$baseName] = 0 }
        $baseNameCounts[$baseName]++
        if ([System.IO.Path]::GetExtension($relative).ToLowerInvariant() -in @('.c', '.cc', '.cpp', '.cxx')) {
            $objectName = ([System.IO.Path]::GetFileNameWithoutExtension($relative) + '.obj').ToLowerInvariant()
            if (-not $objectNameCounts.ContainsKey($objectName)) { $objectNameCounts[$objectName] = 0 }
            $objectNameCounts[$objectName]++
        }
    }
    foreach ($line in @($Output -split "`r?`n")) {
        if (-not [regex]::IsMatch($line, $Pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) { continue }
        foreach ($file in $AllowedFiles) {
            $name = [System.IO.Path]::GetFileName($file.RelativePath)
            $objectName = [System.IO.Path]::GetFileNameWithoutExtension($file.RelativePath) + '.obj'
            $objectRelative = ([System.IO.Path]::ChangeExtension($file.RelativePath, '.obj')).Replace('\', '/')
            if ((Test-TeamBobOutputPathToken $line $file.RelativePath) -or (Test-TeamBobOutputPathToken $line $objectRelative)) { return $true }
            if ($baseNameCounts[$name.ToLowerInvariant()] -eq 1 -and (Test-TeamBobOutputPathToken $line $name)) { return $true }
            if ($objectNameCounts[$objectName.ToLowerInvariant()] -eq 1 -and (Test-TeamBobOutputPathToken $line $objectName)) { return $true }
        }
    }
    return $false
}
