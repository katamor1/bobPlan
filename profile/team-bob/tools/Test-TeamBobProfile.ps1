[CmdletBinding()]
param(
    [string]$RepositoryRoot,
    [string]$BuildProfileId,
    [switch]$Strict
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TeamBob-BuildCommon.ps1')
. (Join-Path $PSScriptRoot 'TeamBob-GovernanceCommon.ps1')

function Get-TeamBobSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try { $stream = [System.IO.File]::OpenRead($Path); try { return ([BitConverter]::ToString($sha256.ComputeHash($stream)).Replace('-', '').ToLowerInvariant()) } finally { $stream.Dispose() } } finally { $sha256.Dispose() }
}
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

function Test-TeamBobRelativePath {
    param([object]$Value, [string]$ExtensionPattern = '')
    if (-not ($Value -is [string]) -or [string]::IsNullOrWhiteSpace($Value) -or [System.IO.Path]::IsPathRooted($Value)) { return $false }
    if ($Value -match '(^|[\\/])\.\.?([\\/]|$)') { return $false }
    if (-not [string]::IsNullOrWhiteSpace($ExtensionPattern) -and $Value -notmatch $ExtensionPattern) { return $false }
    return $true
}

function Test-TeamBobInteger {
    param([object]$Value)
    return $Value -is [sbyte] -or $Value -is [byte] -or $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int32] -or $Value -is [uint32] -or $Value -is [int64] -or $Value -is [uint64]
}

function Test-TeamBobBuildProfileContract {
    param([object]$Profile)
    $errors = @()
    if (-not ($Profile -is [System.Management.Automation.PSCustomObject])) { return @('profile type') }
    $required = @('id', 'enabled', 'projectFile', 'target', 'timeoutSeconds', 'expectedArtifacts', 'excludePatterns', 'outputLogPattern', 'successPattern', 'compilerErrorPattern', 'linkerErrorPattern', 'environmentErrorPattern', 'qualification')
    $actual = @($Profile.PSObject.Properties.Name)
    $actualFieldsKey = (($actual | Sort-Object) -join ',')
    $requiredFieldsKey = (($required | Sort-Object) -join ',')
    if ($actualFieldsKey -ne $requiredFieldsKey) { $errors += 'profile fields' }
    if (-not ($Profile.id -is [string]) -or [string]::IsNullOrWhiteSpace($Profile.id)) { $errors += 'id' }
    if (-not ($Profile.enabled -is [bool])) { $errors += 'enabled' }
    if (-not (Test-TeamBobRelativePath $Profile.projectFile '\.(?:dsw|dsp)$')) { $errors += 'projectFile' }
    if (-not ($Profile.target -is [string]) -or [string]::IsNullOrWhiteSpace($Profile.target)) { $errors += 'target' }
    if (-not (Test-TeamBobInteger $Profile.timeoutSeconds) -or [int64]$Profile.timeoutSeconds -lt 1) { $errors += 'timeoutSeconds' }
    if (-not ($Profile.expectedArtifacts -is [System.Array]) -or @($Profile.expectedArtifacts).Count -lt 1) {
        $errors += 'expectedArtifacts'
    } else {
        foreach ($artifact in @($Profile.expectedArtifacts)) { if (-not (Test-TeamBobRelativePath $artifact)) { $errors += 'expectedArtifact item' } }
    }
    if (-not ($Profile.excludePatterns -is [System.Array])) {
        $errors += 'excludePatterns'
    } else {
        foreach ($exclude in @($Profile.excludePatterns)) { if (-not ($exclude -is [string]) -or [string]::IsNullOrWhiteSpace($exclude)) { $errors += 'excludePatterns item' } }
    }
    foreach ($field in @('outputLogPattern', 'successPattern', 'compilerErrorPattern', 'linkerErrorPattern', 'environmentErrorPattern')) {
        $pattern = $Profile.PSObject.Properties[$field].Value
        if (-not ($pattern -is [string]) -or [string]::IsNullOrWhiteSpace($pattern)) {
            $errors += $field
        } else {
            try { [void][regex]::IsMatch('', $pattern) } catch { $errors += "$field regex" }
        }
    }
    $qualification = $Profile.qualification
    $qualificationFields = @('msdevHelp', 'makeSucceeded', 'rebuildSucceeded', 'compileFailureObserved', 'linkFailureObserved', 'pcId', 'recordId', 'recordedAt')
    if (-not ($qualification -is [System.Management.Automation.PSCustomObject])) {
        $errors += 'qualification type'
    } else {
        $actualQualificationKey = ((@($qualification.PSObject.Properties.Name) | Sort-Object) -join ',')
        $requiredQualificationKey = (($qualificationFields | Sort-Object) -join ',')
        if ($actualQualificationKey -ne $requiredQualificationKey) { $errors += 'qualification fields' }
        foreach ($field in @('msdevHelp', 'makeSucceeded', 'rebuildSucceeded', 'compileFailureObserved', 'linkFailureObserved')) {
            if (-not ($qualification.PSObject.Properties[$field].Value -is [bool])) { $errors += "qualification $field" }
        }
        foreach ($field in @('pcId', 'recordId')) {
            $value = $qualification.PSObject.Properties[$field].Value
            if (-not ($value -is [string]) -or [string]::IsNullOrWhiteSpace($value)) { $errors += "qualification $field" }
        }
        $recordedAt = $qualification.PSObject.Properties['recordedAt'].Value
        if ((-not ($recordedAt -is [string]) -or [string]::IsNullOrWhiteSpace($recordedAt)) -and -not ($recordedAt -is [datetime])) { $errors += 'qualification recordedAt' }
    }
    return @($errors)
}

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) { $RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
$repositoryPhysical = $null
try {
    $RepositoryRoot = Get-TeamBobCanonicalPath $RepositoryRoot 'Repository root' 'ENVIRONMENT_FAILED'
    Assert-TeamBobNotVolumeRoot $RepositoryRoot 'Repository root' 'ENVIRONMENT_FAILED'
    $repositoryPhysical = Get-TeamBobPhysicalPath $RepositoryRoot 'Repository root' 'Container' 'ENVIRONMENT_FAILED'
    $rootValid = $true
} catch {
    $rootValid = $false
    $rootFailure = $_.Exception.Message
}
Add-TeamBobCheck 'Repository root' $rootValid $(if ($rootValid) { $RepositoryRoot } else { $rootFailure })
if (-not $rootValid) {
    Write-Output "SUMMARY Passed=$script:passed Failed=$script:failed Skipped=$script:skipped"
    exit 1
}
$teamBobRoot = Join-Path $RepositoryRoot 'team-bob'
$environmentBoundaryPhysical = $repositoryPhysical
$sourceRepositoryCandidate = Split-Path -Parent $RepositoryRoot
if ((Split-Path -Leaf $RepositoryRoot) -eq 'profile' -and
    (Test-Path -LiteralPath (Join-Path $sourceRepositoryCandidate 'scripts/Install-TeamBobProfile.ps1') -PathType Leaf)) {
    try { $environmentBoundaryPhysical = Get-TeamBobPhysicalPath $sourceRepositoryCandidate 'Distribution repository root' 'Container' 'ENVIRONMENT_FAILED' } catch {
        Add-TeamBobCheck 'Distribution repository root' $false $_.Exception.Message
        $environmentBoundaryPhysical = $null
    }
}

$manifest = $null
$manifestPath = Join-Path $teamBobRoot 'profile-manifest.json'
try {
    $manifest = Read-TeamBobJsonFile $manifestPath 'Profile manifest' 'ENVIRONMENT_FAILED'
    $manifestValid = $manifest.version -eq '0.2.0-poc' -and $manifest.profile.id -eq 'team-bob-vc6-bazaar'
    Add-TeamBobCheck 'Manifest identity' $manifestValid 'Expected team-bob-vc6-bazaar version 0.2.0-poc'
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
    'team-bob/tools/Initialize-LocalEnvironment.ps1', 'team-bob/tools/Start-TeamBobTask.ps1', 'team-bob/tools/Test-TeamBobProfile.ps1',
    'team-bob/tools/Invoke-Vc6Build.ps1', 'team-bob/tools/Export-BazaarEvidence.ps1', 'team-bob/tools/TeamBob-BuildCommon.ps1',
    'team-bob/tools/TeamBob-GovernanceCommon.ps1', 'team-bob/tools/TeamBob-ComplianceCommon.ps1', 'team-bob/tools/Test-TeamBobGovernance.ps1',
    'team-bob/tools/New-TeamBobApprovalRecord.ps1', 'team-bob/tools/Invoke-TeamBobComplianceCheck.ps1',
    '.bob/governance/policy-manifest.json', '.bob/governance/glossary.json', '.bob/governance/checklists/authoring.json',
    '.bob/governance/checklists/review.json', '.bob/governance/roles.json', '.bob/governance/schemas/policy-manifest.schema.json',
    '.bob/governance/schemas/glossary.schema.json', '.bob/governance/schemas/checklist.schema.json', '.bob/governance/schemas/roles.schema.json',
    '.bob/governance/schemas/approval-record.schema.json', '.bob/governance/schemas/compliance-assessment.schema.json',
    '.bob/governance/schemas/compliance-result.schema.json', '.bob/governance/schemas/phase-state.schema.json'
)
$missingRequired = @($requiredRelativePaths | Where-Object { -not (Test-Path -LiteralPath (Join-Path $RepositoryRoot $_) -PathType Leaf) })
Add-TeamBobCheck 'Required modes commands rules templates and tools' ($missingRequired.Count -eq 0) (($missingRequired -join ', '))

$governanceErrors = @(Test-TeamBobGovernancePackage -GovernanceRoot (Join-Path $RepositoryRoot '.bob/governance'))
Add-TeamBobCheck 'Governance package' ($governanceErrors.Count -eq 0) (($governanceErrors -join '; '))
if ($Strict -and $governanceErrors.Count -eq 0) {
    $roleErrors = @(Test-TeamBobGovernanceStrictReadiness -GovernanceRoot (Join-Path $RepositoryRoot '.bob/governance'))
    Add-TeamBobCheck 'Governance role readiness' ($roleErrors.Count -eq 0) (($roleErrors -join '; '))
}

try {
    $modes = Read-TeamBobJsonFile (Join-Path $RepositoryRoot '.bob/custom_modes.yaml') 'Custom modes document' 'ENVIRONMENT_FAILED'
    $slugs = @($modes.customModes.slug)
    $requiredSlugs = @('req-spec-draft', 'impact-review', 'green-implement', 'change-review', 'test-draft')
    $modesValid = $slugs.Count -eq 5 -and @($requiredSlugs | Where-Object { $slugs -notcontains $_ }).Count -eq 0
    Add-TeamBobCheck 'Mode document shape' $modesValid 'Five required custom mode slugs'
} catch { Add-TeamBobCheck 'Mode document shape' $false $_.Exception.Message }

$workSchema = $null
try {
    $workSchema = Read-TeamBobJsonFile (Join-Path $teamBobRoot 'config/work-packet.schema.json') 'Work-packet schema' 'ENVIRONMENT_FAILED'
    $workShape = $workSchema.type -eq 'object' -and $workSchema.additionalProperties -eq $false -and @($workSchema.required).Count -eq 38 -and $workSchema.properties.'Max-Repair-Cycles'.const -eq 2
    Add-TeamBobCheck 'Work-packet JSON schema shape' $workShape 'Closed object with required packet fields and fixed repair budget'
} catch { Add-TeamBobCheck 'Work-packet JSON schema shape' $false $_.Exception.Message }

$buildSchema = $null
try {
    $buildSchema = Read-TeamBobJsonFile (Join-Path $teamBobRoot 'config/vc6-build-targets.schema.json') 'Build-target schema' 'ENVIRONMENT_FAILED'
    $buildShape = $buildSchema.type -eq 'object' -and $buildSchema.properties.profiles.type -eq 'array' -and
        @($buildSchema.properties.profiles.items.required).Count -eq 13 -and $buildSchema.properties.profiles.items.properties.expectedArtifacts.minItems -eq 1
    Add-TeamBobCheck 'Build-target JSON schema shape' $buildShape 'Profiles array has the fixed qualified target interface'
} catch { Add-TeamBobCheck 'Build-target JSON schema shape' $false $_.Exception.Message }

$targets = $null
$catalogProfilesValid = $false
try {
    $targets = Read-TeamBobJsonFile (Join-Path $teamBobRoot 'config/vc6-build-targets.json') 'Build-target catalog' 'ENVIRONMENT_FAILED'
    $catalogShape = $targets -is [System.Management.Automation.PSCustomObject] -and
        (@($targets.PSObject.Properties.Name) -join ',') -eq 'profiles' -and $targets.profiles -is [System.Array]
    Add-TeamBobCheck 'Build-target catalog JSON shape' $catalogShape 'Catalog is a closed object exposing a profiles array'
    if ($catalogShape) {
        $profileErrors = @()
        foreach ($profile in @($targets.profiles)) { $profileErrors += @(Test-TeamBobBuildProfileContract $profile) }
        $catalogProfilesValid = $profileErrors.Count -eq 0
        Add-TeamBobCheck 'Build-target catalog profile contracts' $catalogProfilesValid (($profileErrors | Select-Object -Unique) -join ', ')
    }
} catch { Add-TeamBobCheck 'Build-target catalog JSON shape' $false $_.Exception.Message }

$environment = $null
$environmentPath = if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { '' } else { Join-Path $env:LOCALAPPDATA 'IBM/BobTeamProfile/vc6-machine-control-poc/v0.2.0-poc/environment.json' }
if (-not (Test-Path -LiteralPath $environmentPath -PathType Leaf)) {
    if ($Strict) { Add-TeamBobCheck 'Local environment registration' $false "Missing fixed registration: $environmentPath" }
    else { Add-TeamBobCheck 'Local environment registration' $false 'Not registered; optional outside Strict mode' -Skip }
} else {
    try {
        [void](Get-TeamBobPhysicalPath $environmentPath 'Local environment registration' 'Leaf' 'ENVIRONMENT_FAILED')
        $environment = Read-TeamBobJsonFile $environmentPath 'Local environment registration' 'ENVIRONMENT_FAILED'
        Assert-TeamBobExactProperties $environment @(
            'schemaVersion', 'profileId', 'profileVersion', 'workPacketSchemaId', 'buildTargetSchemaId', 'pcId',
            'msdevPath', 'msdevSha256', 'bazaarPath', 'bazaarSha256', 'sandboxRoot', 'logRoot'
        ) 'Local environment registration' 'ENVIRONMENT_FAILED'
        $identityValid = $null -ne $manifest -and $null -ne $workSchema -and $null -ne $buildSchema -and
            $environment.schemaVersion -eq '1.0' -and $environment.profileId -eq $manifest.profile.id -and
            $environment.profileVersion -eq $manifest.version -and $environment.workPacketSchemaId -eq $workSchema.'$id' -and
            $environment.buildTargetSchemaId -eq $buildSchema.'$id' -and $environment.pcId -eq [Environment]::MachineName
        Add-TeamBobCheck 'Local environment identity' $identityValid 'Registration matches manifest and schema identities'

        $msdevPhysical = $null
        try {
            if (-not (Test-TeamBobAbsolutePath ([string]$environment.msdevPath))) { throw (New-TeamBobFailure 'ENVIRONMENT_FAILED' 'Registered MSDEV tool path must be absolute.') }
            $msdevPhysical = Get-TeamBobPhysicalPath ([string]$environment.msdevPath) 'Registered MSDEV tool' 'Leaf' 'ENVIRONMENT_FAILED'
        } catch { $msdevFailure = $_.Exception.Message }
        $msdevExists = $null -ne $msdevPhysical
        Add-TeamBobCheck 'MSDEV file' $msdevExists $(if ($msdevExists) { 'Existing fixed-local physical tool path with no reparse components' } else { $msdevFailure })
        $msdevHashValid = $msdevExists -and (Get-TeamBobSha256 $environment.msdevPath) -eq ([string]$environment.msdevSha256).ToLowerInvariant()
        Add-TeamBobCheck 'MSDEV hash' $msdevHashValid 'Registered SHA-256 matches tool bytes'

        $bazaarPhysical = $null
        try {
            if (-not (Test-TeamBobAbsolutePath ([string]$environment.bazaarPath))) { throw (New-TeamBobFailure 'ENVIRONMENT_FAILED' 'Registered Bazaar tool path must be absolute.') }
            $bazaarPhysical = Get-TeamBobPhysicalPath ([string]$environment.bazaarPath) 'Registered Bazaar tool' 'Leaf' 'ENVIRONMENT_FAILED'
        } catch { $bazaarFailure = $_.Exception.Message }
        $bazaarExists = $null -ne $bazaarPhysical
        Add-TeamBobCheck 'Bazaar file' $bazaarExists $(if ($bazaarExists) { 'Existing fixed-local physical tool path with no reparse components' } else { $bazaarFailure })
        $bazaarHashValid = $bazaarExists -and (Get-TeamBobSha256 $environment.bazaarPath) -eq ([string]$environment.bazaarSha256).ToLowerInvariant()
        Add-TeamBobCheck 'Bazaar hash' $bazaarHashValid 'Registered SHA-256 matches tool bytes'

        $sandboxPhysical = $null
        try {
            if (-not (Test-TeamBobAbsolutePath ([string]$environment.sandboxRoot))) { throw (New-TeamBobFailure 'ENVIRONMENT_FAILED' 'Registered sandbox root must be absolute.') }
            $sandboxCanonical = Get-TeamBobCanonicalPath ([string]$environment.sandboxRoot) 'Registered sandbox root' 'ENVIRONMENT_FAILED'
            if ($sandboxCanonical.Equals([System.IO.Path]::GetPathRoot($sandboxCanonical), [System.StringComparison]::OrdinalIgnoreCase)) { throw (New-TeamBobFailure 'ENVIRONMENT_FAILED' 'Registered sandbox root must not be a drive-volume root.') }
            $sandboxPhysical = Get-TeamBobPhysicalPath $sandboxCanonical 'Registered sandbox root' 'Container' 'ENVIRONMENT_FAILED'
            if ($null -eq $environmentBoundaryPhysical) { throw (New-TeamBobFailure 'ENVIRONMENT_FAILED' 'Distribution repository physical boundary is unavailable.') }
            Assert-TeamBobPhysicalSeparation $sandboxPhysical $environmentBoundaryPhysical 'Sandbox and repository roots' 'ENVIRONMENT_FAILED'
        } catch { $sandboxFailure = $_.Exception.Message }
        Add-TeamBobCheck 'Sandbox root' ($null -ne $sandboxPhysical -and [string]::IsNullOrWhiteSpace($sandboxFailure)) $(if ([string]::IsNullOrWhiteSpace($sandboxFailure)) { 'Fixed-local, non-volume, non-reparse, and physically separate from the repository' } else { $sandboxFailure })

        $logPhysical = $null
        try {
            if (-not (Test-TeamBobAbsolutePath ([string]$environment.logRoot))) { throw (New-TeamBobFailure 'ENVIRONMENT_FAILED' 'Registered log root must be absolute.') }
            $logCanonical = Get-TeamBobCanonicalPath ([string]$environment.logRoot) 'Registered log root' 'ENVIRONMENT_FAILED'
            if ($logCanonical.Equals([System.IO.Path]::GetPathRoot($logCanonical), [System.StringComparison]::OrdinalIgnoreCase)) { throw (New-TeamBobFailure 'ENVIRONMENT_FAILED' 'Registered log root must not be a drive-volume root.') }
            $logPhysical = Get-TeamBobPhysicalPath $logCanonical 'Registered log root' 'Container' 'ENVIRONMENT_FAILED'
            if ($null -eq $environmentBoundaryPhysical) { throw (New-TeamBobFailure 'ENVIRONMENT_FAILED' 'Distribution repository physical boundary is unavailable.') }
            Assert-TeamBobPhysicalSeparation $logPhysical $environmentBoundaryPhysical 'Log and repository roots' 'ENVIRONMENT_FAILED'
        } catch { $logFailure = $_.Exception.Message }
        Add-TeamBobCheck 'Log root' ($null -ne $logPhysical -and [string]::IsNullOrWhiteSpace($logFailure)) $(if ([string]::IsNullOrWhiteSpace($logFailure)) { 'Fixed-local, non-volume, non-reparse, and physically separate from the repository' } else { $logFailure })

        $rootsSeparate = $false
        if ($null -ne $sandboxPhysical -and $null -ne $logPhysical) {
            try { Assert-TeamBobPhysicalSeparation $sandboxPhysical $logPhysical 'Sandbox and log roots' 'ENVIRONMENT_FAILED'; $rootsSeparate = $true } catch { $rootsFailure = $_.Exception.Message }
        }
        Add-TeamBobCheck 'Sandbox and log root separation' $rootsSeparate $(if ($rootsSeparate) { 'Neither root equals, contains, aliases, or is an ancestor of the other' } else { $rootsFailure })
    } catch { Add-TeamBobCheck 'Local environment JSON' $false $_.Exception.Message }
}

if (-not [string]::IsNullOrWhiteSpace($BuildProfileId)) {
    $selected = @($targets.profiles | Where-Object { $_.id -eq $BuildProfileId })
    Add-TeamBobCheck 'Selected build profile exists' ($selected.Count -eq 1) $BuildProfileId
    if ($selected.Count -eq 1) {
        $profile = $selected[0]
        $selectedContractValid = @(Test-TeamBobBuildProfileContract $profile).Count -eq 0
        Add-TeamBobCheck 'Selected build profile contract' $selectedContractValid $BuildProfileId
        Add-TeamBobCheck 'Selected build profile enabled' ($selectedContractValid -and $profile.enabled -eq $true) $BuildProfileId
        $qualification = $profile.qualification
        $qualified = $selectedContractValid -and $null -ne $qualification -and $qualification.msdevHelp -eq $true -and $qualification.makeSucceeded -eq $true -and
            $qualification.rebuildSucceeded -eq $true -and $qualification.compileFailureObserved -eq $true -and
            $qualification.linkFailureObserved -eq $true -and -not [string]::IsNullOrWhiteSpace($qualification.pcId) -and
            -not [string]::IsNullOrWhiteSpace($qualification.recordId) -and -not [string]::IsNullOrWhiteSpace($qualification.recordedAt)
        Add-TeamBobCheck 'Selected build profile qualified' $qualified $BuildProfileId
        $qualificationPcMatches = $qualified -and $null -ne $environment -and $qualification.pcId -eq $environment.pcId
        Add-TeamBobCheck 'Selected build profile PC identity' $qualificationPcMatches 'Qualification pcId matches the registered environment'
    }
} else {
    Add-TeamBobCheck 'Build profile selection' $true 'No BuildProfileId requested; empty or disabled catalogs are allowed'
}

Write-Output "SUMMARY Passed=$script:passed Failed=$script:failed Skipped=$script:skipped"
if ($script:failed -eq 0) { exit 0 } else { exit 1 }
