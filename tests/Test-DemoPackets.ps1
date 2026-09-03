$ErrorActionPreference = 'Stop'
$demoPacketStandalone = $null -eq (Get-Command Assert-True -ErrorAction SilentlyContinue)
if ($demoPacketStandalone) {
    Set-StrictMode -Version 2.0
    $script:Assertions = 0
    function Assert-True {
        param([bool]$Condition, [string]$Message)
        $script:Assertions++
        if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
    }
    function Assert-Equal {
        param($Actual, $Expected, [string]$Message)
        Assert-True ($Actual -ceq $Expected) "$Message (expected '$Expected', got '$Actual')"
    }
}
$demoPacketAssertionsBefore = $script:Assertions
$script:DemoPacketUtf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:DemoPacketBanner = 'MSBUILD DEMO ADAPTER ' + [char]0x2014 + ' NOT VC6 QUALIFICATION'
$script:DemoPacketInitialFaultLine = '#error MSBUILD_DEMO_ADAPTER_INTENTIONAL_COMPILER_FAULT "demo/CycleWatch/src/CycleWatch.cpp" AFTER_EVIDENCE_REPLACE_THIS_EXACT_LINE_WITH: #pragma message("MSBUILD_DEMO_ADAPTER_INTENTIONAL_FAULT_REPAIRED demo/CycleWatch/src/CycleWatch.cpp")'
$script:DemoPacketRepairedFaultLine = '#pragma message("MSBUILD_DEMO_ADAPTER_INTENTIONAL_FAULT_REPAIRED demo/CycleWatch/src/CycleWatch.cpp")'

function Assert-DemoPacketSequence {
    param([object[]]$Actual, [object[]]$Expected, [string]$Message)
    Assert-Equal (@($Actual) -join "`n") (@($Expected) -join "`n") $Message
}

function Write-DemoPacketBytes {
    param([string]$Path, [byte[]]$Bytes)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { [void][System.IO.Directory]::CreateDirectory($parent) }
    [System.IO.File]::WriteAllBytes($Path, $Bytes)
}

function Write-DemoPacketText {
    param([string]$Path, [string]$Text)
    Write-DemoPacketBytes $Path $script:DemoPacketUtf8NoBom.GetBytes($Text)
}

function Write-DemoPacketJson {
    param([string]$Path, [object]$Value)
    Write-DemoPacketText $Path (($Value | ConvertTo-Json -Depth 40) + "`r`n")
}

function Get-DemoPacketHash {
    param([string]$Path)
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Get-DemoPacketJson {
    param([string]$Path)
    return ([System.IO.File]::ReadAllText($Path, (New-Object System.Text.UTF8Encoding($false, $true))) | ConvertFrom-Json)
}

function Get-DemoCanonicalPacket {
    param([string]$Path)
    $text = [System.IO.File]::ReadAllText($Path, (New-Object System.Text.UTF8Encoding($false, $true)))
    $match = [regex]::Match($text, '(?s)<!-- canonical-work-packet-json:start -->\s*```json\s*(?<json>\{.*?\})\s*```\s*<!-- canonical-work-packet-json:end -->')
    if (-not $match.Success) { throw "Canonical packet JSON is missing: $Path" }
    return ($match.Groups['json'].Value | ConvertFrom-Json)
}

function Get-DemoTreeFingerprint {
    param([string]$Root)
    return (@(Get-ChildItem -LiteralPath $Root -Force -Recurse | Sort-Object FullName | ForEach-Object {
        $relative = $_.FullName.Substring($Root.Length).TrimStart('\').Replace('\', '/')
        if ($_.PSIsContainer) { "D|$relative" } else { "F|$relative|$($_.Length)|$(Get-DemoPacketHash $_.FullName)" }
    }) -join "`n")
}

function Invoke-DemoPacketTool {
    param([string]$ScriptPath, [string]$Phase, [string]$WorkingDirectory)
    $engine = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $arguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath, '-Phase', $Phase)
    $argumentText = @($arguments | ForEach-Object {
        if ($_ -notmatch '[\s"]') { $_ } else { '"' + $_.Replace('\', '\').Replace('"', '\"') + '"' }
    }) -join ' '
    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = $engine
    $start.Arguments = $argumentText
    $start.WorkingDirectory = $WorkingDirectory
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
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

function New-DemoPacketFixture {
    param([string]$RepositoryRoot, [string]$FixtureRoot, [string]$PacketToolSource)
    $demoRoot = Join-Path $FixtureRoot 'demo-root'
    $workspace = Join-Path $demoRoot 'workspace'
    foreach ($path in @($demoRoot, $workspace, (Join-Path $demoRoot 'tools'), (Join-Path $demoRoot 'sandboxes'), (Join-Path $demoRoot 'logs'), (Join-Path $demoRoot 'evidence\qualification'))) {
        [void][System.IO.Directory]::CreateDirectory($path)
    }
    Copy-Item -LiteralPath (Join-Path $RepositoryRoot 'profile\.bob') -Destination (Join-Path $workspace '.bob') -Recurse
    Copy-Item -LiteralPath (Join-Path $RepositoryRoot 'profile\team-bob') -Destination (Join-Path $workspace 'team-bob') -Recurse
    [void][System.IO.Directory]::CreateDirectory((Join-Path $workspace 'demo'))
    Copy-Item -LiteralPath (Join-Path $RepositoryRoot 'demo\inputs') -Destination (Join-Path $workspace 'demo\inputs') -Recurse
    Copy-Item -LiteralPath (Join-Path $RepositoryRoot 'demo\CycleWatch') -Destination (Join-Path $workspace 'demo\CycleWatch') -Recurse
    [void][System.IO.Directory]::CreateDirectory((Join-Path $workspace '.bzr'))
    Write-DemoPacketText (Join-Path $workspace '.bzr\branch.conf') "fixture-bazaar-metadata`r`n"

    $toolPath = Join-Path $demoRoot 'tools\New-TeamBobDemoPacket.ps1'
    [System.IO.File]::Copy($PacketToolSource, $toolPath, $false)
    $lifecycleCommon = Join-Path $demoRoot 'tools\TeamBob-BuildCommon.ps1'
    [System.IO.File]::Copy((Join-Path $RepositoryRoot 'profile\team-bob\tools\TeamBob-BuildCommon.ps1'), $lifecycleCommon, $false)
    $fakeBin = Join-Path $FixtureRoot 'fake-bin'
    [void][System.IO.Directory]::CreateDirectory($fakeBin)
    $fakeBazaar = Join-Path $fakeBin 'bzr.cmd'
    Write-DemoPacketText $fakeBazaar @'
@echo off
if not "%TEAM_BOB_PACKET_BZR_LOG%"=="" echo %*>>"%TEAM_BOB_PACKET_BZR_LOG%"
if /I "%1"=="status" (
  if /I "%3"=="--revision" (
    type "%TEAM_BOB_PACKET_BZR_RANGE_STATUS_FILE%"
    exit /b 0
  )
  if not "%TEAM_BOB_PACKET_BZR_STATUS%"=="" echo %TEAM_BOB_PACKET_BZR_STATUS%
  exit /b 0
)
if /I "%1"=="diff" (
  if /I "%2"=="--revision" (
    type "%TEAM_BOB_PACKET_BZR_RANGE_DIFF_FILE%"
    exit /b 0
  )
  exit /b 91
)
if /I "%1"=="nick" (
  echo %TEAM_BOB_PACKET_BZR_NICK%
  exit /b 0
)
if /I "%1"=="version-info" (
  echo %TEAM_BOB_PACKET_BZR_REVISION%
  exit /b 0
)
exit /b 91
'@
    $fakeAdapter = Join-Path $demoRoot 'tools\DemoMsdevAdapter.exe'
    Write-DemoPacketText $fakeAdapter "fixture adapter`r`n"
    $rangeStatusPath = Join-Path $FixtureRoot 'bazaar-range-status.txt'
    $rangeDiffPath = Join-Path $FixtureRoot 'bazaar-range-diff.patch'
    Write-DemoPacketText $rangeStatusPath ''
    Write-DemoPacketText $rangeDiffPath ''

    $profile = [ordered]@{
        id = 'demo-msbuild-protocol-v1-not-vc6'; enabled = $true
        projectFile = 'demo/CycleWatch/CycleWatch.dsp'; target = 'CycleWatch - Win32 Release'; timeoutSeconds = 120
        expectedArtifacts = @('demo/CycleWatch/bin/Release/CycleWatchTests.exe')
        excludePatterns = @('**/*.obj', '**/*.pdb', '**/*.ilk', '**/*.idb')
        outputLogPattern = '(?i)[\\/]logs[\\/]'; successPattern = 'TEAM_BOB_ADAPTER_STATUS=SUCCEEDED'
        compilerErrorPattern = 'error C[0-9]+'; linkerErrorPattern = 'LNK[0-9]+'
        environmentErrorPattern = 'TEAM_BOB_ADAPTER_ENVIRONMENT_ERROR='
        qualification = [ordered]@{
            msdevHelp = $true; makeSucceeded = $true; rebuildSucceeded = $true; compileFailureObserved = $true; linkFailureObserved = $true
            pcId = [Environment]::MachineName; recordId = 'DEMO-QUAL-FIXTURE-001'; recordedAt = '2026-09-03T00:00:00.0000000+00:00'
        }
    }
    $catalogPath = Join-Path $workspace 'team-bob\config\vc6-build-targets.json'
    Write-DemoPacketJson $catalogPath ([ordered]@{ profiles = @($profile) })

    $rawQualificationPath = Join-Path $demoRoot 'evidence\qualification\demo-adapter-qualification.json'
    Write-DemoPacketJson $rawQualificationPath ([ordered]@{
        schemaVersion = '1.0'; banner = $script:DemoPacketBanner; recordId = 'DEMO-QUAL-FIXTURE-001'
        qualificationEligible = $true; recordedAt = '2026-09-03T00:00:00.0000000+00:00'
    })
    $rawQualificationHash = Get-DemoPacketHash $rawQualificationPath
    $approvalPath = Join-Path $demoRoot 'evidence\qualification\demo-qualification-approval.json'
    $instanceId = '0123456789abcdef0123456789abcdef'
    Write-DemoPacketJson $approvalPath ([ordered]@{
        schemaVersion = '1.0'; banner = $script:DemoPacketBanner; recordType = 'DEMO_ONLY_QUALIFICATION_APPROVAL'
        recordId = 'DEMO-QUAL-FIXTURE-001'; demoProfileId = 'demo-msbuild-protocol-v1-not-vc6'; demoInstanceId = $instanceId
        pcId = [Environment]::MachineName; rawQualificationRelativePath = 'evidence/qualification/demo-adapter-qualification.json'
        rawQualificationSha256 = $rawQualificationHash; acceptedAt = '2026-09-03T00:00:00.0000000+00:00'; acceptNotVc6 = 'YES'
        approved = $true; vc6Qualified = $false; targetPcReviewRole = 'DEMO-TARGET-PC-OWNER-ROLE'; operationsApprovalRole = 'DEMO-OPERATIONS-OWNER-ROLE'
    })

    $localAppData = Join-Path $FixtureRoot 'local-app-data'
    Write-DemoPacketJson (Join-Path $workspace '.bob\governance\roles.json') ([ordered]@{
        policyVersion = '0.2.0-poc'
        assignments = @(
            [ordered]@{ assignmentId='ASSIGN-DEMO-SPECIFICATION'; role='SPECIFICATION_APPROVER'; principalId='demo-specification-principal'; scope=[ordered]@{allTasks=$true;taskIds=@();phases=@('specification','test')}; enabled=$true; validFromUtc='2020-01-01T00:00:00Z'; validUntilUtc='2100-01-01T00:00:00Z' },
            [ordered]@{ assignmentId='ASSIGN-DEMO-IMPLEMENTATION'; role='IMPLEMENTATION_APPROVER'; principalId='demo-implementation-principal'; scope=[ordered]@{allTasks=$true;taskIds=@();phases=@('impact')}; enabled=$true; validFromUtc='2020-01-01T00:00:00Z'; validUntilUtc='2100-01-01T00:00:00Z' },
            [ordered]@{ assignmentId='ASSIGN-DEMO-INDEPENDENT-REVIEW'; role='INDEPENDENT_REVIEWER'; principalId='demo-independent-review-principal'; scope=[ordered]@{allTasks=$true;taskIds=@();phases=@('review')}; enabled=$true; validFromUtc='2020-01-01T00:00:00Z'; validUntilUtc='2100-01-01T00:00:00Z' }
        )
    })
    $environmentPath = Join-Path $localAppData 'IBM\BobTeamProfile\vc6-machine-control-poc\v0.2.0-poc\environment.json'
    $manifest = Get-DemoPacketJson (Join-Path $workspace 'team-bob\profile-manifest.json')
    $workSchema = Get-DemoPacketJson (Join-Path $workspace 'team-bob\config\work-packet.schema.json')
    $buildSchema = Get-DemoPacketJson (Join-Path $workspace 'team-bob\config\vc6-build-targets.schema.json')
    Write-DemoPacketJson $environmentPath ([ordered]@{
        schemaVersion = '1.0'; profileId = $manifest.profile.id; profileVersion = $manifest.version
        workPacketSchemaId = $workSchema.'$id'; buildTargetSchemaId = $buildSchema.'$id'; pcId = [Environment]::MachineName
        msdevPath = $fakeAdapter; msdevSha256 = Get-DemoPacketHash $fakeAdapter
        bazaarPath = $fakeBazaar; bazaarSha256 = Get-DemoPacketHash $fakeBazaar
        sandboxRoot = (Join-Path $demoRoot 'sandboxes'); logRoot = (Join-Path $demoRoot 'logs')
    })

    $initialAllowedFile = Join-Path $workspace 'demo\CycleWatch\src\CycleWatch.cpp'

    $distributionRoot = Join-Path $FixtureRoot 'distribution-root'
    foreach ($relativePath in @('profile\team-bob\tools\Start-TeamBobTask.ps1', 'profile\team-bob\tools\TeamBob-BuildCommon.ps1')) {
        $destination = Join-Path $distributionRoot $relativePath
        [void][System.IO.Directory]::CreateDirectory((Split-Path -Parent $destination))
        [System.IO.File]::Copy((Join-Path $RepositoryRoot $relativePath), $destination, $false)
    }
    $inventoryPath = Join-Path $demoRoot 'evidence\distribution-inventory.json'
    $inventoryEntries = @(
        'profile/team-bob/tools/Start-TeamBobTask.ps1',
        'profile/team-bob/tools/TeamBob-BuildCommon.ps1'
    ) | ForEach-Object {
        $sourcePath = Join-Path $distributionRoot ($_.Replace('/', '\'))
        [ordered]@{ relativePath = $_; length = [int64](Get-Item -LiteralPath $sourcePath).Length; sha256 = Get-DemoPacketHash $sourcePath }
    }
    Write-DemoPacketJson $inventoryPath ([ordered]@{
        schemaVersion = '1.0'; banner = $script:DemoPacketBanner; distributionRoot = $distributionRoot
        recordedAt = '2026-09-03T00:00:00.0000000+00:00'; entries = @($inventoryEntries)
    })

    $markerPath = Join-Path $demoRoot '.team-bob-demo-marker.json'
    Write-DemoPacketJson $markerPath ([ordered]@{
        schemaVersion = '1.0'; banner = $script:DemoPacketBanner; demoProfileId = 'demo-msbuild-protocol-v1-not-vc6'; demoInstanceId = $instanceId
        distributionRoot = $distributionRoot; demoRoot = $demoRoot; pcId = [Environment]::MachineName
        userSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value; state = 'APPROVED'
        createdAt = '2026-09-03T00:00:00.0000000+00:00'; updatedAt = '2026-09-03T00:00:01.0000000+00:00'
        msBuildPath = $fakeAdapter; msBuildSha256 = Get-DemoPacketHash $fakeAdapter; bazaarPath = $fakeBazaar; bazaarSha256 = Get-DemoPacketHash $fakeBazaar
        paths = [ordered]@{
            workspace = 'workspace'; sandboxes = 'sandboxes'; logs = 'logs'; evidence = 'evidence'; tools = 'tools'
            catalog = 'workspace/team-bob/config/vc6-build-targets.json'; adapter = 'tools/DemoMsdevAdapter.exe'
            buildManifest = 'tools/DemoMsdevAdapter.build-manifest.json'; lifecycleCommon = 'tools/TeamBob-BuildCommon.ps1'
            rawQualification = 'evidence/qualification/demo-adapter-qualification.json'; distributionInventory = 'evidence/distribution-inventory.json'
            usageLog = 'evidence/usage-log.csv'; negativePacket = 'evidence/negative-packets/open-qa-green-work-packet.md'
            initialAllowedFile = 'workspace/demo/CycleWatch/src/CycleWatch.cpp'
            environmentRegistration = $environmentPath; environmentBackupMetadata = 'evidence/environment-backup/environment-backup.json'
        }
        hashes = [ordered]@{
            catalog = Get-DemoPacketHash $catalogPath; adapter = Get-DemoPacketHash $fakeAdapter; buildManifest = ('b' * 64); lifecycleCommon = Get-DemoPacketHash $lifecycleCommon
            rawQualification = $rawQualificationHash; distributionInventory = Get-DemoPacketHash $inventoryPath; usageLog = ('e' * 64); negativePacket = ('f' * 64)
            initialAllowedFile = Get-DemoPacketHash $initialAllowedFile
            environmentBackupMetadata = ('1' * 64); demoEnvironment = Get-DemoPacketHash $environmentPath
        }
        approval = [ordered]@{
            recordId = 'DEMO-QUAL-FIXTURE-001'; recordedAt = '2026-09-03T00:00:00.0000000+00:00'
            approvalRelativePath = 'evidence/qualification/demo-qualification-approval.json'; approvalSha256 = Get-DemoPacketHash $approvalPath
        }
    })
    return [pscustomobject]@{
        DemoRoot = $demoRoot; Workspace = $workspace; ToolPath = $toolPath; LocalAppData = $localAppData
        BazaarPath = $fakeBazaar; BazaarLog = (Join-Path $FixtureRoot 'bazaar-commands.log'); MarkerPath = $markerPath
        RawQualificationPath = $rawQualificationPath; ApprovalPath = $approvalPath; DistributionRoot = $distributionRoot; InventoryPath = $inventoryPath
        RangeStatusPath = $rangeStatusPath; RangeDiffPath = $rangeDiffPath
    }
}

function Write-DemoRequirementsArtifacts {
    param([string]$Workspace, [string]$QaStatus)
    $drafts = Join-Path $Workspace 'team-bob-work\DEMO-REQUIREMENTS-001\drafts'
    $ledger = @"
ReqID,Immutable Source Anchor,Interpretation,Acceptance Criteria,QA Links,QA Status,Evidence,Human Approval State
REQ-CYCLEWATCH-001,requirements-demo.docx#paragraph-1,Customer-A cycle warning,Three consecutive 8000us samples after warm-up,QA-DEMO-001,$QaStatus,requirements-demo.docx,APPROVED:DEMO-SPEC-APPROVER-ROLE
REQ-CYCLEWATCH-001,qa-demo.xlsx#Questions!A2:B2,Immediate recovery and reset,7999us returns immediately to Normal,QA-DEMO-001,$QaStatus,qa-demo.xlsx,APPROVED:DEMO-SPEC-APPROVER-ROLE
"@
    Write-DemoPacketText (Join-Path $drafts 'requirement-ledger.csv') ($ledger.TrimStart() -replace "(?<!`r)`n", "`r`n")
    $spec = @"
$($script:DemoPacketBanner)
# External Specification
ReqID: REQ-CYCLEWATCH-001
Scope: Customer-A only. Warm-up suppresses Warning and resets the counter.
Acceptance: after warm-up, 8000 microseconds or more for 3 consecutive cycles enters Warning; 7999 microseconds returns immediately to Normal.
Non-functional boundary: board, driver, ABI, and control period are unchanged.
Open QA: NONE
Human Approval: DEMO-SPEC-APPROVER-ROLE APPROVED
"@
    Write-DemoPacketText (Join-Path $drafts 'external-spec.md') ($spec.TrimStart() -replace "(?<!`r)`n", "`r`n")
}

function Write-DemoImpactArtifact {
    param([string]$Workspace, [string]$Disposition)
    $path = Join-Path $Workspace 'team-bob-work\DEMO-IMPACT-001\drafts\impact-analysis.md'
    $rows = @('RT', 'Safety', 'Board', 'Driver', 'ABI', 'Build', 'Customer Branch') | ForEach-Object { "| $_ | No change | Synthetic source inspection | $Disposition |" }
    $text = @($script:DemoPacketBanner, '# Impact Analysis', '| Area | Impact | Evidence | Disposition |', '| --- | --- | --- | --- |') + $rows + @('', 'Open QA: NONE', 'Human Approval: DEMO-IMPLEMENTATION-APPROVER-ROLE APPROVED')
    Write-DemoPacketText $path (($text -join "`r`n") + "`r`n")
}

function Write-DemoGreenEvidence {
    param([object]$Fixture)
    $task = Join-Path $Fixture.Workspace 'team-bob-work\DEMO-GREEN-001'
    Write-DemoPacketText (Join-Path $task 'results\build-result.md') "$($script:DemoPacketBanner)`r`nREADY_FOR_HUMAN_REVIEW`r`nFinal Rebuild and integrity checks succeeded.`r`n"
    Write-DemoPacketJson (Join-Path $task 'results\build-result-20260903T0000000000000Z-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.json') ([ordered]@{
        schemaVersion = '1.0'; status = 'CODE_FAILED_RETRYABLE'; exitCode = 10; taskId = 'DEMO-GREEN-001'; action = 'Make'; attempt = 0
        buildProfileId = 'demo-msbuild-protocol-v1-not-vc6'; processFinishedAt = '2026-09-03T00:00:00.0000000+00:00'
    })
    Write-DemoPacketJson (Join-Path $task 'results\build-result-20260903T0000300000000Z-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.json') ([ordered]@{
        schemaVersion = '1.0'; status = 'SUCCEEDED'; exitCode = 0; taskId = 'DEMO-GREEN-001'; action = 'Make'; attempt = 1
        buildProfileId = 'demo-msbuild-protocol-v1-not-vc6'; processFinishedAt = '2026-09-03T00:00:30.0000000+00:00'
    })
    Write-DemoPacketJson (Join-Path $task 'results\build-result-20260903T0000000000000Z-0123456789abcdef0123456789abcdef.json') ([ordered]@{
        schemaVersion = '1.0'; status = 'SUCCEEDED'; exitCode = 0; taskId = 'DEMO-GREEN-001'; action = 'Rebuild'; attempt = 1
        buildProfileId = 'demo-msbuild-protocol-v1-not-vc6'; processFinishedAt = '2026-09-03T00:01:00.0000000+00:00'
    })
    Write-DemoPacketText (Join-Path $task 'drafts\code-review.md') "$($script:DemoPacketBanner)`r`n# Code Review`r`nAllowed Files: demo/CycleWatch/src/CycleWatch.cpp only`r`nArtificial training fault replacement and three-cycle semantic repair disclosed.`r`nHuman Disposition: DEMO-INDEPENDENT-REVIEWER-ROLE APPROVED`r`n"
    Write-DemoPacketText (Join-Path $task 'results\bazaar-status.txt') " M  demo/CycleWatch/src/CycleWatch.cpp`r`n"
    Write-DemoPacketText $Fixture.RangeStatusPath " M  demo/CycleWatch/src/CycleWatch.cpp`r`n"
    $diff = @(
        "=== modified file 'demo/CycleWatch/src/CycleWatch.cpp'", '--- old/demo/CycleWatch/src/CycleWatch.cpp', '+++ new/demo/CycleWatch/src/CycleWatch.cpp',
        ('-' + $script:DemoPacketInitialFaultLine), ('+' + $script:DemoPacketRepairedFaultLine),
        '-    if (consecutiveOverruns_ >= 1U) {', '+    if (consecutiveOverruns_ >= 3U) {'
    ) -join "`r`n"
    Write-DemoPacketText (Join-Path $task 'results\bazaar-diff.patch') ($diff + "`r`n")
    Write-DemoPacketText $Fixture.RangeDiffPath ($diff + "`r`n")
    Write-DemoPacketText (Join-Path $task 'results\bazaar-nick.txt') "demo-fixture-branch`r`n"
    Write-DemoPacketText (Join-Path $task 'results\bazaar-revision-id.txt') "demo-fixture-revision-001`r`n"
    Write-DemoPacketJson (Join-Path $task 'results\bazaar-evidence-manifest.json') ([ordered]@{
        schemaVersion = '1.0'; taskId = 'DEMO-GREEN-001'; bazaarRoot = $Fixture.Workspace; bazaarPath = $Fixture.BazaarPath
        bazaarSha256 = Get-DemoPacketHash $Fixture.BazaarPath; branchNick = 'demo-fixture-branch'; revisionId = 'demo-fixture-revision-001'
        commands = @('status --short', 'diff', 'nick', 'version-info --custom --template={revision_id}')
        commandResults = @(
            [ordered]@{ command = 'status --short'; exitCode = 0 }, [ordered]@{ command = 'diff'; exitCode = 0 },
            [ordered]@{ command = 'nick'; exitCode = 0 }, [ordered]@{ command = 'version-info --custom --template={revision_id}'; exitCode = 0 }
        )
        files = @('bazaar-status.txt', 'bazaar-diff.patch', 'bazaar-nick.txt', 'bazaar-revision-id.txt')
        exportedAt = '2026-09-03T00:02:00.0000000+00:00'
    })
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$packetToolSource = Join-Path $repositoryRoot 'demo\tools\New-TeamBobDemoPacket.ps1'
Assert-True (Test-Path -LiteralPath $packetToolSource -PathType Leaf) 'Demo packet progression tool exists'

$fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('team-bob-demo-packets-' + [guid]::NewGuid().ToString('N'))
[void][System.IO.Directory]::CreateDirectory($fixtureRoot)
$savedLocalAppData = $env:LOCALAPPDATA
$savedLog = $env:TEAM_BOB_PACKET_BZR_LOG
$savedStatus = $env:TEAM_BOB_PACKET_BZR_STATUS
$savedNick = $env:TEAM_BOB_PACKET_BZR_NICK
$savedRevision = $env:TEAM_BOB_PACKET_BZR_REVISION
$savedRangeStatusFile = $env:TEAM_BOB_PACKET_BZR_RANGE_STATUS_FILE
$savedRangeDiffFile = $env:TEAM_BOB_PACKET_BZR_RANGE_DIFF_FILE
try {
    $fixture = New-DemoPacketFixture $repositoryRoot $fixtureRoot $packetToolSource
    $env:LOCALAPPDATA = $fixture.LocalAppData
    $env:TEAM_BOB_PACKET_BZR_LOG = $fixture.BazaarLog
    $env:TEAM_BOB_PACKET_BZR_STATUS = ''
    $env:TEAM_BOB_PACKET_BZR_NICK = 'demo-fixture-branch'
    $env:TEAM_BOB_PACKET_BZR_REVISION = 'demo-fixture-revision-001'
    $env:TEAM_BOB_PACKET_BZR_RANGE_STATUS_FILE = $fixture.RangeStatusPath
    $env:TEAM_BOB_PACKET_BZR_RANGE_DIFF_FILE = $fixture.RangeDiffPath
    Write-DemoPacketText $fixture.BazaarLog ''
    $bzrBefore = Get-DemoTreeFingerprint (Join-Path $fixture.Workspace '.bzr')

    $allowedPath = Join-Path $fixture.Workspace 'demo\CycleWatch\src\CycleWatch.cpp'
    $initialAllowedBytes = [System.IO.File]::ReadAllBytes($allowedPath)
    $cp932 = [System.Text.Encoding]::GetEncoding(932)

    $workspaceCommonPath = Join-Path $fixture.Workspace 'team-bob\tools\TeamBob-BuildCommon.ps1'
    $workspaceCommonBytes = [System.IO.File]::ReadAllBytes($workspaceCommonPath)
    Write-DemoPacketBytes $workspaceCommonPath ($workspaceCommonBytes + $script:DemoPacketUtf8NoBom.GetBytes("`r`n# unapproved helper tamper`r`n"))
    $tamperedHelper = Invoke-DemoPacketTool $fixture.ToolPath 'Requirements' $fixture.Workspace
    Assert-True ($tamperedHelper.ExitCode -ne 0) 'Requirements rejects a staged execution helper whose hash differs from the marker-bound distribution inventory'
    Assert-True ($tamperedHelper.Output -match 'SHA-256 does not match') 'Execution-helper tamper is rejected by the marker-bound helper hash'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture.Workspace 'team-bob-work\DEMO-REQUIREMENTS-001'))) 'Execution-helper tamper creates no Requirements task'
    [System.IO.File]::WriteAllBytes($workspaceCommonPath, $workspaceCommonBytes)

    $workspaceStartPath = Join-Path $fixture.Workspace 'team-bob\tools\Start-TeamBobTask.ps1'
    $distributionStartPath = Join-Path $fixture.DistributionRoot 'profile\team-bob\tools\Start-TeamBobTask.ps1'
    $workspaceStartBytes = [System.IO.File]::ReadAllBytes($workspaceStartPath)
    $distributionStartBytes = [System.IO.File]::ReadAllBytes($distributionStartPath)
    $inventoryBytes = [System.IO.File]::ReadAllBytes($fixture.InventoryPath)
    $approvedInventoryHash = Get-DemoPacketHash $fixture.InventoryPath
    $approvedMarkerBytes = [System.IO.File]::ReadAllBytes($fixture.MarkerPath)
    $bzrMetadataPath = Join-Path $fixture.Workspace '.bzr\branch.conf'
    $bzrMetadataBytes = [System.IO.File]::ReadAllBytes($bzrMetadataPath)
    $startText = $script:DemoPacketUtf8NoBom.GetString($workspaceStartBytes)
    $dotSourceLine = ". (Join-Path `$PSScriptRoot 'TeamBob-BuildCommon.ps1')"
    $mutation = @"
$dotSourceLine
[System.IO.File]::AppendAllText((Join-Path `$BazaarRoot '.bzr\branch.conf'), 'trusted-helper-mutation')
[System.IO.File]::AppendAllText((Join-Path `$BazaarRoot 'demo\CycleWatch\src\CycleWatch.cpp'), '// trusted-helper-mutation')
"@
    $mutatingStartBytes = $script:DemoPacketUtf8NoBom.GetBytes($startText.Replace($dotSourceLine, ($mutation.TrimEnd() -replace "(?<!`r)`n", "`r`n")))
    [System.IO.File]::WriteAllBytes($workspaceStartPath, $mutatingStartBytes)
    [System.IO.File]::WriteAllBytes($distributionStartPath, $mutatingStartBytes)
    $mutatingInventory = Get-DemoPacketJson $fixture.InventoryPath
    $startEntry = @($mutatingInventory.entries | Where-Object { $_.relativePath -ceq 'profile/team-bob/tools/Start-TeamBobTask.ps1' })[0]
    $startEntry.length = [int64]$mutatingStartBytes.Length
    $startEntry.sha256 = Get-DemoPacketHash $distributionStartPath
    Write-DemoPacketJson $fixture.InventoryPath $mutatingInventory
    $mutatingInventoryHash = Get-DemoPacketHash $fixture.InventoryPath
    $approvedMarkerText = $script:DemoPacketUtf8NoBom.GetString($approvedMarkerBytes)
    $mutatingMarkerText = $approvedMarkerText.Replace($approvedInventoryHash, $mutatingInventoryHash)
    Assert-True ($mutatingMarkerText -cne $approvedMarkerText) 'Fixture rebinds the mutating helper inventory without reserializing marker timestamps'
    Write-DemoPacketText $fixture.MarkerPath $mutatingMarkerText
    try {
        $mutatingHelper = Invoke-DemoPacketTool $fixture.ToolPath 'Requirements' $fixture.Workspace
        Assert-True ($mutatingHelper.ExitCode -ne 0) 'Requirements rejects an inventory-approved helper that mutates Allowed source or Bazaar metadata during task creation'
        Assert-True ($mutatingHelper.Output -match 'Allowed source or Bazaar metadata changed during Start-TeamBobTask execution') ('Inventory-approved mutation is rejected by the execution snapshot: ' + $mutatingHelper.Output)
    } finally {
        [System.IO.File]::WriteAllBytes($workspaceStartPath, $workspaceStartBytes)
        [System.IO.File]::WriteAllBytes($distributionStartPath, $distributionStartBytes)
        [System.IO.File]::WriteAllBytes($fixture.InventoryPath, $inventoryBytes)
        [System.IO.File]::WriteAllBytes($fixture.MarkerPath, $approvedMarkerBytes)
        [System.IO.File]::WriteAllBytes($bzrMetadataPath, $bzrMetadataBytes)
        [System.IO.File]::WriteAllBytes($allowedPath, $initialAllowedBytes)
        $mutatingTaskPath = Join-Path $fixture.Workspace 'team-bob-work\DEMO-REQUIREMENTS-001'
        if (Test-Path -LiteralPath $mutatingTaskPath -PathType Container) { [System.IO.Directory]::Delete($mutatingTaskPath, $true) }
    }

    $approvalBytes = [System.IO.File]::ReadAllBytes($fixture.ApprovalPath)
    $markerBytes = [System.IO.File]::ReadAllBytes($fixture.MarkerPath)
    $mismatchedApproval = Get-DemoPacketJson $fixture.ApprovalPath
    $mismatchedApproval.acceptedAt = '2026-09-03T00:00:02.0000000+00:00'
    Write-DemoPacketJson $fixture.ApprovalPath $mismatchedApproval
    $mismatchedMarker = Get-DemoPacketJson $fixture.MarkerPath
    $mismatchedMarker.approval.approvalSha256 = Get-DemoPacketHash $fixture.ApprovalPath
    Write-DemoPacketJson $fixture.MarkerPath $mismatchedMarker
    $mismatchedTimestamp = Invoke-DemoPacketTool $fixture.ToolPath 'Requirements' $fixture.Workspace
    Assert-True ($mismatchedTimestamp.ExitCode -ne 0) 'Requirements rejects approval acceptedAt that differs from marker recordedAt'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture.Workspace 'team-bob-work\DEMO-REQUIREMENTS-001'))) 'Approval timestamp mismatch creates no Requirements task'
    [System.IO.File]::WriteAllBytes($fixture.ApprovalPath, $approvalBytes)
    [System.IO.File]::WriteAllBytes($fixture.MarkerPath, $markerBytes)

    $rawQualificationBytes = [System.IO.File]::ReadAllBytes($fixture.RawQualificationPath)
    Write-DemoPacketText $fixture.RawQualificationPath "tampered raw qualification evidence`r`n"
    $tamperedQualification = Invoke-DemoPacketTool $fixture.ToolPath 'Requirements' $fixture.Workspace
    Assert-True ($tamperedQualification.ExitCode -ne 0) 'Requirements rejects raw qualification evidence changed after approval'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture.Workspace 'team-bob-work\DEMO-REQUIREMENTS-001'))) 'Raw qualification tamper creates no Requirements task'
    [System.IO.File]::WriteAllBytes($fixture.RawQualificationPath, $rawQualificationBytes)

    $outOfOrderImpact = Invoke-DemoPacketTool $fixture.ToolPath 'Impact' $fixture.Workspace
    Assert-True ($outOfOrderImpact.ExitCode -ne 0) 'Impact rejects phase progression before Requirements exists'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture.Workspace 'team-bob-work\DEMO-IMPACT-001'))) 'Out-of-order phase rejection creates no Impact task'

    [System.IO.File]::WriteAllBytes($allowedPath, $cp932.GetBytes($cp932.GetString($initialAllowedBytes) + "// premature edit`r`n"))
    $prematureRequirements = Invoke-DemoPacketTool $fixture.ToolPath 'Requirements' $fixture.Workspace
    Assert-True ($prematureRequirements.ExitCode -ne 0) 'Requirements rejects an Allowed File changed before Green starts'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture.Workspace 'team-bob-work\DEMO-REQUIREMENTS-001'))) 'Premature Allowed File edit creates no Requirements task'
    [System.IO.File]::WriteAllBytes($allowedPath, $initialAllowedBytes)

    $requirements = Invoke-DemoPacketTool $fixture.ToolPath 'Requirements' $fixture.Workspace
    Assert-Equal $requirements.ExitCode 0 ("Requirements packet succeeds: " + $requirements.Output)
    Assert-True ($requirements.Output -match 'NOT VC6 QUALIFICATION') 'Requirements output retains the disclaimer'
    $requirementsPacketPath = Join-Path $fixture.Workspace 'team-bob-work\DEMO-REQUIREMENTS-001\work-packet.md'
    $requirementsPacket = Get-DemoCanonicalPacket $requirementsPacketPath
    Assert-Equal $requirementsPacket.'Task ID' 'DEMO-REQUIREMENTS-001' 'Requirements uses the fixed task ID'
    Assert-Equal $requirementsPacket.Risk 'Amber' 'Requirements is a non-Green drafting task'
    Assert-Equal $requirementsPacket.'Specification Assignment ID' 'ASSIGN-DEMO-SPECIFICATION' 'Requirements records the specification assignment'
    $requirementsChainPath = Join-Path $fixture.Workspace 'team-bob-work\DEMO-REQUIREMENTS-001\results\demo-phase-chain.json'
    $requirementsChain = Get-DemoPacketJson $requirementsChainPath
    Assert-Equal $requirementsChain.currentPhase 'Requirements' 'Requirements chain records the current phase'
    Assert-Equal @($requirementsChain.entries).Count 1 'Requirements chain starts with one entry'
    Assert-DemoPacketSequence @($requirementsChain.entries[0].inputs.role) @('word-requirements', 'qa-workbook') 'Requirements chain fixes both immutable Office sources'
    foreach ($input in @($requirementsChain.entries[0].inputs)) {
        Assert-True ([System.IO.Path]::IsPathRooted([string]$input.path)) "Requirements input '$($input.role)' records an absolute path"
        Assert-Equal (Get-DemoPacketHash $input.path) $input.sha256 "Requirements input '$($input.role)' hash is exact"
    }

    Write-DemoRequirementsArtifacts $fixture.Workspace 'OPEN'
    $openQaImpact = Invoke-DemoPacketTool $fixture.ToolPath 'Impact' $fixture.Workspace
    Assert-True ($openQaImpact.ExitCode -ne 0) 'Impact rejects a requirement ledger with Open QA'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture.Workspace 'team-bob-work\DEMO-IMPACT-001'))) 'Open QA rejection creates no Impact task'
    Write-DemoRequirementsArtifacts $fixture.Workspace 'CLOSED'
    $requirementsSpecPath = Join-Path $fixture.Workspace 'team-bob-work\DEMO-REQUIREMENTS-001\drafts\external-spec.md'
    [System.IO.File]::AppendAllText($requirementsSpecPath, "`r`nOpen QA: BLOCKED`r`n", $script:DemoPacketUtf8NoBom)
    $contradictorySpecQa = Invoke-DemoPacketTool $fixture.ToolPath 'Impact' $fixture.Workspace
    Assert-True ($contradictorySpecQa.ExitCode -ne 0) ('Impact rejects an external specification that contradicts Open QA NONE with another Open QA line: ' + $contradictorySpecQa.Output)
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture.Workspace 'team-bob-work\DEMO-IMPACT-001'))) 'Contradictory specification Open QA creates no Impact task'
    Write-DemoRequirementsArtifacts $fixture.Workspace 'CLOSED'
    $impact = Invoke-DemoPacketTool $fixture.ToolPath 'Impact' $fixture.Workspace
    Assert-Equal $impact.ExitCode 0 ("Impact packet succeeds: " + $impact.Output)
    $impactChainPath = Join-Path $fixture.Workspace 'team-bob-work\DEMO-IMPACT-001\results\demo-phase-chain.json'
    $impactChain = Get-DemoPacketJson $impactChainPath
    Assert-Equal @($impactChain.entries).Count 2 'Impact chain contains Requirements and Impact entries'
    Assert-Equal $impactChain.predecessor.sha256 (Get-DemoPacketHash $requirementsChainPath) 'Impact chain fixes the predecessor chain hash'

    $specPath = Join-Path $fixture.Workspace 'team-bob-work\DEMO-REQUIREMENTS-001\drafts\external-spec.md'
    $specBytes = [System.IO.File]::ReadAllBytes($specPath)
    Write-DemoPacketText $specPath "tampered specification`r`n"
    Write-DemoImpactArtifact $fixture.Workspace 'CLEAR'
    $tamperedGreen = Invoke-DemoPacketTool $fixture.ToolPath 'Green' $fixture.Workspace
    Assert-True ($tamperedGreen.ExitCode -ne 0) 'Green rejects a prior artifact whose SHA-256 no longer matches the chain'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture.Workspace 'team-bob-work\DEMO-GREEN-001'))) 'Prior-artifact tamper rejection creates no Green task'
    [System.IO.File]::WriteAllBytes($specPath, $specBytes)

    Write-DemoImpactArtifact $fixture.Workspace 'AMBER'
    $nonGreen = Invoke-DemoPacketTool $fixture.ToolPath 'Green' $fixture.Workspace
    Assert-True ($nonGreen.ExitCode -ne 0) 'Green rejects an impact disposition that is not CLEAR'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture.Workspace 'team-bob-work\DEMO-GREEN-001'))) 'Non-Green impact rejection creates no Green task'
    Write-DemoImpactArtifact $fixture.Workspace 'CLEAR'
    $impactArtifactPath = Join-Path $fixture.Workspace 'team-bob-work\DEMO-IMPACT-001\drafts\impact-analysis.md'
    [System.IO.File]::AppendAllText($impactArtifactPath, "Open QA: BLOCKED`r`n", $script:DemoPacketUtf8NoBom)
    $contradictoryImpactQa = Invoke-DemoPacketTool $fixture.ToolPath 'Green' $fixture.Workspace
    Assert-True ($contradictoryImpactQa.ExitCode -ne 0) 'Green rejects an impact analysis that contradicts Open QA NONE with another Open QA line'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture.Workspace 'team-bob-work\DEMO-GREEN-001'))) 'Contradictory impact Open QA creates no Green task'
    Write-DemoImpactArtifact $fixture.Workspace 'CLEAR'

    $env:TEAM_BOB_PACKET_BZR_STATUS = ' M  demo/CycleWatch/src/CycleWatch.cpp'
    $dirtyGreen = Invoke-DemoPacketTool $fixture.ToolPath 'Green' $fixture.Workspace
    Assert-True ($dirtyGreen.ExitCode -ne 0) 'Green rejects a dirty Bazaar working tree'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture.Workspace 'team-bob-work\DEMO-GREEN-001'))) 'Dirty-tree rejection creates no Green task'
    $env:TEAM_BOB_PACKET_BZR_STATUS = ''

    $green = Invoke-DemoPacketTool $fixture.ToolPath 'Green' $fixture.Workspace
    Assert-Equal $green.ExitCode 0 ("Green packet succeeds: " + $green.Output)
    $greenPacketPath = Join-Path $fixture.Workspace 'team-bob-work\DEMO-GREEN-001\work-packet.md'
    $greenPacket = Get-DemoCanonicalPacket $greenPacketPath
    Assert-Equal $greenPacket.Risk 'Green' 'Green packet has Green risk'
    Assert-Equal @($greenPacket.'Open QA').Count 0 'Green packet has no Open QA'
    Assert-DemoPacketSequence @($greenPacket.'Allowed Files') @('demo/CycleWatch/src/CycleWatch.cpp') 'Green packet allows exactly one C++ file'
    Assert-Equal $greenPacket.'Build Profile ID' 'demo-msbuild-protocol-v1-not-vc6' 'Green packet uses only the demo build profile'
    Assert-Equal $greenPacket.'Implementation Assignment ID' 'ASSIGN-DEMO-IMPLEMENTATION' 'Green packet records the implementation assignment'
    Assert-Equal $greenPacket.'Independent Reviewer Assignment ID' 'ASSIGN-DEMO-INDEPENDENT-REVIEW' 'Green packet records the independent reviewer assignment'
    Assert-Equal $greenPacket.'Max-Repair-Cycles' 2 'Green packet fixes the repair limit at two'
    foreach ($field in @('RT Impact Clear', 'Safety Impact Clear', 'Board Impact Clear', 'Driver Impact Clear', 'ABI Impact Clear', 'Build Impact Clear', 'Customer Branch Impact Clear', 'Clean Working Copy')) {
        Assert-Equal $greenPacket.$field 'YES' "Green packet gate '$field' is YES"
    }
    foreach ($forbidden in @('demo/CycleWatch/CycleWatch.vcxproj', 'demo/CycleWatch/CycleWatch.dsp', 'demo/CycleWatch/CycleWatch.rc', 'demo/CycleWatch/CycleWatch.def', 'demo/CycleWatch/CycleWatch.idl', 'demo/CycleWatch/CycleWatch.mak')) {
        Assert-True (@($greenPacket.'Forbidden Areas') -contains $forbidden) "Green packet explicitly forbids $forbidden"
    }

    $allowedText = $cp932.GetString([System.IO.File]::ReadAllBytes($allowedPath))
    Assert-True ($allowedText -match 'consecutiveOverruns_\s*>=\s*1U') 'Fixture starts with the deliberate one-cycle semantic gap'
    $allowedText = $allowedText -replace 'consecutiveOverruns_\s*>=\s*1U', 'consecutiveOverruns_ >= 3U'
    [System.IO.File]::WriteAllBytes($allowedPath, $cp932.GetBytes($allowedText))

    Write-DemoGreenEvidence $fixture
    $sameRevisionTest = Invoke-DemoPacketTool $fixture.ToolPath 'Test' $fixture.Workspace
    Assert-True ($sameRevisionTest.ExitCode -ne 0) 'Test rejects a Bazaar revision that was not advanced by the human commit'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture.Workspace 'team-bob-work\DEMO-TEST-001'))) 'Same-revision rejection creates no Test task'
    $env:TEAM_BOB_PACKET_BZR_REVISION = 'demo-fixture-revision-002-after-human-commit'

    $retainedCompilerError = Invoke-DemoPacketTool $fixture.ToolPath 'Test' $fixture.Workspace
    Assert-True ($retainedCompilerError.ExitCode -ne 0) 'Test rejects a retained initial #error after the repair cycle'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture.Workspace 'team-bob-work\DEMO-TEST-001'))) 'Retained #error rejection creates no Test task'
    $allowedText = $allowedText.Replace($script:DemoPacketInitialFaultLine, $script:DemoPacketRepairedFaultLine)
    Assert-True ($allowedText -notmatch '(?m)^#error\s+MSBUILD_DEMO_ADAPTER_INTENTIONAL_COMPILER_FAULT') 'Fixture removes the exact initial compiler fault line'
    Assert-Equal ([regex]::Matches($allowedText, [regex]::Escape($script:DemoPacketRepairedFaultLine))).Count 1 'Fixture installs exactly one approved pragma repair marker'
    [System.IO.File]::WriteAllBytes($allowedPath, $cp932.GetBytes($allowedText))

    $rangeDiffBytes = [System.IO.File]::ReadAllBytes($fixture.RangeDiffPath)
    [System.IO.File]::AppendAllText($fixture.RangeDiffPath, "+// unauthorized third revision delta`r`n", $script:DemoPacketUtf8NoBom)
    $thirdRevisionDelta = Invoke-DemoPacketTool $fixture.ToolPath 'Test' $fixture.Workspace
    Assert-True ($thirdRevisionDelta.ExitCode -ne 0) 'Test rejects a committed revision range with a third changed line in the Allowed File'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture.Workspace 'team-bob-work\DEMO-TEST-001'))) 'Third revision delta creates no Test task'
    [System.IO.File]::WriteAllBytes($fixture.RangeDiffPath, $rangeDiffBytes)

    [System.IO.File]::AppendAllText($fixture.RangeDiffPath, "=== modified file 'README.md'`r`n", $script:DemoPacketUtf8NoBom)
    $extraFileRevisionDelta = Invoke-DemoPacketTool $fixture.ToolPath 'Test' $fixture.Workspace
    Assert-True ($extraFileRevisionDelta.ExitCode -ne 0) 'Test rejects a committed revision range that includes an extra file'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture.Workspace 'team-bob-work\DEMO-TEST-001'))) 'Extra-file revision delta creates no Test task'
    [System.IO.File]::WriteAllBytes($fixture.RangeDiffPath, $rangeDiffBytes)

    $env:TEAM_BOB_PACKET_BZR_REVISION = 'unsafe..revision'
    $unsafeRevision = Invoke-DemoPacketTool $fixture.ToolPath 'Test' $fixture.Workspace
    Assert-True ($unsafeRevision.ExitCode -ne 0) 'Test rejects an unsafe Bazaar revision ID before composing a revision range'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture.Workspace 'team-bob-work\DEMO-TEST-001'))) 'Unsafe Bazaar revision ID creates no Test task'
    $env:TEAM_BOB_PACKET_BZR_REVISION = 'demo-fixture-revision-002-after-human-commit'

    $failedBuildPath = Join-Path $fixture.Workspace 'team-bob-work\DEMO-GREEN-001\results\build-result-20260903T0000000000000Z-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.json'
    $failedBuildBytes = [System.IO.File]::ReadAllBytes($failedBuildPath)
    $invalidBuildSequence = Get-DemoPacketJson $failedBuildPath
    $invalidBuildSequence.status = 'SUCCEEDED'
    $invalidBuildSequence.exitCode = 0
    Write-DemoPacketJson $failedBuildPath $invalidBuildSequence
    $invalidBuildResult = Invoke-DemoPacketTool $fixture.ToolPath 'Test' $fixture.Workspace
    Assert-True ($invalidBuildResult.ExitCode -ne 0) 'Test rejects build JSON that does not prove exactly one retryable compiler failure'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture.Workspace 'team-bob-work\DEMO-TEST-001'))) 'Invalid build sequence creates no Test task'
    [System.IO.File]::WriteAllBytes($failedBuildPath, $failedBuildBytes)

    $extraBuildPath = Join-Path $fixture.Workspace 'team-bob-work\DEMO-GREEN-001\results\build-result-20260903T0002000000000Z-cccccccccccccccccccccccccccccccc.json'
    Write-DemoPacketJson $extraBuildPath ([ordered]@{
        schemaVersion = '1.0'; status = 'SUCCEEDED'; exitCode = 0; taskId = 'DEMO-GREEN-001'; action = 'Rebuild'; attempt = 2
        buildProfileId = 'demo-msbuild-protocol-v1-not-vc6'; processFinishedAt = '2026-09-03T00:02:00.0000000+00:00'
    })
    $extraBuildResult = Invoke-DemoPacketTool $fixture.ToolPath 'Test' $fixture.Workspace
    Assert-True ($extraBuildResult.ExitCode -ne 0) 'Test rejects an extra attempt-2 machine result'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture.Workspace 'team-bob-work\DEMO-TEST-001'))) 'Extra machine result creates no Test task'
    [System.IO.File]::Delete($extraBuildPath)

    $finalBuildPath = Join-Path $fixture.Workspace 'team-bob-work\DEMO-GREEN-001\results\build-result-20260903T0000000000000Z-0123456789abcdef0123456789abcdef.json'
    $finalBuildBytes = [System.IO.File]::ReadAllBytes($finalBuildPath)
    $makeOnlySequence = Get-DemoPacketJson $finalBuildPath
    $makeOnlySequence.action = 'Make'
    $makeOnlySequence.attempt = 2
    Write-DemoPacketJson $finalBuildPath $makeOnlySequence
    $makeOnlyResult = Invoke-DemoPacketTool $fixture.ToolPath 'Test' $fixture.Workspace
    Assert-True ($makeOnlyResult.ExitCode -ne 0) 'Test rejects a Make-only sequence without the fixed final Rebuild'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture.Workspace 'team-bob-work\DEMO-TEST-001'))) 'Make-only machine sequence creates no Test task'
    [System.IO.File]::WriteAllBytes($finalBuildPath, $finalBuildBytes)

    $manifestPath = Join-Path $fixture.Workspace 'team-bob-work\DEMO-GREEN-001\results\bazaar-evidence-manifest.json'
    $manifestBytes = [System.IO.File]::ReadAllBytes($manifestPath)
    $duplicateManifest = Get-DemoPacketJson $manifestPath
    $duplicateManifest.commandResults[1].command = 'status --short'
    Write-DemoPacketJson $manifestPath $duplicateManifest
    $duplicateCommandResult = Invoke-DemoPacketTool $fixture.ToolPath 'Test' $fixture.Workspace
    Assert-True ($duplicateCommandResult.ExitCode -ne 0) 'Test rejects duplicated Bazaar commandResults even when count remains four'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $fixture.Workspace 'team-bob-work\DEMO-TEST-001'))) 'Duplicate Bazaar command rejection creates no Test task'
    [System.IO.File]::WriteAllBytes($manifestPath, $manifestBytes)

    $testPhase = Invoke-DemoPacketTool $fixture.ToolPath 'Test' $fixture.Workspace
    Assert-Equal $testPhase.ExitCode 0 ("Test packet succeeds after the human revision advances: " + $testPhase.Output)
    $testPacketPath = Join-Path $fixture.Workspace 'team-bob-work\DEMO-TEST-001\work-packet.md'
    $testPacket = Get-DemoCanonicalPacket $testPacketPath
    Assert-Equal $testPacket.'Task ID' 'DEMO-TEST-001' 'Test uses a task distinct from Green'
    Assert-Equal $testPacket.Risk 'Amber' 'Test is a non-Green drafting task'
    Assert-Equal $testPacket.'Bazaar Full Revision ID' 'demo-fixture-revision-002-after-human-commit' 'Test records the new full revision ID'
    Assert-Equal $testPacket.'Independent Reviewer Assignment ID' 'ASSIGN-DEMO-INDEPENDENT-REVIEW' 'Test records the independent-review assignment'
    $testChain = Get-DemoPacketJson (Join-Path $fixture.Workspace 'team-bob-work\DEMO-TEST-001\results\demo-phase-chain.json')
    Assert-Equal @($testChain.entries).Count 4 'Test chain contains all four phases'
    Assert-DemoPacketSequence @($testChain.entries.phase) @('Requirements', 'Impact', 'Green', 'Test') 'Phase chain order is fixed'
    $testInputs = @($testChain.entries[3].inputs)
    foreach ($role in @('implementation-source', 'build-summary', 'final-build-result', 'code-review', 'bazaar-status', 'bazaar-diff', 'bazaar-nick', 'bazaar-revision', 'bazaar-manifest')) {
        Assert-Equal @($testInputs | Where-Object { $_.role -ceq $role }).Count 1 "Test chain fixes one $role evidence item"
    }
    Assert-DemoPacketSequence @($testInputs | Where-Object { $_.role -like 'build-invocation-*' } | ForEach-Object role) @('build-invocation-000', 'build-invocation-001') 'Test chain fixes both pre-Rebuild machine invocations in order'
    foreach ($input in $testInputs) { Assert-Equal (Get-DemoPacketHash $input.path) $input.sha256 "Test evidence '$($input.role)' hash is exact" }

    $commands = @(Get-Content -LiteralPath $fixture.BazaarLog | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    Assert-True ($commands.Count -gt 0) 'Packet progression performs Bazaar preflight reads'
    foreach ($command in $commands) {
        Assert-True ($command -match '^(status --short|nick|version-info --custom --template=\{revision_id\}|status --short --revision revid:[A-Za-z0-9@._+:/=-]+\.\.revid:[A-Za-z0-9@._+:/=-]+|diff --revision revid:[A-Za-z0-9@._+:/=-]+\.\.revid:[A-Za-z0-9@._+:/=-]+)$') "Packet tool invokes only an approved Bazaar read: $command"
    }
    Assert-True (-not (($commands -join "`n") -match '(?im)^(init|add|commit|merge|tag|whoami|push|pull|remove|delete)(?:\s|$)')) 'Packet tool invokes zero Bazaar mutation or identity commands'
    Assert-Equal (Get-DemoTreeFingerprint (Join-Path $fixture.Workspace '.bzr')) $bzrBefore 'All packet phases preserve .bzr bytes'
    $allChainText = [System.IO.File]::ReadAllText((Join-Path $fixture.Workspace 'team-bob-work\DEMO-TEST-001\results\demo-phase-chain.json'), [System.Text.Encoding]::UTF8)
    Assert-True ($allChainText -notmatch '(?i)"(person|operator|member|name|email|account|user)"\s*:') 'Phase chain has no personal-identity field'
} finally {
    $env:LOCALAPPDATA = $savedLocalAppData
    if ($null -eq $savedLog) { Remove-Item Env:TEAM_BOB_PACKET_BZR_LOG -ErrorAction SilentlyContinue } else { $env:TEAM_BOB_PACKET_BZR_LOG = $savedLog }
    if ($null -eq $savedStatus) { Remove-Item Env:TEAM_BOB_PACKET_BZR_STATUS -ErrorAction SilentlyContinue } else { $env:TEAM_BOB_PACKET_BZR_STATUS = $savedStatus }
    if ($null -eq $savedNick) { Remove-Item Env:TEAM_BOB_PACKET_BZR_NICK -ErrorAction SilentlyContinue } else { $env:TEAM_BOB_PACKET_BZR_NICK = $savedNick }
    if ($null -eq $savedRevision) { Remove-Item Env:TEAM_BOB_PACKET_BZR_REVISION -ErrorAction SilentlyContinue } else { $env:TEAM_BOB_PACKET_BZR_REVISION = $savedRevision }
    if ($null -eq $savedRangeStatusFile) { Remove-Item Env:TEAM_BOB_PACKET_BZR_RANGE_STATUS_FILE -ErrorAction SilentlyContinue } else { $env:TEAM_BOB_PACKET_BZR_RANGE_STATUS_FILE = $savedRangeStatusFile }
    if ($null -eq $savedRangeDiffFile) { Remove-Item Env:TEAM_BOB_PACKET_BZR_RANGE_DIFF_FILE -ErrorAction SilentlyContinue } else { $env:TEAM_BOB_PACKET_BZR_RANGE_DIFF_FILE = $savedRangeDiffFile }
    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\')
    $fixtureFull = [System.IO.Path]::GetFullPath($fixtureRoot).TrimEnd('\')
    if ($fixtureFull.StartsWith($tempRoot + '\', [System.StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $fixtureFull) -match '^team-bob-demo-packets-[0-9a-f]{32}$') {
        [System.IO.Directory]::Delete($fixtureFull, $true)
    }
}

$demoPacketAssertionCount = $script:Assertions - $demoPacketAssertionsBefore
Write-Host "PASS: $demoPacketAssertionCount demo packet assertions"

if ($demoPacketStandalone) { exit 0 }
