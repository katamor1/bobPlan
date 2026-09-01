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

function Test-TeamBobAbsolutePath {
    param([string]$Path)
    return $Path -match '^(?:[A-Za-z]:[\\/]|\\\\[^\\/]+[\\/][^\\/]+)'
}

function Get-TeamBobCanonicalDirectory {
    param([string]$Path)
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $volumeRoot = [System.IO.Path]::GetPathRoot($fullPath)
    if ($fullPath.Equals($volumeRoot, [System.StringComparison]::OrdinalIgnoreCase)) { return $volumeRoot }
    return $fullPath.TrimEnd('\', '/')
}

function Invoke-TeamBobBazaarRead {
    param([string]$Executable, [string]$WorkingDirectory, [string[]]$Arguments)
    Push-Location -LiteralPath $WorkingDirectory
    try {
        $lines = @(& $Executable @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    if ($exitCode -ne 0) { throw "Bazaar command failed with exit code ${exitCode}: $($Arguments -join ' ')" }
    return (($lines | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine).Trim()
}

try {
    if ($TaskId -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$') { throw 'TaskId contains unsupported characters or length.' }
    foreach ($requiredText in @($Difficulty, $Customer, $WordBaseline, $QaBaseline, $SpecBaseline, $BuildProfileId, $SpecificationApprover, $ImplementationApprover)) {
        if ([string]::IsNullOrWhiteSpace($requiredText)) { throw 'Required task metadata must not be empty.' }
    }
    if (@($ReqIds).Count -eq 0 -or @($ReqIds | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) { throw 'ReqIds must contain non-empty values.' }
    if (@($ForbiddenAreas).Count -eq 0 -or @($ForbiddenAreas | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) { throw 'ForbiddenAreas must contain non-empty values.' }
    if ($MaxRepairCycles -ne 2) { throw 'MaxRepairCycles is fixed to 2.' }
    if (-not (Test-TeamBobAbsolutePath $BazaarRoot) -or -not (Test-Path -LiteralPath $BazaarRoot -PathType Container)) { throw 'BazaarRoot must be an absolute existing directory.' }
    $bazaarRootFull = Get-TeamBobCanonicalDirectory $BazaarRoot
    if (-not (Test-Path -LiteralPath (Join-Path $bazaarRootFull '.bzr') -PathType Container)) { throw 'BazaarRoot must itself contain a .bzr directory.' }
    $taskDirectory = Join-Path $bazaarRootFull (Join-Path 'team-bob-work' $TaskId)
    if (Test-Path -LiteralPath $taskDirectory) { throw "Task directory already exists: $taskDirectory" }

    $supportedExtensions = @('.c', '.cc', '.cpp', '.cxx', '.h', '.hh', '.hpp', '.hxx', '.inl')
    $normalizedAllowed = @()
    foreach ($allowed in @($AllowedFiles)) {
        if ([string]::IsNullOrWhiteSpace($allowed)) { throw 'AllowedFiles must contain non-empty values.' }
        if ([System.IO.Path]::IsPathRooted($allowed) -or $allowed -match '(^|[\\/])\.\.?([\\/]|$)') { throw "Allowed file must be a relative path within BazaarRoot: $allowed" }
        $candidate = [System.IO.Path]::GetFullPath((Join-Path $bazaarRootFull $allowed))
        $prefix = $bazaarRootFull
        if (-not ($prefix.EndsWith('\') -or $prefix.EndsWith('/'))) { $prefix += [System.IO.Path]::DirectorySeparatorChar }
        if (-not $candidate.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { throw "Allowed file resolves outside BazaarRoot: $allowed" }
        if (-not ($supportedExtensions -contains [System.IO.Path]::GetExtension($candidate).ToLowerInvariant())) { throw "Allowed file extension is unsupported: $allowed" }
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { throw "Allowed file does not exist as a file: $allowed" }
        $normalizedAllowed += ($candidate.Substring($prefix.Length).Replace('\', '/'))
    }
    if ($normalizedAllowed.Count -eq 0) { throw 'AllowedFiles must contain at least one supported file.' }

    $impactClearValues = @($RTImpactClear, $SafetyImpactClear, $BoardImpactClear, $DriverImpactClear, $ABIImpactClear, $BuildImpactClear, $CustomerBranchImpactClear)
    if ($Classification -eq 'Green') {
        if (@($OpenQa).Count -gt 0) { throw 'Green tasks cannot contain OpenQa items.' }
        if (@($impactClearValues | Where-Object { $_ -ne 'YES' }).Count -gt 0) { throw 'Green tasks require YES for every impact-clear gate.' }
        if ($AutonomousEditBuildApproved -ne 'YES' -or $SoftExecuteRiskAccepted -ne 'YES') { throw 'Green tasks require both explicit YES approvals.' }
    }
    if ($AutonomousEditBuildApproved -ne 'YES' -or $SoftExecuteRiskAccepted -ne 'YES') { throw 'A schema-valid work packet requires both explicit YES approvals.' }

    $environmentPath = Join-Path $env:LOCALAPPDATA 'IBM/BobTeamProfile/vc6-machine-control-poc/environment.json'
    if (-not (Test-Path -LiteralPath $environmentPath -PathType Leaf)) { throw "Local environment registration is missing: $environmentPath" }
    $environment = Get-Content -Raw -LiteralPath $environmentPath | ConvertFrom-Json
    if ($environment.profileId -ne 'team-bob-vc6-bazaar' -or $environment.profileVersion -ne '0.1.0-poc') { throw 'Local environment profile identity does not match this profile.' }
    if (-not (Test-Path -LiteralPath $environment.bazaarPath -PathType Leaf)) { throw 'Registered Bazaar executable is missing.' }
    $actualBazaarHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $environment.bazaarPath).Hash.ToLowerInvariant()
    if ($actualBazaarHash -ne $environment.bazaarSha256) { throw 'Registered Bazaar executable hash does not match.' }

    $status = Invoke-TeamBobBazaarRead $environment.bazaarPath $bazaarRootFull @('status', '--short')
    if (-not [string]::IsNullOrWhiteSpace($status)) { throw 'Bazaar working tree is not clean.' }
    $branch = Invoke-TeamBobBazaarRead $environment.bazaarPath $bazaarRootFull @('nick')
    if ([string]::IsNullOrWhiteSpace($branch)) { throw 'Bazaar branch nick is empty.' }
    $revision = Invoke-TeamBobBazaarRead $environment.bazaarPath $bazaarRootFull @('version-info', '--custom', '--template={revision_id}')
    if ([string]::IsNullOrWhiteSpace($revision)) { throw 'Bazaar full revision id is empty.' }

    $templatePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'templates/work-packet.md'
    if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) { throw "Work-packet template is missing: $templatePath" }
    $packet = [ordered]@{
        'Profile Version' = '0.1.0-poc'; 'Task ID' = $TaskId; 'Difficulty' = $Difficulty; 'Risk' = $Classification; 'Customer' = $Customer
        'ReqIDs' = @($ReqIds); 'Word Baseline' = $WordBaseline; 'QA Baseline' = $QaBaseline; 'Spec Baseline' = $SpecBaseline
        'Bazaar Root' = $bazaarRootFull; 'Bazaar Branch' = $branch; 'Bazaar Full Revision ID' = $revision
        'Allowed Files' = @($normalizedAllowed); 'Forbidden Areas' = @($ForbiddenAreas)
        'RT Impact' = $RTImpact; 'Safety Impact' = $SafetyImpact; 'Board Impact' = $BoardImpact; 'Driver Impact' = $DriverImpact
        'ABI Impact' = $ABIImpact; 'Build Impact' = $BuildImpact; 'Customer Branch Impact' = $CustomerBranchImpact
        'RT Impact Clear' = $RTImpactClear; 'Safety Impact Clear' = $SafetyImpactClear; 'Board Impact Clear' = $BoardImpactClear
        'Driver Impact Clear' = $DriverImpactClear; 'ABI Impact Clear' = $ABIImpactClear; 'Build Impact Clear' = $BuildImpactClear
        'Customer Branch Impact Clear' = $CustomerBranchImpactClear; 'Clean Working Copy' = 'YES'; 'Open QA' = @($OpenQa)
        'Build Profile ID' = $BuildProfileId; 'Autonomous-Edit-Build-Approved' = $AutonomousEditBuildApproved
        'Soft-Execute-Risk-Accepted' = $SoftExecuteRiskAccepted; 'Max-Repair-Cycles' = 2
        'Specification Approver' = $SpecificationApprover; 'Implementation Approver' = $ImplementationApprover
    }
    $template = [System.IO.File]::ReadAllText($templatePath)
    $pattern = '(?s)(<!-- canonical-work-packet-json:start -->\s*```json\s*)\{.*?\}(\s*```\s*<!-- canonical-work-packet-json:end -->)'
    if (-not [regex]::IsMatch($template, $pattern)) { throw 'Work-packet template canonical JSON block is malformed.' }
    $packetJson = $packet | ConvertTo-Json -Depth 10
    $replacementEvaluator = [System.Text.RegularExpressions.MatchEvaluator] {
        param($match)
        return $match.Groups[1].Value + $packetJson + $match.Groups[2].Value
    }
    $document = [regex]::Replace($template, $pattern, $replacementEvaluator, 1)

    $draftsDirectory = Join-Path $taskDirectory 'drafts'
    $resultsDirectory = Join-Path $taskDirectory 'results'
    New-Item -ItemType Directory -Path $draftsDirectory -Force | Out-Null
    New-Item -ItemType Directory -Path $resultsDirectory -Force | Out-Null
    $packetPath = Join-Path $taskDirectory 'work-packet.md'
    $temporaryPacket = Join-Path $taskDirectory ('.work-packet.' + [guid]::NewGuid().ToString('N') + '.tmp')
    [System.IO.File]::WriteAllText($temporaryPacket, $document, (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::Move($temporaryPacket, $packetPath)
    Write-Output "CREATED $packetPath"
    exit 0
} catch {
    Write-Error $_.Exception.Message
    exit 1
}
