$ErrorActionPreference = 'Stop'

$demoLifecycleStandalone = $null -eq (Get-Command Assert-True -ErrorAction SilentlyContinue)
if ($demoLifecycleStandalone) {
    $script:Assertions = 0
    function Assert-True { param([bool]$Condition, [string]$Message); $script:Assertions++; if (-not $Condition) { throw "ASSERTION FAILED: $Message" } }
    function Assert-Equal { param([object]$Actual, [object]$Expected, [string]$Message); Assert-True ($Actual -eq $Expected) "$Message (expected '$Expected', got '$Actual')" }
}

function Write-DemoLifecycleText {
    param([string]$Path, [string]$Text)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { [void][System.IO.Directory]::CreateDirectory($parent) }
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Write-DemoLifecycleJson {
    param([string]$Path, [object]$Value)
    Write-DemoLifecycleText $Path (($Value | ConvertTo-Json -Depth 30) + "`r`n")
}

function Get-DemoLifecycleHash {
    param([string]$Path)
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Get-DemoLifecycleJson {
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    Assert-True (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) "Lifecycle JSON is UTF-8 without BOM: $Path"
    return ((New-Object System.Text.UTF8Encoding($false, $true)).GetString($bytes) | ConvertFrom-Json)
}

function New-DemoLifecycleSymbolicLink {
    param([string]$Path, [string]$Target)
    if ($PSVersionTable.PSEdition -eq 'Core') {
        New-Item -ItemType SymbolicLink -Path $Path -Target $Target -ErrorAction Stop | Out-Null
    } else {
        $pwsh = Get-Command pwsh.exe -ErrorAction Stop
        $linkWasSet = Test-Path Env:TEAM_BOB_LIFECYCLE_TEST_LINK
        $targetWasSet = Test-Path Env:TEAM_BOB_LIFECYCLE_TEST_TARGET
        $savedLink = $env:TEAM_BOB_LIFECYCLE_TEST_LINK
        $savedTarget = $env:TEAM_BOB_LIFECYCLE_TEST_TARGET
        try {
            $env:TEAM_BOB_LIFECYCLE_TEST_LINK = $Path
            $env:TEAM_BOB_LIFECYCLE_TEST_TARGET = $Target
            & $pwsh.Source -NoLogo -NoProfile -NonInteractive -Command '$ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop; New-Item -ItemType SymbolicLink -Path $env:TEAM_BOB_LIFECYCLE_TEST_LINK -Target $env:TEAM_BOB_LIFECYCLE_TEST_TARGET -ErrorAction Stop | Out-Null'
            if ($LASTEXITCODE -ne 0) { throw "PowerShell 7 symbolic-link fixture helper failed with exit code $LASTEXITCODE." }
        } finally {
            if ($linkWasSet) { $env:TEAM_BOB_LIFECYCLE_TEST_LINK = $savedLink } else { Remove-Item Env:TEAM_BOB_LIFECYCLE_TEST_LINK -ErrorAction SilentlyContinue }
            if ($targetWasSet) { $env:TEAM_BOB_LIFECYCLE_TEST_TARGET = $savedTarget } else { Remove-Item Env:TEAM_BOB_LIFECYCLE_TEST_TARGET -ErrorAction SilentlyContinue }
        }
    }
    if (([System.IO.File]::GetAttributes($Path) -band [System.IO.FileAttributes]::ReparsePoint) -eq 0) {
        throw "Symbolic-link fixture was not created as a reparse point: $Path"
    }
}

function Get-DemoLifecycleFingerprint {
    param([string]$Root)
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return '<missing>' }
    $full = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    return ((Get-ChildItem -LiteralPath $full -Recurse -File -Force | Sort-Object FullName | ForEach-Object {
        $_.FullName.Substring($full.Length).TrimStart('\', '/').Replace('\', '/') + ':' + (Get-DemoLifecycleHash $_.FullName)
    }) -join "`n")
}

function Invoke-DemoLifecycleScript {
    param([string]$Path, [string[]]$Arguments = @())
    $engine = (Get-Process -Id $PID).Path
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $engine -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Path @Arguments 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $saved }
    return [pscustomobject]@{ ExitCode = $exitCode; Output = $output }
}

function Copy-DemoLifecycleTree {
    param([string]$Source, [string]$Destination)
    if (Test-Path -LiteralPath $Destination) { throw "Fixture destination already exists: $Destination" }
    Copy-Item -LiteralPath $Source -Destination $Destination -Recurse
}

function New-DemoLifecycleDistribution {
    param([string]$RepositoryRoot, [string]$Destination)
    [void][System.IO.Directory]::CreateDirectory($Destination)
    Copy-DemoLifecycleTree (Join-Path $RepositoryRoot 'profile') (Join-Path $Destination 'profile')
    [void][System.IO.Directory]::CreateDirectory((Join-Path $Destination 'scripts'))
    Copy-Item -LiteralPath (Join-Path $RepositoryRoot 'scripts\Install-TeamBobProfile.ps1') -Destination (Join-Path $Destination 'scripts\Install-TeamBobProfile.ps1')
    [void][System.IO.Directory]::CreateDirectory((Join-Path $Destination 'demo'))
    Copy-Item -LiteralPath (Join-Path $RepositoryRoot 'demo\README.md') -Destination (Join-Path $Destination 'demo\README.md')
    foreach ($name in @('inputs', 'CycleWatch', 'adapter')) {
        Copy-DemoLifecycleTree (Join-Path $RepositoryRoot "demo\$name") (Join-Path $Destination "demo\$name")
    }
    [void][System.IO.Directory]::CreateDirectory((Join-Path $Destination 'demo\docs'))
    Copy-Item -LiteralPath (Join-Path $RepositoryRoot 'demo\docs\usage-log.csv') -Destination (Join-Path $Destination 'demo\docs\usage-log.csv')
    [void][System.IO.Directory]::CreateDirectory((Join-Path $Destination 'demo\tools'))
    $fixtureTools = Join-Path $RepositoryRoot 'tests\fixtures\demo-lifecycle'
    Copy-Item -LiteralPath (Join-Path $fixtureTools 'Build-DemoMsdevAdapter.ps1') -Destination (Join-Path $Destination 'demo\tools\Build-DemoMsdevAdapter.ps1')
    Copy-Item -LiteralPath (Join-Path $fixtureTools 'Invoke-DemoAdapterQualification.ps1') -Destination (Join-Path $Destination 'demo\tools\Invoke-DemoAdapterQualification.ps1')
    foreach ($name in @('Prepare-TeamBobDemo.ps1', 'Restore-TeamBobDemo.ps1')) {
        $source = Join-Path $RepositoryRoot "demo\tools\$name"
        if (Test-Path -LiteralPath $source -PathType Leaf) { Copy-Item -LiteralPath $source -Destination (Join-Path $Destination "demo\tools\$name") }
    }
    $bzrMetadata = Join-Path $Destination '.bzr'
    [void][System.IO.Directory]::CreateDirectory($bzrMetadata)
    Write-DemoLifecycleText (Join-Path $bzrMetadata 'sentinel') "distribution Bazaar sentinel`r`n"
}

function Get-DemoLifecycleArgs {
    param([string]$Distribution, [string]$DemoRoot, [string]$MsBuild, [string]$Bazaar)
    return @('-DistributionRoot', $Distribution, '-DemoRoot', $DemoRoot, '-MsBuildPath', $MsBuild, '-BazaarPath', $Bazaar)
}

function Assert-DemoLifecycleAcl {
    param([string]$Path)
    $acl = Get-Acl -LiteralPath $Path
    Assert-True $acl.AreAccessRulesProtected "Backup ACL inheritance is disabled: $Path"
    $allowed = @([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value, 'S-1-5-18')
    $actual = @($acl.Access | ForEach-Object { $_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value } | Sort-Object -Unique)
    Assert-Equal ($actual -join ',') (($allowed | Sort-Object -Unique) -join ',') "Backup ACL contains only current SID and SYSTEM: $Path"
    Assert-True (@($acl.Access | Where-Object { $_.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow }).Count -eq 0) "Backup ACL has allow rules only: $Path"
    Assert-True (@($acl.Access | Where-Object { ($_.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::FullControl) -ne [System.Security.AccessControl.FileSystemRights]::FullControl }).Count -eq 0) "Backup ACL grants full control only to its two allowed identities: $Path"
}

function Remove-DemoLifecycleFixtureRoot {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Container)) { return }
    $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $temp = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\', '/')
    $leaf = [System.IO.Path]::GetFileName($full)
    if (-not $full.StartsWith($temp + '\', [System.StringComparison]::OrdinalIgnoreCase) -or $leaf -notmatch '^team-bob-lifecycle-test-[0-9a-f]{32}$') {
        throw "Refusing fixture cleanup outside the verified lifecycle-test root: $full"
    }
    Remove-Item -LiteralPath $full -Recurse -Force
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$preparePath = Join-Path $repositoryRoot 'demo\tools\Prepare-TeamBobDemo.ps1'
$restorePath = Join-Path $repositoryRoot 'demo\tools\Restore-TeamBobDemo.ps1'
Assert-True (Test-Path -LiteralPath $preparePath -PathType Leaf) 'Prepare-TeamBobDemo.ps1 exists'
Assert-True (Test-Path -LiteralPath $restorePath -PathType Leaf) 'Restore-TeamBobDemo.ps1 exists'

$fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('team-bob-lifecycle-test-' + [guid]::NewGuid().ToString('N'))
$savedLocalAppData = $env:LOCALAPPDATA
$savedQualificationMode = $env:TEAM_BOB_DEMO_TEST_QUALIFICATION_MODE
$junctionPath = $null
try {
    [void][System.IO.Directory]::CreateDirectory($fixtureRoot)
    $distribution = Join-Path $fixtureRoot 'distribution'
    New-DemoLifecycleDistribution $repositoryRoot $distribution
    $tools = Join-Path $fixtureRoot 'fake-tools'
    [void][System.IO.Directory]::CreateDirectory($tools)
    $msBuild = Join-Path $tools 'MSBuild.exe'
    $bazaar = Join-Path $tools 'bzr.exe'
    Write-DemoLifecycleText $msBuild "fake MSBuild identity`r`n"
    Write-DemoLifecycleText $bazaar "THIS FILE MUST NEVER BE EXECUTED`r`n"
    $distributionFingerprint = Get-DemoLifecycleFingerprint $distribution
    $productionProfileFingerprint = Get-DemoLifecycleFingerprint (Join-Path $repositoryRoot 'profile')

    $env:LOCALAPPDATA = Join-Path $fixtureRoot 'localappdata-main'
    [void][System.IO.Directory]::CreateDirectory($env:LOCALAPPDATA)
    $stageArgs = Get-DemoLifecycleArgs $distribution (Join-Path $fixtureRoot 'demo-main') $msBuild $bazaar
    $whatIf = Invoke-DemoLifecycleScript $preparePath ($stageArgs + @('-Stage', '-WhatIf'))
    Assert-Equal $whatIf.ExitCode 0 'Stage WhatIf succeeds for a safe new root'
    Assert-True ($whatIf.Output -match 'NOT VC6 QUALIFICATION') 'Stage WhatIf displays the immutable disclaimer'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixtureRoot 'demo-main'))) 'Stage WhatIf creates no demo root'

    $markerless = Join-Path $fixtureRoot 'markerless'
    [void][System.IO.Directory]::CreateDirectory($markerless)
    $markerlessResult = Invoke-DemoLifecycleScript $preparePath ((Get-DemoLifecycleArgs $distribution $markerless $msBuild $bazaar) + @('-Stage'))
    Assert-True ($markerlessResult.ExitCode -ne 0) 'Stage rejects an existing markerless directory'
    Assert-Equal @(Get-ChildItem -LiteralPath $markerless -Force).Count 0 'Markerless rejection does not mutate the directory'

    $uncResult = Invoke-DemoLifecycleScript $preparePath ((Get-DemoLifecycleArgs $distribution '\\invalid-demo-host\share\demo' $msBuild $bazaar) + @('-Stage', '-WhatIf'))
    Assert-True ($uncResult.ExitCode -ne 0) 'Stage rejects a UNC demo root before access'
    Assert-True ($uncResult.Output -match 'UNC|local') 'UNC rejection explains the local-path boundary'

    $overlap = Join-Path $distribution 'unsafe-demo-child'
    $overlapResult = Invoke-DemoLifecycleScript $preparePath ((Get-DemoLifecycleArgs $distribution $overlap $msBuild $bazaar) + @('-Stage', '-WhatIf'))
    Assert-True ($overlapResult.ExitCode -ne 0) 'Stage rejects a demo root below the distribution'
    Assert-True (-not (Test-Path -LiteralPath $overlap)) 'Overlap rejection creates no path'

    $junctionTarget = Join-Path $fixtureRoot 'junction-target'
    [void][System.IO.Directory]::CreateDirectory($junctionTarget)
    $junctionPath = Join-Path $fixtureRoot 'junction-demo'
    New-Item -ItemType Junction -Path $junctionPath -Target $junctionTarget -ErrorAction Stop | Out-Null
    $junctionResult = Invoke-DemoLifecycleScript $preparePath ((Get-DemoLifecycleArgs $distribution $junctionPath $msBuild $bazaar) + @('-Stage', '-WhatIf'))
    Assert-True ($junctionResult.ExitCode -ne 0) 'Stage rejects a reparse demo root'
    Assert-True ($junctionResult.Output -match 'reparse|alias|physical') 'Reparse rejection identifies the unsafe boundary'
    Assert-Equal @(Get-ChildItem -LiteralPath $junctionTarget -Force).Count 0 'Rejected junction target remains unchanged'
    [System.IO.Directory]::Delete($junctionPath)
    $junctionPath = $null

    $mappedTarget = Join-Path $fixtureRoot 'mapped-target'
    [void][System.IO.Directory]::CreateDirectory($mappedTarget)
    $driveName = @('Z','Y','X','W') | Where-Object { $null -eq (Get-PSDrive -Name $_ -ErrorAction SilentlyContinue) } | Select-Object -First 1
    Assert-True (-not [string]::IsNullOrWhiteSpace($driveName)) 'A temporary PSDrive letter is available for mapped-drive rejection'
    $mappedWrapper = Join-Path $fixtureRoot 'invoke-mapped.ps1'
    Write-DemoLifecycleText $mappedWrapper @'
param([string]$Prepare, [string]$Distribution, [string]$MappedTarget, [string]$DriveName, [string]$MsBuild, [string]$Bazaar)
$ErrorActionPreference = 'Stop'
New-PSDrive -Name $DriveName -PSProvider FileSystem -Root $MappedTarget | Out-Null
& $Prepare -DistributionRoot $Distribution -DemoRoot ($DriveName + ':\demo') -MsBuildPath $MsBuild -BazaarPath $Bazaar -Stage -WhatIf
exit $LASTEXITCODE
'@
    $mappedResult = Invoke-DemoLifecycleScript $mappedWrapper @($preparePath, $distribution, $mappedTarget, $driveName, $msBuild, $bazaar)
    Assert-True ($mappedResult.ExitCode -ne 0) 'Stage rejects a PowerShell mapped drive root'
    Assert-True ($mappedResult.Output -match 'mapped|drive|local') 'Mapped-drive rejection explains the drive boundary'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $mappedTarget 'demo'))) 'Mapped-drive rejection creates no directory'

    $environmentPath = Join-Path $env:LOCALAPPDATA 'IBM\BobTeamProfile\vc6-machine-control-poc\environment.json'
    $originalSecret = 'ORIGINAL-OPAQUE-SECRET-9f4c6f2a'
    Write-DemoLifecycleText $environmentPath $originalSecret
    $originalBytes = [System.IO.File]::ReadAllBytes($environmentPath)
    $demoRoot = Join-Path $fixtureRoot 'demo-main'
    $stage = Invoke-DemoLifecycleScript $preparePath ($stageArgs + @('-Stage'))
    Assert-Equal $stage.ExitCode 0 ("Stage succeeds with synthetic fixture tools. Output: " + $stage.Output)
    Assert-True ($stage.Output -match 'NOT VC6 QUALIFICATION') 'Stage output retains the immutable disclaimer'
    Assert-True ($stage.Output -notmatch [regex]::Escape($originalSecret)) 'Stage never prints backed-up environment contents'
    foreach ($name in @('workspace', 'sandboxes', 'logs', 'evidence', 'tools')) {
        Assert-True (Test-Path -LiteralPath (Join-Path $demoRoot $name) -PathType Container) "Stage creates $name"
    }
    $markerPath = Join-Path $demoRoot '.team-bob-demo-marker.json'
    $marker = Get-DemoLifecycleJson $markerPath
    Assert-Equal $marker.state 'STAGED' 'Stage marker reaches STAGED only after completion'
    Assert-Equal $marker.banner ('MSBUILD DEMO ADAPTER ' + [char]0x2014 + ' NOT VC6 QUALIFICATION') 'Marker has the exact Unicode disclaimer'
    Assert-Equal $marker.demoRoot ([System.IO.Path]::GetFullPath($demoRoot).TrimEnd('\', '/')) 'Marker binds the canonical demo root'
    Assert-Equal $marker.pcId ([Environment]::MachineName) 'Marker binds the current PC'
    Assert-Equal $marker.userSid ([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value) 'Marker binds the current Windows identity'

    $workspace = Join-Path $demoRoot 'workspace'
    Assert-True (Test-Path -LiteralPath (Join-Path $workspace '.bob\custom_modes.yaml') -PathType Leaf) 'Stage installs Bob custom modes into the workspace'
    Assert-True (Test-Path -LiteralPath (Join-Path $workspace 'demo\CycleWatch\src\CycleWatch.cpp') -PathType Leaf) 'Stage copies the synthetic project'
    Assert-True (Test-Path -LiteralPath (Join-Path $workspace 'demo\inputs\requirements-demo.docx') -PathType Leaf) 'Stage copies the synthetic Word input'
    Assert-True (Test-Path -LiteralPath (Join-Path $workspace '.bobignore') -PathType Leaf) 'Stage materializes the reviewed Bob ignore file'
    Assert-True (Test-Path -LiteralPath (Join-Path $workspace '.bzrignore') -PathType Leaf) 'Stage materializes the reviewed Bazaar ignore file'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $workspace '.bzr'))) 'Stage never initializes Bazaar'
    Assert-True (Test-Path -LiteralPath (Join-Path $demoRoot 'tools\Restore-TeamBobDemo.ps1') -PathType Leaf) 'Stage copies the restore tool outside the workspace'
    $externalCommonPath = Join-Path $demoRoot 'tools\TeamBob-BuildCommon.ps1'
    Assert-True (Test-Path -LiteralPath $externalCommonPath -PathType Leaf) 'Stage copies the lifecycle common helper outside the Bob-editable workspace'
    Assert-Equal $marker.paths.lifecycleCommon 'tools/TeamBob-BuildCommon.ps1' 'Marker fixes the external lifecycle helper path'
    Assert-Equal (Get-DemoLifecycleHash $externalCommonPath) $marker.hashes.lifecycleCommon 'Marker fixes the external lifecycle helper hash'
    $initialAllowedPath = Join-Path $workspace 'demo\CycleWatch\src\CycleWatch.cpp'
    Assert-Equal $marker.paths.initialAllowedFile 'workspace/demo/CycleWatch/src/CycleWatch.cpp' 'Marker fixes the live-demo initial Allowed File path'
    Assert-Equal (Get-DemoLifecycleHash $initialAllowedPath) $marker.hashes.initialAllowedFile 'Marker fixes the initial Allowed File hash before Bob edits'
    $cp932 = [System.Text.Encoding]::GetEncoding(932, (New-Object System.Text.EncoderExceptionFallback), (New-Object System.Text.DecoderExceptionFallback))
    $initialAllowedText = $cp932.GetString([System.IO.File]::ReadAllBytes($initialAllowedPath))
    Assert-True ($initialAllowedText -match 'consecutiveOverruns_\s*>=\s*1U') 'Stage initial Allowed File retains the deliberate one-cycle baseline'
    Assert-True ($initialAllowedText -match '(?m)^#error MSBUILD_DEMO_ADAPTER_INTENTIONAL_COMPILER_FAULT') 'Stage initial Allowed File retains the conditional artificial compiler fault baseline'
    $exactRepairContract = '#error MSBUILD_DEMO_ADAPTER_INTENTIONAL_COMPILER_FAULT "demo/CycleWatch/src/CycleWatch.cpp" AFTER_EVIDENCE_REPLACE_THIS_EXACT_LINE_WITH: #pragma message("MSBUILD_DEMO_ADAPTER_INTENTIONAL_FAULT_REPAIRED demo/CycleWatch/src/CycleWatch.cpp")'
    Assert-Equal (@($initialAllowedText -split '\r\n' | Where-Object { $_ -ceq $exactRepairContract }).Count) 1 'Stage fixes exactly one full artificial-fault repair contract line'
    Assert-Equal (Get-DemoLifecycleHash (Join-Path $workspace '.bob\commands\bob-implement-green.md')) (Get-DemoLifecycleHash (Join-Path $distribution 'profile\.bob\commands\bob-implement-green.md')) 'Stage keeps the production Green command byte-identical in the isolated workspace'
    Assert-Equal (Get-DemoLifecycleHash (Join-Path $workspace '.bob\rules-green-implement\10-edit-build-loop.md')) (Get-DemoLifecycleHash (Join-Path $distribution 'profile\.bob\rules-green-implement\10-edit-build-loop.md')) 'Stage keeps the production Green rule byte-identical in the isolated workspace'

    $catalogPath = Join-Path $workspace 'team-bob\config\vc6-build-targets.json'
    $catalog = Get-DemoLifecycleJson $catalogPath
    Assert-Equal @($catalog.profiles).Count 1 'Demo workspace catalog has exactly one profile'
    Assert-Equal $catalog.profiles[0].id 'demo-msbuild-protocol-v1-not-vc6' 'Demo catalog uses the fixed profile ID'
    Assert-Equal $catalog.profiles[0].enabled $false 'Stage leaves the demo profile disabled'
    Assert-Equal $catalog.profiles[0].environmentErrorPattern 'TEAM_BOB_ADAPTER_ENVIRONMENT_ERROR=' 'Demo catalog classifies the adapter stable environment-error marker'
    $representativeLogPath = Join-Path $demoRoot 'logs\DEMO-GREEN-001\attempt-0-make-0123456789abcdef0123456789abcdef\build.log'
    Assert-True ([regex]::IsMatch($representativeLogPath, [string]$catalog.profiles[0].outputLogPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) 'Demo catalog outputLogPattern accepts the wrapper fixed build.log path'
    $productionCatalog = Get-DemoLifecycleJson (Join-Path $distribution 'profile\team-bob\config\vc6-build-targets.json')
    Assert-Equal @($productionCatalog.profiles).Count 0 'Stage leaves the distribution production catalog empty'
    Assert-Equal (Get-DemoLifecycleFingerprint $distribution) $distributionFingerprint 'Stage and probes leave the complete fixture distribution unchanged'
    Assert-Equal (Get-DemoLifecycleFingerprint (Join-Path $repositoryRoot 'profile')) $productionProfileFingerprint 'Stage leaves the real production profile unchanged'

    $backupMetadataPath = Join-Path $demoRoot ($marker.paths.environmentBackupMetadata.Replace('/', '\'))
    $backupMetadata = Get-DemoLifecycleJson $backupMetadataPath
    Assert-Equal $backupMetadata.originalExisted $true 'Stage records that an original environment registration existed'
    $backupPath = Join-Path $demoRoot ($backupMetadata.backupRelativePath.Replace('/', '\'))
    Assert-Equal ([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($backupPath))) ([Convert]::ToBase64String($originalBytes)) 'Environment backup preserves exact original bytes'
    Assert-DemoLifecycleAcl (Split-Path -Parent $backupPath)
    Assert-DemoLifecycleAcl $backupPath
    Assert-DemoLifecycleAcl $backupMetadataPath
    $demoEnvironment = Get-DemoLifecycleJson $environmentPath
    Assert-Equal $demoEnvironment.msdevPath (Join-Path $demoRoot 'tools\DemoMsdevAdapter.exe') 'Stage registers only the generated demo adapter'
    Assert-Equal $demoEnvironment.bazaarPath ([System.IO.Path]::GetFullPath($bazaar).TrimEnd('\', '/')) 'Stage records but does not execute the fixed Bazaar binary'
    Assert-Equal (Get-DemoLifecycleHash $environmentPath) $marker.hashes.demoEnvironment 'Marker fixes the demo environment hash'

    $usagePath = Join-Path $demoRoot ($marker.paths.usageLog.Replace('/', '\'))
    Assert-True (Test-Path -LiteralPath $usagePath -PathType Leaf) 'Stage creates an external runtime usage log'
    Assert-Equal (Get-DemoLifecycleHash $usagePath) (Get-DemoLifecycleHash (Join-Path $distribution 'demo\docs\usage-log.csv')) 'Runtime usage log starts as an exact template copy'
    $usageHeader = ([System.IO.File]::ReadAllLines($usagePath))[0]
    Assert-True ($usageHeader -notmatch '(?i)person|operator|member|name|email|account|user') 'Runtime usage log has no personal-identity column'
    $negativePath = Join-Path $demoRoot ($marker.paths.negativePacket.Replace('/', '\'))
    $negativeText = [System.IO.File]::ReadAllText($negativePath, (New-Object System.Text.UTF8Encoding($false, $true)))
    Assert-True ($negativeText -match 'MSBUILD DEMO ADAPTER . NOT VC6 QUALIFICATION') 'External negative packet retains the disclaimer'
    Assert-True ($negativeText -match '"Risk"\s*:\s*"Green"') 'Negative packet exercises the Green gate'
    Assert-True ($negativeText -match '"Open QA"\s*:\s*\[\s*"QA-DEMO-OPEN-001"') 'Negative packet contains a deliberate Open QA'
    Assert-True (-not $negativePath.StartsWith($workspace + '\', [System.StringComparison]::OrdinalIgnoreCase)) 'Negative packet stays outside the versioned workspace'
    Assert-True ($stage.Output -match ('(?m)^OPEN_QA_NEGATIVE_PACKET ' + [regex]::Escape($negativePath) + '\r?$')) 'Stage reports the absolute Open QA negative-packet path'
    Assert-True ($stage.Output -match ('(?m)^OPEN_QA_NEGATIVE_PACKET_SHA256 ' + [regex]::Escape($marker.hashes.negativePacket) + '\r?$')) 'Stage reports the marker-bound Open QA negative-packet hash'
    Assert-True ($stage.Output -match ('(?m)^RUNTIME_USAGE_LOG ' + [regex]::Escape($usagePath) + '\r?$')) 'Stage reports the external runtime usage-log path'

    foreach ($pair in @(
        @('catalog', $catalogPath), @('adapter', (Join-Path $demoRoot 'tools\DemoMsdevAdapter.exe')),
        @('buildManifest', (Join-Path $demoRoot 'tools\DemoMsdevAdapter.build-manifest.json')),
        @('lifecycleCommon', $externalCommonPath),
        @('initialAllowedFile', $initialAllowedPath),
        @('rawQualification', (Join-Path $demoRoot 'evidence\qualification\demo-adapter-qualification.json')),
        @('usageLog', $usagePath), @('negativePacket', $negativePath), @('environmentBackupMetadata', $backupMetadataPath)
    )) { Assert-Equal (Get-DemoLifecycleHash $pair[1]) $marker.hashes.($pair[0]) "Marker fixes the $($pair[0]) hash" }
    $stageJournal = Get-DemoLifecycleJson (Join-Path $demoRoot 'evidence\lifecycle\stage-journal.json')
    Assert-Equal $stageJournal.state 'STAGED' 'Stage journal records the completed state'

    $stagedFingerprint = Get-DemoLifecycleFingerprint $demoRoot
    $rerun = Invoke-DemoLifecycleScript $preparePath ($stageArgs + @('-Stage'))
    Assert-Equal $rerun.ExitCode 0 'An identical STAGED invocation is idempotent'
    Assert-True ($rerun.Output -match 'IDENTICAL') 'Idempotent Stage reports IDENTICAL'
    Assert-Equal (Get-DemoLifecycleFingerprint $demoRoot) $stagedFingerprint 'Idempotent Stage changes no retained demo evidence'

    $rawPath = Join-Path $demoRoot 'evidence\qualification\demo-adapter-qualification.json'
    $rawBytes = [System.IO.File]::ReadAllBytes($rawPath)
    $raw = Get-DemoLifecycleJson $rawPath
    $raw.adapterSha256 = ('f' * 64)
    Write-DemoLifecycleJson $rawPath $raw
    $marker = Get-DemoLifecycleJson $markerPath
    $marker.hashes.rawQualification = Get-DemoLifecycleHash $rawPath
    Write-DemoLifecycleJson $markerPath $marker
    $approveArgs = $stageArgs + @('-ApproveQualification', '-RecordId', 'DEMO-QUAL-TEST-001', '-AcceptNotVc6')
    $tamperedApproval = Invoke-DemoLifecycleScript $preparePath $approveArgs
    Assert-True ($tamperedApproval.ExitCode -ne 0) 'Approval rejects a semantically tampered raw record even if the marker hash is also changed'
    $catalog = Get-DemoLifecycleJson $catalogPath
    Assert-Equal $catalog.profiles[0].enabled $false 'Rejected approval never enables the demo profile'
    Assert-Equal (Get-DemoLifecycleJson $markerPath).state 'STAGED' 'Pre-transition approval rejection leaves the marker STAGED'
    [System.IO.File]::WriteAllBytes($rawPath, $rawBytes)
    $marker = Get-DemoLifecycleJson $markerPath
    $marker.hashes.rawQualification = Get-DemoLifecycleHash $rawPath
    Write-DemoLifecycleJson $markerPath $marker

    $backupMetadataBytes = [System.IO.File]::ReadAllBytes($backupMetadataPath)
    $tamperedBackupMetadata = Get-DemoLifecycleJson $backupMetadataPath
    $tamperedBackupMetadata.registrationPath = Join-Path $fixtureRoot 'wrong-environment.json'
    Write-DemoLifecycleJson $backupMetadataPath $tamperedBackupMetadata
    $marker = Get-DemoLifecycleJson $markerPath
    $marker.hashes.environmentBackupMetadata = Get-DemoLifecycleHash $backupMetadataPath
    Write-DemoLifecycleJson $markerPath $marker
    $tamperedBackupMetadataApproval = Invoke-DemoLifecycleScript $preparePath $approveArgs
    Assert-True ($tamperedBackupMetadataApproval.ExitCode -ne 0) 'Approval rejects semantically changed environment-backup metadata even when its marker hash is also changed'
    Assert-Equal (Get-DemoLifecycleJson $catalogPath).profiles[0].enabled $false 'Backup-metadata approval rejection leaves the catalog disabled'
    Assert-Equal (Get-DemoLifecycleJson $markerPath).state 'STAGED' 'Backup-metadata approval rejection occurs before state transition'
    [System.IO.File]::WriteAllBytes($backupMetadataPath, $backupMetadataBytes)
    $marker = Get-DemoLifecycleJson $markerPath
    $marker.hashes.environmentBackupMetadata = Get-DemoLifecycleHash $backupMetadataPath
    Write-DemoLifecycleJson $markerPath $marker

    $rawHashBeforeApproval = Get-DemoLifecycleHash $rawPath
    $demoEnvironmentHashBeforeApproval = Get-DemoLifecycleHash $environmentPath
    $approval = Invoke-DemoLifecycleScript $preparePath $approveArgs
    Assert-Equal $approval.ExitCode 0 'Approval succeeds only with complete revalidated qualification evidence and explicit acceptance'
    Assert-True ($approval.Output -match 'NOT VC6 QUALIFICATION') 'Approval output retains the disclaimer'
    $approvedMarker = Get-DemoLifecycleJson $markerPath
    Assert-Equal $approvedMarker.state 'APPROVED' 'Approval marker reaches APPROVED'
    Assert-Equal $approvedMarker.approval.recordId 'DEMO-QUAL-TEST-001' 'Marker records the supplied role-reviewed Record ID'
    $approvedCatalog = Get-DemoLifecycleJson $catalogPath
    Assert-Equal $approvedCatalog.profiles[0].enabled $true 'Approval enables only the isolated demo profile'
    foreach ($flag in @('msdevHelp', 'makeSucceeded', 'rebuildSucceeded', 'compileFailureObserved', 'linkFailureObserved')) {
        Assert-Equal $approvedCatalog.profiles[0].qualification.$flag $true "Approval records $flag"
    }
    Assert-Equal $approvedCatalog.profiles[0].qualification.recordId 'DEMO-QUAL-TEST-001' 'Catalog qualification binds the approved Record ID'
    Assert-Equal (Get-DemoLifecycleHash $rawPath) $rawHashBeforeApproval 'Approval never rewrites raw qualification evidence'
    Assert-Equal (Get-DemoLifecycleHash $environmentPath) $demoEnvironmentHashBeforeApproval 'Approval never rewrites the local environment registration'
    $approvalRecordPath = Join-Path $demoRoot ($approvedMarker.approval.approvalRelativePath.Replace('/', '\'))
    $approvalRecord = Get-DemoLifecycleJson $approvalRecordPath
    Assert-Equal $approvalRecord.vc6Qualified $false 'Approval record explicitly denies VC6 qualification'
    Assert-Equal $approvalRecord.acceptNotVc6 'YES' 'Approval record captures explicit NOT-VC6 acceptance'
    Assert-Equal $approvalRecord.targetPcReviewRole 'DEMO-TARGET-PC-OWNER-ROLE' 'Approval record uses a role, not a personal identity'
    Assert-Equal $approvalRecord.operationsApprovalRole 'DEMO-OPERATIONS-OWNER-ROLE' 'Approval record uses the operations role'

    $approvedFingerprint = Get-DemoLifecycleFingerprint $demoRoot
    $approvalRerun = Invoke-DemoLifecycleScript $preparePath $approveArgs
    Assert-Equal $approvalRerun.ExitCode 0 'Approval is idempotent only for the same Record ID'
    Assert-True ($approvalRerun.Output -match 'IDENTICAL') 'Idempotent approval reports IDENTICAL'
    Assert-Equal (Get-DemoLifecycleFingerprint $demoRoot) $approvedFingerprint 'Idempotent approval changes no evidence'
    $differentApproval = Invoke-DemoLifecycleScript $preparePath ($stageArgs + @('-ApproveQualification', '-RecordId', 'DEMO-QUAL-TEST-OTHER', '-AcceptNotVc6'))
    Assert-True ($differentApproval.ExitCode -ne 0) 'An approved root rejects a different Record ID'
    Assert-Equal (Get-DemoLifecycleJson $markerPath).state 'APPROVED' 'Rejected duplicate approval preserves APPROVED state'

    $externalCommonBytes = [System.IO.File]::ReadAllBytes($externalCommonPath)
    $externalCommonSentinel = Join-Path $demoRoot 'external-common-executed.txt'
    Write-DemoLifecycleText $externalCommonPath ("[System.IO.File]::WriteAllText('" + $externalCommonSentinel.Replace("'", "''") + "','EXECUTED'); throw 'untrusted external helper executed'`r`n")
    $tamperedHelperRestore = Invoke-DemoLifecycleScript $restorePath @('-DemoRoot', $demoRoot)
    Assert-True ($tamperedHelperRestore.ExitCode -ne 0) 'Restore rejects a changed external lifecycle helper before dot-sourcing it'
    Assert-True (-not (Test-Path -LiteralPath $externalCommonSentinel)) 'Restore never executes a lifecycle helper whose marker hash does not match'
    Assert-Equal (Get-DemoLifecycleJson $catalogPath).profiles[0].enabled $true 'External-helper rejection occurs before catalog mutation'
    [System.IO.File]::WriteAllBytes($externalCommonPath, $externalCommonBytes)

    $backupBytes = [System.IO.File]::ReadAllBytes($backupPath)
    [System.IO.File]::WriteAllBytes($backupPath, (New-Object System.Text.UTF8Encoding($false)).GetBytes('tampered backup'))
    $tamperedRestore = Invoke-DemoLifecycleScript $restorePath @('-DemoRoot', $demoRoot)
    Assert-True ($tamperedRestore.ExitCode -ne 0) 'Restore rejects a backup whose hash no longer matches the marker'
    Assert-Equal (Get-DemoLifecycleHash $environmentPath) $demoEnvironmentHashBeforeApproval 'Rejected restore does not overwrite the active environment registration'
    Assert-Equal (Get-DemoLifecycleJson $catalogPath).profiles[0].enabled $true 'Backup-integrity rejection occurs before catalog mutation'
    [System.IO.File]::WriteAllBytes($backupPath, $backupBytes)

    Write-DemoLifecycleText (Join-Path $workspace 'retain-workspace.txt') "retain`r`n"
    Write-DemoLifecycleText (Join-Path $demoRoot 'logs\retain-log.txt') "retain`r`n"
    Write-DemoLifecycleText (Join-Path $demoRoot 'evidence\retain-evidence.txt') "retain`r`n"
    $workspaceCommonPath = Join-Path $workspace 'team-bob\tools\TeamBob-BuildCommon.ps1'
    $workspaceCommonSentinel = Join-Path $demoRoot 'workspace-common-executed.txt'
    Write-DemoLifecycleText $workspaceCommonPath ("[System.IO.File]::WriteAllText('" + $workspaceCommonSentinel.Replace("'", "''") + "','EXECUTED'); throw 'Bob-editable workspace helper executed'`r`n")
    $restore = Invoke-DemoLifecycleScript $restorePath @('-DemoRoot', $demoRoot)
    Assert-Equal $restore.ExitCode 0 'Restore succeeds from the matching marker and exact backup'
    Assert-True (-not (Test-Path -LiteralPath $workspaceCommonSentinel)) 'Restore never executes lifecycle code from the Bob-editable workspace'
    Assert-True ($restore.Output -match 'NOT VC6 QUALIFICATION') 'Restore output retains the disclaimer'
    Assert-Equal (Get-DemoLifecycleJson $markerPath).state 'RESTORED' 'Restore marker reaches RESTORED'
    Assert-Equal (Get-DemoLifecycleJson $catalogPath).profiles[0].enabled $false 'Restore disables the demo catalog before completing'
    Assert-Equal ([Convert]::ToBase64String([System.IO.File]::ReadAllBytes($environmentPath))) ([Convert]::ToBase64String($originalBytes)) 'Restore writes back the exact original environment bytes'
    foreach ($path in @((Join-Path $workspace 'retain-workspace.txt'), (Join-Path $demoRoot 'logs\retain-log.txt'), (Join-Path $demoRoot 'evidence\retain-evidence.txt'))) {
        Assert-True (Test-Path -LiteralPath $path -PathType Leaf) "Restore preserves retained demo data: $path"
    }
    $restoreAgain = Invoke-DemoLifecycleScript $restorePath @('-DemoRoot', $demoRoot)
    Assert-Equal $restoreAgain.ExitCode 0 'A completed restore is idempotent'
    Assert-True ($restoreAgain.Output -match 'IDENTICAL') 'Idempotent restore reports IDENTICAL'

    $env:LOCALAPPDATA = Join-Path $fixtureRoot 'localappdata-absent'
    [void][System.IO.Directory]::CreateDirectory($env:LOCALAPPDATA)
    $env:TEAM_BOB_DEMO_TEST_QUALIFICATION_MODE = 'incomplete'
    $absentRoot = Join-Path $fixtureRoot 'demo-absent'
    $absentArgs = Get-DemoLifecycleArgs $distribution $absentRoot $msBuild $bazaar
    $absentStage = Invoke-DemoLifecycleScript $preparePath ($absentArgs + @('-Stage'))
    Assert-Equal $absentStage.ExitCode 0 'Stage retains raw evidence even when Visual Studio qualification is incomplete'
    $absentMarkerPath = Join-Path $absentRoot '.team-bob-demo-marker.json'
    $absentMarker = Get-DemoLifecycleJson $absentMarkerPath
    $absentEnvironmentPath = Join-Path $env:LOCALAPPDATA 'IBM\BobTeamProfile\vc6-machine-control-poc\environment.json'
    Assert-True (Test-Path -LiteralPath $absentEnvironmentPath -PathType Leaf) 'Stage creates the demo registration when no original existed'
    $markerOriginalPath = Join-Path $absentRoot 'evidence\marker-original.json'
    $markerLinkTarget = Join-Path $absentRoot 'evidence\marker-link-target.txt'
    [System.IO.File]::Move($absentMarkerPath, $markerOriginalPath)
    Write-DemoLifecycleText $markerLinkTarget "not valid marker json`r`n"
    New-DemoLifecycleSymbolicLink $absentMarkerPath $markerLinkTarget
    $markerLinkRestore = Invoke-DemoLifecycleScript $restorePath @('-DemoRoot', $absentRoot)
    Assert-True ($markerLinkRestore.ExitCode -ne 0) 'Restore rejects a marker file that is itself a reparse point before reading it'
    Assert-True ($markerLinkRestore.Output -match 'reparse|alias') 'Marker reparse rejection identifies the unsafe boundary'
    Assert-True (Test-Path -LiteralPath $absentEnvironmentPath -PathType Leaf) 'Marker reparse rejection occurs before environment mutation'
    [System.IO.File]::Delete($absentMarkerPath)
    [System.IO.File]::Delete($markerLinkTarget)
    [System.IO.File]::Move($markerOriginalPath, $absentMarkerPath)
    $environmentLinkTarget = Join-Path (Split-Path -Parent $absentEnvironmentPath) 'environment-link-target.json'
    [System.IO.File]::Move($absentEnvironmentPath, $environmentLinkTarget)
    New-DemoLifecycleSymbolicLink $absentEnvironmentPath $environmentLinkTarget
    $environmentLinkRestore = Invoke-DemoLifecycleScript $restorePath @('-DemoRoot', $absentRoot)
    Assert-True ($environmentLinkRestore.ExitCode -ne 0) 'Restore rejects an environment registration that was replaced with a reparse file'
    Assert-True ($environmentLinkRestore.Output -match 'reparse|alias') 'Environment-registration reparse rejection identifies the unsafe boundary'
    Assert-True (Test-Path -LiteralPath $environmentLinkTarget -PathType Leaf) 'Environment-registration reparse rejection preserves the linked target'
    [System.IO.File]::Delete($absentEnvironmentPath)
    [System.IO.File]::Move($environmentLinkTarget, $absentEnvironmentPath)
    $incompleteApproval = Invoke-DemoLifecycleScript $preparePath ($absentArgs + @('-ApproveQualification', '-RecordId', 'DEMO-QUAL-INCOMPLETE-001', '-AcceptNotVc6'))
    Assert-True ($incompleteApproval.ExitCode -ne 0) 'Approval rejects qualificationEligible false'
    Assert-Equal (Get-DemoLifecycleJson (Join-Path $absentRoot 'workspace\team-bob\config\vc6-build-targets.json')).profiles[0].enabled $false 'Incomplete qualification leaves the catalog disabled'
    Assert-Equal (Get-DemoLifecycleJson $absentMarkerPath).state 'STAGED' 'Incomplete qualification leaves the marker STAGED'

    $markerBytes = [System.IO.File]::ReadAllBytes($absentMarkerPath)
    $wrongMarker = Get-DemoLifecycleJson $absentMarkerPath
    $wrongMarker.demoRoot = Join-Path $fixtureRoot 'wrong-root'
    Write-DemoLifecycleJson $absentMarkerPath $wrongMarker
    $mismatchedRestore = Invoke-DemoLifecycleScript $restorePath @('-DemoRoot', $absentRoot)
    Assert-True ($mismatchedRestore.ExitCode -ne 0) 'Restore rejects a marker bound to another root'
    Assert-True (Test-Path -LiteralPath $absentEnvironmentPath -PathType Leaf) 'Marker mismatch never removes the environment registration'
    [System.IO.File]::WriteAllBytes($absentMarkerPath, $markerBytes)
    $absentRestore = Invoke-DemoLifecycleScript $restorePath @('-DemoRoot', $absentRoot)
    Assert-Equal $absentRestore.ExitCode 0 'Restore succeeds when the original environment registration was absent'
    Assert-True (-not (Test-Path -LiteralPath $absentEnvironmentPath)) 'Restore removes only the exact demo registration when no original existed'
    Assert-Equal (Get-DemoLifecycleJson $absentMarkerPath).state 'RESTORED' 'Absent-original restore reaches RESTORED'

    $env:LOCALAPPDATA = Join-Path $fixtureRoot 'localappdata-failure'
    [void][System.IO.Directory]::CreateDirectory($env:LOCALAPPDATA)
    $failedEnvironmentPath = Join-Path $env:LOCALAPPDATA 'IBM\BobTeamProfile\vc6-machine-control-poc\environment.json'
    Write-DemoLifecycleText $failedEnvironmentPath "failure-original`r`n"
    $failedOriginalHash = Get-DemoLifecycleHash $failedEnvironmentPath
    $env:TEAM_BOB_DEMO_TEST_QUALIFICATION_MODE = 'fail'
    $failedRoot = Join-Path $fixtureRoot 'demo-failed'
    $failedStage = Invoke-DemoLifecycleScript $preparePath ((Get-DemoLifecycleArgs $distribution $failedRoot $msBuild $bazaar) + @('-Stage'))
    Assert-True ($failedStage.ExitCode -ne 0) 'A failed qualification prevents Stage completion'
    Assert-Equal (Get-DemoLifecycleHash $failedEnvironmentPath) $failedOriginalHash 'Failed Stage leaves the pre-existing environment bytes unchanged'
    Assert-Equal (Get-DemoLifecycleJson (Join-Path $failedRoot '.team-bob-demo-marker.json')).state 'STAGING' 'Failed Stage remains visibly STAGING for forensic restore'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $failedRoot 'workspace\.bzr'))) 'Failed Stage never invokes Bazaar'

    Assert-Equal (Get-DemoLifecycleFingerprint $distribution) $distributionFingerprint 'All lifecycle operations preserve the fixture distribution and its .bzr sentinel'
    Assert-Equal (Get-DemoLifecycleFingerprint (Join-Path $repositoryRoot 'profile')) $productionProfileFingerprint 'All lifecycle operations preserve the real production profile'
} finally {
    if ($null -ne $junctionPath -and (Test-Path -LiteralPath $junctionPath)) { [System.IO.Directory]::Delete($junctionPath) }
    if ($null -eq $savedQualificationMode) { Remove-Item Env:TEAM_BOB_DEMO_TEST_QUALIFICATION_MODE -ErrorAction SilentlyContinue } else { $env:TEAM_BOB_DEMO_TEST_QUALIFICATION_MODE = $savedQualificationMode }
    $env:LOCALAPPDATA = $savedLocalAppData
    Remove-DemoLifecycleFixtureRoot $fixtureRoot
}

if ($demoLifecycleStandalone) { Write-Output "PASS: $script:Assertions assertions" }
