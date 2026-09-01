$ErrorActionPreference = 'Stop'

$script:Assertions = 0

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    $script:Assertions++
    if (-not $Condition) {
        throw "ASSERTION FAILED: $Message"
    }
}

function Assert-Equal {
    param(
        [object]$Actual,
        [object]$Expected,
        [string]$Message
    )

    Assert-True ($Actual -eq $Expected) "$Message (expected '$Expected', got '$Actual')"
}

function Get-Contract {
    param([string]$Path)

    $text = Get-Content -Raw -LiteralPath $Path
    $match = [regex]::Match($text, '<!-- bob-contract: (\{.*?\}) -->', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    Assert-True $match.Success "Template '$Path' has a parseable bob-contract JSON block"
    return ($match.Groups[1].Value | ConvertFrom-Json)
}

function Get-ModeDefinitions {
    param([string]$Path)

    $lines = Get-Content -LiteralPath $Path | Where-Object { $_.Trim() -ne '' -and -not $_.Trim().StartsWith('#') }
    Assert-Equal $lines[0].Trim() 'customModes:' 'custom_modes.yaml begins with the customModes collection'

    $modes = @()
    $current = $null
    $activeList = $null
    foreach ($line in $lines[1..($lines.Count - 1)]) {
        if ($line -match '^  - slug: ([a-z0-9-]+)$') {
            $current = [ordered]@{ slug = $Matches[1]; groups = @(); editScopes = @(); allowedExtensions = @(); excludedGroups = @() }
            $modes += $current
            $activeList = $null
            continue
        }
        if ($line -match '^    (groups|editScopes|allowedExtensions|excludedGroups):$') {
            Assert-True ($null -ne $current) 'Mode list is nested under a mode'
            $activeList = $Matches[1]
            continue
        }
        if ($line -match '^      - "?([^"\r\n]+)"?$') {
            Assert-True ($null -ne $current -and $null -ne $activeList) 'Mode list item belongs to a declared collection'
            $current[$activeList] += $Matches[1]
            continue
        }
        throw "Unsupported or malformed custom_modes.yaml line: $line"
    }
    return @($modes | ForEach-Object { [pscustomobject]$_ })
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$profileRoot = Join-Path $repoRoot 'profile'
Assert-True (Test-Path -LiteralPath $profileRoot -PathType Container) 'profile directory exists'

$requiredFiles = @(
    'AGENTS.md',
    '.bobignore.base',
    '.bzrignore.snippet',
    '.bob/custom_modes.yaml',
    '.bob/commands/bob-normalize-requirements.md',
    '.bob/commands/bob-draft-spec.md',
    '.bob/commands/bob-analyze-impact.md',
    '.bob/commands/bob-implement-green.md',
    '.bob/commands/bob-review-change.md',
    '.bob/commands/bob-draft-test.md',
    'team-bob/rules/00-governance.md',
    'team-bob/rules/10-vc6-realtime.md',
    'team-bob/rules/20-traceability.md',
    'team-bob/rules/30-output-contracts.md',
    'team-bob/rules-green-implement/10-edit-build-loop.md',
    'team-bob/profile-manifest.json',
    'team-bob/config/work-packet.schema.json',
    'team-bob/config/vc6-build-targets.schema.json',
    'team-bob/config/vc6-build-targets.json',
    'team-bob/config/vc6-build-targets.example.json',
    'team-bob/templates/work-packet.md',
    'team-bob/templates/requirement-ledger.csv',
    'team-bob/templates/external-spec.md',
    'team-bob/templates/impact-analysis.md',
    'team-bob/templates/code-review.md',
    'team-bob/templates/test-spec.md',
    'team-bob/templates/review-rubric.md',
    'team-bob/templates/usage-log.csv',
    'team-bob/templates/exception-record.md'
)
foreach ($relativePath in $requiredFiles) {
    Assert-True (Test-Path -LiteralPath (Join-Path $profileRoot $relativePath) -PathType Leaf) "Required profile file exists: $relativePath"
}

$manifest = Get-Content -Raw -LiteralPath (Join-Path $profileRoot 'team-bob/profile-manifest.json') | ConvertFrom-Json
Assert-Equal $manifest.version '0.1.0-poc' 'Manifest version is stable'
Assert-Equal $manifest.profile.id 'team-bob-vc6-bazaar' 'Manifest exposes the Team Bob profile identity'
Assert-Equal $manifest.compatibility.operatingSystem 'Windows' 'Manifest declares Windows compatibility'
Assert-Equal $manifest.compatibility.ide 'IBM Bob IDE 2.1.x' 'Manifest declares Bob IDE compatibility'
Assert-Equal $manifest.compatibility.toolchain 'Visual C++ 6.0' 'Manifest declares the VC6 toolchain'
Assert-Equal $manifest.compatibility.vcs 'Bazaar' 'Manifest declares Bazaar compatibility'

$modes = Get-ModeDefinitions (Join-Path $profileRoot '.bob/custom_modes.yaml')
$expectedSlugs = @('req-spec-draft', 'impact-review', 'green-implement', 'change-review', 'test-draft')
Assert-Equal $modes.Count $expectedSlugs.Count 'Exactly five custom modes are declared'
Assert-Equal (($modes.slug | Sort-Object) -join ',') (($expectedSlugs | Sort-Object) -join ',') 'Mode slugs match the package contract'
$forbiddenGroups = @('mcp', 'skill', 'workflow', 'todo', 'subtask', 'subagent', 'mode')
foreach ($mode in $modes) {
    Assert-True ((($mode.excludedGroups | Sort-Object) -join ',') -eq (($forbiddenGroups | Sort-Object) -join ',')) "Mode '$($mode.slug)' excludes privileged or delegation groups"
    if ($mode.slug -eq 'green-implement') {
        Assert-Equal (($mode.groups | Sort-Object) -join ',') 'edit,execute,read' 'Green mode has read, edit, and execute groups only'
        Assert-Equal (($mode.editScopes) -join ',') 'team-bob-work/<Task>/results/**' 'Green edits only task results'
        Assert-Equal (($mode.allowedExtensions | Sort-Object) -join ',') '.c,.cc,.cpp,.cxx,.h,.hh,.hpp,.hxx,.inl' 'Green C/C++ extension boundary is exact'
    } else {
        Assert-Equal (($mode.groups | Sort-Object) -join ',') 'edit,read' "Normal mode '$($mode.slug)' has read and edit groups only"
        Assert-Equal (($mode.editScopes) -join ',') 'team-bob-work/<Task>/drafts/**' "Normal mode '$($mode.slug)' edits only task drafts"
        Assert-Equal $mode.allowedExtensions.Count 0 "Normal mode '$($mode.slug)' does not expand source edit extensions"
    }
}

$workPacketSchema = Get-Content -Raw -LiteralPath (Join-Path $profileRoot 'team-bob/config/work-packet.schema.json') | ConvertFrom-Json
$requiredPacketFields = @('Profile Version', 'Task ID', 'Difficulty', 'Risk', 'Customer', 'ReqIDs', 'Word Baseline', 'QA Baseline', 'Spec Baseline', 'Bazaar Root', 'Bazaar Branch', 'Bazaar Full Revision ID', 'Allowed Files', 'Forbidden Areas', 'RT Impact', 'Safety Impact', 'Board Impact', 'Driver Impact', 'ABI Impact', 'Build Impact', 'Customer Branch Impact', 'Open QA', 'Build Profile ID', 'Autonomous-Edit-Build-Approved', 'Soft-Execute-Risk-Accepted', 'Max-Repair-Cycles', 'Specification Approver', 'Implementation Approver')
foreach ($field in $requiredPacketFields) {
    Assert-True ($workPacketSchema.required -contains $field) "Work-packet schema requires '$field'"
}
Assert-Equal (($workPacketSchema.properties.Risk.enum) -join ',') 'Green,Amber,Red' 'Work-packet risk enum is fixed'
Assert-Equal $workPacketSchema.properties.'Autonomous-Edit-Build-Approved'.const 'YES' 'Autonomous edit/build requires explicit approval'
Assert-Equal $workPacketSchema.properties.'Soft-Execute-Risk-Accepted'.const 'YES' 'Soft execute risk requires explicit acceptance'
Assert-Equal $workPacketSchema.properties.'Max-Repair-Cycles'.const 2 'Repair cycles are capped at two'

$targetSchema = Get-Content -Raw -LiteralPath (Join-Path $profileRoot 'team-bob/config/vc6-build-targets.schema.json') | ConvertFrom-Json
Assert-True ($targetSchema.properties.profiles.type -eq 'array') 'Build-target schema models profiles as an array'
$targets = Get-Content -Raw -LiteralPath (Join-Path $profileRoot 'team-bob/config/vc6-build-targets.json') | ConvertFrom-Json
Assert-Equal $targets.profiles.Count 0 'Shipped build-target collection is empty'
$exampleTargets = Get-Content -Raw -LiteralPath (Join-Path $profileRoot 'team-bob/config/vc6-build-targets.example.json') | ConvertFrom-Json
Assert-Equal $exampleTargets.profiles.Count 1 'Build-target example has one profile'
Assert-Equal $exampleTargets.profiles[0].enabled $false 'Build-target example is disabled'

$workPacketContract = Get-Contract (Join-Path $profileRoot 'team-bob/templates/work-packet.md')
Assert-True ($workPacketContract.requiredFields -contains 'Allowed Files') 'Work-packet template exposes allowed-file control'
Assert-True ($workPacketContract.gates -contains 'clean-working-copy') 'Work-packet template exposes a clean-copy gate'
$ledgerHeaders = (Get-Content -LiteralPath (Join-Path $profileRoot 'team-bob/templates/requirement-ledger.csv') -TotalCount 1).Split(',')
foreach ($header in @('ReqID', 'Immutable Source Anchor', 'Interpretation', 'Acceptance Criteria', 'QA Links', 'QA Status', 'Evidence', 'Human Approval State')) {
    Assert-True ($ledgerHeaders -contains $header) "Requirement ledger exposes '$header'"
}
$usageHeaders = (Get-Content -LiteralPath (Join-Path $profileRoot 'team-bob/templates/usage-log.csv') -TotalCount 1).Split(',')
$expectedUsageHeaders = @('Task ID', 'Profile Version', 'Phase', 'Difficulty', 'Bobcoin', 'Human Hours', 'Rework Hours', 'Build Count', 'First Pass', 'Critical Findings', 'Result')
Assert-Equal ($usageHeaders -join ',') ($expectedUsageHeaders -join ',') 'Usage log is task-level and has the fixed column contract'
foreach ($personField in @('user', 'person', 'operator', 'member', 'name', 'email')) {
    Assert-True (-not ($usageHeaders -match $personField)) "Usage log excludes person-identifying '$personField' fields"
}

$rubric = Get-Contract (Join-Path $profileRoot 'team-bob/templates/review-rubric.md')
Assert-True ($rubric.criteria -contains 'traceability') 'Review rubric includes traceability'
Assert-True ($rubric.criteria -contains 'realtime-safety') 'Review rubric includes realtime and safety review'
$exception = Get-Contract (Join-Path $profileRoot 'team-bob/templates/exception-record.md')
Assert-True ($exception.requiredFields -contains 'Soft-Execute-Risk-Accepted') 'Exception record repeats the soft-execute risk acceptance'

$commandOutputs = @{
    'bob-normalize-requirements.md' = 'team-bob-work/<Task>/drafts/requirement-ledger.csv'
    'bob-draft-spec.md' = 'team-bob-work/<Task>/drafts/external-spec.md'
    'bob-analyze-impact.md' = 'team-bob-work/<Task>/drafts/impact-analysis.md'
    'bob-implement-green.md' = 'team-bob-work/<Task>/results/build-result.md'
    'bob-review-change.md' = 'team-bob-work/<Task>/drafts/code-review.md'
    'bob-draft-test.md' = 'team-bob-work/<Task>/drafts/test-spec.md'
}
foreach ($commandName in $commandOutputs.Keys) {
    $command = Get-Contract (Join-Path $profileRoot ".bob/commands/$commandName")
    Assert-Equal $command.argument '$1' "Command '$commandName' accepts a work-packet argument"
    Assert-Equal $command.validatesWorkPacket $true "Command '$commandName' validates its work packet"
    Assert-Equal $command.targetedContext $true "Command '$commandName' uses targeted context"
    Assert-Equal $command.stopOnMissingEvidence $true "Command '$commandName' stops on missing evidence"
    Assert-Equal $command.output $commandOutputs[$commandName] "Command '$commandName' has one prescribed output"
}
$greenCommand = Get-Contract (Join-Path $profileRoot '.bob/commands/bob-implement-green.md')
Assert-Equal (($greenCommand.workflow) -join ',') 'edit,Make,repair,final-Rebuild' 'Green command has the required edit/build workflow'
Assert-Equal $greenCommand.maxRepairCycles 2 'Green command limits repairs to two'
Assert-Equal $greenCommand.readyAfter 'final-rebuild-success-and-integrity' 'Green command gates human review on success and integrity'

$outputRule = Get-Contract (Join-Path $profileRoot 'team-bob/rules/30-output-contracts.md')
Assert-Equal (($outputRule.buildStatuses) -join ',') 'SUCCEEDED,CODE_FAILED_RETRYABLE,CODE_FAILED_STOP,ENVIRONMENT_FAILED,TIMED_OUT,INTEGRITY_FAILED' 'Output contract has the fixed build-status set'

Write-Host "PASS: $script:Assertions package contract assertions succeeded."
