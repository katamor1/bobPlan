[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$TargetPath,

    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'
$distributionRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $distributionRoot 'profile/team-bob/tools/TeamBob-BuildCommon.ps1')

try {
    $sourcePath = Join-Path $distributionRoot 'profile'
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Container)) { throw "Profile source directory does not exist: $sourcePath" }
    if (-not (Test-TeamBobAbsolutePath $TargetPath)) { throw 'TargetPath must be an absolute local drive directory path.' }

    $distributionFull = Get-TeamBobCanonicalPath $distributionRoot 'Distribution repository root' 'INTEGRITY_FAILED'
    $distributionPhysical = Get-TeamBobPhysicalPath $distributionFull 'Distribution repository root' 'Container' 'INTEGRITY_FAILED'
    $sourcePath = Get-TeamBobCanonicalPath $sourcePath 'Profile source directory' 'INTEGRITY_FAILED'
    $sourcePhysical = Get-TeamBobPhysicalPath $sourcePath 'Profile source directory' 'Container' 'INTEGRITY_FAILED'
    Assert-TeamBobPhysicalChild $sourcePhysical $distributionPhysical 'Profile source directory' 'INTEGRITY_FAILED'
    $targetInfo = Get-TeamBobProspectiveDirectory $TargetPath 'TargetPath' 'INTEGRITY_FAILED' -RejectVolumeRoot
    $targetFullPath = $targetInfo.FullPath
    Assert-TeamBobPhysicalSeparation $targetInfo.PhysicalPath $distributionPhysical 'TargetPath and protected distribution source' 'INTEGRITY_FAILED'

    # A genuine v0.1 profile is never upgraded in place.  Inspect only the
    # canonical marker leaf, after the physical target boundary is trusted and
    # before source enumeration, planning output, directory creation, or writes.
    $legacyMarkerPath = Join-Path $targetFullPath 'team-bob\profile-manifest.json'
    if (Test-Path -LiteralPath $legacyMarkerPath -PathType Leaf) {
        $isClosedLegacyMarker = $false
        try {
            $legacyMarkerPhysical = Get-TeamBobPhysicalPath $legacyMarkerPath 'Existing profile marker' 'Leaf' 'INTEGRITY_FAILED'
            Assert-TeamBobPhysicalChild $legacyMarkerPhysical $targetInfo.PhysicalPath 'Existing profile marker' 'INTEGRITY_FAILED'
            $legacyMarkerText = Read-TeamBobUtf8File $legacyMarkerPath 'Existing profile marker' 'INTEGRITY_FAILED'
            $legacyMarkerScan = Get-TeamBobJsonMemberScan $legacyMarkerText
            $legacyMarker = $legacyMarkerText | ConvertFrom-Json
            Assert-TeamBobExactProperties $legacyMarker @('version','profile','compatibility','contracts') 'Existing v0.1 profile marker' 'INTEGRITY_FAILED'
            Assert-TeamBobExactProperties $legacyMarker.profile @('id','name') 'Existing v0.1 profile marker profile' 'INTEGRITY_FAILED'
            Assert-TeamBobExactProperties $legacyMarker.compatibility @('operatingSystem','ide','toolchain','vcs') 'Existing v0.1 profile marker compatibility' 'INTEGRITY_FAILED'
            Assert-TeamBobExactProperties $legacyMarker.contracts @('workPacketSchema','buildTargetSchema','buildTargets','modes','rules') 'Existing v0.1 profile marker contracts' 'INTEGRITY_FAILED'
            $isClosedLegacyMarker = $legacyMarkerScan.DuplicateMemberNames.Count -eq 0 -and
                $legacyMarker.version -ceq '0.1.0-poc' -and $legacyMarker.profile.id -ceq 'team-bob-vc6-bazaar' -and
                $legacyMarker.profile.name -ceq 'Team Bob VC6 Bazaar Profile' -and
                $legacyMarker.compatibility.operatingSystem -ceq 'Windows' -and $legacyMarker.compatibility.ide -ceq 'IBM Bob IDE 2.1.x' -and
                $legacyMarker.compatibility.toolchain -ceq 'Visual C++ 6.0' -and $legacyMarker.compatibility.vcs -ceq 'Bazaar' -and
                $legacyMarker.contracts.workPacketSchema -ceq 'config/work-packet.schema.json' -and
                $legacyMarker.contracts.buildTargetSchema -ceq 'config/vc6-build-targets.schema.json' -and
                $legacyMarker.contracts.buildTargets -ceq 'config/vc6-build-targets.json' -and
                $legacyMarker.contracts.modes -ceq '../.bob/custom_modes.yaml' -and $legacyMarker.contracts.rules -ceq '../.bob/rules/'
        } catch {
            # Malformed, spoofed, partial, and unknown markers deliberately fall
            # through to the normal all-or-nothing conflict preflight.
            $isClosedLegacyMarker = $false
        }
        if ($isClosedLegacyMarker) { throw 'UPGRADE_REQUIRES_FRESH_TARGET: v0.1.0-poc must be installed into a fresh target.' }
    }

    $directories = @()
    $files = @()
    $pendingSourceDirectories = New-Object System.Collections.ArrayList
    [void]$pendingSourceDirectories.Add($sourcePath)
    while ($pendingSourceDirectories.Count -gt 0) {
        $sourceDirectory = [string]$pendingSourceDirectories[0]
        $pendingSourceDirectories.RemoveAt(0)
        foreach ($sourceItem in @(Get-ChildItem -LiteralPath $sourceDirectory -Force | Sort-Object FullName)) {
            if (($sourceItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Profile source contains a forbidden reparse/alias component: $($sourceItem.FullName)" }
            if ($sourceItem.PSIsContainer) { $directories += $sourceItem; [void]$pendingSourceDirectories.Add($sourceItem.FullName) } else { $files += $sourceItem }
        }
    }
    $directories = @($directories | Sort-Object FullName)
    $files = @($files | Sort-Object FullName)
    $plans = New-Object System.Collections.Generic.List[object]
    $hasConflict = $false

    $rootAction = if (Test-Path -LiteralPath $targetFullPath -PathType Container) { 'IDENTICAL' } else { 'CREATE' }
    $plans.Add([pscustomobject]@{ Action = $rootAction; Kind = 'directory'; Path = $targetFullPath })

    foreach ($directory in $directories) {
        $sourceDirectoryPhysical = Get-TeamBobPhysicalPath $directory.FullName 'Profile source directory component' 'Container' 'INTEGRITY_FAILED'
        Assert-TeamBobPhysicalChild $sourceDirectoryPhysical $sourcePhysical 'Profile source directory component' 'INTEGRITY_FAILED'
        $relative = $directory.FullName.Substring($sourcePath.Length).TrimStart('\', '/')
        $destination = Join-Path $targetFullPath $relative
        if (Test-Path -LiteralPath $destination -PathType Leaf) {
            $plans.Add([pscustomobject]@{ Action = 'CONFLICT'; Kind = 'directory'; Path = $destination })
            $hasConflict = $true
        } elseif (Test-Path -LiteralPath $destination -PathType Container) {
            $destinationPhysical = Get-TeamBobPhysicalPath $destination 'Existing destination directory' 'Container' 'INTEGRITY_FAILED'
            Assert-TeamBobPhysicalChild $destinationPhysical $targetInfo.PhysicalPath 'Existing destination directory' 'INTEGRITY_FAILED'
            $plans.Add([pscustomobject]@{ Action = 'IDENTICAL'; Kind = 'directory'; Path = $destination })
        } else {
            $plans.Add([pscustomobject]@{ Action = 'CREATE'; Kind = 'directory'; Path = $destination })
        }
    }

    foreach ($file in $files) {
        $sourceFilePhysical = Get-TeamBobPhysicalPath $file.FullName 'Profile source file' 'Leaf' 'INTEGRITY_FAILED'
        Assert-TeamBobPhysicalChild $sourceFilePhysical $sourcePhysical 'Profile source file' 'INTEGRITY_FAILED'
        $relative = $file.FullName.Substring($sourcePath.Length).TrimStart('\', '/')
        $destination = Join-Path $targetFullPath $relative
        if (Test-Path -LiteralPath $destination -PathType Container) {
            $plans.Add([pscustomobject]@{ Action = 'CONFLICT'; Kind = 'file'; Path = $destination; Source = $file.FullName })
            $hasConflict = $true
        } elseif (Test-Path -LiteralPath $destination -PathType Leaf) {
            $destinationPhysical = Get-TeamBobPhysicalPath $destination 'Existing destination file' 'Leaf' 'INTEGRITY_FAILED'
            Assert-TeamBobPhysicalChild $destinationPhysical $targetInfo.PhysicalPath 'Existing destination file' 'INTEGRITY_FAILED'
            $sourceHash = Get-TeamBobFileHash $file.FullName
            $destinationHash = Get-TeamBobFileHash $destination
            if ($sourceHash -eq $destinationHash) {
                $plans.Add([pscustomobject]@{ Action = 'IDENTICAL'; Kind = 'file'; Path = $destination; Source = $file.FullName })
            } else {
                $plans.Add([pscustomobject]@{ Action = 'CONFLICT'; Kind = 'file'; Path = $destination; Source = $file.FullName })
                $hasConflict = $true
            }
        } else {
            $plans.Add([pscustomobject]@{ Action = 'CREATE'; Kind = 'file'; Path = $destination; Source = $file.FullName })
        }
    }

    foreach ($plan in $plans) { Write-Output ("{0} {1} {2}" -f $plan.Action, $plan.Kind, $plan.Path) }
    if ($hasConflict) { throw 'Installation preflight found one or more conflicts; no files were written.' }
    if ($WhatIf) { exit 0 }

    $createdTarget = Get-TeamBobProspectiveDirectory $targetFullPath 'TargetPath' 'INTEGRITY_FAILED' -RejectVolumeRoot -Create
    Assert-TeamBobPhysicalSeparation $createdTarget.PhysicalPath $distributionPhysical 'TargetPath and protected distribution source' 'INTEGRITY_FAILED'
    foreach ($plan in @($plans | Where-Object { $_.Action -eq 'CREATE' -and $_.Kind -eq 'directory' })) {
        $createdDirectory = Get-TeamBobProspectiveDirectory $plan.Path 'Destination directory' 'INTEGRITY_FAILED' -RejectVolumeRoot -Create
        if (-not $createdDirectory.FullPath.Equals($createdTarget.FullPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            Assert-TeamBobPhysicalChild $createdDirectory.PhysicalPath $createdTarget.PhysicalPath 'Destination directory' 'INTEGRITY_FAILED'
        }
    }
    foreach ($plan in @($plans | Where-Object { $_.Action -eq 'CREATE' -and $_.Kind -eq 'file' })) {
        $parent = Split-Path -Parent $plan.Path
        $parentPhysical = Get-TeamBobPhysicalPath $parent 'Destination file parent' 'Container' 'INTEGRITY_FAILED'
        Assert-TeamBobPhysicalAtOrBelow $parentPhysical $createdTarget.PhysicalPath 'Destination file parent' 'INTEGRITY_FAILED'
        if (Test-Path -LiteralPath $plan.Path) { throw "Destination appeared after preflight; create-only publication refused to overwrite it: $($plan.Path)" }
        [void](Get-TeamBobPhysicalPath $plan.Source 'Profile source file' 'Leaf' 'INTEGRITY_FAILED')
        $sourceStream = [System.IO.File]::Open($plan.Source, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        try {
            $destinationStream = New-Object System.IO.FileStream($plan.Path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            try { $sourceStream.CopyTo($destinationStream); $destinationStream.Flush() } finally { $destinationStream.Dispose() }
        } finally { $sourceStream.Dispose() }
    }
    exit 0
} catch {
    if ($_.Exception.Message -like 'UPGRADE_REQUIRES_FRESH_TARGET:*') {
        [Console]::Error.WriteLine('UPGRADE_REQUIRES_FRESH_TARGET')
        exit 1
    }
    Write-Error $_.Exception.Message
    exit 1
}
