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
    public static uint GetDriveType(string rootPath) { return GetDriveTypeW(rootPath); }
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
    foreach ($prefix in @('\??', '\GLOBAL??', '\Device')) {
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

function Assert-TeamBobSupportedLocalDriveType {
    param([uint32]$DriveType, [string]$Label = 'Path', [string]$FailureStatus = 'INTEGRITY_FAILED')
    if ($DriveType -ne 3) { throw (New-TeamBobFailure $FailureStatus "$Label must resolve through a DRIVE_FIXED local drive; unknown, unavailable, removable, optical, RAM, and remote drives are forbidden.") }
}

function Assert-TeamBobLocalPhysicalPath {
    param([string]$Path, [string]$Label = 'Path', [string]$FailureStatus = 'INTEGRITY_FAILED')
    $normalized = $Path.Replace('/', '\')
    if ($normalized -notmatch '^\\Device\\HarddiskVolume[0-9]+(?:\\|$)') {
        throw (New-TeamBobFailure $FailureStatus "$Label must resolve to a supported local hard-disk volume device path.")
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
        $driveType = [TeamBobNativePath]::GetDriveType($volumeRoot)
        Assert-TeamBobSupportedLocalDriveType $driveType $Label $FailureStatus
    } catch {
        if ($null -ne $_.Exception.Data['TeamBobStatus']) { throw }
        throw (New-TeamBobFailure $FailureStatus ("$Label drive locality could not be verified: " + $_.Exception.Message))
    }
    if ($fullPath.Equals($volumeRoot, [System.StringComparison]::OrdinalIgnoreCase)) { return $volumeRoot }
    return $fullPath.TrimEnd('\', '/')
}

function Assert-TeamBobNotVolumeRoot {
    param([string]$Path, [string]$Label = 'Path', [string]$FailureStatus = 'INTEGRITY_FAILED')
    $volumeRoot = [System.IO.Path]::GetPathRoot($Path)
    if ($Path.Equals($volumeRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw (New-TeamBobFailure $FailureStatus "$Label must not be a drive-volume root.")
    }
}

function Get-TeamBobPhysicalPath {
    param(
        [string]$Path, [string]$Label, [ValidateSet('Container', 'Leaf')][string]$PathType = 'Container',
        [string]$FailureStatus = 'INTEGRITY_FAILED'
    )
    $fullPath = Get-TeamBobCanonicalPath $Path $Label $FailureStatus
    if (-not (Test-Path -LiteralPath $fullPath -PathType $PathType)) { throw (New-TeamBobFailure $FailureStatus "$Label must be an existing $($PathType.ToLowerInvariant()) for physical path validation.") }
    $root = [System.IO.Path]::GetPathRoot($fullPath)
    $current = $root
    $remainder = $fullPath.Substring($root.Length)
    foreach ($component in @($remainder -split '[\\/]' | Where-Object { $_.Length -gt 0 })) {
        $current = Join-Path $current $component
        try { $attributes = [System.IO.File]::GetAttributes($current) } catch { throw (New-TeamBobFailure $FailureStatus ("$Label component could not be inspected during physical validation: " + $_.Exception.Message)) }
        if (($attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw (New-TeamBobFailure $FailureStatus "$Label contains a forbidden reparse/alias component: $current") }
    }
    try { $physical = [TeamBobNativePath]::GetFinalDirectoryPath($fullPath) } catch { throw (New-TeamBobFailure $FailureStatus ("$Label physical path resolution failed: " + $_.Exception.Message)) }
    Assert-TeamBobLocalPhysicalPath $physical $Label $FailureStatus
    if ($physical.StartsWith('\\?\UNC\', [System.StringComparison]::OrdinalIgnoreCase)) { $physical = '\\' + $physical.Substring(8) }
    elseif ($physical.StartsWith('\\?\', [System.StringComparison]::OrdinalIgnoreCase)) { $physical = $physical.Substring(4) }
    $physical = $physical.Replace('/', '\')
    if ($physical.Length -gt 1) { $physical = $physical.TrimEnd('\') }
    return $physical
}

function Read-TeamBobUtf8File {
    param([string]$Path, [string]$Label = 'UTF-8 file', [string]$FailureStatus = 'ENVIRONMENT_FAILED')
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw (New-TeamBobFailure $FailureStatus "$Label is missing: $Path") }
    try { $bytes = [System.IO.File]::ReadAllBytes($Path) } catch { throw (New-TeamBobFailure $FailureStatus ("$Label could not be read: " + $_.Exception.Message)) }
    if (($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) -or
        ($bytes.Length -ge 2 -and (($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) -or ($bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF)))) {
        throw (New-TeamBobFailure $FailureStatus "$Label must be UTF-8 without a byte-order mark: $Path")
    }
    $encoding = New-Object System.Text.UTF8Encoding($false, $true)
    try { return $encoding.GetString($bytes) } catch { throw (New-TeamBobFailure $FailureStatus ("$Label is not strict UTF-8: " + $_.Exception.Message)) }
}

function Read-TeamBobJsonFile {
    param([string]$Path, [string]$Label = 'JSON file', [string]$FailureStatus = 'ENVIRONMENT_FAILED')
    $text = Read-TeamBobUtf8File $Path $Label $FailureStatus
    try { return ($text | ConvertFrom-Json) } catch { throw (New-TeamBobFailure $FailureStatus ("$Label is invalid JSON: " + $_.Exception.Message)) }
}

function Get-TeamBobProspectiveDirectory {
    param(
        [string]$Path, [string]$Label = 'Directory', [string]$FailureStatus = 'INTEGRITY_FAILED',
        [switch]$Create, [switch]$RejectVolumeRoot
    )
    $fullPath = Get-TeamBobCanonicalPath $Path $Label $FailureStatus
    if ($RejectVolumeRoot) { Assert-TeamBobNotVolumeRoot $fullPath $Label $FailureStatus }
    if (Test-Path -LiteralPath $fullPath -PathType Leaf) { throw (New-TeamBobFailure $FailureStatus "$Label is an existing file: $fullPath") }

    $nearest = $fullPath
    while (-not (Test-Path -LiteralPath $nearest -PathType Container)) {
        if (Test-Path -LiteralPath $nearest) { throw (New-TeamBobFailure $FailureStatus "$Label has a non-directory ancestor: $nearest") }
        $parent = [System.IO.Path]::GetDirectoryName($nearest.TrimEnd('\', '/'))
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent.Equals($nearest, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw (New-TeamBobFailure $FailureStatus "$Label has no verifiable existing local ancestor.")
        }
        $nearest = $parent
    }
    $nearest = Get-TeamBobCanonicalPath $nearest $Label $FailureStatus
    $nearestPhysical = Get-TeamBobPhysicalPath $nearest "$Label nearest existing ancestor" 'Container' $FailureStatus
    $suffix = $fullPath.Substring($nearest.Length).TrimStart('\', '/')
    $prospectivePhysical = $nearestPhysical
    if (-not [string]::IsNullOrWhiteSpace($suffix)) { $prospectivePhysical = $nearestPhysical.TrimEnd('\') + '\' + $suffix.Replace('/', '\') }

    if ($Create) {
        $current = $nearest
        $currentPhysical = $nearestPhysical
        foreach ($component in @($suffix -split '[\\/]' | Where-Object { $_.Length -gt 0 })) {
            $next = Join-Path $current $component
            if (Test-Path -LiteralPath $next -PathType Leaf) { throw (New-TeamBobFailure $FailureStatus "$Label creation encountered an existing file: $next") }
            if (-not (Test-Path -LiteralPath $next -PathType Container)) {
                [System.IO.Directory]::CreateDirectory($next) | Out-Null
            }
            $nextPhysical = Get-TeamBobPhysicalPath $next $Label 'Container' $FailureStatus
            if (-not (Test-TeamBobResolvedPathAtOrBelow $nextPhysical $currentPhysical) -or $nextPhysical.Equals($currentPhysical, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw (New-TeamBobFailure $FailureStatus "$Label creation escaped or aliased its trusted physical parent.")
            }
            $current = $next
            $currentPhysical = $nextPhysical
        }
        $prospectivePhysical = Get-TeamBobPhysicalPath $fullPath $Label 'Container' $FailureStatus
    }
    return [pscustomobject]@{ FullPath = $fullPath; PhysicalPath = $prospectivePhysical; ExistingAncestor = $nearest; ExistingAncestorPhysical = $nearestPhysical }
}

function Test-TeamBobResolvedPathAtOrBelow {
    param([string]$Candidate, [string]$Root)
    $candidateValue = $Candidate.Replace('/', '\').TrimEnd('\')
    $rootValue = $Root.Replace('/', '\').TrimEnd('\')
    if ($candidateValue.Equals($rootValue, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $candidateValue.StartsWith($rootValue + '\', [System.StringComparison]::OrdinalIgnoreCase)
}

function Assert-TeamBobPhysicalChild {
    param([string]$CandidatePhysical, [string]$ParentPhysical, [string]$Label = 'Path', [string]$FailureStatus = 'INTEGRITY_FAILED')
    if (-not (Test-TeamBobResolvedPathAtOrBelow $CandidatePhysical $ParentPhysical) -or $CandidatePhysical.Equals($ParentPhysical, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw (New-TeamBobFailure $FailureStatus "$Label must remain physically below its trusted parent.")
    }
}

function Assert-TeamBobPhysicalAtOrBelow {
    param([string]$CandidatePhysical, [string]$RootPhysical, [string]$Label = 'Path', [string]$FailureStatus = 'INTEGRITY_FAILED')
    if (-not (Test-TeamBobResolvedPathAtOrBelow $CandidatePhysical $RootPhysical)) {
        throw (New-TeamBobFailure $FailureStatus "$Label must remain physically at or below its trusted root.")
    }
}

function Get-TeamBobPhysicalRelativePath {
    param([string]$CandidatePhysical, [string]$RootPhysical, [string]$Label = 'Path', [string]$FailureStatus = 'INTEGRITY_FAILED')
    Assert-TeamBobPhysicalAtOrBelow $CandidatePhysical $RootPhysical $Label $FailureStatus
    return $CandidatePhysical.Substring($RootPhysical.TrimEnd('\').Length).TrimStart('\').Replace('\', '/')
}

function Assert-TeamBobPhysicalSeparation {
    param([string]$FirstPhysical, [string]$SecondPhysical, [string]$Label = 'Paths', [string]$FailureStatus = 'INTEGRITY_FAILED')
    if ((Test-TeamBobResolvedPathAtOrBelow $FirstPhysical $SecondPhysical) -or (Test-TeamBobResolvedPathAtOrBelow $SecondPhysical $FirstPhysical)) {
        throw (New-TeamBobFailure $FailureStatus "$Label must not be equal, nested, ancestral, or physically aliased.")
    }
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

function ConvertTo-TeamBobNormalizedRelativeText {
    param([object]$Value, [string]$Label, [string]$FailureStatus = 'INTEGRITY_FAILED')
    if (-not ($Value -is [string]) -or [string]::IsNullOrWhiteSpace($Value) -or $Value -match '[\x00-\x1F\x7F]' -or
        (Test-TeamBobNetworkPathForm $Value) -or [System.IO.Path]::IsPathRooted($Value) -or $Value -match '[:*?"<>|]') {
        throw (New-TeamBobFailure $FailureStatus "$Label must be a safe non-empty relative path: $Value")
    }
    $components = @()
    foreach ($component in @($Value -split '[\\/]' | Where-Object { $_.Length -gt 0 })) {
        if ($component -eq '.' -or $component -eq '..') { throw (New-TeamBobFailure $FailureStatus "$Label contains a forbidden dot path component: $Value") }
        if ([string]::IsNullOrWhiteSpace($component) -or $component.Length -gt 255 -or $component.EndsWith('.') -or $component.EndsWith(' ') -or
            $component -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?$') {
            throw (New-TeamBobFailure $FailureStatus "$Label contains a Windows-unsafe or aliasing path component: $Value")
        }
        $components += $component
    }
    if ($components.Count -eq 0) { throw (New-TeamBobFailure $FailureStatus "$Label normalizes to an empty path.") }
    return ($components -join '/')
}

function Test-TeamBobRelativePathAtOrBelow {
    param([string]$Candidate, [string]$Root)
    $candidateValue = $Candidate.Replace('\', '/').Trim('/')
    $rootValue = $Root.Replace('\', '/').Trim('/')
    if ($candidateValue.Equals($rootValue, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $candidateValue.StartsWith($rootValue + '/', [System.StringComparison]::OrdinalIgnoreCase)
}

function ConvertTo-TeamBobForbiddenAreas {
    param(
        [object[]]$Entries, [string]$FailureStatus = 'INTEGRITY_FAILED',
        [string]$Root = '', [string]$RootPhysical = ''
    )
    $normalized = @()
    $seen = @{}
    foreach ($entry in @($Entries)) {
        $value = ConvertTo-TeamBobNormalizedRelativeText $entry 'Forbidden Areas entry' $FailureStatus
        if (-not [string]::IsNullOrWhiteSpace($Root)) {
            $resolved = ConvertTo-TeamBobRelativePath $Root $value 'Forbidden Areas entry' $FailureStatus
            $value = $resolved.RelativePath
            $pathType = $null
            if (Test-Path -LiteralPath $resolved.FullPath -PathType Container) { $pathType = 'Container' }
            elseif (Test-Path -LiteralPath $resolved.FullPath -PathType Leaf) { $pathType = 'Leaf' }
            if ($null -ne $pathType) {
                $physical = Get-TeamBobPhysicalPath $resolved.FullPath 'Forbidden Areas entry' $pathType $FailureStatus
                $value = Get-TeamBobPhysicalRelativePath $physical $RootPhysical 'Forbidden Areas entry' $FailureStatus
            }
        }
        $key = $value.ToLowerInvariant()
        if (-not $seen.ContainsKey($key)) { $seen[$key] = $true; $normalized += $value }
    }
    if ($normalized.Count -eq 0) { throw (New-TeamBobFailure $FailureStatus 'Forbidden Areas must contain at least one safe entry.') }
    return @($normalized)
}

function ConvertTo-TeamBobRelativePath {
    param([string]$Root, [string]$RelativePath, [string]$Label, [string]$FailureStatus = 'INTEGRITY_FAILED')
    $normalizedRelative = ConvertTo-TeamBobNormalizedRelativeText $RelativePath $Label $FailureStatus
    $candidate = Get-TeamBobCanonicalPath (Join-Path $Root ($normalizedRelative.Replace('/', [System.IO.Path]::DirectorySeparatorChar))) $Label $FailureStatus
    if (-not (Test-TeamBobPathAtOrBelow $candidate $Root) -or $candidate.Equals((Get-TeamBobCanonicalPath $Root), [System.StringComparison]::OrdinalIgnoreCase)) {
        throw (New-TeamBobFailure $FailureStatus "$Label resolves outside its root: $RelativePath")
    }
    return [pscustomobject]@{ FullPath = $candidate; RelativePath = (Get-TeamBobRelativePath $Root $candidate) }
}

function Assert-TeamBobExactProperties {
    param([object]$Object, [string[]]$Names, [string]$Label, [string]$FailureStatus = 'ENVIRONMENT_FAILED')
    if ($null -eq $Object -or -not ($Object -is [System.Management.Automation.PSCustomObject])) { throw (New-TeamBobFailure $FailureStatus "$Label must be a JSON object.") }
    $actual = @($Object.PSObject.Properties.Name)
    if ($actual.Count -ne $Names.Count) { throw (New-TeamBobFailure $FailureStatus "$Label has missing or unsupported fields.") }
    foreach ($expectedName in $Names) {
        if (@($actual | Where-Object { [string]::Equals($_, $expectedName, [System.StringComparison]::Ordinal) }).Count -ne 1) {
            throw (New-TeamBobFailure $FailureStatus "$Label has missing or unsupported fields.")
        }
    }
    foreach ($actualName in $actual) {
        if (@($Names | Where-Object { [string]::Equals($_, $actualName, [System.StringComparison]::Ordinal) }).Count -ne 1) {
            throw (New-TeamBobFailure $FailureStatus "$Label has missing or unsupported fields.")
        }
    }
}

function Get-TeamBobJsonMemberScan {
    param([Parameter(Mandatory = $true)][string]$Text)
    $state = [pscustomobject]@{ Index = 0 }
    $rootNames = New-Object 'System.Collections.Generic.List[string]'
    $duplicates = New-Object 'System.Collections.Generic.List[string]'

    function Skip-TeamBobJsonWhitespace {
        while ($state.Index -lt $Text.Length -and [char]::IsWhiteSpace($Text[$state.Index])) { $state.Index++ }
    }
    function Read-TeamBobJsonStringToken {
        if ($state.Index -ge $Text.Length -or $Text[$state.Index] -ne '"') { throw 'JSON string expected.' }
        $start = $state.Index
        $state.Index++
        $escaped = $false
        while ($state.Index -lt $Text.Length) {
            $character = $Text[$state.Index]
            $state.Index++
            if ($escaped) { $escaped = $false; continue }
            if ($character -eq '\') { $escaped = $true; continue }
            if ($character -eq '"') {
                $literal = $Text.Substring($start, $state.Index - $start)
                return ($literal | ConvertFrom-Json)
            }
            if ([int][char]$character -lt 0x20) { throw 'Unescaped control character in JSON string.' }
        }
        throw 'Unterminated JSON string.'
    }
    function Read-TeamBobJsonValue {
        param([int]$Depth)
        Skip-TeamBobJsonWhitespace
        if ($state.Index -ge $Text.Length) { throw 'JSON value expected.' }
        $character = $Text[$state.Index]
        if ($character -eq '{') {
            $state.Index++
            $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
            Skip-TeamBobJsonWhitespace
            if ($state.Index -lt $Text.Length -and $Text[$state.Index] -eq '}') { $state.Index++; return }
            while ($true) {
                Skip-TeamBobJsonWhitespace
                $name = Read-TeamBobJsonStringToken
                if ($Depth -eq 0) { $rootNames.Add([string]$name) }
                if (-not $seen.Add([string]$name)) { $duplicates.Add([string]$name) }
                Skip-TeamBobJsonWhitespace
                if ($state.Index -ge $Text.Length -or $Text[$state.Index] -ne ':') { throw 'JSON object member colon expected.' }
                $state.Index++
                Read-TeamBobJsonValue ($Depth + 1)
                Skip-TeamBobJsonWhitespace
                if ($state.Index -ge $Text.Length) { throw 'Unterminated JSON object.' }
                if ($Text[$state.Index] -eq '}') { $state.Index++; return }
                if ($Text[$state.Index] -ne ',') { throw 'JSON object comma expected.' }
                $state.Index++
            }
        }
        if ($character -eq '[') {
            $state.Index++
            Skip-TeamBobJsonWhitespace
            if ($state.Index -lt $Text.Length -and $Text[$state.Index] -eq ']') { $state.Index++; return }
            while ($true) {
                Read-TeamBobJsonValue ($Depth + 1)
                Skip-TeamBobJsonWhitespace
                if ($state.Index -ge $Text.Length) { throw 'Unterminated JSON array.' }
                if ($Text[$state.Index] -eq ']') { $state.Index++; return }
                if ($Text[$state.Index] -ne ',') { throw 'JSON array comma expected.' }
                $state.Index++
            }
        }
        if ($character -eq '"') { [void](Read-TeamBobJsonStringToken); return }
        $start = $state.Index
        while ($state.Index -lt $Text.Length -and ',]}'.IndexOf($Text[$state.Index]) -lt 0 -and -not [char]::IsWhiteSpace($Text[$state.Index])) { $state.Index++ }
        if ($state.Index -eq $start) { throw 'Invalid JSON scalar.' }
    }

    Read-TeamBobJsonValue 0
    Skip-TeamBobJsonWhitespace
    if ($state.Index -ne $Text.Length) { throw 'Trailing content after JSON value.' }
    return [pscustomobject]@{ RootMemberNames = @($rootNames); DuplicateMemberNames = @($duplicates) }
}

function Test-TeamBobInteger {
    param([object]$Value)
    return $Value -is [sbyte] -or $Value -is [byte] -or $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int32] -or $Value -is [uint32] -or $Value -is [int64] -or $Value -is [uint64]
}

function Assert-TeamBobWorkPacketContract {
    param([object]$Packet)
    $failureStatus = 'PACKET_SCHEMA_INVALID'
    if (-not ($Packet.'Profile Version' -is [string]) -or $Packet.'Profile Version' -cne '0.2.0-poc') { throw (New-TeamBobFailure 'PACKET_VERSION_UNSUPPORTED' 'PACKET_VERSION_UNSUPPORTED: Work packet Profile Version is missing, malformed, or unsupported.') }
    foreach ($field in @(
        'Policy Version', 'Task ID', 'Difficulty', 'Customer', 'Word Baseline', 'QA Baseline', 'Spec Baseline', 'Bazaar Root', 'Bazaar Branch',
        'Bazaar Full Revision ID', 'RT Impact', 'Safety Impact', 'Board Impact', 'Driver Impact', 'ABI Impact', 'Build Impact',
        'Customer Branch Impact', 'Build Profile ID', 'Specification Assignment ID', 'Implementation Assignment ID', 'Independent Reviewer Assignment ID'
    )) {
        $value = $Packet.PSObject.Properties[$field].Value
        if (-not ($value -is [string]) -or [string]::IsNullOrWhiteSpace($value)) { throw (New-TeamBobFailure $failureStatus "Work packet field '$field' must be a non-empty string.") }
    }
    if (-not ($Packet.Risk -is [string]) -or @('Green', 'Amber', 'Red') -notcontains $Packet.Risk) { throw (New-TeamBobFailure $failureStatus 'Work packet Risk must be Green, Amber, or Red.') }
    foreach ($field in @('ReqIDs', 'Allowed Files', 'Forbidden Areas')) {
        $value = $Packet.PSObject.Properties[$field].Value
        if (-not ($value -is [System.Array]) -or $value.Count -lt 1) { throw (New-TeamBobFailure $failureStatus "Work packet field '$field' must be a non-empty array.") }
        foreach ($item in @($value)) { if (-not ($item -is [string]) -or [string]::IsNullOrWhiteSpace($item)) { throw (New-TeamBobFailure $failureStatus "Work packet field '$field' must contain non-empty strings only.") } }
    }
    $openQa = $Packet.'Open QA'
    if (-not ($openQa -is [System.Array])) { throw (New-TeamBobFailure $failureStatus 'Work packet Open QA must be an array.') }
    foreach ($item in @($openQa)) { if (-not ($item -is [string]) -or [string]::IsNullOrWhiteSpace($item)) { throw (New-TeamBobFailure $failureStatus 'Work packet Open QA must contain non-empty strings only.') } }
    foreach ($field in @('RT Impact Clear', 'Safety Impact Clear', 'Board Impact Clear', 'Driver Impact Clear', 'ABI Impact Clear', 'Build Impact Clear', 'Customer Branch Impact Clear', 'Clean Working Copy')) {
        $value = $Packet.PSObject.Properties[$field].Value
        if (-not ($value -is [string]) -or @('YES', 'NO') -notcontains $value) { throw (New-TeamBobFailure $failureStatus "Work packet field '$field' must be the string YES or NO.") }
    }
    if ($Packet.'Policy Version' -cne '0.2.0-poc') { throw (New-TeamBobFailure $failureStatus "Work packet Policy Version must be '0.2.0-poc'.") }
    foreach ($field in @('Policy Bundle SHA256', 'Role Ledger SHA256')) {
        $value = $Packet.PSObject.Properties[$field].Value
        if (-not ($value -is [string]) -or $value -cnotmatch '^[0-9a-f]{64}$') { throw (New-TeamBobFailure $failureStatus "Work packet field '$field' must be a lowercase SHA-256 hash.") }
    }
    $reqIdSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($reqId in @($Packet.ReqIDs)) { if (-not $reqIdSet.Add([string]$reqId)) { throw (New-TeamBobFailure $failureStatus 'Work packet ReqIDs must be ordinally unique.') } }
    foreach ($field in @('Specification Assignment ID', 'Implementation Assignment ID', 'Independent Reviewer Assignment ID')) {
        if ([string]$Packet.PSObject.Properties[$field].Value -cnotmatch '^ASSIGN-[A-Z0-9]+(?:-[A-Z0-9]+)*$') { throw (New-TeamBobFailure $failureStatus "Work packet field '$field' must be an assignment ID.") }
    }
    if (-not (Test-TeamBobInteger $Packet.'Max-Repair-Cycles') -or [int64]$Packet.'Max-Repair-Cycles' -ne 2) { throw (New-TeamBobFailure $failureStatus 'Work packet Max-Repair-Cycles must be the integer constant 2.') }
    if ($Packet.Risk -eq 'Green') {
        if ($openQa.Count -ne 0) { throw (New-TeamBobFailure $failureStatus 'Green work packets must have an empty Open QA array.') }
        foreach ($field in @('RT Impact Clear', 'Safety Impact Clear', 'Board Impact Clear', 'Driver Impact Clear', 'ABI Impact Clear', 'Build Impact Clear', 'Customer Branch Impact Clear', 'Clean Working Copy')) {
            if ($Packet.PSObject.Properties[$field].Value -cne 'YES') { throw (New-TeamBobFailure $failureStatus "Green work packet field '$field' must be YES.") }
        }
    }
}

function Read-TeamBobCanonicalPacket {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' "Work packet does not exist: $Path") }
    $text = Read-TeamBobUtf8File $Path 'Work packet' 'INTEGRITY_FAILED'
    $match = [regex]::Match($text, '(?s)<!-- canonical-work-packet-json:start -->\s*```json\s*(?<json>\{.*?\})\s*```\s*<!-- canonical-work-packet-json:end -->')
    if (-not $match.Success) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Work packet canonical JSON block is missing or malformed.') }
    $json = $match.Groups['json'].Value
    try { $scan = Get-TeamBobJsonMemberScan $json } catch { throw (New-TeamBobFailure 'PACKET_SCHEMA_INVALID' ('Work packet canonical JSON is invalid: ' + $_.Exception.Message)) }
    $versionNames = @($scan.RootMemberNames | Where-Object { [string]::Equals($_, 'Profile Version', [System.StringComparison]::OrdinalIgnoreCase) })
    if ($versionNames.Count -ne 1 -or -not [string]::Equals($versionNames[0], 'Profile Version', [System.StringComparison]::Ordinal) -or @($scan.DuplicateMemberNames | Where-Object { [string]::Equals($_, 'Profile Version', [System.StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) {
        throw (New-TeamBobFailure 'PACKET_VERSION_UNSUPPORTED' 'PACKET_VERSION_UNSUPPORTED: Work packet Profile Version is missing, malformed, duplicated, ambiguous, or unsupported.')
    }
    if ($scan.DuplicateMemberNames.Count -gt 0) { throw (New-TeamBobFailure 'PACKET_SCHEMA_INVALID' 'Work packet JSON contains a duplicate object member.') }
    try { $packet = $json | ConvertFrom-Json } catch { throw (New-TeamBobFailure 'PACKET_SCHEMA_INVALID' ('Work packet canonical JSON is invalid: ' + $_.Exception.Message)) }
    $versionProperty = @($packet.PSObject.Properties | Where-Object { [string]::Equals($_.Name, 'Profile Version', [System.StringComparison]::Ordinal) })
    if ($versionProperty.Count -ne 1 -or -not ($versionProperty[0].Value -is [string]) -or $versionProperty[0].Value -cne '0.2.0-poc') {
        throw (New-TeamBobFailure 'PACKET_VERSION_UNSUPPORTED' 'PACKET_VERSION_UNSUPPORTED: Work packet Profile Version is missing, malformed, or unsupported.')
    }
    $fields = @(
        'Profile Version', 'Policy Version', 'Policy Bundle SHA256', 'Role Ledger SHA256', 'Task ID', 'Difficulty', 'Risk', 'Customer', 'ReqIDs', 'Word Baseline', 'QA Baseline', 'Spec Baseline',
        'Bazaar Root', 'Bazaar Branch', 'Bazaar Full Revision ID', 'Allowed Files', 'Forbidden Areas', 'RT Impact', 'Safety Impact',
        'Board Impact', 'Driver Impact', 'ABI Impact', 'Build Impact', 'Customer Branch Impact', 'RT Impact Clear', 'Safety Impact Clear',
        'Board Impact Clear', 'Driver Impact Clear', 'ABI Impact Clear', 'Build Impact Clear', 'Customer Branch Impact Clear', 'Clean Working Copy',
        'Open QA', 'Build Profile ID', 'Max-Repair-Cycles', 'Specification Assignment ID', 'Implementation Assignment ID',
        'Independent Reviewer Assignment ID'
    )
    Assert-TeamBobExactProperties $packet $fields 'Work packet' 'PACKET_SCHEMA_INVALID'
    Assert-TeamBobWorkPacketContract $packet
    return $packet
}

function Get-TeamBobPacketContext {
    param([object]$Packet, [string]$WorkPacketPath)
    if ($Packet.Risk -cne 'Green') { throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Build and evidence consumers require a Green work packet.') }
    if ([string]$Packet.'Task ID' -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$') { throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Work packet Task ID is unsafe.') }
    if (-not (Test-TeamBobAbsolutePath ([string]$Packet.'Bazaar Root'))) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Bazaar Root must be absolute.') }
    $bazaarRoot = Get-TeamBobCanonicalPath ([string]$Packet.'Bazaar Root') 'Bazaar Root' 'INTEGRITY_FAILED'
    Assert-TeamBobNotVolumeRoot $bazaarRoot 'Bazaar Root' 'INTEGRITY_FAILED'
    if (-not (Test-Path -LiteralPath $bazaarRoot -PathType Container) -or -not (Test-Path -LiteralPath (Join-Path $bazaarRoot '.bzr') -PathType Container)) {
        throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Bazaar Root must be an existing Bazaar working-tree root.')
    }
    $bazaarPhysical = Get-TeamBobPhysicalPath $bazaarRoot 'Bazaar Root' 'Container' 'INTEGRITY_FAILED'
    $bzrPath = Join-Path $bazaarRoot '.bzr'
    $bzrPhysical = Get-TeamBobPhysicalPath $bzrPath 'Bazaar metadata root' 'Container' 'INTEGRITY_FAILED'
    Assert-TeamBobPhysicalChild $bzrPhysical $bazaarPhysical 'Bazaar metadata root' 'INTEGRITY_FAILED'
    $expectedPacket = Get-TeamBobCanonicalPath (Join-Path $bazaarRoot (Join-Path (Join-Path 'team-bob-work' ([string]$Packet.'Task ID')) 'work-packet.md'))
    $workPacketFull = Get-TeamBobCanonicalPath $WorkPacketPath 'Work packet' 'INTEGRITY_FAILED'
    if (-not $expectedPacket.Equals($workPacketFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Work packet path does not match its Bazaar Root and Task ID.')
    }
    $teamBobWorkPath = Join-Path $bazaarRoot 'team-bob-work'
    $taskPath = Join-Path $teamBobWorkPath ([string]$Packet.'Task ID')
    $teamBobWorkPhysical = Get-TeamBobPhysicalPath $teamBobWorkPath 'team-bob-work root' 'Container' 'INTEGRITY_FAILED'
    $taskPhysical = Get-TeamBobPhysicalPath $taskPath 'Task directory' 'Container' 'INTEGRITY_FAILED'
    $packetPhysical = Get-TeamBobPhysicalPath $workPacketFull 'Work packet' 'Leaf' 'INTEGRITY_FAILED'
    Assert-TeamBobPhysicalChild $teamBobWorkPhysical $bazaarPhysical 'team-bob-work root' 'INTEGRITY_FAILED'
    Assert-TeamBobPhysicalChild $taskPhysical $teamBobWorkPhysical 'Task directory' 'INTEGRITY_FAILED'
    Assert-TeamBobPhysicalChild $packetPhysical $taskPhysical 'Work packet' 'INTEGRITY_FAILED'

    $forbiddenAreas = @(ConvertTo-TeamBobForbiddenAreas @($Packet.'Forbidden Areas') 'INTEGRITY_FAILED' $bazaarRoot $bazaarPhysical)
    $supported = @('.c', '.cc', '.cpp', '.cxx', '.h', '.hh', '.hpp', '.hxx', '.inl')
    $allowed = @()
    $seen = @{}
    foreach ($entry in @($Packet.'Allowed Files')) {
        $resolved = ConvertTo-TeamBobRelativePath $bazaarRoot $entry 'Allowed File' 'INTEGRITY_FAILED'
        if (-not ($supported -contains [System.IO.Path]::GetExtension($resolved.FullPath).ToLowerInvariant())) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' "Allowed File extension is unsupported: $entry") }
        if (-not (Test-Path -LiteralPath $resolved.FullPath -PathType Leaf)) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' "Allowed File is missing: $entry") }
        $allowedPhysical = Get-TeamBobPhysicalPath $resolved.FullPath "Allowed File '$entry'" 'Leaf' 'INTEGRITY_FAILED'
        $allowedPhysicalRelative = Get-TeamBobPhysicalRelativePath $allowedPhysical $bazaarPhysical "Allowed File '$entry'" 'INTEGRITY_FAILED'
        $key = $allowedPhysicalRelative.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' "Allowed File is duplicated: $entry") }
        $seen[$key] = $true
        foreach ($forbiddenNormalized in $forbiddenAreas) {
            if ((Test-TeamBobRelativePathAtOrBelow $resolved.RelativePath $forbiddenNormalized) -or
                (Test-TeamBobRelativePathAtOrBelow $allowedPhysicalRelative $forbiddenNormalized)) {
                throw (New-TeamBobFailure 'INTEGRITY_FAILED' "Allowed File is inside a forbidden area: $entry")
            }
        }
        $resolved.RelativePath = $allowedPhysicalRelative
        $resolved | Add-Member -NotePropertyName PhysicalPath -NotePropertyValue $allowedPhysical
        $allowed += $resolved
    }
    if ($allowed.Count -eq 0) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'At least one Allowed File is required.') }
    return [pscustomobject]@{
        TaskId = [string]$Packet.'Task ID'; BazaarRoot = $bazaarRoot; BazaarPhysical = $bazaarPhysical; BzrPath = $bzrPath; BzrPhysical = $bzrPhysical
        TeamBobWorkPath = $teamBobWorkPath; TeamBobWorkPhysical = $teamBobWorkPhysical; TaskPath = $taskPath; TaskPhysical = $taskPhysical
        WorkPacketPath = $workPacketFull; WorkPacketPhysical = $packetPhysical; AllowedFiles = @($allowed); ForbiddenAreas = @($forbiddenAreas)
        BuildProfileId = [string]$Packet.'Build Profile ID'; BazaarBranch = [string]$Packet.'Bazaar Branch'; BazaarRevision = [string]$Packet.'Bazaar Full Revision ID'
    }
}

function Get-TeamBobTaskResultsContext {
    param([object]$Context, [switch]$Create)
    $resultsPath = Join-Path $Context.TaskPath 'results'
    if (Test-Path -LiteralPath $resultsPath -PathType Leaf) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Task results path is an existing file.') }
    $resultsInfo = Get-TeamBobProspectiveDirectory $resultsPath 'Task results directory' 'INTEGRITY_FAILED' -RejectVolumeRoot -Create:$Create
    Assert-TeamBobPhysicalChild $resultsInfo.PhysicalPath $Context.TaskPhysical 'Task results directory' 'INTEGRITY_FAILED'
    return $resultsInfo
}

function Get-TeamBobTrustedChildDirectory {
    param(
        [string]$ParentPath, [string]$ParentPhysical, [string]$ChildName, [string]$Label,
        [string]$FailureStatus = 'INTEGRITY_FAILED', [switch]$Create, [switch]$RequireMissing
    )
    $normalizedName = ConvertTo-TeamBobNormalizedRelativeText $ChildName $Label $FailureStatus
    if ($normalizedName.Contains('/')) { throw (New-TeamBobFailure $FailureStatus "$Label must be one direct child directory name.") }
    $childPath = Join-Path $ParentPath $normalizedName
    if ($RequireMissing -and (Test-Path -LiteralPath $childPath)) { throw (New-TeamBobFailure $FailureStatus "$Label already exists and cannot be reused: $childPath") }
    $info = Get-TeamBobProspectiveDirectory $childPath $Label $FailureStatus -RejectVolumeRoot -Create:$Create
    Assert-TeamBobPhysicalChild $info.PhysicalPath $ParentPhysical $Label $FailureStatus
    return $info
}

function Get-TeamBobFileHash {
    param([string]$Path)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try { $stream = [System.IO.File]::OpenRead($Path); try { return ([BitConverter]::ToString($sha256.ComputeHash($stream)).Replace('-', '').ToLowerInvariant()) } finally { $stream.Dispose() } } finally { $sha256.Dispose() }
}

function Write-TeamBobUtf8File {
    param([string]$Path, [string]$Text, [string]$TrustedParentPhysical)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' "UTF-8 output parent is missing: $parent") }
    $parentPhysical = Get-TeamBobPhysicalPath $parent 'UTF-8 output parent' 'Container' 'INTEGRITY_FAILED'
    if (-not [string]::IsNullOrWhiteSpace($TrustedParentPhysical)) { Assert-TeamBobPhysicalAtOrBelow $parentPhysical $TrustedParentPhysical 'UTF-8 output parent' 'INTEGRITY_FAILED' }
    if (Test-Path -LiteralPath $Path -PathType Container) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' "UTF-8 output path is an existing directory: $Path") }
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $existingPhysical = Get-TeamBobPhysicalPath $Path 'Existing UTF-8 output file' 'Leaf' 'INTEGRITY_FAILED'
        Assert-TeamBobPhysicalChild $existingPhysical $parentPhysical 'Existing UTF-8 output file' 'INTEGRITY_FAILED'
    }
    $temporaryPath = Join-Path $parent ('.team-bob.' + [guid]::NewGuid().ToString('N') + '.tmp')
    $backupPath = Join-Path $parent ('.team-bob.' + [guid]::NewGuid().ToString('N') + '.bak')
    try {
        $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($Text)
        $stream = New-Object System.IO.FileStream($temporaryPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush() } finally { $stream.Dispose() }
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
    param(
        [string]$ManifestPath, [string]$WorkSchemaPath, [string]$BuildSchemaPath, [switch]$BazaarOnly,
        [string]$RootFailureStatus = 'ENVIRONMENT_FAILED'
    )
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA) -or -not (Test-TeamBobAbsolutePath $env:LOCALAPPDATA)) { throw (New-TeamBobFailure 'ENVIRONMENT_FAILED' 'LOCALAPPDATA must be an absolute path.') }
    $localAppData = Get-TeamBobCanonicalPath $env:LOCALAPPDATA 'LOCALAPPDATA' 'ENVIRONMENT_FAILED'
    $path = Join-Path $localAppData 'IBM/BobTeamProfile/vc6-machine-control-poc/v0.2.0-poc/environment.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw (New-TeamBobFailure 'ENVIRONMENT_FAILED' "Local environment registration is missing: $path") }
    [void](Get-TeamBobPhysicalPath $path 'Local environment registration' 'Leaf' 'ENVIRONMENT_FAILED')
    $environment = Read-TeamBobJsonFile $path 'Local environment registration' 'ENVIRONMENT_FAILED'
    $fields = @('schemaVersion', 'profileId', 'profileVersion', 'workPacketSchemaId', 'buildTargetSchemaId', 'pcId', 'msdevPath', 'msdevSha256', 'bazaarPath', 'bazaarSha256', 'sandboxRoot', 'logRoot')
    Assert-TeamBobExactProperties $environment $fields 'Local environment registration' 'ENVIRONMENT_FAILED'
    $manifest = Read-TeamBobJsonFile $ManifestPath 'Profile manifest' 'ENVIRONMENT_FAILED'
    $workSchema = Read-TeamBobJsonFile $WorkSchemaPath 'Work-packet schema' 'ENVIRONMENT_FAILED'
    $buildSchema = Read-TeamBobJsonFile $BuildSchemaPath 'Build-target schema' 'ENVIRONMENT_FAILED'
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
    [void](Get-TeamBobPhysicalPath $environment.bazaarPath 'Registered Bazaar tool' 'Leaf' 'ENVIRONMENT_FAILED')
    if ((Get-TeamBobFileHash $environment.bazaarPath) -ne ([string]$environment.bazaarSha256).ToLowerInvariant()) { throw (New-TeamBobFailure 'ENVIRONMENT_FAILED' 'Registered Bazaar hash does not match.') }
    foreach ($field in @('sandboxRoot', 'logRoot')) {
        if (-not (Test-Path -LiteralPath $environment.$field -PathType Container)) { throw (New-TeamBobFailure 'ENVIRONMENT_FAILED' "Registered root is missing or not a directory: $($environment.$field)") }
        [void](Get-TeamBobPhysicalPath $environment.$field "Registered $field" 'Container' $RootFailureStatus)
    }
    if (-not $BazaarOnly) {
        if (-not (Test-Path -LiteralPath $environment.msdevPath -PathType Leaf)) { throw (New-TeamBobFailure 'ENVIRONMENT_FAILED' "Registered MSDEV tool is missing: $($environment.msdevPath)") }
        [void](Get-TeamBobPhysicalPath $environment.msdevPath 'Registered MSDEV tool' 'Leaf' 'ENVIRONMENT_FAILED')
        if ((Get-TeamBobFileHash $environment.msdevPath) -ne ([string]$environment.msdevSha256).ToLowerInvariant()) { throw (New-TeamBobFailure 'ENVIRONMENT_FAILED' 'Registered MSDEV hash does not match.') }
    }
    return $environment
}

function Get-TeamBobBuildProfile {
    param([string]$CatalogPath, [string]$ProfileId, [string]$PcId)
    $catalog = Read-TeamBobJsonFile $CatalogPath 'Build target catalog' 'ENVIRONMENT_FAILED'
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
    param([string]$Root, [string[]]$ExcludedTopNames = @(), [string[]]$ForbiddenAreas = @())
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
            $insideForbidden = $false
            foreach ($forbidden in $ForbiddenAreas) { if (Test-TeamBobRelativePathAtOrBelow $relative $forbidden) { $insideForbidden = $true; break } }
            if ($insideForbidden) { continue }
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
        SourceInventory = @(Get-TeamBobInventory $Context.BazaarRoot @('.bzr', 'team-bob-work') $Context.ForbiddenAreas)
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
    param([string]$RelativePath, [string[]]$Patterns, [string[]]$ExpectedArtifacts, [string[]]$ForbiddenAreas)
    $normalized = $RelativePath.Replace('\', '/')
    $top = ($normalized -split '/')[0]
    if ($top -ieq '.bzr' -or $top -ieq 'team-bob-work') { return $true }
    foreach ($forbidden in $ForbiddenAreas) { if (Test-TeamBobRelativePathAtOrBelow $normalized $forbidden) { return $true } }
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
    param([string]$SourceRoot, [string]$DestinationRoot, [string[]]$Patterns, [string[]]$ExpectedArtifacts, [string[]]$ForbiddenAreas)
    if (-not (Test-Path -LiteralPath $DestinationRoot -PathType Container)) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' "Sandbox destination must be a newly validated directory: $DestinationRoot") }
    [void](Get-TeamBobPhysicalPath $DestinationRoot 'Sandbox destination' 'Container' 'INTEGRITY_FAILED')
    if (@(Get-ChildItem -LiteralPath $DestinationRoot -Force).Count -ne 0) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' "Sandbox destination must be empty and never reused: $DestinationRoot") }
    $sourceFull = Get-TeamBobCanonicalPath $SourceRoot
    $pending = New-Object System.Collections.ArrayList
    [void]$pending.Add($sourceFull)
    while ($pending.Count -gt 0) {
        $directory = [string]$pending[0]
        $pending.RemoveAt(0)
        foreach ($item in @(Get-ChildItem -LiteralPath $directory -Force | Sort-Object Name)) {
            $relative = Get-TeamBobRelativePath $sourceFull $item.FullName
            if (Test-TeamBobCopyExclusion $relative $Patterns $ExpectedArtifacts $ForbiddenAreas) { continue }
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
