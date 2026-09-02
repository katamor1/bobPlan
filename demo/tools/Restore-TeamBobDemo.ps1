[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)][string]$DemoRoot
)

$ErrorActionPreference = 'Stop'
$script:DemoBanner = 'MSBUILD DEMO ADAPTER ' + [char]0x2014 + ' NOT VC6 QUALIFICATION'
$script:DemoBannerAscii = 'MSBUILD DEMO ADAPTER - NOT VC6 QUALIFICATION'
$script:DemoProfileId = 'demo-msbuild-protocol-v1-not-vc6'
$script:DemoMarkerName = '.team-bob-demo-marker.json'

function Assert-DemoRestoreBootstrapRoot {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.StartsWith('\\') -or $Path.StartsWith('//') -or
        $Path.IndexOfAny([char[]]@([char]0, [char]13, [char]10)) -ge 0 -or $Path -notmatch '^[A-Za-z]:[\\/]') {
        throw 'DemoRoot must be an absolute non-UNC local-drive path.'
    }
    $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $driveName = $full.Substring(0, 1)
    $psDrive = Get-PSDrive -Name $driveName -PSProvider FileSystem -ErrorAction SilentlyContinue
    if ($null -ne $psDrive) {
        $expectedRoot = $driveName + ':\'
        if (-not [string]::IsNullOrWhiteSpace([string]$psDrive.DisplayRoot) -or
            -not ([string]$psDrive.Root).Equals($expectedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'DemoRoot must not use a mapped drive.'
        }
    }
    $drive = New-Object System.IO.DriveInfo([System.IO.Path]::GetPathRoot($full))
    if (-not $drive.IsReady -or $drive.DriveType -ne [System.IO.DriveType]::Fixed) { throw 'DemoRoot must use a ready fixed local drive.' }
    if (-not (Test-Path -LiteralPath $full -PathType Container)) { throw "DemoRoot must be an existing directory: $full" }
    $root = [System.IO.Path]::GetPathRoot($full)
    $current = $root
    foreach ($component in $full.Substring($root.Length).Split([char[]]@('\', '/'), [System.StringSplitOptions]::RemoveEmptyEntries)) {
        $current = Join-Path $current $component
        if (([System.IO.File]::GetAttributes($current) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw "DemoRoot contains a forbidden reparse/alias component: $current" }
    }
    return $full
}

$bootstrapRoot = Assert-DemoRestoreBootstrapRoot $DemoRoot
$bootstrapMarkerPath = Join-Path $bootstrapRoot $script:DemoMarkerName
if (-not (Test-Path -LiteralPath $bootstrapMarkerPath -PathType Leaf)) { throw "DemoRoot marker is missing: $bootstrapMarkerPath" }
if (([System.IO.File]::GetAttributes($bootstrapMarkerPath) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "DemoRoot marker is a forbidden reparse/alias file: $bootstrapMarkerPath"
}
$bootstrapMarkerBytes = [System.IO.File]::ReadAllBytes($bootstrapMarkerPath)
if (($bootstrapMarkerBytes.Length -ge 3 -and $bootstrapMarkerBytes[0] -eq 0xEF -and $bootstrapMarkerBytes[1] -eq 0xBB -and $bootstrapMarkerBytes[2] -eq 0xBF) -or
    ($bootstrapMarkerBytes.Length -ge 2 -and (($bootstrapMarkerBytes[0] -eq 0xFF -and $bootstrapMarkerBytes[1] -eq 0xFE) -or ($bootstrapMarkerBytes[0] -eq 0xFE -and $bootstrapMarkerBytes[1] -eq 0xFF)))) {
    throw 'DemoRoot marker must be UTF-8 without a byte-order mark.'
}
try {
    $bootstrapMarkerText = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($bootstrapMarkerBytes)
    $bootstrapMarker = $bootstrapMarkerText | ConvertFrom-Json
} catch { throw ('DemoRoot marker cannot be safely parsed before lifecycle helper validation: ' + $_.Exception.Message) }
$bootstrapTopFields = @('schemaVersion','banner','demoProfileId','demoInstanceId','distributionRoot','demoRoot','pcId','userSid','state','createdAt','updatedAt','msBuildPath','msBuildSha256','bazaarPath','bazaarSha256','paths','hashes','approval')
if ($null -eq $bootstrapMarker -or (@($bootstrapMarker.PSObject.Properties.Name | Sort-Object) -join ',') -cne (@($bootstrapTopFields | Sort-Object) -join ',') -or
    $bootstrapMarker.schemaVersion -cne '1.0' -or $bootstrapMarker.banner -cne $script:DemoBanner -or $bootstrapMarker.demoProfileId -cne $script:DemoProfileId -or
    $bootstrapMarker.demoRoot -cne $bootstrapRoot -or $bootstrapMarker.pcId -cne [Environment]::MachineName -or
    $bootstrapMarker.userSid -cne [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value -or
    $null -eq $bootstrapMarker.paths -or $null -eq $bootstrapMarker.hashes -or
    $bootstrapMarker.paths.lifecycleCommon -cne 'tools/TeamBob-BuildCommon.ps1' -or [string]$bootstrapMarker.hashes.lifecycleCommon -notmatch '^[0-9a-f]{64}$') {
    throw 'DemoRoot marker cannot establish the external lifecycle-helper trust boundary.'
}
$commonPath = Join-Path $bootstrapRoot 'tools\TeamBob-BuildCommon.ps1'
if (-not (Test-Path -LiteralPath $commonPath -PathType Leaf)) { throw "External lifecycle support is missing: $commonPath" }
$bootstrapCurrent = [System.IO.Path]::GetPathRoot($commonPath)
foreach ($component in $commonPath.Substring($bootstrapCurrent.Length).Split([char[]]@('\', '/'), [System.StringSplitOptions]::RemoveEmptyEntries)) {
    $bootstrapCurrent = Join-Path $bootstrapCurrent $component
    if (([System.IO.File]::GetAttributes($bootstrapCurrent) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw "External lifecycle helper contains a forbidden reparse/alias component: $bootstrapCurrent" }
}
$commonBytes = [System.IO.File]::ReadAllBytes($commonPath)
$bootstrapSha = [System.Security.Cryptography.SHA256]::Create()
try { $commonHash = ([BitConverter]::ToString($bootstrapSha.ComputeHash($commonBytes))).Replace('-', '').ToLowerInvariant() } finally { $bootstrapSha.Dispose() }
if ($commonHash -cne [string]$bootstrapMarker.hashes.lifecycleCommon) { throw 'External lifecycle helper hash does not match the trusted marker; helper was not executed.' }
try { $commonText = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($commonBytes) }
catch { throw ('External lifecycle helper is not strict UTF-8: ' + $_.Exception.Message) }
$commonScript = [ScriptBlock]::Create($commonText)
. $commonScript

function Get-DemoRestoreHash {
    param([string]$Path)
    return Get-TeamBobFileHash $Path
}

function Get-DemoRestoreJson {
    param([string]$Path, [string]$Label)
    return Read-TeamBobJsonFile $Path $Label 'INTEGRITY_FAILED'
}

function ConvertTo-DemoRestoreJsonBytes {
    param([object]$Value)
    return (New-Object System.Text.UTF8Encoding($false)).GetBytes(($Value | ConvertTo-Json -Depth 40) + "`r`n")
}

function Write-DemoRestoreJsonAtomic {
    param([string]$Path, [object]$Value, [string]$TrustedParentPhysical = '')
    $text = (New-Object System.Text.UTF8Encoding($false)).GetString((ConvertTo-DemoRestoreJsonBytes $Value))
    Write-TeamBobUtf8File $Path $text $TrustedParentPhysical
}

function Write-DemoRestoreBytesCreateNew {
    param([string]$Path, [byte[]]$Bytes)
    $stream = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try { $stream.Write($Bytes, 0, $Bytes.Length); $stream.Flush() } finally { $stream.Dispose() }
}

function Write-DemoRestoreAtomicBytes {
    param([string]$Path, [byte[]]$Bytes, [string]$ExpectedCurrentHash)
    $parent = Split-Path -Parent $Path
    [void](Get-TeamBobPhysicalPath $parent 'Environment registration parent' 'Container' 'INTEGRITY_FAILED')
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf) -or (Get-DemoRestoreHash $Path) -cne $ExpectedCurrentHash) {
        throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Environment registration changed before exact restore; overwrite refused.')
    }
    $temporary = Join-Path $parent ('.team-bob-demo-restore-' + [guid]::NewGuid().ToString('N') + '.tmp')
    $replacementBackup = Join-Path $parent ('.team-bob-demo-restore-' + [guid]::NewGuid().ToString('N') + '.bak')
    try {
        Write-DemoRestoreBytesCreateNew $temporary $Bytes
        [System.IO.File]::Replace($temporary, $Path, $replacementBackup)
    } finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) { [System.IO.File]::Delete($temporary) }
        if (Test-Path -LiteralPath $replacementBackup -PathType Leaf) { [System.IO.File]::Delete($replacementBackup) }
    }
}

function Resolve-DemoRestoreRelativePath {
    param([string]$Root, [string]$RelativePath, [string]$Label, [ValidateSet('File', 'Directory')][string]$Kind)
    $resolved = ConvertTo-TeamBobRelativePath $Root $RelativePath $Label 'INTEGRITY_FAILED'
    if ($Kind -eq 'File') { [void](Get-TeamBobPhysicalPath $resolved.FullPath $Label 'Leaf' 'INTEGRITY_FAILED') }
    else { [void](Get-TeamBobPhysicalPath $resolved.FullPath $Label 'Container' 'INTEGRITY_FAILED') }
    return $resolved.FullPath
}

function Assert-DemoRestoreMarker {
    param([object]$Marker, [string]$Root)
    Assert-TeamBobExactProperties $Marker @(
        'schemaVersion', 'banner', 'demoProfileId', 'demoInstanceId', 'distributionRoot', 'demoRoot', 'pcId', 'userSid', 'state',
        'createdAt', 'updatedAt', 'msBuildPath', 'msBuildSha256', 'bazaarPath', 'bazaarSha256', 'paths', 'hashes', 'approval'
    ) 'Demo root marker' 'INTEGRITY_FAILED'
    Assert-TeamBobExactProperties $Marker.paths @(
        'workspace', 'sandboxes', 'logs', 'evidence', 'tools', 'catalog', 'adapter', 'buildManifest', 'lifecycleCommon', 'initialAllowedFile', 'rawQualification',
        'distributionInventory', 'usageLog', 'negativePacket', 'environmentRegistration', 'environmentBackupMetadata'
    ) 'Demo marker paths' 'INTEGRITY_FAILED'
    Assert-TeamBobExactProperties $Marker.hashes @(
        'catalog', 'adapter', 'buildManifest', 'lifecycleCommon', 'initialAllowedFile', 'rawQualification', 'distributionInventory', 'usageLog', 'negativePacket',
        'environmentBackupMetadata', 'demoEnvironment'
    ) 'Demo marker hashes' 'INTEGRITY_FAILED'
    Assert-TeamBobExactProperties $Marker.approval @('recordId', 'recordedAt', 'approvalRelativePath', 'approvalSha256') 'Demo marker approval' 'INTEGRITY_FAILED'
    if ($Marker.schemaVersion -cne '1.0' -or $Marker.banner -cne $script:DemoBanner -or $Marker.demoProfileId -cne $script:DemoProfileId -or
        [string]$Marker.demoInstanceId -notmatch '^[0-9a-f]{32}$' -or $Marker.demoRoot -cne $Root -or $Marker.pcId -cne [Environment]::MachineName -or
        $Marker.userSid -cne [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value -or
        @('STAGING', 'STAGED', 'APPROVING', 'APPROVED', 'RESTORING', 'RESTORED') -notcontains [string]$Marker.state) {
        throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Demo root marker identity or state is invalid.')
    }
    $expectedPaths = [ordered]@{
        workspace = 'workspace'; sandboxes = 'sandboxes'; logs = 'logs'; evidence = 'evidence'; tools = 'tools'
        catalog = 'workspace/team-bob/config/vc6-build-targets.json'; adapter = 'tools/DemoMsdevAdapter.exe'
        buildManifest = 'tools/DemoMsdevAdapter.build-manifest.json'; lifecycleCommon = 'tools/TeamBob-BuildCommon.ps1'
        initialAllowedFile = 'workspace/demo/CycleWatch/src/CycleWatch.cpp'
        rawQualification = 'evidence/qualification/demo-adapter-qualification.json'
        distributionInventory = 'evidence/distribution-inventory.json'; usageLog = 'evidence/usage-log.csv'
        negativePacket = 'evidence/negative-packets/open-qa-green-work-packet.md'; environmentBackupMetadata = 'evidence/environment-backup/environment-backup.json'
    }
    foreach ($property in $expectedPaths.Keys) {
        if ([string]$Marker.paths.$property -cne [string]$expectedPaths[$property]) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' "Demo marker path '$property' is invalid.") }
    }
}

function Assert-DemoRestoreHash {
    param([string]$Path, [object]$ExpectedHash, [string]$Label)
    if (-not ($ExpectedHash -is [string]) -or [string]$ExpectedHash -notmatch '^[0-9a-f]{64}$' -or
        -not (Test-Path -LiteralPath $Path -PathType Leaf) -or (Get-DemoRestoreHash $Path) -cne [string]$ExpectedHash) {
        throw (New-TeamBobFailure 'INTEGRITY_FAILED' "$Label hash validation failed.")
    }
}

function Assert-DemoRestoreAcl {
    param([string]$Path)
    $acl = Get-Acl -LiteralPath $Path
    if (-not $acl.AreAccessRulesProtected) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' "Backup ACL inheritance is not protected: $Path") }
    $allowed = @([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value, 'S-1-5-18')
    foreach ($rule in @($acl.Access)) {
        $sid = $rule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value
        $hasFullControl = ($rule.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::FullControl) -eq [System.Security.AccessControl.FileSystemRights]::FullControl
        if ($allowed -notcontains $sid -or $rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow -or -not $hasFullControl) {
            throw (New-TeamBobFailure 'INTEGRITY_FAILED' "Backup ACL contains an unsupported identity or rule: $Path")
        }
    }
}

function Get-DemoRestoreEnvironmentPath {
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA) -or $env:LOCALAPPDATA -notmatch '^[A-Za-z]:[\\/]') {
        throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'LOCALAPPDATA is unavailable or unsafe.')
    }
    $localAppData = Get-TeamBobCanonicalPath $env:LOCALAPPDATA 'LOCALAPPDATA' 'INTEGRITY_FAILED'
    [void](Get-TeamBobPhysicalPath $localAppData 'LOCALAPPDATA' 'Container' 'INTEGRITY_FAILED')
    return Join-Path $localAppData 'IBM\BobTeamProfile\vc6-machine-control-poc\environment.json'
}

function Get-DemoRestoreBackupContext {
    param([object]$Marker, [string]$Root)
    $metadataPath = Resolve-DemoRestoreRelativePath $Root $Marker.paths.environmentBackupMetadata 'Environment backup metadata' 'File'
    Assert-DemoRestoreHash $metadataPath $Marker.hashes.environmentBackupMetadata 'Environment backup metadata'
    $metadata = Get-DemoRestoreJson $metadataPath 'Environment backup metadata'
    Assert-TeamBobExactProperties $metadata @(
        'schemaVersion', 'banner', 'demoInstanceId', 'userSid', 'registrationPath', 'originalExisted', 'backupRelativePath',
        'originalSha256', 'originalLength', 'demoEnvironmentSha256', 'createdAt'
    ) 'Environment backup metadata' 'INTEGRITY_FAILED'
    $environmentPath = Get-DemoRestoreEnvironmentPath
    if (Test-Path -LiteralPath $environmentPath -PathType Leaf) {
        [void](Get-TeamBobPhysicalPath $environmentPath 'Current environment registration' 'Leaf' 'INTEGRITY_FAILED')
    } elseif (Test-Path -LiteralPath $environmentPath) {
        throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Current environment registration has an unsupported path type.')
    }
    if ($metadata.schemaVersion -cne '1.0' -or $metadata.banner -cne $script:DemoBanner -or $metadata.demoInstanceId -cne $Marker.demoInstanceId -or
        $metadata.userSid -cne $Marker.userSid -or $metadata.registrationPath -cne $environmentPath -or $Marker.paths.environmentRegistration -cne $environmentPath -or
        $metadata.demoEnvironmentSha256 -cne $Marker.hashes.demoEnvironment -or [string]$metadata.demoEnvironmentSha256 -notmatch '^[0-9a-f]{64}$' -or
        -not ($metadata.originalExisted -is [bool])) {
        throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Environment backup metadata identity is invalid.')
    }
    $backupDirectory = Split-Path -Parent $metadataPath
    Assert-DemoRestoreAcl $backupDirectory
    Assert-DemoRestoreAcl $metadataPath
    $backupPath = $null
    if ($metadata.originalExisted) {
        if ($metadata.backupRelativePath -cne 'evidence/environment-backup/environment.json' -or [string]$metadata.originalSha256 -notmatch '^[0-9a-f]{64}$' -or
            -not ($metadata.originalLength -is [long] -or $metadata.originalLength -is [int])) {
            throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Existing-environment backup metadata is incomplete.')
        }
        $backupPath = Resolve-DemoRestoreRelativePath $Root $metadata.backupRelativePath 'Environment backup' 'File'
        Assert-DemoRestoreHash $backupPath $metadata.originalSha256 'Environment backup'
        if ((Get-Item -LiteralPath $backupPath).Length -ne [int64]$metadata.originalLength) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Environment backup length does not match metadata.') }
        Assert-DemoRestoreAcl $backupPath
    } else {
        if ($null -ne $metadata.backupRelativePath -or $null -ne $metadata.originalSha256 -or [int64]$metadata.originalLength -ne 0) {
            throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Absent-environment backup metadata is invalid.')
        }
    }
    return [pscustomobject]@{ Metadata = $metadata; MetadataPath = $metadataPath; BackupPath = $backupPath; EnvironmentPath = $environmentPath }
}

function Set-DemoRestoreCatalogDisabled {
    param([string]$CatalogPath)
    $catalog = Get-DemoRestoreJson $CatalogPath 'Demo catalog'
    Assert-TeamBobExactProperties $catalog @('profiles') 'Demo catalog' 'INTEGRITY_FAILED'
    if (@($catalog.profiles).Count -ne 1 -or $catalog.profiles[0].id -cne $script:DemoProfileId -or -not ($catalog.profiles[0].enabled -is [bool])) {
        throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Restore found an unexpected demo catalog shape.')
    }
    $catalog.profiles[0].enabled = $false
    Write-DemoRestoreJsonAtomic $CatalogPath $catalog
}

function Write-DemoRestoreJournal {
    param([string]$Path, [string]$InstanceId, [string]$State, [string]$Step)
    $journal = [ordered]@{
        schemaVersion = '1.0'; banner = $script:DemoBanner; demoInstanceId = $InstanceId; state = $State; step = $Step
        updatedAt = [DateTimeOffset]::UtcNow.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
    }
    Write-DemoRestoreJsonAtomic $Path $journal
}

try {
    Write-Output $script:DemoBannerAscii
    $root = Get-TeamBobCanonicalPath $bootstrapRoot 'DemoRoot' 'INTEGRITY_FAILED'
    Assert-TeamBobNotVolumeRoot $root 'DemoRoot' 'INTEGRITY_FAILED'
    $rootPhysical = Get-TeamBobPhysicalPath $root 'DemoRoot' 'Container' 'INTEGRITY_FAILED'
    $markerPath = Join-Path $root $script:DemoMarkerName
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'DemoRoot marker is missing.') }
    $marker = Get-DemoRestoreJson $markerPath 'Demo root marker'
    Assert-DemoRestoreMarker $marker $root
    $backup = Get-DemoRestoreBackupContext $marker $root
    $catalogPath = Resolve-DemoRestoreRelativePath $root $marker.paths.catalog 'Demo catalog' 'File'
    $catalog = Get-DemoRestoreJson $catalogPath 'Demo catalog'
    if (@($catalog.profiles).Count -ne 1 -or $catalog.profiles[0].id -cne $script:DemoProfileId) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Demo catalog identity is invalid.') }

    if ($marker.state -ceq 'RESTORED') {
        if ($catalog.profiles[0].enabled -ne $false) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'RESTORED marker has an enabled demo catalog.') }
        if ($backup.Metadata.originalExisted) {
            Assert-DemoRestoreHash $backup.EnvironmentPath $backup.Metadata.originalSha256 'Restored environment registration'
        } elseif (Test-Path -LiteralPath $backup.EnvironmentPath) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'RESTORED marker unexpectedly has an environment registration.') }
        Write-Output "$script:DemoBannerAscii`r`nIDENTICAL RESTORED $root"
        exit 0
    }
    if (@('STAGING', 'STAGED', 'APPROVING', 'APPROVED', 'RESTORING') -notcontains [string]$marker.state) {
        throw (New-TeamBobFailure 'INTEGRITY_FAILED' "Restore cannot process marker state $($marker.state).")
    }
    if (-not $PSCmdlet.ShouldProcess($root, 'Disable the demo catalog and restore the exact prior local environment registration')) {
        Write-Output "$script:DemoBannerAscii`r`nWHATIF RESTORE $root"
        exit 0
    }

    $journalPath = Join-Path $root 'evidence\lifecycle\restore-journal.json'
    $marker.state = 'RESTORING'
    $marker.updatedAt = [DateTimeOffset]::UtcNow.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
    Write-DemoRestoreJsonAtomic $markerPath $marker $rootPhysical
    Write-DemoRestoreJournal $journalPath $marker.demoInstanceId 'RESTORING' 'restore-started'

    Set-DemoRestoreCatalogDisabled $catalogPath
    $marker.hashes.catalog = Get-DemoRestoreHash $catalogPath
    Write-DemoRestoreJsonAtomic $markerPath $marker $rootPhysical
    Write-DemoRestoreJournal $journalPath $marker.demoInstanceId 'RESTORING' 'demo-profile-disabled'

    $currentExists = Test-Path -LiteralPath $backup.EnvironmentPath -PathType Leaf
    $currentHash = if ($currentExists) { Get-DemoRestoreHash $backup.EnvironmentPath } else { $null }
    if ($backup.Metadata.originalExisted) {
        if ($currentExists -and $currentHash -ceq [string]$backup.Metadata.originalSha256) {
            # The original bytes are already present, as can happen after an interrupted Stage rollback.
        } elseif ($currentExists -and $currentHash -ceq [string]$backup.Metadata.demoEnvironmentSha256) {
            $bytes = [System.IO.File]::ReadAllBytes($backup.BackupPath)
            Write-DemoRestoreAtomicBytes $backup.EnvironmentPath $bytes ([string]$backup.Metadata.demoEnvironmentSha256)
        } else {
            throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Environment registration is neither the expected demo registration nor the exact original bytes; overwrite refused.')
        }
        Assert-DemoRestoreHash $backup.EnvironmentPath $backup.Metadata.originalSha256 'Restored environment registration'
    } else {
        if (-not $currentExists) {
            # The original state was already absent.
        } elseif ($currentHash -ceq [string]$backup.Metadata.demoEnvironmentSha256) {
            [System.IO.File]::Delete($backup.EnvironmentPath)
        } else {
            throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Unexpected environment registration cannot be deleted during restore.')
        }
        if (Test-Path -LiteralPath $backup.EnvironmentPath) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Environment registration removal did not complete.') }
    }
    Write-DemoRestoreJournal $journalPath $marker.demoInstanceId 'RESTORING' 'environment-restored'

    $marker.state = 'RESTORED'
    $marker.updatedAt = [DateTimeOffset]::UtcNow.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
    Write-DemoRestoreJsonAtomic $markerPath $marker $rootPhysical
    Write-DemoRestoreJournal $journalPath $marker.demoInstanceId 'RESTORED' 'restore-complete-data-retained'
    Write-Output "$script:DemoBannerAscii`r`nRESTORED_ENVIRONMENT $($backup.EnvironmentPath)`r`nDEMO_DATA_RETAINED $root"
    exit 0
} catch {
    Write-Error ($script:DemoBannerAscii + ' :: ' + $_.Exception.Message)
    exit 1
}
