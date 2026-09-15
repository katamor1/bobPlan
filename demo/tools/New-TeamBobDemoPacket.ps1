[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Requirements', 'Impact', 'Green', 'Test')]
    [string]$Phase
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$script:DemoBanner = 'MSBUILD DEMO ADAPTER ' + [char]0x2014 + ' NOT VC6 QUALIFICATION'
$script:DemoProfileId = 'demo-msbuild-protocol-v1-not-vc6'
$script:RequirementId = 'REQ-CYCLEWATCH-001'
$script:AllowedFile = 'demo/CycleWatch/src/CycleWatch.cpp'
$script:PhaseNames = @('Requirements', 'Impact', 'Green', 'Test')
$script:TaskIds = @{
    Requirements = 'DEMO-REQUIREMENTS-001'
    Impact = 'DEMO-IMPACT-001'
    Green = 'DEMO-GREEN-001'
    Test = 'DEMO-TEST-001'
}
$script:SpecificationRole = 'DEMO-SPEC-APPROVER-ROLE'
$script:ImplementationRole = 'DEMO-IMPLEMENTATION-APPROVER-ROLE'
$script:IndependentReviewRole = 'DEMO-INDEPENDENT-REVIEWER-ROLE'
$script:SpecificationAssignmentId = 'ASSIGN-DEMO-SPECIFICATION'
$script:ImplementationAssignmentId = 'ASSIGN-DEMO-IMPLEMENTATION'
$script:IndependentReviewerAssignmentId = 'ASSIGN-DEMO-INDEPENDENT-REVIEW'
$script:InitialFaultLine = '#error MSBUILD_DEMO_ADAPTER_INTENTIONAL_COMPILER_FAULT "demo/CycleWatch/src/CycleWatch.cpp" AFTER_EVIDENCE_REPLACE_THIS_EXACT_LINE_WITH: #pragma message("MSBUILD_DEMO_ADAPTER_INTENTIONAL_FAULT_REPAIRED demo/CycleWatch/src/CycleWatch.cpp")'
$script:RepairedFaultLine = '#pragma message("MSBUILD_DEMO_ADAPTER_INTENTIONAL_FAULT_REPAIRED demo/CycleWatch/src/CycleWatch.cpp")'
$script:ForbiddenAreas = @(
    'actual-machine', 'control-network', 'mainline', 'secrets',
    'demo/CycleWatch/CycleWatch.vcxproj', 'demo/CycleWatch/CycleWatch.dsp', 'demo/CycleWatch/CycleWatch.rc',
    'demo/CycleWatch/CycleWatch.def', 'demo/CycleWatch/CycleWatch.idl', 'demo/CycleWatch/CycleWatch.mak'
)

function Get-DemoBootstrapHash {
    param([string]$Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() } finally { $stream.Dispose() }
    } finally { $sha.Dispose() }
}

function Read-DemoBootstrapJson {
    param([string]$Path, [string]$Label)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "$Label is missing: $Path" }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { throw "$Label must be UTF-8 without BOM." }
    try {
        $text = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($bytes)
        return ($text | ConvertFrom-Json)
    } catch { throw "$Label is not strict JSON/UTF-8: $($_.Exception.Message)" }
}

function Assert-DemoBootstrapNoReparse {
    param([string]$Path, [string]$Label)
    $full = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($full)
    $current = $root
    foreach ($part in $full.Substring($root.Length).Split([char[]]@('\', '/'), [System.StringSplitOptions]::RemoveEmptyEntries)) {
        $current = Join-Path $current $part
        if (-not (Test-Path -LiteralPath $current)) { throw "$Label path component is missing: $current" }
        if (([System.IO.File]::GetAttributes($current) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw "$Label contains a reparse point: $current" }
    }
    return $full.TrimEnd('\', '/')
}

$scriptRoot = Assert-DemoBootstrapNoReparse $PSScriptRoot 'Packet tool root'
$demoRoot = Assert-DemoBootstrapNoReparse (Split-Path -Parent $scriptRoot) 'Demo root'
if (-not (Split-Path -Leaf $scriptRoot).Equals('tools', [System.StringComparison]::OrdinalIgnoreCase)) { throw 'Packet tool must run from the staged DemoRoot tools directory.' }
$markerPath = Join-Path $demoRoot '.team-bob-demo-marker.json'
$bootstrapMarker = Read-DemoBootstrapJson $markerPath 'Demo root marker'
if ($null -eq $bootstrapMarker.paths -or $null -eq $bootstrapMarker.hashes -or
    [string]$bootstrapMarker.paths.lifecycleCommon -cne 'tools/TeamBob-BuildCommon.ps1' -or
    [string]$bootstrapMarker.hashes.lifecycleCommon -notmatch '^[0-9a-f]{64}$') {
    throw 'Demo marker does not contain the staged lifecycle helper identity.'
}
$commonPath = Assert-DemoBootstrapNoReparse (Join-Path $demoRoot 'tools\TeamBob-BuildCommon.ps1') 'Staged lifecycle helper'
if ((Get-DemoBootstrapHash $commonPath) -cne [string]$bootstrapMarker.hashes.lifecycleCommon) { throw 'Staged lifecycle helper hash does not match the marker.' }
. $commonPath

function Assert-DemoRequiredProperties {
    param([object]$Object, [string[]]$Names, [string]$Label)
    if ($null -eq $Object -or -not ($Object -is [System.Management.Automation.PSCustomObject])) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' "$Label must be a JSON object.") }
    foreach ($name in $Names) {
        if ($null -eq $Object.PSObject.Properties[$name]) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' "$Label is missing required field '$name'.") }
    }
}

function Resolve-DemoRootPath {
    param([string]$RelativePath, [string]$Label, [ValidateSet('Leaf', 'Container')][string]$PathType)
    $resolved = ConvertTo-TeamBobRelativePath $demoRoot $RelativePath $Label 'INTEGRITY_FAILED'
    [void](Get-TeamBobPhysicalPath $resolved.FullPath $Label $PathType 'INTEGRITY_FAILED')
    return $resolved.FullPath
}

function Assert-DemoHash {
    param([string]$Path, [object]$Expected, [string]$Label)
    if (-not ($Expected -is [string]) -or [string]$Expected -notmatch '^[0-9a-f]{64}$' -or (Get-TeamBobFileHash $Path) -cne [string]$Expected) {
        throw (New-TeamBobFailure 'INTEGRITY_FAILED' "$Label SHA-256 does not match the approved marker/chain.")
    }
}

function Get-DemoRawJsonRoundtripTimestamp {
    param([string]$Path, [string]$PropertyName, [string]$Label)
    $text = Read-TeamBobUtf8File $Path $Label 'INTEGRITY_FAILED'
    $pattern = '"' + [regex]::Escape($PropertyName) + '"\s*:\s*"(?<value>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{7}(?:Z|[+-][0-9]{2}:[0-9]{2}))"'
    $matches = [regex]::Matches($text, $pattern)
    if ($matches.Count -ne 1) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' "$Label must contain exactly one JSON string '$PropertyName' in round-trip form.") }
    $timestampText = $matches[0].Groups['value'].Value
    $parsed = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParseExact($timestampText, 'o', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) {
        throw (New-TeamBobFailure 'INTEGRITY_FAILED' "$Label property '$PropertyName' is not a valid round-trip timestamp.")
    }
    return [pscustomobject]@{ Text = $timestampText; Value = $parsed }
}

function Assert-DemoApprovalRecord {
    param([object]$Marker)
    Assert-DemoRequiredProperties $Marker.approval @('recordId', 'recordedAt', 'approvalRelativePath', 'approvalSha256') 'Demo marker approval'
    if ([string]::IsNullOrWhiteSpace([string]$Marker.approval.recordId) -or [string]::IsNullOrWhiteSpace([string]$Marker.approval.recordedAt)) {
        throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Demo marker has no completed qualification approval.')
    }
    $approvalPath = Resolve-DemoRootPath ([string]$Marker.approval.approvalRelativePath) 'Qualification approval record' 'Leaf'
    Assert-DemoHash $approvalPath $Marker.approval.approvalSha256 'Qualification approval record'
    $record = Read-TeamBobJsonFile $approvalPath 'Qualification approval record' 'INTEGRITY_FAILED'
    Assert-TeamBobExactProperties $record @(
        'schemaVersion', 'banner', 'recordType', 'recordId', 'demoProfileId', 'demoInstanceId', 'pcId',
        'rawQualificationRelativePath', 'rawQualificationSha256', 'acceptedAt', 'acceptNotVc6', 'approved', 'vc6Qualified',
        'targetPcReviewRole', 'operationsApprovalRole'
    ) 'Qualification approval record' 'INTEGRITY_FAILED'
    if ($record.schemaVersion -cne '1.0' -or $record.banner -cne $script:DemoBanner -or $record.recordType -cne 'DEMO_ONLY_QUALIFICATION_APPROVAL' -or
        $record.recordId -cne $Marker.approval.recordId -or $record.demoProfileId -cne $script:DemoProfileId -or
        $record.demoInstanceId -cne $Marker.demoInstanceId -or $record.pcId -cne [Environment]::MachineName -or
        $record.acceptNotVc6 -cne 'YES' -or $record.approved -isnot [bool] -or -not $record.approved -or
        $record.vc6Qualified -isnot [bool] -or $record.vc6Qualified -or
        $record.targetPcReviewRole -cne 'DEMO-TARGET-PC-OWNER-ROLE' -or $record.operationsApprovalRole -cne 'DEMO-OPERATIONS-OWNER-ROLE') {
        throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Qualification approval record is not the approved demo-only NOT-VC6 record.')
    }
    if ($Marker.paths.rawQualification -cne 'evidence/qualification/demo-adapter-qualification.json' -or
        $record.rawQualificationRelativePath -cne $Marker.paths.rawQualification -or
        -not ($record.rawQualificationSha256 -is [string]) -or [string]$record.rawQualificationSha256 -notmatch '^[0-9a-f]{64}$' -or
        $record.rawQualificationSha256 -cne $Marker.hashes.rawQualification) {
        throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Qualification approval does not bind the fixed raw qualification evidence path and SHA-256.')
    }
    $rawQualificationPath = Resolve-DemoRootPath ([string]$Marker.paths.rawQualification) 'Raw qualification evidence' 'Leaf'
    Assert-DemoHash $rawQualificationPath $record.rawQualificationSha256 'Raw qualification evidence'
    $acceptedAt = Get-DemoRawJsonRoundtripTimestamp $approvalPath 'acceptedAt' 'Qualification approval record'
    $markerRecordedAt = Get-DemoRawJsonRoundtripTimestamp $markerPath 'recordedAt' 'Demo root marker approval'
    if ($acceptedAt.Text -cne $markerRecordedAt.Text) {
        throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Qualification acceptedAt and marker recordedAt must be identical round-trip timestamps.')
    }
}

function Get-DemoApprovedExecutionHelpers {
    param([object]$Marker, [string]$Workspace, [string]$WorkspacePhysical)
    if ($Marker.paths.distributionInventory -cne 'evidence/distribution-inventory.json' -or
        -not ($Marker.hashes.distributionInventory -is [string]) -or [string]$Marker.hashes.distributionInventory -notmatch '^[0-9a-f]{64}$') {
        throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Demo marker does not bind the fixed distribution inventory.')
    }
    $inventoryPath = Resolve-DemoRootPath ([string]$Marker.paths.distributionInventory) 'Distribution inventory evidence' 'Leaf'
    Assert-DemoHash $inventoryPath $Marker.hashes.distributionInventory 'Distribution inventory evidence'
    $inventory = Read-TeamBobJsonFile $inventoryPath 'Distribution inventory evidence' 'INTEGRITY_FAILED'
    Assert-TeamBobExactProperties $inventory @('schemaVersion', 'banner', 'distributionRoot', 'recordedAt', 'entries') 'Distribution inventory evidence' 'INTEGRITY_FAILED'
    if ($inventory.schemaVersion -cne '1.0' -or $inventory.banner -cne $script:DemoBanner -or
        [string]::IsNullOrWhiteSpace([string]$Marker.distributionRoot) -or $inventory.distributionRoot -cne $Marker.distributionRoot) {
        throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Distribution inventory identity does not match the approved marker.')
    }
    $distributionRoot = Get-TeamBobCanonicalPath ([string]$Marker.distributionRoot) 'Distribution root' 'INTEGRITY_FAILED'
    $distributionPhysical = Get-TeamBobPhysicalPath $distributionRoot 'Distribution root' 'Container' 'INTEGRITY_FAILED'
    $definitions = @(
        [pscustomobject]@{ RelativePath = 'profile/team-bob/tools/Start-TeamBobTask.ps1'; WorkspaceRelativePath = 'team-bob/tools/Start-TeamBobTask.ps1'; Label = 'Staged Start-TeamBobTask.ps1' },
        [pscustomobject]@{ RelativePath = 'profile/team-bob/tools/TeamBob-BuildCommon.ps1'; WorkspaceRelativePath = 'team-bob/tools/TeamBob-BuildCommon.ps1'; Label = 'Staged task lifecycle helper' }
    )
    $approved = @()
    foreach ($definition in $definitions) {
        $matches = @($inventory.entries | Where-Object { $_.relativePath -ceq $definition.RelativePath })
        if ($matches.Count -ne 1) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' "$($definition.Label) must have exactly one distribution inventory entry.") }
        $entry = $matches[0]
        Assert-TeamBobExactProperties $entry @('relativePath', 'length', 'sha256') "$($definition.Label) inventory entry" 'INTEGRITY_FAILED'
        if (-not (Test-TeamBobInteger $entry.length) -or [int64]$entry.length -lt 0 -or
            -not ($entry.sha256 -is [string]) -or [string]$entry.sha256 -notmatch '^[0-9a-f]{64}$') {
            throw (New-TeamBobFailure 'INTEGRITY_FAILED' "$($definition.Label) inventory entry is invalid.")
        }
        $distributionFile = ConvertTo-TeamBobRelativePath $distributionRoot $definition.RelativePath "$($definition.Label) distribution source" 'INTEGRITY_FAILED'
        $distributionFilePhysical = Get-TeamBobPhysicalPath $distributionFile.FullPath "$($definition.Label) distribution source" 'Leaf' 'INTEGRITY_FAILED'
        Assert-TeamBobPhysicalChild $distributionFilePhysical $distributionPhysical "$($definition.Label) distribution source" 'INTEGRITY_FAILED'
        Assert-DemoHash $distributionFile.FullPath $entry.sha256 "$($definition.Label) distribution source"
        if ((Get-Item -LiteralPath $distributionFile.FullPath).Length -ne [int64]$entry.length) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' "$($definition.Label) distribution length is invalid.") }

        $workspaceFile = ConvertTo-TeamBobRelativePath $Workspace $definition.WorkspaceRelativePath $definition.Label 'INTEGRITY_FAILED'
        $workspaceFilePhysical = Get-TeamBobPhysicalPath $workspaceFile.FullPath $definition.Label 'Leaf' 'INTEGRITY_FAILED'
        Assert-TeamBobPhysicalChild $workspaceFilePhysical $WorkspacePhysical $definition.Label 'INTEGRITY_FAILED'
        Assert-DemoHash $workspaceFile.FullPath $entry.sha256 $definition.Label
        if ((Get-Item -LiteralPath $workspaceFile.FullPath).Length -ne [int64]$entry.length) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' "$($definition.Label) length differs from the approved inventory.") }
        $approved += [pscustomobject]@{ Path = $workspaceFile.FullPath; Sha256 = [string]$entry.sha256 }
    }
    return [pscustomobject]@{ InventoryPath = $inventoryPath; Helpers = @($approved) }
}

function Get-DemoApprovedContext {
    $marker = Read-TeamBobJsonFile $markerPath 'Demo root marker' 'INTEGRITY_FAILED'
    Assert-DemoRequiredProperties $marker @(
        'schemaVersion', 'banner', 'demoProfileId', 'demoInstanceId', 'distributionRoot', 'demoRoot', 'pcId', 'userSid', 'state',
        'bazaarPath', 'bazaarSha256', 'paths', 'hashes', 'approval'
    ) 'Demo root marker'
    Assert-DemoRequiredProperties $marker.paths @('workspace', 'catalog', 'lifecycleCommon', 'initialAllowedFile', 'rawQualification', 'distributionInventory', 'environmentRegistration') 'Demo marker paths'
    Assert-DemoRequiredProperties $marker.hashes @('catalog', 'lifecycleCommon', 'initialAllowedFile', 'rawQualification', 'distributionInventory', 'demoEnvironment') 'Demo marker hashes'
    $currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    if ($marker.schemaVersion -cne '1.0' -or $marker.banner -cne $script:DemoBanner -or $marker.demoProfileId -cne $script:DemoProfileId -or
        [string]$marker.demoInstanceId -notmatch '^[0-9a-f]{32}$' -or $marker.demoRoot -cne $demoRoot -or
        $marker.pcId -cne [Environment]::MachineName -or $marker.userSid -cne $currentSid -or $marker.state -cne 'APPROVED') {
        throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Packet creation requires the matching APPROVED staged demo marker on this PC and Windows identity.')
    }
    if ($marker.paths.workspace -cne 'workspace' -or $marker.paths.catalog -cne 'workspace/team-bob/config/vc6-build-targets.json' -or
        $marker.paths.initialAllowedFile -cne 'workspace/demo/CycleWatch/src/CycleWatch.cpp') {
        throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Demo marker workspace/catalog paths are not the fixed staged layout.')
    }
    $workspace = Resolve-DemoRootPath $marker.paths.workspace 'Staged workspace' 'Container'
    $currentDirectory = Get-TeamBobCanonicalPath ((Get-Location).ProviderPath) 'Current directory' 'INTEGRITY_FAILED'
    if (-not $currentDirectory.Equals($workspace, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Run New-TeamBobDemoPacket.ps1 with the staged workspace as the current directory.')
    }
    if (-not (Test-Path -LiteralPath (Join-Path $workspace '.bzr') -PathType Container)) {
        throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Human-created Bazaar metadata is missing from the staged workspace.')
    }
    $workspacePhysical = Get-TeamBobPhysicalPath $workspace 'Staged workspace' 'Container' 'INTEGRITY_FAILED'
    $bzrPhysical = Get-TeamBobPhysicalPath (Join-Path $workspace '.bzr') 'Bazaar metadata root' 'Container' 'INTEGRITY_FAILED'
    Assert-TeamBobPhysicalChild $bzrPhysical $workspacePhysical 'Bazaar metadata root' 'INTEGRITY_FAILED'

    $approvedExecution = Get-DemoApprovedExecutionHelpers $marker $workspace $workspacePhysical

    Assert-DemoApprovalRecord $marker
    $initialAllowedFilePath = Resolve-DemoRootPath $marker.paths.initialAllowedFile 'Initial Allowed File' 'Leaf'
    if ([string]$marker.hashes.initialAllowedFile -notmatch '^[0-9a-f]{64}$') { throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Initial Allowed File marker hash is invalid.') }
    $catalogPath = Resolve-DemoRootPath $marker.paths.catalog 'Approved demo catalog' 'Leaf'
    Assert-DemoHash $catalogPath $marker.hashes.catalog 'Approved demo catalog'
    $profileRoot = Join-Path $workspace 'team-bob'
    $manifestPath = Join-Path $profileRoot 'profile-manifest.json'
    $workSchemaPath = Join-Path $profileRoot 'config\work-packet.schema.json'
    $buildSchemaPath = Join-Path $profileRoot 'config\vc6-build-targets.schema.json'
    $environment = Get-TeamBobLocalEnvironment $manifestPath $workSchemaPath $buildSchemaPath -BazaarOnly -RootFailureStatus 'INTEGRITY_FAILED'
    $environmentPath = Get-TeamBobCanonicalPath ([string]$marker.paths.environmentRegistration) 'Marker environment registration' 'INTEGRITY_FAILED'
    if (-not (Test-Path -LiteralPath $environmentPath -PathType Leaf)) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Marker environment registration is missing.') }
    if (-not $environmentPath.Equals((Join-Path (Get-TeamBobCanonicalPath $env:LOCALAPPDATA) 'IBM\BobTeamProfile\vc6-machine-control-poc\v0.2.0-poc\environment.json'), [System.StringComparison]::OrdinalIgnoreCase)) {
        throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Marker environment registration does not match current LOCALAPPDATA.')
    }
    Assert-DemoHash $environmentPath $marker.hashes.demoEnvironment 'Demo environment registration'
    if (-not $environment.bazaarPath.Equals([string]$marker.bazaarPath, [System.StringComparison]::OrdinalIgnoreCase) -or
        $environment.bazaarSha256 -cne $marker.bazaarSha256) {
        throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Registered Bazaar identity does not match the approved demo marker.')
    }
    [void](Get-TeamBobBuildProfile $catalogPath $script:DemoProfileId $environment.pcId)
    return [pscustomobject]@{
        Marker = $marker; Workspace = $workspace; WorkspacePhysical = $workspacePhysical; Environment = $environment
        ProfileRoot = $profileRoot; CatalogPath = $catalogPath; EnvironmentPath = $environmentPath
        DistributionInventoryPath = $approvedExecution.InventoryPath; ApprovedExecutionHelpers = @($approvedExecution.Helpers)
        MarkerSha256 = Get-TeamBobFileHash $markerPath; InitialAllowedFilePath = $initialAllowedFilePath
        InitialAllowedFileSha256 = [string]$marker.hashes.initialAllowedFile
    }
}

function Assert-DemoApprovedContextUnchanged {
    param([object]$Context, [string]$Stage)
    if ((Get-TeamBobFileHash $markerPath) -cne $Context.MarkerSha256 -or
        (Get-TeamBobFileHash $Context.CatalogPath) -cne [string]$Context.Marker.hashes.catalog -or
        (Get-TeamBobFileHash $Context.EnvironmentPath) -cne [string]$Context.Marker.hashes.demoEnvironment -or
        (Get-TeamBobFileHash $commonPath) -cne [string]$Context.Marker.hashes.lifecycleCommon -or
        (Get-TeamBobFileHash $Context.DistributionInventoryPath) -cne [string]$Context.Marker.hashes.distributionInventory) {
        throw (New-TeamBobFailure 'INTEGRITY_FAILED' "Approved marker, catalog, environment, or helper changed during $Stage.")
    }
    foreach ($helper in @($Context.ApprovedExecutionHelpers)) {
        Assert-DemoHash $helper.Path $helper.Sha256 'Approved execution helper'
    }
}

function Invoke-DemoBazaarProcess {
    param([object]$Context, [string[]]$Arguments, [int[]]$AllowedExitCodes = @(0))
    Push-Location -LiteralPath $Context.Workspace
    try {
        $lines = @(& $Context.Environment.bazaarPath @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    } finally { Pop-Location }
    if ($AllowedExitCodes -notcontains [int]$exitCode) { throw (New-TeamBobFailure 'ENVIRONMENT_FAILED' "Bazaar read failed with exit code $exitCode.") }
    return (($lines | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine).TrimEnd()
}

function Invoke-DemoBazaarRead {
    param([object]$Context, [string[]]$Arguments)
    $allowed = @(
        'status --short',
        'nick',
        'version-info --custom --template={revision_id}'
    )
    if ($allowed -notcontains ($Arguments -join ' ')) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Unsupported Bazaar command requested by packet tool.') }
    $output = Invoke-DemoBazaarProcess $Context $Arguments
    if (($Arguments -join ' ') -eq 'status --short') { return $output }
    return $output.Trim()
}

function ConvertTo-DemoBazaarRevisionSpec {
    param([string]$RevisionId, [string]$Label)
    if ([string]::IsNullOrWhiteSpace($RevisionId) -or $RevisionId.Length -gt 255 -or
        $RevisionId -notmatch '^[A-Za-z0-9][A-Za-z0-9@._+:/=-]*$' -or $RevisionId.Contains('..')) {
        throw (New-TeamBobFailure 'INTEGRITY_FAILED' "$Label is not a safe full Bazaar revision ID.")
    }
    return 'revid:' + $RevisionId
}

function Invoke-DemoBazaarRangeRead {
    param([object]$Context, [ValidateSet('status', 'diff')][string]$Action, [string]$FromRevision, [string]$ToRevision)
    $range = (ConvertTo-DemoBazaarRevisionSpec $FromRevision 'Green baseline revision') + '..' + (ConvertTo-DemoBazaarRevisionSpec $ToRevision 'Current revision')
    if ($Action -ceq 'status') { return Invoke-DemoBazaarProcess $Context @('status', '--short', '--revision', $range) }
    return Invoke-DemoBazaarProcess $Context @('diff', '--revision', $range) @(0, 1)
}

function Get-DemoBazaarPreflight {
    param([object]$Context)
    $status = Invoke-DemoBazaarRead $Context @('status', '--short')
    if (-not [string]::IsNullOrWhiteSpace($status)) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Packet creation requires a clean Bazaar working tree.') }
    $branch = Invoke-DemoBazaarRead $Context @('nick')
    $revision = Invoke-DemoBazaarRead $Context @('version-info', '--custom', '--template={revision_id}')
    if ([string]::IsNullOrWhiteSpace($branch) -or [string]::IsNullOrWhiteSpace($revision)) {
        throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Bazaar branch nick and full revision ID must both be non-empty.')
    }
    return [pscustomobject]@{ Branch = $branch; Revision = $revision }
}

function New-DemoTaskExecutionSnapshot {
    param([object]$Context, [object]$Preflight)
    return [pscustomobject]@{
        AllowedFileSha256 = Get-TeamBobFileHash $Context.InitialAllowedFilePath
        BazaarInventory = @(Get-TeamBobInventory (Join-Path $Context.Workspace '.bzr'))
        Branch = [string]$Preflight.Branch
        Revision = [string]$Preflight.Revision
    }
}

function Assert-DemoTaskExecutionSnapshot {
    param([object]$Context, [object]$Baseline)
    $currentAllowedHash = Get-TeamBobFileHash $Context.InitialAllowedFilePath
    $currentBazaarInventory = @(Get-TeamBobInventory (Join-Path $Context.Workspace '.bzr'))
    if ($currentAllowedHash -cne $Baseline.AllowedFileSha256 -or
        ($currentBazaarInventory -join "`n") -cne (@($Baseline.BazaarInventory) -join "`n")) {
        throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Allowed source or Bazaar metadata changed during Start-TeamBobTask execution.')
    }
    $postflight = Get-DemoBazaarPreflight $Context
    if ($postflight.Branch -cne $Baseline.Branch -or $postflight.Revision -cne $Baseline.Revision) {
        throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Bazaar branch or full revision changed during Start-TeamBobTask execution.')
    }
    $afterReadInventory = @(Get-TeamBobInventory (Join-Path $Context.Workspace '.bzr'))
    if ((Get-TeamBobFileHash $Context.InitialAllowedFilePath) -cne $Baseline.AllowedFileSha256 -or
        ($afterReadInventory -join "`n") -cne (@($Baseline.BazaarInventory) -join "`n")) {
        throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Allowed source or Bazaar metadata changed during Start-TeamBobTask postflight reads.')
    }
}

function Get-DemoPhaseIndex {
    param([string]$Name)
    for ($i = 0; $i -lt $script:PhaseNames.Count; $i++) { if ($script:PhaseNames[$i] -ceq $Name) { return $i } }
    throw (New-TeamBobFailure 'INTEGRITY_FAILED' "Unsupported phase in chain: $Name")
}

function Get-DemoTaskDirectory {
    param([string]$Workspace, [string]$PhaseName)
    return Join-Path $Workspace ('team-bob-work\' + $script:TaskIds[$PhaseName])
}

function Get-DemoChainPath {
    param([string]$Workspace, [string]$PhaseName)
    return Join-Path (Get-DemoTaskDirectory $Workspace $PhaseName) 'results\demo-phase-chain.json'
}

function Get-DemoExpectedInputMap {
    param([string]$Workspace, [string]$PhaseName)
    if ($PhaseName -ceq 'Requirements') {
        return [ordered]@{
            'word-requirements' = (Join-Path $Workspace 'demo\inputs\requirements-demo.docx')
            'qa-workbook' = (Join-Path $Workspace 'demo\inputs\qa-demo.xlsx')
        }
    }
    if ($PhaseName -ceq 'Impact') {
        $task = Get-DemoTaskDirectory $Workspace 'Requirements'
        return [ordered]@{
            'requirement-ledger' = (Join-Path $task 'drafts\requirement-ledger.csv')
            'external-specification' = (Join-Path $task 'drafts\external-spec.md')
        }
    }
    if ($PhaseName -ceq 'Green') {
        return [ordered]@{ 'impact-analysis' = (Join-Path (Get-DemoTaskDirectory $Workspace 'Impact') 'drafts\impact-analysis.md') }
    }
    return $null
}

function Assert-DemoAbsoluteWorkspaceFile {
    param([string]$Workspace, [string]$Path, [string]$ExpectedPath, [string]$Label)
    if (-not (Test-TeamBobAbsolutePath $Path)) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' "$Label path must be absolute.") }
    $full = Get-TeamBobCanonicalPath $Path "$Label path" 'INTEGRITY_FAILED'
    if (-not $full.Equals((Get-TeamBobCanonicalPath $ExpectedPath), [System.StringComparison]::OrdinalIgnoreCase)) {
        throw (New-TeamBobFailure 'INTEGRITY_FAILED' "$Label path is not the fixed workspace artifact.")
    }
    $workspacePhysical = Get-TeamBobPhysicalPath $Workspace 'Staged workspace' 'Container' 'INTEGRITY_FAILED'
    $physical = Get-TeamBobPhysicalPath $full $Label 'Leaf' 'INTEGRITY_FAILED'
    Assert-TeamBobPhysicalChild $physical $workspacePhysical $Label 'INTEGRITY_FAILED'
    return $full
}

function Assert-DemoChain {
    param([object]$Context, [string]$ChainPath, [string]$ExpectedPhase)
    $phaseIndex = Get-DemoPhaseIndex $ExpectedPhase
    $expectedChainPath = Get-DemoChainPath $Context.Workspace $ExpectedPhase
    $chainFull = Assert-DemoAbsoluteWorkspaceFile $Context.Workspace $ChainPath $expectedChainPath "$ExpectedPhase phase chain"
    $chain = Read-TeamBobJsonFile $chainFull "$ExpectedPhase phase chain" 'INTEGRITY_FAILED'
    Assert-TeamBobExactProperties $chain @(
        'schemaVersion', 'banner', 'demoProfileId', 'demoInstanceId', 'workspaceRoot', 'currentPhase', 'currentTaskId',
        'predecessor', 'entries', 'createdAt'
    ) "$ExpectedPhase phase chain" 'INTEGRITY_FAILED'
    if ($chain.schemaVersion -cne '1.0' -or $chain.banner -cne $script:DemoBanner -or $chain.demoProfileId -cne $script:DemoProfileId -or
        $chain.demoInstanceId -cne $Context.Marker.demoInstanceId -or $chain.workspaceRoot -cne $Context.Workspace -or
        $chain.currentPhase -cne $ExpectedPhase -or $chain.currentTaskId -cne $script:TaskIds[$ExpectedPhase] -or
        @($chain.entries).Count -ne ($phaseIndex + 1)) {
        throw (New-TeamBobFailure 'INTEGRITY_FAILED' "$ExpectedPhase phase chain identity/order is invalid.")
    }
    $parsedTime = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse([string]$chain.createdAt, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsedTime)) {
        throw (New-TeamBobFailure 'INTEGRITY_FAILED' "$ExpectedPhase phase chain createdAt is invalid.")
    }

    $previousChain = $null
    if ($phaseIndex -eq 0) {
        if ($null -ne $chain.predecessor) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Requirements chain must not have a predecessor.') }
    } else {
        $previousPhase = $script:PhaseNames[$phaseIndex - 1]
        Assert-TeamBobExactProperties $chain.predecessor @('phase', 'taskId', 'path', 'sha256') "$ExpectedPhase predecessor" 'INTEGRITY_FAILED'
        $previousPath = Get-DemoChainPath $Context.Workspace $previousPhase
        if ($chain.predecessor.phase -cne $previousPhase -or $chain.predecessor.taskId -cne $script:TaskIds[$previousPhase]) {
            throw (New-TeamBobFailure 'INTEGRITY_FAILED' "$ExpectedPhase predecessor phase/task is invalid.")
        }
        $resolvedPrevious = Assert-DemoAbsoluteWorkspaceFile $Context.Workspace ([string]$chain.predecessor.path) $previousPath "$ExpectedPhase predecessor chain"
        Assert-DemoHash $resolvedPrevious $chain.predecessor.sha256 "$ExpectedPhase predecessor chain"
        $previousChain = Assert-DemoChain $Context $resolvedPrevious $previousPhase
        for ($i = 0; $i -lt @($previousChain.entries).Count; $i++) {
            if ((@($chain.entries)[$i] | ConvertTo-Json -Depth 30) -cne (@($previousChain.entries)[$i] | ConvertTo-Json -Depth 30)) {
                throw (New-TeamBobFailure 'INTEGRITY_FAILED' "$ExpectedPhase cumulative entries do not exactly preserve the predecessor chain.")
            }
        }
    }

    for ($i = 0; $i -lt @($chain.entries).Count; $i++) {
        $entry = @($chain.entries)[$i]
        $entryPhase = $script:PhaseNames[$i]
        Assert-TeamBobExactProperties $entry @(
            'phase', 'taskId', 'risk', 'packetPath', 'packetSha256', 'bazaarBranch', 'bazaarFullRevisionId',
            'specificationApproverRole', 'implementationApproverRole', 'inputs'
        ) "$ExpectedPhase chain entry $i" 'INTEGRITY_FAILED'
        $packetPath = Join-Path (Get-DemoTaskDirectory $Context.Workspace $entryPhase) 'work-packet.md'
        if ($entry.phase -cne $entryPhase -or $entry.taskId -cne $script:TaskIds[$entryPhase]) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' "$ExpectedPhase chain entry $i has the wrong phase/task.") }
        $resolvedPacket = Assert-DemoAbsoluteWorkspaceFile $Context.Workspace ([string]$entry.packetPath) $packetPath "$entryPhase packet"
        Assert-DemoHash $resolvedPacket $entry.packetSha256 "$entryPhase packet"
        $packet = Read-TeamBobCanonicalPacket $resolvedPacket
        $expectedRisk = @('Amber', 'Amber', 'Green', 'Amber')[$i]
        $expectedSpecificationRole = $script:SpecificationAssignmentId
        $expectedImplementationRole = if ($entryPhase -ceq 'Test') { $script:IndependentReviewerAssignmentId } else { $script:ImplementationAssignmentId }
        if ($packet.'Task ID' -cne $entry.taskId -or $packet.Risk -cne $entry.risk -or
            $packet.'Bazaar Branch' -cne $entry.bazaarBranch -or $packet.'Bazaar Full Revision ID' -cne $entry.bazaarFullRevisionId -or
            $packet.'Specification Assignment ID' -cne $entry.specificationApproverRole -or
            $(if ($entryPhase -ceq 'Test') { $packet.'Independent Reviewer Assignment ID' } else { $packet.'Implementation Assignment ID' }) -cne $entry.implementationApproverRole -or
            $entry.risk -cne $expectedRisk -or $entry.specificationApproverRole -cne $expectedSpecificationRole -or
            $entry.implementationApproverRole -cne $expectedImplementationRole) {
            throw (New-TeamBobFailure 'INTEGRITY_FAILED' "$entryPhase chain entry does not match its canonical packet.")
        }
        if (@($packet.'Allowed Files').Count -ne 1 -or $packet.'Allowed Files'[0] -cne $script:AllowedFile -or
            $packet.'Build Profile ID' -cne $script:DemoProfileId) {
            throw (New-TeamBobFailure 'INTEGRITY_FAILED' "$entryPhase packet has an unexpected Allowed Files or build-profile boundary.")
        }
        foreach ($forbidden in $script:ForbiddenAreas) {
            if (@($packet.'Forbidden Areas') -cnotcontains $forbidden) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' "$entryPhase packet lost forbidden boundary '$forbidden'.") }
        }
        $expectedInputs = Get-DemoExpectedInputMap $Context.Workspace $entryPhase
        if ($null -ne $expectedInputs) {
            if (@($entry.inputs).Count -ne $expectedInputs.Count) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' "$entryPhase chain input count is invalid.") }
            $inputIndex = 0
            foreach ($role in $expectedInputs.Keys) {
                $input = @($entry.inputs)[$inputIndex]
                Assert-TeamBobExactProperties $input @('role', 'path', 'sha256') "$entryPhase chain input" 'INTEGRITY_FAILED'
                if ($input.role -cne $role) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' "$entryPhase chain input role/order is invalid.") }
                $resolvedInput = Assert-DemoAbsoluteWorkspaceFile $Context.Workspace ([string]$input.path) $expectedInputs[$role] "$entryPhase input $role"
                Assert-DemoHash $resolvedInput $input.sha256 "$entryPhase input $role"
                $inputIndex++
            }
        } else {
            $fixedTestPaths = [ordered]@{
                'implementation-source' = (Join-Path $Context.Workspace ($script:AllowedFile.Replace('/', '\')))
                'build-summary' = (Join-Path (Get-DemoTaskDirectory $Context.Workspace 'Green') 'results\build-result.md')
                'code-review' = (Join-Path (Get-DemoTaskDirectory $Context.Workspace 'Green') 'drafts\code-review.md')
                'bazaar-status' = (Join-Path (Get-DemoTaskDirectory $Context.Workspace 'Green') 'results\bazaar-status.txt')
                'bazaar-diff' = (Join-Path (Get-DemoTaskDirectory $Context.Workspace 'Green') 'results\bazaar-diff.patch')
                'bazaar-nick' = (Join-Path (Get-DemoTaskDirectory $Context.Workspace 'Green') 'results\bazaar-nick.txt')
                'bazaar-revision' = (Join-Path (Get-DemoTaskDirectory $Context.Workspace 'Green') 'results\bazaar-revision-id.txt')
                'bazaar-manifest' = (Join-Path (Get-DemoTaskDirectory $Context.Workspace 'Green') 'results\bazaar-evidence-manifest.json')
            }
            $seenRoles = @{}
            $invocationIndexes = @()
            $finalBuildCount = 0
            foreach ($input in @($entry.inputs)) {
                Assert-TeamBobExactProperties $input @('role', 'path', 'sha256') "$entryPhase chain input" 'INTEGRITY_FAILED'
                $role = [string]$input.role
                if ([string]::IsNullOrWhiteSpace($role) -or $seenRoles.ContainsKey($role)) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Test chain contains an empty or duplicate evidence role.') }
                $seenRoles[$role] = $true
                $expectedInputPath = $null
                if ($fixedTestPaths.Contains($role)) {
                    $expectedInputPath = [string]$fixedTestPaths[$role]
                } elseif ($role -ceq 'final-build-result' -or $role -match '^build-invocation-[0-9]{3}$') {
                    $invocationIndex = $null
                    if ($role -ne 'final-build-result') {
                        $invocationMatch = [regex]::Match($role, '^build-invocation-(?<index>[0-9]{3})$')
                        $invocationIndex = [int]$invocationMatch.Groups['index'].Value
                    }
                    $expectedInputPath = [string]$input.path
                    $resultRoot = Join-Path (Get-DemoTaskDirectory $Context.Workspace 'Green') 'results'
                    $candidate = Get-TeamBobCanonicalPath $expectedInputPath 'Test build-result input' 'INTEGRITY_FAILED'
                    $resultRootFull = Get-TeamBobCanonicalPath $resultRoot 'Green results root' 'INTEGRITY_FAILED'
                    if (-not (Split-Path -Parent $candidate).Equals($resultRootFull, [System.StringComparison]::OrdinalIgnoreCase) -or
                        (Split-Path -Leaf $candidate) -notmatch '^build-result-[A-Za-z0-9_-]+\.json$') {
                        throw (New-TeamBobFailure 'INTEGRITY_FAILED' "Test chain role '$role' is not a Green machine build result.")
                    }
                    if ($role -ceq 'final-build-result') { $finalBuildCount++ } else { $invocationIndexes += $invocationIndex }
                } else {
                    throw (New-TeamBobFailure 'INTEGRITY_FAILED' "Test chain contains unsupported evidence role '$role'.")
                }
                $resolvedInput = Assert-DemoAbsoluteWorkspaceFile $Context.Workspace ([string]$input.path) $expectedInputPath "$entryPhase input $role"
                Assert-DemoHash $resolvedInput $input.sha256 "$entryPhase input $($input.role)"
            }
            foreach ($role in $fixedTestPaths.Keys) {
                if (-not $seenRoles.ContainsKey($role)) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' "Test chain is missing evidence role '$role'.") }
            }
            if ($finalBuildCount -ne 1) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Test chain requires exactly one final-build-result role.') }
            if ((@($invocationIndexes | Sort-Object) -join ',') -cne '0,1') {
                throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Test chain requires exactly build-invocation-000 and build-invocation-001 before final-build-result.')
            }
        }
    }
    return $chain
}

function New-DemoInputRecord {
    param([object]$Context, [string]$Role, [string]$Path)
    $full = Assert-DemoAbsoluteWorkspaceFile $Context.Workspace $Path $Path "Phase input $Role"
    return [ordered]@{ role = $Role; path = $full; sha256 = Get-TeamBobFileHash $full }
}

function Assert-DemoNoOpenQa {
    param([string]$Text, [string]$Label)
    $matches = [regex]::Matches($Text, '(?im)^\s*Open QA:\s*(?<value>[^\r\n]*?)\s*$')
    if ($matches.Count -ne 1 -or $matches[0].Groups['value'].Value.Trim() -cne 'NONE') {
        throw (New-TeamBobFailure 'INTEGRITY_FAILED' "$Label must contain exactly one Open QA line whose value is NONE.")
    }
}

function Assert-DemoRequirementsArtifacts {
    param([object]$Context)
    $inputs = Get-DemoExpectedInputMap $Context.Workspace 'Impact'
    $ledgerPath = [string]$inputs['requirement-ledger']
    $specPath = [string]$inputs['external-specification']
    $ledgerText = Read-TeamBobUtf8File $ledgerPath 'Requirement ledger' 'INTEGRITY_FAILED'
    try { $rows = @($ledgerText | ConvertFrom-Csv) } catch { throw (New-TeamBobFailure 'INTEGRITY_FAILED' ('Requirement ledger CSV is invalid: ' + $_.Exception.Message)) }
    if ($rows.Count -eq 0) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Requirement ledger has no approved requirement rows.') }
    $columns = @('ReqID', 'Immutable Source Anchor', 'Interpretation', 'Acceptance Criteria', 'QA Links', 'QA Status', 'Evidence', 'Human Approval State')
    if ((@($rows[0].PSObject.Properties.Name) -join "`n") -cne ($columns -join "`n")) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Requirement ledger columns do not match the template contract.') }
    $hasWord = $false; $hasQa = $false; $hasRequirement = $false
    foreach ($row in $rows) {
        if ($row.ReqID -ceq $script:RequirementId) { $hasRequirement = $true }
        if ($row.'Immutable Source Anchor' -match '(?i)requirements-demo\.docx#paragraph-[0-9]+') { $hasWord = $true }
        if ($row.'Immutable Source Anchor' -match '(?i)qa-demo\.xlsx#[^!]+![A-Z]+[0-9]+(?::[A-Z]+[0-9]+)?') { $hasQa = $true }
        if ($row.'QA Status' -cne 'CLOSED') { throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Requirement ledger contains Open/unresolved QA; the next phase is blocked.') }
        if ($row.'Human Approval State' -cne ('APPROVED:' + $script:SpecificationRole)) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Requirement ledger is missing the specification-role approval.') }
    }
    if (-not $hasRequirement -or -not $hasWord -or -not $hasQa) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Requirement ledger lacks the fixed ReqID or immutable Word/Excel source anchors.') }
    $spec = Read-TeamBobUtf8File $specPath 'External specification' 'INTEGRITY_FAILED'
    Assert-DemoNoOpenQa $spec 'External specification'
    foreach ($pattern in @(
        [regex]::Escape($script:DemoBanner), [regex]::Escape($script:RequirementId), '(?i)Customer-A', '(?i)warm-up', '(?i)8000', '(?i)3\s+consecutive',
        '(?i)7999', '(?i)Normal', '(?i)board', '(?i)driver', '(?i)ABI', '(?i)control period',
        ('(?i)' + [regex]::Escape($script:SpecificationRole) + '.*APPROVED')
    )) {
        if ($spec -notmatch $pattern) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' "External specification is missing required approved demo evidence: $pattern") }
    }
    return @(
        (New-DemoInputRecord $Context 'requirement-ledger' $ledgerPath),
        (New-DemoInputRecord $Context 'external-specification' $specPath)
    )
}

function Assert-DemoImpactArtifact {
    param([object]$Context)
    $path = Join-Path (Get-DemoTaskDirectory $Context.Workspace 'Impact') 'drafts\impact-analysis.md'
    $text = Read-TeamBobUtf8File $path 'Impact analysis' 'INTEGRITY_FAILED'
    Assert-DemoNoOpenQa $text 'Impact analysis'
    if ($text -notmatch [regex]::Escape($script:DemoBanner) -or
        $text -notmatch ('(?i)' + [regex]::Escape($script:ImplementationRole) + '.*APPROVED')) {
        throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Impact analysis lacks the NOT-VC6 banner, empty Open QA, or implementation-role approval.')
    }
    $expectedAreas = @('RT', 'Safety', 'Board', 'Driver', 'ABI', 'Build', 'Customer Branch')
    $dispositions = @{}
    foreach ($line in @($text -split "`r?`n")) {
        if ($line -notmatch '^\s*\|') { continue }
        $cells = @($line.Trim().Trim('|').Split('|') | ForEach-Object { $_.Trim() })
        if ($cells.Count -eq 4 -and $expectedAreas -contains $cells[0]) {
            if ($dispositions.ContainsKey($cells[0])) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' "Impact area '$($cells[0])' is duplicated.") }
            $dispositions[$cells[0]] = $cells[3]
        }
    }
    foreach ($area in $expectedAreas) {
        if (-not $dispositions.ContainsKey($area) -or [string]$dispositions[$area] -cne 'CLEAR') {
            throw (New-TeamBobFailure 'INTEGRITY_FAILED' "Impact area '$area' is not CLEAR; Green packet creation is blocked.")
        }
    }
    return @((New-DemoInputRecord $Context 'impact-analysis' $path))
}

function Assert-DemoExactRepairDiff {
    param([string]$Diff, [string]$Label)
    $diffPaths = @([regex]::Matches($Diff, "(?m)^=== modified file '(?<path>[^']+)'\s*$") | ForEach-Object { $_.Groups['path'].Value.Replace('\\', '/') })
    if ($diffPaths.Count -ne 1 -or $diffPaths[0] -cne $script:AllowedFile) {
        throw (New-TeamBobFailure 'INTEGRITY_FAILED' "$Label must modify only the approved Allowed File.")
    }
    $removedLines = @($Diff -split "`r?`n" | Where-Object { $_.StartsWith('-') -and -not $_.StartsWith('---') } | ForEach-Object { $_.Substring(1) } | Sort-Object)
    $addedLines = @($Diff -split "`r?`n" | Where-Object { $_.StartsWith('+') -and -not $_.StartsWith('+++') } | ForEach-Object { $_.Substring(1) } | Sort-Object)
    $expectedRemoved = @($script:InitialFaultLine, '    if (consecutiveOverruns_ >= 1U) {') | Sort-Object
    $expectedAdded = @($script:RepairedFaultLine, '    if (consecutiveOverruns_ >= 3U) {') | Sort-Object
    if (($removedLines -join "`n") -cne ($expectedRemoved -join "`n") -or ($addedLines -join "`n") -cne ($expectedAdded -join "`n")) {
        throw (New-TeamBobFailure 'INTEGRITY_FAILED' "$Label must contain only the exact threshold repair and exact #error-to-pragma training-fault repair.")
    }
}

function Assert-DemoGreenEvidence {
    param([object]$Context, [object]$GreenChain, [object]$Preflight)
    $greenTask = Get-DemoTaskDirectory $Context.Workspace 'Green'
    $greenEntry = @($GreenChain.entries)[2]
    if ($greenEntry.risk -cne 'Green' -or $greenEntry.bazaarBranch -cne $Preflight.Branch -or $greenEntry.bazaarFullRevisionId -ceq $Preflight.Revision) {
        throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Test requires a Green predecessor on the same branch and a new human-created full revision ID.')
    }
    $greenPacket = Read-TeamBobCanonicalPacket ([string]$greenEntry.packetPath)
    if ($greenPacket.Risk -cne 'Green' -or @($greenPacket.'Open QA').Count -ne 0) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Test requires the validated Green work packet with no Open QA.') }

    $sourcePath = Join-Path $Context.Workspace ($script:AllowedFile.Replace('/', '\'))
    Assert-TeamBobAllowedEncoding @([pscustomobject]@{ FullPath = $sourcePath; RelativePath = $script:AllowedFile })
    if ((Get-TeamBobFileHash $sourcePath) -ceq $Context.InitialAllowedFileSha256) {
        throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Test requires the human-approved Green implementation revision, not the initial Allowed File baseline.')
    }
    $sourceText = Read-TeamBobStrictCp932File $sourcePath
    $sourceLines = @($sourceText -split "`r?`n")
    $initialFaultCount = @($sourceLines | Where-Object { $_ -ceq $script:InitialFaultLine }).Count
    $repairedFaultCount = @($sourceLines | Where-Object { $_ -ceq $script:RepairedFaultLine }).Count
    $faultBeginCount = @($sourceLines | Where-Object { $_ -ceq '// TEAM_BOB_DEMO_FAULT_BEGIN' }).Count
    $faultEndCount = @($sourceLines | Where-Object { $_ -ceq '// TEAM_BOB_DEMO_FAULT_END' }).Count
    if ($sourceText -notmatch 'if\s*\(\s*consecutiveOverruns_\s*>=\s*3U\s*\)' -or
        $sourceText -match 'if\s*\(\s*consecutiveOverruns_\s*>=\s*1U\s*\)' -or
        $initialFaultCount -ne 0 -or $repairedFaultCount -ne 1 -or $faultBeginCount -ne 1 -or $faultEndCount -ne 1) {
        throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Test requires the approved three-cycle behavior and exact one-line pragma repair inside the preserved fault-training markers.')
    }
    $rangeStatus = Invoke-DemoBazaarRangeRead $Context 'status' ([string]$greenEntry.bazaarFullRevisionId) ([string]$Preflight.Revision)
    $rangeStatusLines = @($rangeStatus -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($rangeStatusLines.Count -ne 1 -or $rangeStatusLines[0] -cnotmatch ('^ M\s+' + [regex]::Escape($script:AllowedFile) + '$')) {
        throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Committed revision range must modify exactly one Allowed File.')
    }
    Assert-TeamBobBazaarStatus $rangeStatus @([pscustomobject]@{ RelativePath = $script:AllowedFile })
    $rangeDiff = Invoke-DemoBazaarRangeRead $Context 'diff' ([string]$greenEntry.bazaarFullRevisionId) ([string]$Preflight.Revision)
    Assert-DemoExactRepairDiff $rangeDiff 'Committed Bazaar revision range'
    $summaryPath = Join-Path $greenTask 'results\build-result.md'
    $reviewPath = Join-Path $greenTask 'drafts\code-review.md'
    $summary = Read-TeamBobUtf8File $summaryPath 'Build result summary' 'INTEGRITY_FAILED'
    if ($summary -notmatch [regex]::Escape($script:DemoBanner) -or $summary -notmatch '(?m)^READY_FOR_HUMAN_REVIEW\s*$') {
        throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Test requires the NOT-VC6 build summary and READY_FOR_HUMAN_REVIEW after final Rebuild.')
    }
    $review = Read-TeamBobUtf8File $reviewPath 'Code review' 'INTEGRITY_FAILED'
    if ($review -notmatch [regex]::Escape($script:DemoBanner) -or $review -notmatch [regex]::Escape($script:AllowedFile) -or
        $review -notmatch '(?i)artificial|training' -or $review -notmatch ('(?i)' + [regex]::Escape($script:IndependentReviewRole) + '.*APPROVED')) {
        throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Test requires an approved independent code review with Allowed File and artificial-fault disclosure.')
    }

    $machineResults = @()
    foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $greenTask 'results') -File -Filter 'build-result-*.json')) {
        $json = Read-TeamBobJsonFile $file.FullName 'Machine build result' 'INTEGRITY_FAILED'
        Assert-DemoRequiredProperties $json @('schemaVersion', 'status', 'exitCode', 'taskId', 'action', 'attempt', 'buildProfileId', 'processFinishedAt') 'Machine build result'
        if ($json.schemaVersion -cne '1.0' -or $json.taskId -cne 'DEMO-GREEN-001' -or $json.buildProfileId -cne $script:DemoProfileId -or
            -not (Test-TeamBobInteger $json.attempt) -or [int]$json.attempt -lt 0 -or [int]$json.attempt -gt 2 -or
            -not (Test-TeamBobInteger $json.exitCode)) {
            throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Machine build result identity/attempt is invalid.')
        }
        $finished = [DateTimeOffset]::MinValue
        if (-not [DateTimeOffset]::TryParse([string]$json.processFinishedAt, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$finished)) {
            throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Machine build result processFinishedAt is invalid.')
        }
        $machineResults += [pscustomobject]@{ File = $file.FullName; Json = $json; Finished = $finished }
    }
    if ($machineResults.Count -ne 3) {
        throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Test requires exactly three machine build results: failed Make 0, successful Make 1, successful Rebuild 1.')
    }
    $machineResults = @($machineResults | Sort-Object Finished, File)
    $expectedBuildSequence = @(
        [pscustomobject]@{ Action = 'Make'; Attempt = 0; Status = 'CODE_FAILED_RETRYABLE'; ExitCode = 10 },
        [pscustomobject]@{ Action = 'Make'; Attempt = 1; Status = 'SUCCEEDED'; ExitCode = 0 },
        [pscustomobject]@{ Action = 'Rebuild'; Attempt = 1; Status = 'SUCCEEDED'; ExitCode = 0 }
    )
    for ($buildIndex = 0; $buildIndex -lt $expectedBuildSequence.Count; $buildIndex++) {
        $actualBuild = $machineResults[$buildIndex]
        $expectedBuild = $expectedBuildSequence[$buildIndex]
        if ($buildIndex -gt 0 -and $actualBuild.Finished -le $machineResults[$buildIndex - 1].Finished) {
            throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Machine build results must have strictly increasing completion timestamps.')
        }
        if ($actualBuild.Json.action -cne $expectedBuild.Action -or [int]$actualBuild.Json.attempt -ne $expectedBuild.Attempt -or
            $actualBuild.Json.status -cne $expectedBuild.Status -or [int]$actualBuild.Json.exitCode -ne $expectedBuild.ExitCode) {
            throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Machine build results do not prove the fixed one-repair sequence: Make 0 retryable, Make 1 success, Rebuild 1 success.')
        }
    }

    $statusPath = Join-Path $greenTask 'results\bazaar-status.txt'
    $diffPath = Join-Path $greenTask 'results\bazaar-diff.patch'
    $nickPath = Join-Path $greenTask 'results\bazaar-nick.txt'
    $revisionPath = Join-Path $greenTask 'results\bazaar-revision-id.txt'
    $manifestPath = Join-Path $greenTask 'results\bazaar-evidence-manifest.json'
    $status = Read-TeamBobUtf8File $statusPath 'Bazaar status evidence' 'INTEGRITY_FAILED'
    Assert-TeamBobBazaarStatus $status @([pscustomobject]@{ RelativePath = $script:AllowedFile })
    if ([string]::IsNullOrWhiteSpace($status)) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Bazaar status evidence must contain the approved Allowed File modification.') }
    $diff = Read-TeamBobUtf8File $diffPath 'Bazaar diff evidence' 'INTEGRITY_FAILED'
    Assert-DemoExactRepairDiff $diff 'Bazaar diff evidence'
    $nick = (Read-TeamBobUtf8File $nickPath 'Bazaar nick evidence' 'INTEGRITY_FAILED').Trim()
    $revision = (Read-TeamBobUtf8File $revisionPath 'Bazaar revision evidence' 'INTEGRITY_FAILED').Trim()
    if ($nick -cne $greenEntry.bazaarBranch -or $revision -cne $greenEntry.bazaarFullRevisionId) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Bazaar evidence branch/revision does not match the Green baseline.') }
    $manifest = Read-TeamBobJsonFile $manifestPath 'Bazaar evidence manifest' 'INTEGRITY_FAILED'
    Assert-TeamBobExactProperties $manifest @(
        'schemaVersion', 'taskId', 'bazaarRoot', 'bazaarPath', 'bazaarSha256', 'branchNick', 'revisionId',
        'commands', 'commandResults', 'files', 'exportedAt'
    ) 'Bazaar evidence manifest' 'INTEGRITY_FAILED'
    $expectedCommands = @('status --short', 'diff', 'nick', 'version-info --custom --template={revision_id}')
    $expectedFiles = @('bazaar-status.txt', 'bazaar-diff.patch', 'bazaar-nick.txt', 'bazaar-revision-id.txt')
    if ($manifest.schemaVersion -cne '1.0' -or $manifest.taskId -cne 'DEMO-GREEN-001' -or $manifest.bazaarRoot -cne $Context.Workspace -or
        $manifest.bazaarPath -cne $Context.Environment.bazaarPath -or $manifest.bazaarSha256 -cne $Context.Environment.bazaarSha256 -or
        $manifest.branchNick -cne $greenEntry.bazaarBranch -or $manifest.revisionId -cne $greenEntry.bazaarFullRevisionId -or
        (@($manifest.commands) -join "`n") -cne ($expectedCommands -join "`n") -or (@($manifest.files) -join "`n") -cne ($expectedFiles -join "`n") -or
        @($manifest.commandResults).Count -ne 4) {
        throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Bazaar evidence manifest is incomplete or does not match the Green baseline.')
    }
    for ($commandIndex = 0; $commandIndex -lt @($manifest.commandResults).Count; $commandIndex++) {
        $commandResult = @($manifest.commandResults)[$commandIndex]
        Assert-TeamBobExactProperties $commandResult @('command', 'exitCode') 'Bazaar evidence command result' 'INTEGRITY_FAILED'
        if ($commandResult.command -cne $expectedCommands[$commandIndex] -or -not (Test-TeamBobInteger $commandResult.exitCode)) {
            throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Bazaar evidence command result is invalid.')
        }
        if ($commandResult.command -eq 'diff') {
            if (@(0, 1) -notcontains [int]$commandResult.exitCode) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Bazaar diff evidence exit code is invalid.') }
        } elseif ([int]$commandResult.exitCode -ne 0) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Bazaar read evidence contains a failed command.') }
    }

    $records = @(
        (New-DemoInputRecord $Context 'implementation-source' $sourcePath),
        (New-DemoInputRecord $Context 'build-summary' $summaryPath)
    )
    for ($i = 0; $i -lt $machineResults.Count; $i++) {
        $role = if ($i -eq ($machineResults.Count - 1)) { 'final-build-result' } else { 'build-invocation-' + $i.ToString('000', [Globalization.CultureInfo]::InvariantCulture) }
        $records += New-DemoInputRecord $Context $role $machineResults[$i].File
    }
    $records += @(
        (New-DemoInputRecord $Context 'code-review' $reviewPath),
        (New-DemoInputRecord $Context 'bazaar-status' $statusPath),
        (New-DemoInputRecord $Context 'bazaar-diff' $diffPath),
        (New-DemoInputRecord $Context 'bazaar-nick' $nickPath),
        (New-DemoInputRecord $Context 'bazaar-revision' $revisionPath),
        (New-DemoInputRecord $Context 'bazaar-manifest' $manifestPath)
    )
    return @($records)
}

function Invoke-DemoStartTask {
    param(
        [object]$Context, [string]$TaskId, [string]$Classification, [string]$WordBaseline, [string]$QaBaseline,
        [string]$SpecBaseline, [string]$SpecificationApprover, [string]$ImplementationApprover, [bool]$ImpactsClear
    )
    $startScript = [string]@($Context.ApprovedExecutionHelpers)[0].Path
    [void](Get-TeamBobPhysicalPath $startScript 'Installed Start-TeamBobTask.ps1' 'Leaf' 'INTEGRITY_FAILED')
    $parameters = [ordered]@{
        TaskId = $TaskId; BazaarRoot = $Context.Workspace; Difficulty = 'Small'; Classification = $Classification
        Customer = 'Customer-A'; ReqIds = @($script:RequirementId); WordBaseline = $WordBaseline; QaBaseline = $QaBaseline
        SpecBaseline = $SpecBaseline; AllowedFiles = @($script:AllowedFile); BuildProfileId = $script:DemoProfileId
        SpecificationAssignmentId = $script:SpecificationAssignmentId
        ImplementationAssignmentId = $script:ImplementationAssignmentId
        IndependentReviewerAssignmentId = $script:IndependentReviewerAssignmentId
        MaxRepairCycles = 2
        ForbiddenAreas = @($script:ForbiddenAreas)
    }
    if ($ImpactsClear) {
        $parameters.RTImpact = 'No RT scheduling or control-period change; decision logic only.'
        $parameters.SafetyImpact = 'No safety-function change in this synthetic demo.'
        $parameters.BoardImpact = 'No board or dedicated-hardware change.'
        $parameters.DriverImpact = 'No driver change.'
        $parameters.ABIImpact = 'No ABI or public-header change.'
        $parameters.BuildImpact = 'Synthetic Release Win32 demo adapter build only; not VC6 qualification.'
        $parameters.CustomerBranchImpact = 'Customer-A behavior only; all other customers remain Normal.'
        foreach ($name in @('RTImpactClear', 'SafetyImpactClear', 'BoardImpactClear', 'DriverImpactClear', 'ABIImpactClear', 'BuildImpactClear', 'CustomerBranchImpactClear')) {
            $parameters[$name] = 'YES'
        }
    }
    # -File cannot faithfully bind a multi-value array followed by more named parameters in all supported hosts.
    # Build one single-quoted fixed splat; every scalar is data-quoted and no user command text is accepted.
    function ConvertTo-DemoEncodedLiteral {
        param($Value)
        if ($Value -is [System.Array]) {
            return '@(' + ((@($Value) | ForEach-Object { "'" + ([string]$_).Replace("'", "''") + "'" }) -join ',') + ')'
        }
        if ($Value -is [int]) { return ([string]$Value) }
        return "'" + ([string]$Value).Replace("'", "''") + "'"
    }
    $pairs = @()
    foreach ($name in $parameters.Keys) { $pairs += ([string]$name + '=' + (ConvertTo-DemoEncodedLiteral $parameters[$name])) }
    $command = '$p=@{' + ($pairs -join ';') + '};& ' + (ConvertTo-DemoEncodedLiteral $startScript) + ' @p'
    $arguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', $command)
    $engine = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $result = Invoke-TeamBobProcess $engine $arguments $Context.Workspace 60
    if ($result.TimedOut -or -not $result.CaptureComplete -or [int]$result.ExitCode -ne 0) {
        $detail = (([string]$result.StandardError) + ' ' + ([string]$result.StandardOutput)).Trim()
        throw (New-TeamBobFailure 'INTEGRITY_FAILED' "Start-TeamBobTask rejected the demo packet: $detail")
    }
    return $result
}

function Assert-DemoCreatedPacket {
    param(
        [object]$Context, [string]$PhaseName, [string]$Classification, [object]$Preflight,
        [string]$WordBaseline, [string]$QaBaseline, [string]$SpecBaseline,
        [string]$SpecificationApprover, [string]$ImplementationApprover, [bool]$ImpactsClear
    )
    $packetPath = Join-Path (Get-DemoTaskDirectory $Context.Workspace $PhaseName) 'work-packet.md'
    $packet = Read-TeamBobCanonicalPacket $packetPath
    if ($packet.'Task ID' -cne $script:TaskIds[$PhaseName] -or $packet.Risk -cne $Classification -or
        $packet.Customer -cne 'Customer-A' -or @($packet.ReqIDs).Count -ne 1 -or $packet.ReqIDs[0] -cne $script:RequirementId -or
        $packet.'Word Baseline' -cne $WordBaseline -or $packet.'QA Baseline' -cne $QaBaseline -or $packet.'Spec Baseline' -cne $SpecBaseline -or
        $packet.'Bazaar Root' -cne $Context.Workspace -or $packet.'Bazaar Branch' -cne $Preflight.Branch -or
        $packet.'Bazaar Full Revision ID' -cne $Preflight.Revision -or @($packet.'Allowed Files').Count -ne 1 -or
        $packet.'Allowed Files'[0] -cne $script:AllowedFile -or $packet.'Build Profile ID' -cne $script:DemoProfileId -or
        $packet.'Profile Version' -cne '0.2.0-poc' -or $packet.'Policy Version' -cne '0.2.0-poc' -or
        $packet.'Specification Assignment ID' -cne $script:SpecificationAssignmentId -or
        $packet.'Implementation Assignment ID' -cne $script:ImplementationAssignmentId -or
        $packet.'Independent Reviewer Assignment ID' -cne $script:IndependentReviewerAssignmentId -or
        [int]$packet.'Max-Repair-Cycles' -ne 2 -or @($packet.'Open QA').Count -ne 0) {
        throw (New-TeamBobFailure 'INTEGRITY_FAILED' "$PhaseName canonical packet does not match the fixed demo contract.")
    }
    foreach ($forbidden in $script:ForbiddenAreas) {
        if (@($packet.'Forbidden Areas') -cnotcontains $forbidden) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' "$PhaseName packet is missing forbidden boundary '$forbidden'.") }
    }
    $clearFields = @('RT Impact Clear', 'Safety Impact Clear', 'Board Impact Clear', 'Driver Impact Clear', 'ABI Impact Clear', 'Build Impact Clear', 'Customer Branch Impact Clear')
    foreach ($field in $clearFields) {
        $expected = if ($ImpactsClear) { 'YES' } else { 'NO' }
        if ($packet.$field -cne $expected) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' "$PhaseName packet impact gate '$field' is invalid.") }
    }
    if ($packet.'Clean Working Copy' -cne 'YES') { throw (New-TeamBobFailure 'INTEGRITY_FAILED' "$PhaseName packet did not preserve the clean-working-copy proof.") }
    return [pscustomobject]@{ Path = $packetPath; Packet = $packet }
}

function Write-DemoChainCreateOnly {
    param([object]$Context, [string]$PhaseName, [object]$PacketInfo, [object[]]$Inputs, [object]$PredecessorChain)
    $phaseIndex = Get-DemoPhaseIndex $PhaseName
    $predecessor = $null
    $entries = @()
    if ($phaseIndex -gt 0) {
        $previousPhase = $script:PhaseNames[$phaseIndex - 1]
        $previousPath = Get-DemoChainPath $Context.Workspace $previousPhase
        $predecessor = [ordered]@{
            phase = $previousPhase; taskId = $script:TaskIds[$previousPhase]; path = $previousPath; sha256 = Get-TeamBobFileHash $previousPath
        }
        $entries = @($PredecessorChain.entries)
    }
    $packet = $PacketInfo.Packet
    $entry = [ordered]@{
        phase = $PhaseName; taskId = $script:TaskIds[$PhaseName]; risk = [string]$packet.Risk
        packetPath = $PacketInfo.Path; packetSha256 = Get-TeamBobFileHash $PacketInfo.Path
        bazaarBranch = [string]$packet.'Bazaar Branch'; bazaarFullRevisionId = [string]$packet.'Bazaar Full Revision ID'
        specificationApproverRole = [string]$packet.'Specification Assignment ID'
        implementationApproverRole = $(if ($PhaseName -ceq 'Test') { [string]$packet.'Independent Reviewer Assignment ID' } else { [string]$packet.'Implementation Assignment ID' })
        inputs = @($Inputs)
    }
    $entries += $entry
    $chain = [ordered]@{
        schemaVersion = '1.0'; banner = $script:DemoBanner; demoProfileId = $script:DemoProfileId
        demoInstanceId = $Context.Marker.demoInstanceId; workspaceRoot = $Context.Workspace
        currentPhase = $PhaseName; currentTaskId = $script:TaskIds[$PhaseName]; predecessor = $predecessor; entries = @($entries)
        createdAt = [DateTimeOffset]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    }
    $path = Get-DemoChainPath $Context.Workspace $PhaseName
    if (Test-Path -LiteralPath $path) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' "$PhaseName phase chain already exists; create-only replay is forbidden.") }
    $resultsPhysical = Get-TeamBobPhysicalPath (Split-Path -Parent $path) "$PhaseName results directory" 'Container' 'INTEGRITY_FAILED'
    Assert-TeamBobPhysicalChild $resultsPhysical $Context.WorkspacePhysical "$PhaseName results directory" 'INTEGRITY_FAILED'
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes(($chain | ConvertTo-Json -Depth 40) + "`r`n")
    $stream = New-Object System.IO.FileStream($path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush() } finally { $stream.Dispose() }
    [void](Assert-DemoChain $Context $path $PhaseName)
    return $path
}

try {
    $context = Get-DemoApprovedContext
    $phaseIndex = Get-DemoPhaseIndex $Phase
    if ($Phase -cne 'Test') {
        Assert-DemoHash $context.InitialAllowedFilePath $context.InitialAllowedFileSha256 'Initial Allowed File before Green'
        Assert-TeamBobAllowedEncoding @([pscustomobject]@{ FullPath = $context.InitialAllowedFilePath; RelativePath = $script:AllowedFile })
    }
    $taskDirectory = Get-DemoTaskDirectory $context.Workspace $Phase
    if (Test-Path -LiteralPath $taskDirectory) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' "Fixed demo task already exists and cannot be replayed: $taskDirectory") }
    $preflight = Get-DemoBazaarPreflight $context
    Assert-DemoApprovedContextUnchanged $context 'packet preflight'

    $previousChain = $null
    $inputs = @()
    if ($phaseIndex -eq 0) {
        $sourceMap = Get-DemoExpectedInputMap $context.Workspace 'Requirements'
        foreach ($role in $sourceMap.Keys) { $inputs += New-DemoInputRecord $context $role $sourceMap[$role] }
    } else {
        $previousPhase = $script:PhaseNames[$phaseIndex - 1]
        $previousChain = Assert-DemoChain $context (Get-DemoChainPath $context.Workspace $previousPhase) $previousPhase
        $previousEntry = @($previousChain.entries)[$phaseIndex - 1]
        if ($preflight.Branch -cne $previousEntry.bazaarBranch) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Phase progression cannot change Bazaar branch.') }
        if ($Phase -ceq 'Test') {
            if ($preflight.Revision -ceq $previousEntry.bazaarFullRevisionId) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Test requires a new full Bazaar revision ID after the human-approved commit.') }
            $inputs = @(Assert-DemoGreenEvidence $context $previousChain $preflight)
        } else {
            if ($preflight.Revision -cne $previousEntry.bazaarFullRevisionId) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Requirements, Impact, and Green must remain on the same immutable Bazaar baseline.') }
            if ($Phase -ceq 'Impact') { $inputs = @(Assert-DemoRequirementsArtifacts $context) }
            elseif ($Phase -ceq 'Green') {
                [void](Assert-DemoRequirementsArtifacts $context)
                $inputs = @(Assert-DemoImpactArtifact $context)
            }
        }
    }

    $wordPath = Join-Path $context.Workspace 'demo\inputs\requirements-demo.docx'
    $qaPath = Join-Path $context.Workspace 'demo\inputs\qa-demo.xlsx'
    $wordBaseline = 'SHA256:' + (Get-TeamBobFileHash $wordPath)
    $qaBaseline = 'SHA256:' + (Get-TeamBobFileHash $qaPath)
    $specBaseline = if ($Phase -ceq 'Requirements') { 'NOT-ESTABLISHED-REQUIREMENTS-PHASE' } else {
        'SHA256:' + (Get-TeamBobFileHash (Join-Path (Get-DemoTaskDirectory $context.Workspace 'Requirements') 'drafts\external-spec.md'))
    }
    $classification = if ($Phase -ceq 'Green') { 'Green' } else { 'Amber' }
    $specApprover = $script:SpecificationRole
    $implementationApprover = if ($Phase -ceq 'Test') { $script:IndependentReviewRole } else { $script:ImplementationRole }
    $impactsClear = ($Phase -ceq 'Green' -or $Phase -ceq 'Test')
    $executionSnapshot = New-DemoTaskExecutionSnapshot $context $preflight
    [void](Invoke-DemoStartTask $context $script:TaskIds[$Phase] $classification $wordBaseline $qaBaseline $specBaseline $specApprover $implementationApprover $impactsClear)
    Assert-DemoTaskExecutionSnapshot $context $executionSnapshot
    Assert-DemoApprovedContextUnchanged $context 'Start-TeamBobTask execution'
    $packetInfo = Assert-DemoCreatedPacket $context $Phase $classification $preflight $wordBaseline $qaBaseline $specBaseline $specApprover $implementationApprover $impactsClear
    $chainPath = Write-DemoChainCreateOnly $context $Phase $packetInfo $inputs $previousChain
    Write-Output $script:DemoBanner
    Write-Output "CREATED $($packetInfo.Path)"
    Write-Output "CHAIN $chainPath"
    exit 0
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    [Console]::Out.WriteLine($script:DemoBanner)
    [Console]::Out.WriteLine('PACKET_CREATION_REFUSED')
    exit 1
}
