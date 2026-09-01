$ErrorActionPreference = 'Stop'

$script:Assertions = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    $script:Assertions++
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Assert-Equal {
    param([object]$Actual, [object]$Expected, [string]$Message)
    Assert-True ($Actual -eq $Expected) "$Message (expected '$Expected', got '$Actual')"
}

function Assert-SetEqual {
    param([object[]]$Actual, [object[]]$Expected, [string]$Message)
    Assert-Equal (($Actual | Sort-Object) -join ',') (($Expected | Sort-Object) -join ',') $Message
}

function Get-YamlScalar {
    param([string]$Value)
    $value = $Value.Trim()
    if (($value.StartsWith("'") -and $value.EndsWith("'")) -or ($value.StartsWith('"') -and $value.EndsWith('"'))) { return $value.Substring(1, $value.Length - 2) }
    return $value
}

function Get-ModeDefinitions {
    param([string]$Path)
    $lines = Get-Content -LiteralPath $Path
    Assert-Equal $lines[0].Trim() 'customModes:' 'custom_modes.yaml begins with the documented customModes collection'
    $modes = @(); $current = $null; $inInstructions = $false; $inGroups = $false; $inEdit = $false
    foreach ($line in $lines[1..($lines.Count - 1)]) {
        if ($line.Trim() -eq '' -or $line.Trim().StartsWith('#')) { continue }
        if ($line -match '^  - slug: ([a-z0-9-]+)$') {
            $current = [ordered]@{ slug = $Matches[1]; groups = @(); edit = $null }
            $modes += $current; $inInstructions = $false; $inGroups = $false; $inEdit = $false
            continue
        }
        Assert-True ($null -ne $current) 'Each custom-mode entry follows a slug'
        if ($line -match '^    (name|description|roleDefinition|whenToUse): (.+)$') {
            $current[$Matches[1]] = Get-YamlScalar $Matches[2]
            $inInstructions = $false; $inGroups = $false; $inEdit = $false
            continue
        }
        if ($line -eq '    customInstructions: |') {
            $current['customInstructions'] = ''
            $inInstructions = $true; $inGroups = $false; $inEdit = $false
            continue
        }
        if ($line -eq '    groups:') { $inInstructions = $false; $inGroups = $true; $inEdit = $false; continue }
        if ($inInstructions -and $line -match '^      ') { $current['customInstructions'] += $line.Substring(6) + "`n"; continue }
        if ($inGroups -and $line -match '^      - (read|execute)$') { $current['groups'] += $Matches[1]; $inEdit = $false; continue }
        if ($inGroups -and $line -eq '      - edit:') { $current['groups'] += 'edit'; $current['edit'] = [ordered]@{}; $inEdit = $true; continue }
        if ($inGroups -and $inEdit -and $line -match '^          (fileRegex|description): (.+)$') { $current['edit'][$Matches[1]] = Get-YamlScalar $Matches[2]; continue }
        throw "Unsupported or malformed custom_modes.yaml line: $line"
    }
    return @($modes | ForEach-Object { [pscustomobject]$_ })
}

function Get-MarkdownDocument {
    param([string]$Path)
    $text = Get-Content -Raw -LiteralPath $Path
    $match = [regex]::Match($text, '\A---\r?\n(?<front>.*?)\r?\n---\r?\n(?<body>[\s\S]*)\z', [System.Text.RegularExpressions.RegexOptions]::Singleline)
    Assert-True $match.Success "Command '$Path' has valid slash-command frontmatter"
    $frontmatter = @{}
    foreach ($line in ($match.Groups['front'].Value -split "`r?`n")) {
        if ($line -match '^([a-z-]+): (.+)$') { $frontmatter[$Matches[1]] = $Matches[2] } else { throw "Malformed frontmatter line in '$Path': $line" }
    }
    return [pscustomobject]@{ Frontmatter = $frontmatter; Body = $match.Groups['body'].Value }
}

function Get-MarkdownSection {
    param([string]$Body, [string]$Title)
    $pattern = '(?ms)^## ' + [regex]::Escape($Title) + '\r?\n(?<content>.*?)(?=^## |\z)'
    $match = [regex]::Match($Body, $pattern)
    Assert-True $match.Success "Markdown document has a '$Title' section"
    return $match.Groups['content'].Value.Trim()
}

function Get-CanonicalWorkPacket {
    param([string]$Path)
    $text = Get-Content -Raw -LiteralPath $Path
    $pattern = '(?s)<!-- canonical-work-packet-json:start -->\s*```json\s*(?<json>\{.*?\})\s*```\s*<!-- canonical-work-packet-json:end -->'
    $match = [regex]::Match($text, $pattern)
    Assert-True $match.Success 'Work-packet template has a delimited canonical JSON object'
    return ($match.Groups['json'].Value | ConvertFrom-Json)
}

function Get-PropertyValue {
    param([object]$Object, [string]$Name)
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    if ($property.Value -is [System.Array]) { Write-Output -NoEnumerate $property.Value } else { return $property.Value }
}

function Test-WorkPacketAgainstSchema {
    param([object]$Schema, [object]$Packet)
    $errors = @()
    foreach ($field in $Schema.required) { if ($null -eq $Packet.PSObject.Properties[$field]) { $errors += "missing:$field" } }
    foreach ($property in $Schema.properties.PSObject.Properties) {
        $name = $property.Name; $rule = $property.Value; $value = Get-PropertyValue $Packet $name
        if ($null -eq $value) { continue }
        if ($null -ne $rule.const -and $value -ne $rule.const) { $errors += "const:$name" }
        if ($null -ne $rule.enum -and -not ($rule.enum -contains $value)) { $errors += "enum:$name" }
        if ($rule.type -eq 'string' -and -not ($value -is [string])) { $errors += "type:$name" }
        if ($rule.type -eq 'array') {
            if (-not ($value -is [System.Array])) { $errors += "type:$name"; continue }
            if ($null -ne $rule.minItems -and $value.Count -lt $rule.minItems) { $errors += "minItems:$name" }
            if ($null -ne $rule.maxItems -and $value.Count -gt $rule.maxItems) { $errors += "maxItems:$name" }
        }
    }
    foreach ($conditional in $Schema.allOf) {
        $risk = Get-PropertyValue $Packet 'Risk'; $expectedRisk = $conditional.if.properties.Risk.const
        if ($risk -ne $expectedRisk) { continue }
        foreach ($property in $conditional.then.properties.PSObject.Properties) {
            $value = Get-PropertyValue $Packet $property.Name; $rule = $property.Value
            if ($null -ne $rule.const -and $value -ne $rule.const) { $errors += "green-const:$($property.Name)" }
            if ($null -ne $rule.maxItems -and $value.Count -gt $rule.maxItems) { $errors += "green-maxItems:$($property.Name)" }
        }
    }
    return @($errors)
}

function Test-PathRegex { param([string]$Regex, [string]$Path); return [regex]::IsMatch($Path, $Regex) }

$repoRoot = Split-Path -Parent $PSScriptRoot
$profileRoot = Join-Path $repoRoot 'profile'
Assert-True (Test-Path -LiteralPath $profileRoot -PathType Container) 'profile directory exists'

$requiredFiles = @(
    'AGENTS.md', '.bobignore.base', '.bzrignore.snippet', '.bob/custom_modes.yaml',
    '.bob/commands/bob-normalize-requirements.md', '.bob/commands/bob-draft-spec.md', '.bob/commands/bob-analyze-impact.md',
    '.bob/commands/bob-implement-green.md', '.bob/commands/bob-review-change.md', '.bob/commands/bob-draft-test.md',
    '.bob/rules/00-governance.md', '.bob/rules/10-vc6-realtime.md', '.bob/rules/20-traceability.md', '.bob/rules/30-output-contracts.md',
    '.bob/rules-green-implement/10-edit-build-loop.md', 'team-bob/profile-manifest.json',
    'team-bob/config/work-packet.schema.json', 'team-bob/config/vc6-build-targets.schema.json',
    'team-bob/config/vc6-build-targets.json', 'team-bob/config/vc6-build-targets.example.json',
    'team-bob/templates/work-packet.md', 'team-bob/templates/requirement-ledger.csv', 'team-bob/templates/external-spec.md',
    'team-bob/templates/impact-analysis.md', 'team-bob/templates/code-review.md', 'team-bob/templates/test-spec.md',
    'team-bob/templates/review-rubric.md', 'team-bob/templates/usage-log.csv', 'team-bob/templates/exception-record.md'
)
foreach ($relativePath in $requiredFiles) { Assert-True (Test-Path -LiteralPath (Join-Path $profileRoot $relativePath) -PathType Leaf) "Required profile file exists: $relativePath" }

$manifestPath = Join-Path $profileRoot 'team-bob/profile-manifest.json'
$manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
Assert-Equal $manifest.version '0.1.0-poc' 'Manifest version is stable'
Assert-Equal $manifest.profile.id 'team-bob-vc6-bazaar' 'Manifest exposes the Team Bob profile identity'
Assert-Equal $manifest.compatibility.operatingSystem 'Windows' 'Manifest declares Windows compatibility'
Assert-Equal $manifest.compatibility.ide 'IBM Bob IDE 2.1.x' 'Manifest declares Bob IDE compatibility'
Assert-Equal $manifest.compatibility.toolchain 'Visual C++ 6.0' 'Manifest declares the VC6 toolchain'
Assert-Equal $manifest.compatibility.vcs 'Bazaar' 'Manifest declares Bazaar compatibility'
$manifestDirectory = Split-Path -Parent $manifestPath
foreach ($entry in @('workPacketSchema', 'buildTargetSchema', 'buildTargets', 'modes', 'rules')) {
    $resolved = Join-Path $manifestDirectory $manifest.contracts.$entry
    Assert-True (Test-Path -LiteralPath $resolved) "Manifest contract '$entry' resolves from the manifest directory"
}

$modes = Get-ModeDefinitions (Join-Path $profileRoot '.bob/custom_modes.yaml')
$expectedSlugs = @('req-spec-draft', 'impact-review', 'green-implement', 'change-review', 'test-draft')
Assert-Equal $modes.Count $expectedSlugs.Count 'Exactly five custom modes are declared'
Assert-SetEqual $modes.slug $expectedSlugs 'Mode slugs match the package contract'
foreach ($mode in $modes) {
    foreach ($field in @('name', 'description', 'roleDefinition', 'whenToUse', 'customInstructions')) { Assert-True (-not [string]::IsNullOrWhiteSpace($mode.$field)) "Mode '$($mode.slug)' has documented '$field'" }
    Assert-True ($null -ne $mode.edit.fileRegex -and $null -ne $mode.edit.description) "Mode '$($mode.slug)' has a documented nested edit group"
    if ($mode.slug -eq 'green-implement') {
        Assert-SetEqual $mode.groups @('read', 'edit', 'execute') 'Green mode has only read, nested edit, and execute groups'
        Assert-True (Test-PathRegex $mode.edit.fileRegex 'src/driver.cpp') 'Green edit regex accepts legacy C/C++ sources'
        Assert-True (Test-PathRegex $mode.edit.fileRegex 'include/driver.hpp') 'Green edit regex accepts legacy C/C++ headers'
        Assert-True (Test-PathRegex $mode.edit.fileRegex 'team-bob-work/TASK-1/results/build-result.md') 'Green edit regex accepts safe task-result artifacts'
        Assert-True (-not (Test-PathRegex $mode.edit.fileRegex 'src/resource.rc')) 'Green edit regex rejects forbidden resource files'
        Assert-True (-not (Test-PathRegex $mode.edit.fileRegex 'project/project.dsp')) 'Green edit regex rejects forbidden VC6 project files'
        Assert-True (-not (Test-PathRegex $mode.edit.fileRegex 'team-bob-work/TASK-1/results/unsafe.exe')) 'Green edit regex rejects unsafe task-result artifacts'
    } else {
        Assert-SetEqual $mode.groups @('read', 'edit') "Normal mode '$($mode.slug)' has only read and nested edit groups"
        Assert-True (Test-PathRegex $mode.edit.fileRegex 'team-bob-work/TASK-1/drafts/external-spec.md') "Normal mode '$($mode.slug)' accepts draft Markdown artifacts"
        Assert-True (Test-PathRegex $mode.edit.fileRegex 'team-bob-work/TASK-1/drafts/requirement-ledger.csv') "Normal mode '$($mode.slug)' accepts draft CSV artifacts"
        Assert-True (-not (Test-PathRegex $mode.edit.fileRegex 'team-bob-work/TASK-1/results/build-result.md')) "Normal mode '$($mode.slug)' rejects task results"
        Assert-True (-not (Test-PathRegex $mode.edit.fileRegex 'src/driver.cpp')) "Normal mode '$($mode.slug)' rejects source edits"
    }
}

$workPacketSchema = Get-Content -Raw -LiteralPath (Join-Path $profileRoot 'team-bob/config/work-packet.schema.json') | ConvertFrom-Json
$requiredPacketFields = @('Profile Version', 'Task ID', 'Difficulty', 'Risk', 'Customer', 'ReqIDs', 'Word Baseline', 'QA Baseline', 'Spec Baseline', 'Bazaar Root', 'Bazaar Branch', 'Bazaar Full Revision ID', 'Allowed Files', 'Forbidden Areas', 'RT Impact', 'Safety Impact', 'Board Impact', 'Driver Impact', 'ABI Impact', 'Build Impact', 'Customer Branch Impact', 'RT Impact Clear', 'Safety Impact Clear', 'Board Impact Clear', 'Driver Impact Clear', 'ABI Impact Clear', 'Build Impact Clear', 'Customer Branch Impact Clear', 'Clean Working Copy', 'Open QA', 'Build Profile ID', 'Autonomous-Edit-Build-Approved', 'Soft-Execute-Risk-Accepted', 'Max-Repair-Cycles', 'Specification Approver', 'Implementation Approver')
foreach ($field in $requiredPacketFields) { Assert-True ($workPacketSchema.required -contains $field) "Work-packet schema requires '$field'" }
Assert-Equal (($workPacketSchema.properties.Risk.enum) -join ',') 'Green,Amber,Red' 'Work-packet risk enum is fixed'
Assert-Equal $workPacketSchema.properties.'Autonomous-Edit-Build-Approved'.const 'YES' 'Autonomous edit/build requires explicit approval'
Assert-Equal $workPacketSchema.properties.'Soft-Execute-Risk-Accepted'.const 'YES' 'Soft execute risk requires explicit acceptance'
Assert-Equal $workPacketSchema.properties.'Max-Repair-Cycles'.const 2 'Repair cycles are capped at two'

$packet = Get-CanonicalWorkPacket (Join-Path $profileRoot 'team-bob/templates/work-packet.md')
Assert-Equal $packet.Risk 'Amber' 'Representative packet is Amber so open QA can be recorded'
Assert-True (@($packet.'Open QA').Count -gt 0) 'Representative Amber packet contains open QA'
Assert-Equal (Test-WorkPacketAgainstSchema $workPacketSchema $packet).Count 0 'Canonical packet validates against the work-packet schema'
$greenPacket = ($packet | ConvertTo-Json -Depth 20 | ConvertFrom-Json)
$greenPacket.PSObject.Properties['Risk'].Value = 'Green'; $greenPacket.PSObject.Properties['Open QA'].Value = @()
foreach ($field in @('RT Impact Clear', 'Safety Impact Clear', 'Board Impact Clear', 'Driver Impact Clear', 'ABI Impact Clear', 'Build Impact Clear', 'Customer Branch Impact Clear', 'Clean Working Copy')) { $greenPacket.PSObject.Properties[$field].Value = 'YES' }
Assert-Equal (Test-WorkPacketAgainstSchema $workPacketSchema $greenPacket).Count 0 'Green packet with clear impacts and clean copy validates'
$greenPacket.PSObject.Properties['Open QA'].Value = @('QA-OPEN')
Assert-True ((Test-WorkPacketAgainstSchema $workPacketSchema $greenPacket) -contains 'green-maxItems:Open QA') 'Green packet rejects open QA'
$greenPacket.PSObject.Properties['Open QA'].Value = @(); $greenPacket.PSObject.Properties['Clean Working Copy'].Value = 'NO'
Assert-True ((Test-WorkPacketAgainstSchema $workPacketSchema $greenPacket) -contains 'green-const:Clean Working Copy') 'Green packet rejects a dirty working copy'

$targetSchema = Get-Content -Raw -LiteralPath (Join-Path $profileRoot 'team-bob/config/vc6-build-targets.schema.json') | ConvertFrom-Json
$targetFields = @('id', 'enabled', 'projectFile', 'target', 'timeoutSeconds', 'expectedArtifacts', 'excludePatterns', 'outputLogPattern', 'successPattern', 'compilerErrorPattern', 'linkerErrorPattern', 'environmentErrorPattern', 'qualification')
Assert-SetEqual $targetSchema.properties.profiles.items.required $targetFields 'Build-target schema has the approved fixed profile interface'
Assert-SetEqual $targetSchema.properties.profiles.items.properties.PSObject.Properties.Name $targetFields 'Build-target schema exposes no command-injection fields'
$qualificationFields = @('msdevHelp', 'makeSucceeded', 'rebuildSucceeded', 'compileFailureObserved', 'linkFailureObserved', 'pcId', 'recordId', 'recordedAt')
Assert-SetEqual $targetSchema.properties.profiles.items.properties.qualification.required $qualificationFields 'Build-target qualification has the approved fixed interface'
$targets = Get-Content -Raw -LiteralPath (Join-Path $profileRoot 'team-bob/config/vc6-build-targets.json') | ConvertFrom-Json
Assert-Equal $targets.profiles.Count 0 'Shipped build-target collection is empty'
$exampleTargets = Get-Content -Raw -LiteralPath (Join-Path $profileRoot 'team-bob/config/vc6-build-targets.example.json') | ConvertFrom-Json
Assert-Equal $exampleTargets.profiles.Count 1 'Build-target example has one profile'
Assert-Equal $exampleTargets.profiles[0].enabled $false 'Build-target example is disabled'
Assert-True ($exampleTargets.profiles[0].projectFile -notmatch '^[A-Za-z]:|^[/\\]') 'Build-target example project file is relative'
foreach ($field in @('msdevHelp', 'makeSucceeded', 'rebuildSucceeded', 'compileFailureObserved', 'linkFailureObserved')) { Assert-True ($exampleTargets.profiles[0].qualification.$field -is [bool]) "Build-target qualification has boolean '$field'" }
foreach ($field in @('pcId', 'recordId', 'recordedAt')) { Assert-True (-not [string]::IsNullOrWhiteSpace($exampleTargets.profiles[0].qualification.$field)) "Build-target qualification has '$field'" }

$ledgerHeaders = (Get-Content -LiteralPath (Join-Path $profileRoot 'team-bob/templates/requirement-ledger.csv') -TotalCount 1).Split(',')
foreach ($header in @('ReqID', 'Immutable Source Anchor', 'Interpretation', 'Acceptance Criteria', 'QA Links', 'QA Status', 'Evidence', 'Human Approval State')) { Assert-True ($ledgerHeaders -contains $header) "Requirement ledger exposes '$header'" }
$usageHeaders = (Get-Content -LiteralPath (Join-Path $profileRoot 'team-bob/templates/usage-log.csv') -TotalCount 1).Split(',')
$expectedUsageHeaders = @('Task ID', 'Profile Version', 'Phase', 'Difficulty', 'Bobcoin', 'Human Hours', 'Rework Hours', 'Build Count', 'First Pass', 'Critical Findings', 'Result')
Assert-Equal ($usageHeaders -join ',') ($expectedUsageHeaders -join ',') 'Usage log is task-level and has the fixed column contract'
foreach ($personField in @('user', 'person', 'operator', 'member', 'name', 'email')) { Assert-True (-not ($usageHeaders -match $personField)) "Usage log excludes person-identifying '$personField' fields" }

$rubric = Get-Content -Raw -LiteralPath (Join-Path $profileRoot 'team-bob/templates/review-rubric.md')
Assert-True ($rubric -match '(?m)^\| Traceability \|') 'Review rubric has a traceability row'
Assert-True ($rubric -match '(?m)^\| Real-time and safety \|') 'Review rubric has a real-time and safety row'
$exception = Get-Content -Raw -LiteralPath (Join-Path $profileRoot 'team-bob/templates/exception-record.md')
Assert-True ($exception -match '(?m)^\| Soft-Execute-Risk-Accepted \| YES \|') 'Exception record repeats the soft-execute risk acceptance'

$commandOutputs = @{
    'bob-normalize-requirements.md' = 'team-bob-work/<Task>/drafts/requirement-ledger.csv'; 'bob-draft-spec.md' = 'team-bob-work/<Task>/drafts/external-spec.md'
    'bob-analyze-impact.md' = 'team-bob-work/<Task>/drafts/impact-analysis.md'; 'bob-implement-green.md' = 'team-bob-work/<Task>/results/build-result.md'
    'bob-review-change.md' = 'team-bob-work/<Task>/drafts/code-review.md'; 'bob-draft-test.md' = 'team-bob-work/<Task>/drafts/test-spec.md'
}
foreach ($commandName in $commandOutputs.Keys) {
    $command = Get-MarkdownDocument (Join-Path $profileRoot ".bob/commands/$commandName")
    Assert-True (-not [string]::IsNullOrWhiteSpace($command.Frontmatter['description'])) "Command '$commandName' has a description"
    Assert-Equal $command.Frontmatter['argument-hint'] '<work-packet-path>' "Command '$commandName' declares its packet argument hint"
    Assert-True ((Get-MarkdownSection $command.Body 'Input') -match [regex]::Escape('$1')) "Command '$commandName' accepts `$1"
    Assert-True ((Get-MarkdownSection $command.Body 'Preconditions') -match 'work-packet\.schema\.json') "Command '$commandName' validates the schema-backed packet"
    Assert-True ((Get-MarkdownSection $command.Body 'Context') -match 'targeted') "Command '$commandName' uses targeted context"
    Assert-True ((Get-MarkdownSection $command.Body 'Output') -match [regex]::Escape($commandOutputs[$commandName])) "Command '$commandName' has one prescribed output path"
    Assert-True ((Get-MarkdownSection $command.Body 'Stop Conditions') -match 'missing evidence') "Command '$commandName' stops on missing evidence"
}
$greenCommand = Get-MarkdownDocument (Join-Path $profileRoot '.bob/commands/bob-implement-green.md')
$greenWorkflow = Get-MarkdownSection $greenCommand.Body 'Green Workflow'
$order = @('Edit only', 'Make', 'At most two', 'Final Rebuild') | ForEach-Object { $greenWorkflow.IndexOf($_) }
Assert-True ($order[0] -ge 0 -and $order[1] -gt $order[0] -and $order[2] -gt $order[1] -and $order[3] -gt $order[2]) 'Green command has ordered edit, Make, repair, final-Rebuild workflow'
Assert-True ($greenWorkflow -match 'READY_FOR_HUMAN_REVIEW.*success.*integrity') 'Green command gates human review on success and integrity'

$outputRule = Get-Content -Raw -LiteralPath (Join-Path $profileRoot '.bob/rules/30-output-contracts.md')
$statusSection = Get-MarkdownSection $outputRule 'Build Statuses'
foreach ($status in @('SUCCEEDED', 'CODE_FAILED_RETRYABLE', 'CODE_FAILED_STOP', 'ENVIRONMENT_FAILED', 'TIMED_OUT', 'INTEGRITY_FAILED')) { Assert-True ($statusSection -match "(?m)^\| $status \|") "Output contract includes build status '$status'" }

Write-Host "PASS: $script:Assertions package contract assertions succeeded."
