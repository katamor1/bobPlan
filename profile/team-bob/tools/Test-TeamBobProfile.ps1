[CmdletBinding()]
param(
    [string]$RepositoryRoot,
    [string]$BuildProfileId,
    [switch]$Strict
)

$ErrorActionPreference = 'Stop'
$script:passed = 0
$script:failed = 0
$script:skipped = 0

function Add-TeamBobCheck {
    param([string]$Name, [bool]$Passed, [string]$Detail, [switch]$Skip)
    if ($Skip) {
        $script:skipped++
        Write-Output "SKIP $Name - $Detail"
    } elseif ($Passed) {
        $script:passed++
        Write-Output "PASS $Name - $Detail"
    } else {
        $script:failed++
        Write-Output "FAIL $Name - $Detail"
    }
}

function Test-TeamBobPathOutside {
    param([string]$Candidate, [string]$Root)
    $candidateFull = [System.IO.Path]::GetFullPath($Candidate).TrimEnd('\', '/')
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    if ($candidateFull.Equals($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
    return -not $candidateFull.StartsWith($rootFull + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)
}

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) { $RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
$rootValid = $RepositoryRoot -match '^(?:[A-Za-z]:[\\/]|\\\\[^\\/]+[\\/][^\\/]+)' -and (Test-Path -LiteralPath $RepositoryRoot -PathType Container)
Add-TeamBobCheck 'Repository root' $rootValid $RepositoryRoot
if (-not $rootValid) {
    Write-Output "SUMMARY Passed=$script:passed Failed=$script:failed Skipped=$script:skipped"
    exit 1
}
$RepositoryRoot = [System.IO.Path]::GetFullPath($RepositoryRoot)
$teamBobRoot = Join-Path $RepositoryRoot 'team-bob'

$manifest = $null
$manifestPath = Join-Path $teamBobRoot 'profile-manifest.json'
try {
    $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
    $manifestValid = $manifest.version -eq '0.1.0-poc' -and $manifest.profile.id -eq 'team-bob-vc6-bazaar'
    Add-TeamBobCheck 'Manifest identity' $manifestValid 'Expected team-bob-vc6-bazaar version 0.1.0-poc'
} catch {
    Add-TeamBobCheck 'Manifest identity' $false $_.Exception.Message
}

$requiredRelativePaths = @(
    'AGENTS.md', '.bobignore.base', '.bzrignore.snippet', '.bob/custom_modes.yaml',
    '.bob/commands/bob-normalize-requirements.md', '.bob/commands/bob-draft-spec.md', '.bob/commands/bob-analyze-impact.md',
    '.bob/commands/bob-implement-green.md', '.bob/commands/bob-review-change.md', '.bob/commands/bob-draft-test.md',
    '.bob/rules/00-governance.md', '.bob/rules/10-vc6-realtime.md', '.bob/rules/20-traceability.md', '.bob/rules/30-output-contracts.md',
    '.bob/rules-green-implement/10-edit-build-loop.md', 'team-bob/templates/work-packet.md', 'team-bob/templates/requirement-ledger.csv',
    'team-bob/templates/external-spec.md', 'team-bob/templates/impact-analysis.md', 'team-bob/templates/code-review.md',
    'team-bob/templates/test-spec.md', 'team-bob/templates/review-rubric.md', 'team-bob/templates/usage-log.csv',
    'team-bob/templates/exception-record.md', 'team-bob/config/work-packet.schema.json',
    'team-bob/config/vc6-build-targets.schema.json', 'team-bob/config/vc6-build-targets.json',
    'team-bob/tools/Initialize-LocalEnvironment.ps1', 'team-bob/tools/Start-TeamBobTask.ps1', 'team-bob/tools/Test-TeamBobProfile.ps1'
)
$missingRequired = @($requiredRelativePaths | Where-Object { -not (Test-Path -LiteralPath (Join-Path $RepositoryRoot $_) -PathType Leaf) })
Add-TeamBobCheck 'Required modes commands rules templates and tools' ($missingRequired.Count -eq 0) (($missingRequired -join ', '))

try {
    $modes = Get-Content -Raw -LiteralPath (Join-Path $RepositoryRoot '.bob/custom_modes.yaml') | ConvertFrom-Json
    $slugs = @($modes.customModes.slug)
    $requiredSlugs = @('req-spec-draft', 'impact-review', 'green-implement', 'change-review', 'test-draft')
    $modesValid = $slugs.Count -eq 5 -and @($requiredSlugs | Where-Object { $slugs -notcontains $_ }).Count -eq 0
    Add-TeamBobCheck 'Mode document shape' $modesValid 'Five required custom mode slugs'
} catch { Add-TeamBobCheck 'Mode document shape' $false $_.Exception.Message }

$workSchema = $null
try {
    $workSchema = Get-Content -Raw -LiteralPath (Join-Path $teamBobRoot 'config/work-packet.schema.json') | ConvertFrom-Json
    $workShape = $workSchema.type -eq 'object' -and $workSchema.additionalProperties -eq $false -and @($workSchema.required).Count -eq 36 -and $workSchema.properties.'Max-Repair-Cycles'.const -eq 2
    Add-TeamBobCheck 'Work-packet JSON schema shape' $workShape 'Closed object with required packet fields and fixed repair budget'
} catch { Add-TeamBobCheck 'Work-packet JSON schema shape' $false $_.Exception.Message }

$buildSchema = $null
try {
    $buildSchema = Get-Content -Raw -LiteralPath (Join-Path $teamBobRoot 'config/vc6-build-targets.schema.json') | ConvertFrom-Json
    $buildShape = $buildSchema.type -eq 'object' -and $buildSchema.properties.profiles.type -eq 'array' -and @($buildSchema.properties.profiles.items.required).Count -ge 13
    Add-TeamBobCheck 'Build-target JSON schema shape' $buildShape 'Profiles array has the fixed qualified target interface'
} catch { Add-TeamBobCheck 'Build-target JSON schema shape' $false $_.Exception.Message }

$targets = $null
try {
    $targets = Get-Content -Raw -LiteralPath (Join-Path $teamBobRoot 'config/vc6-build-targets.json') | ConvertFrom-Json
    Add-TeamBobCheck 'Build-target catalog JSON shape' ($null -ne $targets.PSObject.Properties['profiles'] -and $targets.profiles -is [System.Array]) 'Catalog exposes a profiles array'
} catch { Add-TeamBobCheck 'Build-target catalog JSON shape' $false $_.Exception.Message }

$environment = $null
$environmentPath = Join-Path $env:LOCALAPPDATA 'IBM/BobTeamProfile/vc6-machine-control-poc/environment.json'
if (-not (Test-Path -LiteralPath $environmentPath -PathType Leaf)) {
    if ($Strict) { Add-TeamBobCheck 'Local environment registration' $false "Missing fixed registration: $environmentPath" }
    else { Add-TeamBobCheck 'Local environment registration' $false 'Not registered; optional outside Strict mode' -Skip }
} else {
    try {
        $environment = Get-Content -Raw -LiteralPath $environmentPath | ConvertFrom-Json
        $identityValid = $null -ne $manifest -and $null -ne $workSchema -and $null -ne $buildSchema -and
            $environment.schemaVersion -eq '1.0' -and $environment.profileId -eq $manifest.profile.id -and
            $environment.profileVersion -eq $manifest.version -and $environment.workPacketSchemaId -eq $workSchema.'$id' -and
            $environment.buildTargetSchemaId -eq $buildSchema.'$id'
        Add-TeamBobCheck 'Local environment identity' $identityValid 'Registration matches manifest and schema identities'

        $msdevExists = Test-Path -LiteralPath $environment.msdevPath -PathType Leaf
        Add-TeamBobCheck 'MSDEV file' $msdevExists ([string]$environment.msdevPath)
        $msdevHashValid = $msdevExists -and (Get-FileHash -Algorithm SHA256 -LiteralPath $environment.msdevPath).Hash.ToLowerInvariant() -eq $environment.msdevSha256
        Add-TeamBobCheck 'MSDEV hash' $msdevHashValid 'Registered SHA-256 matches tool bytes'

        $bazaarExists = Test-Path -LiteralPath $environment.bazaarPath -PathType Leaf
        Add-TeamBobCheck 'Bazaar file' $bazaarExists ([string]$environment.bazaarPath)
        $bazaarHashValid = $bazaarExists -and (Get-FileHash -Algorithm SHA256 -LiteralPath $environment.bazaarPath).Hash.ToLowerInvariant() -eq $environment.bazaarSha256
        Add-TeamBobCheck 'Bazaar hash' $bazaarHashValid 'Registered SHA-256 matches tool bytes'

        $sandboxExists = Test-Path -LiteralPath $environment.sandboxRoot -PathType Container
        $logExists = Test-Path -LiteralPath $environment.logRoot -PathType Container
        Add-TeamBobCheck 'Sandbox root' ($sandboxExists -and (Test-TeamBobPathOutside $environment.sandboxRoot $RepositoryRoot)) 'Exists outside RepositoryRoot'
        Add-TeamBobCheck 'Log root' ($logExists -and (Test-TeamBobPathOutside $environment.logRoot $RepositoryRoot)) 'Exists outside RepositoryRoot'
    } catch { Add-TeamBobCheck 'Local environment JSON' $false $_.Exception.Message }
}

if (-not [string]::IsNullOrWhiteSpace($BuildProfileId)) {
    $selected = @($targets.profiles | Where-Object { $_.id -eq $BuildProfileId })
    Add-TeamBobCheck 'Selected build profile exists' ($selected.Count -eq 1) $BuildProfileId
    if ($selected.Count -eq 1) {
        $profile = $selected[0]
        Add-TeamBobCheck 'Selected build profile enabled' ($profile.enabled -eq $true) $BuildProfileId
        $qualification = $profile.qualification
        $qualified = $null -ne $qualification -and $qualification.msdevHelp -eq $true -and $qualification.makeSucceeded -eq $true -and
            $qualification.rebuildSucceeded -eq $true -and $qualification.compileFailureObserved -eq $true -and
            $qualification.linkFailureObserved -eq $true -and -not [string]::IsNullOrWhiteSpace($qualification.pcId) -and
            -not [string]::IsNullOrWhiteSpace($qualification.recordId) -and -not [string]::IsNullOrWhiteSpace($qualification.recordedAt)
        Add-TeamBobCheck 'Selected build profile qualified' $qualified $BuildProfileId
    }
} else {
    Add-TeamBobCheck 'Build profile selection' $true 'No BuildProfileId requested; empty or disabled catalogs are allowed'
}

Write-Output "SUMMARY Passed=$script:passed Failed=$script:failed Skipped=$script:skipped"
if ($script:failed -eq 0) { exit 0 } else { exit 1 }
