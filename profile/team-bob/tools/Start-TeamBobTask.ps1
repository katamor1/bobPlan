[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$TaskId,
    [Parameter(Mandatory = $true)][string]$BazaarRoot,
    [Parameter(Mandatory = $true)][string]$Difficulty,
    [Parameter(Mandatory = $true)][ValidateSet('Green', 'Amber', 'Red')][string]$Classification,
    [Parameter(Mandatory = $true)][string]$Customer,
    [Parameter(Mandatory = $true)][string[]]$ReqIds,
    [Parameter(Mandatory = $true)][string]$WordBaseline,
    [Parameter(Mandatory = $true)][string]$QaBaseline,
    [Parameter(Mandatory = $true)][string]$SpecBaseline,
    [Parameter(Mandatory = $true)][string[]]$AllowedFiles,
    [Parameter(Mandatory = $true)][string]$BuildProfileId,
    [Parameter(Mandatory = $true)][string]$SpecificationApprover,
    [Parameter(Mandatory = $true)][string]$ImplementationApprover,
    [string[]]$ForbiddenAreas = @('actual-machine', 'control-network', 'mainline', 'secrets'),
    [string]$RTImpact = 'No assessed RT impact.',
    [string]$SafetyImpact = 'No assessed safety impact.',
    [string]$BoardImpact = 'No assessed board impact.',
    [string]$DriverImpact = 'No assessed driver impact.',
    [string]$ABIImpact = 'No assessed ABI impact.',
    [string]$BuildImpact = 'No assessed build impact.',
    [string]$CustomerBranchImpact = 'No assessed customer-branch impact.',
    [ValidateSet('YES', 'NO')][string]$RTImpactClear = 'NO',
    [ValidateSet('YES', 'NO')][string]$SafetyImpactClear = 'NO',
    [ValidateSet('YES', 'NO')][string]$BoardImpactClear = 'NO',
    [ValidateSet('YES', 'NO')][string]$DriverImpactClear = 'NO',
    [ValidateSet('YES', 'NO')][string]$ABIImpactClear = 'NO',
    [ValidateSet('YES', 'NO')][string]$BuildImpactClear = 'NO',
    [ValidateSet('YES', 'NO')][string]$CustomerBranchImpactClear = 'NO',
    [string[]]$OpenQa = @(),
    [ValidateSet('YES', 'NO')][string]$AutonomousEditBuildApproved = 'NO',
    [ValidateSet('YES', 'NO')][string]$SoftExecuteRiskAccepted = 'NO',
    [int]$MaxRepairCycles = 2
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TeamBob-BuildCommon.ps1')

function Invoke-TeamBobStartBazaarRead {
    param([string]$Executable, [string]$WorkingDirectory, [string[]]$Arguments)
    Push-Location -LiteralPath $WorkingDirectory
    try { $lines = @(& $Executable @Arguments 2>&1); $exitCode = $LASTEXITCODE } finally { Pop-Location }
    if ($exitCode -ne 0) { throw "Bazaar command failed with exit code ${exitCode}: $($Arguments -join ' ')" }
    return (($lines | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine).Trim()
}

try {
    if ($TaskId -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$') { throw 'TaskId contains unsupported characters or length.' }
    foreach ($requiredText in @($Difficulty, $Customer, $WordBaseline, $QaBaseline, $SpecBaseline, $BuildProfileId, $SpecificationApprover, $ImplementationApprover)) {
        if ([string]::IsNullOrWhiteSpace($requiredText)) { throw 'Required task metadata must not be empty.' }
    }
    if (@($ReqIds).Count -eq 0 -or @($ReqIds | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) { throw 'ReqIds must contain non-empty values.' }
    foreach ($impact in @($RTImpact, $SafetyImpact, $BoardImpact, $DriverImpact, $ABIImpact, $BuildImpact, $CustomerBranchImpact)) { if ([string]::IsNullOrWhiteSpace($impact)) { throw 'Impact evidence fields must not be empty.' } }
    if (@($OpenQa | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) { throw 'OpenQa entries must be non-empty strings.' }
    if ($MaxRepairCycles -ne 2) { throw 'MaxRepairCycles is fixed to 2.' }
    if (-not (Test-TeamBobAbsolutePath $BazaarRoot) -or -not (Test-Path -LiteralPath $BazaarRoot -PathType Container)) { throw 'BazaarRoot must be an absolute existing directory.' }
    $bazaarRootFull = Get-TeamBobCanonicalPath $BazaarRoot 'BazaarRoot' 'INTEGRITY_FAILED'
    Assert-TeamBobNotVolumeRoot $bazaarRootFull 'BazaarRoot' 'INTEGRITY_FAILED'
    $bazaarRootPhysical = Get-TeamBobPhysicalPath $bazaarRootFull 'BazaarRoot' 'Container' 'INTEGRITY_FAILED'
    if (-not (Test-Path -LiteralPath (Join-Path $bazaarRootFull '.bzr') -PathType Container)) { throw 'BazaarRoot must itself contain a .bzr directory.' }
    $bzrPhysical = Get-TeamBobPhysicalPath (Join-Path $bazaarRootFull '.bzr') 'Bazaar metadata root' 'Container' 'INTEGRITY_FAILED'
    Assert-TeamBobPhysicalChild $bzrPhysical $bazaarRootPhysical 'Bazaar metadata root' 'INTEGRITY_FAILED'
    $normalizedForbidden = @(ConvertTo-TeamBobForbiddenAreas @($ForbiddenAreas) 'INTEGRITY_FAILED' $bazaarRootFull $bazaarRootPhysical)

    $teamBobWorkPath = Join-Path $bazaarRootFull 'team-bob-work'
    $teamBobWorkPlan = Get-TeamBobProspectiveDirectory $teamBobWorkPath 'team-bob-work root' 'INTEGRITY_FAILED' -RejectVolumeRoot
    Assert-TeamBobPhysicalChild $teamBobWorkPlan.PhysicalPath $bazaarRootPhysical 'team-bob-work root' 'INTEGRITY_FAILED'
    $taskDirectory = Join-Path $teamBobWorkPath $TaskId
    if (Test-Path -LiteralPath $taskDirectory) { throw "Task directory already exists: $taskDirectory" }
    $taskPlan = Get-TeamBobTrustedChildDirectory $teamBobWorkPlan.FullPath $teamBobWorkPlan.PhysicalPath $TaskId 'Task directory' 'INTEGRITY_FAILED' -RequireMissing
    $draftsPlan = Get-TeamBobTrustedChildDirectory $taskPlan.FullPath $taskPlan.PhysicalPath 'drafts' 'Task drafts directory' 'INTEGRITY_FAILED' -RequireMissing
    $resultsPlan = Get-TeamBobTrustedChildDirectory $taskPlan.FullPath $taskPlan.PhysicalPath 'results' 'Task results directory' 'INTEGRITY_FAILED' -RequireMissing

    $supportedExtensions = @('.c', '.cc', '.cpp', '.cxx', '.h', '.hh', '.hpp', '.hxx', '.inl')
    $normalizedAllowed = @()
    $seenAllowed = @{}
    foreach ($allowed in @($AllowedFiles)) {
        if ([string]::IsNullOrWhiteSpace($allowed)) { throw 'AllowedFiles must contain non-empty values.' }
        $resolved = ConvertTo-TeamBobRelativePath $bazaarRootFull $allowed 'Allowed File' 'INTEGRITY_FAILED'
        if (-not ($supportedExtensions -contains [System.IO.Path]::GetExtension($resolved.FullPath).ToLowerInvariant())) { throw "Allowed file extension is unsupported: $allowed" }
        if (-not (Test-Path -LiteralPath $resolved.FullPath -PathType Leaf)) { throw "Allowed file does not exist as a file: $allowed" }
        $allowedPhysical = Get-TeamBobPhysicalPath $resolved.FullPath "Allowed File '$allowed'" 'Leaf' 'INTEGRITY_FAILED'
        $allowedPhysicalRelative = Get-TeamBobPhysicalRelativePath $allowedPhysical $bazaarRootPhysical "Allowed File '$allowed'" 'INTEGRITY_FAILED'
        foreach ($forbidden in $normalizedForbidden) {
            if ((Test-TeamBobRelativePathAtOrBelow $resolved.RelativePath $forbidden) -or
                (Test-TeamBobRelativePathAtOrBelow $allowedPhysicalRelative $forbidden)) { throw "Allowed file is equal to or below Forbidden Areas entry '$forbidden': $allowed" }
        }
        $allowedKey = $allowedPhysicalRelative.ToLowerInvariant()
        if ($seenAllowed.ContainsKey($allowedKey)) { throw "Allowed file is duplicated after normalization: $allowed" }
        $seenAllowed[$allowedKey] = $true
        $normalizedAllowed += $allowedPhysicalRelative
    }
    if ($normalizedAllowed.Count -eq 0) { throw 'AllowedFiles must contain at least one supported file.' }

    $impactClearValues = @($RTImpactClear, $SafetyImpactClear, $BoardImpactClear, $DriverImpactClear, $ABIImpactClear, $BuildImpactClear, $CustomerBranchImpactClear)
    if ($Classification -eq 'Green') {
        if (@($OpenQa).Count -gt 0) { throw 'Green tasks cannot contain OpenQa items.' }
        if (@($impactClearValues | Where-Object { $_ -ne 'YES' }).Count -gt 0) { throw 'Green tasks require YES for every impact-clear gate.' }
        if ($AutonomousEditBuildApproved -ne 'YES' -or $SoftExecuteRiskAccepted -ne 'YES') { throw 'Green tasks require both explicit YES approvals.' }
    }
    if ($AutonomousEditBuildApproved -ne 'YES' -or $SoftExecuteRiskAccepted -ne 'YES') { throw 'A schema-valid work packet requires both explicit YES approvals.' }

    $profileRoot = Split-Path -Parent $PSScriptRoot
    $manifestPath = Join-Path $profileRoot 'profile-manifest.json'
    $workSchemaPath = Join-Path $profileRoot 'config/work-packet.schema.json'
    $buildSchemaPath = Join-Path $profileRoot 'config/vc6-build-targets.schema.json'
    $environment = Get-TeamBobLocalEnvironment $manifestPath $workSchemaPath $buildSchemaPath -BazaarOnly
    $sandboxPhysical = Get-TeamBobPhysicalPath $environment.sandboxRoot 'Registered sandbox root' 'Container' 'INTEGRITY_FAILED'
    $logPhysical = Get-TeamBobPhysicalPath $environment.logRoot 'Registered log root' 'Container' 'INTEGRITY_FAILED'
    Assert-TeamBobPhysicalSeparation $bazaarRootPhysical $sandboxPhysical 'Bazaar and sandbox roots' 'INTEGRITY_FAILED'
    Assert-TeamBobPhysicalSeparation $bazaarRootPhysical $logPhysical 'Bazaar and log roots' 'INTEGRITY_FAILED'
    Assert-TeamBobPhysicalSeparation $sandboxPhysical $logPhysical 'Sandbox and log roots' 'INTEGRITY_FAILED'

    $status = Invoke-TeamBobStartBazaarRead $environment.bazaarPath $bazaarRootFull @('status', '--short')
    if (-not [string]::IsNullOrWhiteSpace($status)) { throw 'Bazaar working tree is not clean.' }
    $branch = Invoke-TeamBobStartBazaarRead $environment.bazaarPath $bazaarRootFull @('nick')
    if ([string]::IsNullOrWhiteSpace($branch)) { throw 'Bazaar branch nick is empty.' }
    $revision = Invoke-TeamBobStartBazaarRead $environment.bazaarPath $bazaarRootFull @('version-info', '--custom', '--template={revision_id}')
    if ([string]::IsNullOrWhiteSpace($revision)) { throw 'Bazaar full revision id is empty.' }

    $templatePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'templates/work-packet.md'
    if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) { throw "Work-packet template is missing: $templatePath" }
    $packet = [ordered]@{
        'Profile Version' = '0.1.0-poc'; 'Task ID' = $TaskId; 'Difficulty' = $Difficulty; 'Risk' = $Classification; 'Customer' = $Customer
        'ReqIDs' = @($ReqIds); 'Word Baseline' = $WordBaseline; 'QA Baseline' = $QaBaseline; 'Spec Baseline' = $SpecBaseline
        'Bazaar Root' = $bazaarRootFull; 'Bazaar Branch' = $branch; 'Bazaar Full Revision ID' = $revision
        'Allowed Files' = @($normalizedAllowed); 'Forbidden Areas' = @($normalizedForbidden)
        'RT Impact' = $RTImpact; 'Safety Impact' = $SafetyImpact; 'Board Impact' = $BoardImpact; 'Driver Impact' = $DriverImpact
        'ABI Impact' = $ABIImpact; 'Build Impact' = $BuildImpact; 'Customer Branch Impact' = $CustomerBranchImpact
        'RT Impact Clear' = $RTImpactClear; 'Safety Impact Clear' = $SafetyImpactClear; 'Board Impact Clear' = $BoardImpactClear
        'Driver Impact Clear' = $DriverImpactClear; 'ABI Impact Clear' = $ABIImpactClear; 'Build Impact Clear' = $BuildImpactClear
        'Customer Branch Impact Clear' = $CustomerBranchImpactClear; 'Clean Working Copy' = 'YES'; 'Open QA' = @($OpenQa)
        'Build Profile ID' = $BuildProfileId; 'Autonomous-Edit-Build-Approved' = $AutonomousEditBuildApproved
        'Soft-Execute-Risk-Accepted' = $SoftExecuteRiskAccepted; 'Max-Repair-Cycles' = 2
        'Specification Approver' = $SpecificationApprover; 'Implementation Approver' = $ImplementationApprover
    }
    Assert-TeamBobWorkPacketContract ([pscustomobject]$packet)
    [void](Get-TeamBobPhysicalPath $templatePath 'Work-packet template' 'Leaf' 'INTEGRITY_FAILED')
    $template = Read-TeamBobUtf8File $templatePath 'Work-packet template' 'INTEGRITY_FAILED'
    $pattern = '(?s)(<!-- canonical-work-packet-json:start -->\s*```json\s*)\{.*?\}(\s*```\s*<!-- canonical-work-packet-json:end -->)'
    if (-not [regex]::IsMatch($template, $pattern)) { throw 'Work-packet template canonical JSON block is malformed.' }
    $packetJson = $packet | ConvertTo-Json -Depth 10
    $replacementEvaluator = [System.Text.RegularExpressions.MatchEvaluator] {
        param($match)
        return $match.Groups[1].Value + $packetJson + $match.Groups[2].Value
    }
    $document = [regex]::Replace($template, $pattern, $replacementEvaluator, 1)

    $teamBobWorkCreated = Get-TeamBobProspectiveDirectory $teamBobWorkPlan.FullPath 'team-bob-work root' 'INTEGRITY_FAILED' -RejectVolumeRoot -Create
    Assert-TeamBobPhysicalChild $teamBobWorkCreated.PhysicalPath $bazaarRootPhysical 'team-bob-work root' 'INTEGRITY_FAILED'
    $taskCreated = Get-TeamBobTrustedChildDirectory $teamBobWorkCreated.FullPath $teamBobWorkCreated.PhysicalPath $TaskId 'Task directory' 'INTEGRITY_FAILED' -RequireMissing -Create
    $draftsCreated = Get-TeamBobTrustedChildDirectory $taskCreated.FullPath $taskCreated.PhysicalPath 'drafts' 'Task drafts directory' 'INTEGRITY_FAILED' -RequireMissing -Create
    $resultsCreated = Get-TeamBobTrustedChildDirectory $taskCreated.FullPath $taskCreated.PhysicalPath 'results' 'Task results directory' 'INTEGRITY_FAILED' -RequireMissing -Create
    $packetPath = Join-Path $taskDirectory 'work-packet.md'
    Write-TeamBobUtf8File $packetPath $document $teamBobWorkCreated.PhysicalPath
    Write-Output "CREATED $packetPath"
    exit 0
} catch {
    Write-Error $_.Exception.Message
    exit 1
}
