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

function Get-ModeDefinitions {
    param([string]$Path)
    $configuration = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
    Assert-True ($null -ne $configuration.customModes) 'custom_modes.yaml is a JSON/YAML customModes document'
    return @($configuration.customModes)
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

function Test-JsonSchemaKeywords {
    param([object]$Schema, [string]$Path = '$')
    $allowed = @('$schema', '$id', 'title', 'description', 'type', 'additionalProperties', 'required', 'properties', 'const', 'enum', 'minLength', 'minItems', 'maxItems', 'items', 'pattern', 'allOf', 'if', 'then')
    $errors = @()
    foreach ($property in $Schema.PSObject.Properties) {
        if (-not ($allowed -contains $property.Name)) { $errors += "unsupported:$Path.$($property.Name)" }
    }
    if ($null -ne $Schema.properties) {
        foreach ($property in $Schema.properties.PSObject.Properties) { $errors += @(Test-JsonSchemaKeywords $property.Value "$Path.properties.$($property.Name)") }
    }
    if ($null -ne $Schema.items) { $errors += @(Test-JsonSchemaKeywords $Schema.items "$Path.items") }
    foreach ($subschema in @($Schema.allOf)) { if ($null -ne $subschema) { $errors += @(Test-JsonSchemaKeywords $subschema "$Path.allOf") } }
    if ($null -ne $Schema.if) { $errors += @(Test-JsonSchemaKeywords $Schema.if "$Path.if") }
    if ($null -ne $Schema.then) { $errors += @(Test-JsonSchemaKeywords $Schema.then "$Path.then") }
    return @($errors)
}

function Test-JsonSchemaNode {
    param([object]$Schema, [object]$Value, [string]$Path = '$')
    $errors = @()
    if ($null -ne $Schema.type) {
        $typeMatches = switch ($Schema.type) {
            'object' { $Value -is [System.Management.Automation.PSCustomObject] }
            'array' { $Value -is [System.Array] }
            'string' { $Value -is [string] }
            'integer' { $Value -is [sbyte] -or $Value -is [byte] -or $Value -is [int16] -or $Value -is [uint16] -or $Value -is [int32] -or $Value -is [uint32] -or $Value -is [int64] -or $Value -is [uint64] }
            default { $false }
        }
        if (-not $typeMatches) { return @("type:$Path") }
    }
    if ($null -ne $Schema.PSObject.Properties['const'] -and $Value -ne $Schema.const) { $errors += "const:$Path" }
    if ($null -ne $Schema.enum -and -not ($Schema.enum -contains $Value)) { $errors += "enum:$Path" }
    if ($Value -is [string]) {
        if ($null -ne $Schema.minLength -and $Value.Length -lt [int]$Schema.minLength) { $errors += "minLength:$Path" }
        if ($null -ne $Schema.pattern -and -not [regex]::IsMatch($Value, $Schema.pattern)) { $errors += "pattern:$Path" }
    }
    if ($Value -is [System.Array]) {
        if ($null -ne $Schema.minItems -and $Value.Count -lt [int]$Schema.minItems) { $errors += "minItems:$Path" }
        if ($null -ne $Schema.maxItems -and $Value.Count -gt [int]$Schema.maxItems) { $errors += "maxItems:$Path" }
        if ($null -ne $Schema.items) {
            for ($index = 0; $index -lt $Value.Count; $index++) { $errors += @(Test-JsonSchemaNode $Schema.items $Value[$index] "$Path[$index]") }
        }
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        if ($null -ne $Schema.required) {
            foreach ($field in @($Schema.required)) { if ($null -eq $Value.PSObject.Properties[$field]) { $errors += "required:$Path.$field" } }
        }
        if ($Schema.additionalProperties -eq $false) {
            foreach ($property in $Value.PSObject.Properties) { if ($null -eq $Schema.properties.PSObject.Properties[$property.Name]) { $errors += "additionalProperties:$Path.$($property.Name)" } }
        }
        if ($null -ne $Schema.properties) {
            foreach ($property in $Schema.properties.PSObject.Properties) {
                $valueProperty = $Value.PSObject.Properties[$property.Name]
                if ($null -ne $valueProperty) { $errors += @(Test-JsonSchemaNode $property.Value $valueProperty.Value "$Path.$($property.Name)") }
            }
        }
    }
    foreach ($subschema in @($Schema.allOf)) { if ($null -ne $subschema) { $errors += @(Test-JsonSchemaNode $subschema $Value $Path) } }
    if ($null -ne $Schema.if -and @(Test-JsonSchemaNode $Schema.if $Value $Path).Count -eq 0 -and $null -ne $Schema.then) { $errors += @(Test-JsonSchemaNode $Schema.then $Value $Path) }
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
    $editGroups = @($mode.groups | Where-Object { $_ -is [System.Array] -and $_.Count -eq 2 -and $_[0] -eq 'edit' })
    Assert-Equal $editGroups.Count 1 "Mode '$($mode.slug)' has one constrained edit group tuple"
    $editOptions = $editGroups[0][1]
    Assert-True ($null -ne $editOptions.fileRegex -and $null -ne $editOptions.description) "Mode '$($mode.slug)' edit tuple has fileRegex and description"
    if ($mode.slug -eq 'green-implement') {
        Assert-Equal $mode.groups.Count 3 'Green mode has no extra groups'
        Assert-SetEqual @($mode.groups | Where-Object { $_ -is [string] }) @('read', 'execute') 'Green mode has only read and execute simple groups'
        Assert-True (Test-PathRegex $editOptions.fileRegex 'src/driver.cpp') 'Green edit regex accepts legacy C/C++ sources'
        Assert-True (Test-PathRegex $editOptions.fileRegex 'include/driver.hpp') 'Green edit regex accepts legacy C/C++ headers'
        Assert-True (Test-PathRegex $editOptions.fileRegex 'team-bob-work/TASK-1/results/build-result.md') 'Green edit regex accepts safe task-result artifacts'
        foreach ($forbidden in @('src/resource.rc', 'project/project.dsp', 'project/project.dsw', 'src/library.def', 'src/interface.idl', 'src/legacy.mak')) { Assert-True (-not (Test-PathRegex $editOptions.fileRegex $forbidden)) "Green edit regex rejects '$forbidden'" }
        Assert-True (-not (Test-PathRegex $editOptions.fileRegex 'team-bob-work/TASK-1/results/unsafe.exe')) 'Green edit regex rejects unsafe task-result artifacts'
    } else {
        Assert-Equal $mode.groups.Count 2 "Normal mode '$($mode.slug)' has no extra groups"
        Assert-SetEqual @($mode.groups | Where-Object { $_ -is [string] }) @('read') "Normal mode '$($mode.slug)' has only a read simple group"
        Assert-True (Test-PathRegex $editOptions.fileRegex 'team-bob-work/TASK-1/drafts/external-spec.md') "Normal mode '$($mode.slug)' accepts draft Markdown artifacts"
        Assert-True (Test-PathRegex $editOptions.fileRegex 'team-bob-work/TASK-1/drafts/requirement-ledger.csv') "Normal mode '$($mode.slug)' accepts draft CSV artifacts"
        Assert-True (-not (Test-PathRegex $editOptions.fileRegex 'team-bob-work/TASK-1/results/build-result.md')) "Normal mode '$($mode.slug)' rejects task results"
        Assert-True (-not (Test-PathRegex $editOptions.fileRegex 'src/driver.cpp')) "Normal mode '$($mode.slug)' rejects source edits"
    }
}

$workPacketSchema = Get-Content -Raw -LiteralPath (Join-Path $profileRoot 'team-bob/config/work-packet.schema.json') | ConvertFrom-Json
Assert-Equal @(Test-JsonSchemaKeywords $workPacketSchema).Count 0 'Work-packet schema uses only validator-supported keywords'
$requiredPacketFields = @('Profile Version', 'Task ID', 'Difficulty', 'Risk', 'Customer', 'ReqIDs', 'Word Baseline', 'QA Baseline', 'Spec Baseline', 'Bazaar Root', 'Bazaar Branch', 'Bazaar Full Revision ID', 'Allowed Files', 'Forbidden Areas', 'RT Impact', 'Safety Impact', 'Board Impact', 'Driver Impact', 'ABI Impact', 'Build Impact', 'Customer Branch Impact', 'RT Impact Clear', 'Safety Impact Clear', 'Board Impact Clear', 'Driver Impact Clear', 'ABI Impact Clear', 'Build Impact Clear', 'Customer Branch Impact Clear', 'Clean Working Copy', 'Open QA', 'Build Profile ID', 'Autonomous-Edit-Build-Approved', 'Soft-Execute-Risk-Accepted', 'Max-Repair-Cycles', 'Specification Approver', 'Implementation Approver')
foreach ($field in $requiredPacketFields) { Assert-True ($workPacketSchema.required -contains $field) "Work-packet schema requires '$field'" }
Assert-Equal (($workPacketSchema.properties.Risk.enum) -join ',') 'Green,Amber,Red' 'Work-packet risk enum is fixed'
Assert-Equal $workPacketSchema.properties.'Autonomous-Edit-Build-Approved'.const 'YES' 'Autonomous edit/build requires explicit approval'
Assert-Equal $workPacketSchema.properties.'Soft-Execute-Risk-Accepted'.const 'YES' 'Soft execute risk requires explicit acceptance'
Assert-Equal $workPacketSchema.properties.'Max-Repair-Cycles'.const 2 'Repair cycles are capped at two'

$packet = Get-CanonicalWorkPacket (Join-Path $profileRoot 'team-bob/templates/work-packet.md')
Assert-Equal $packet.Risk 'Amber' 'Representative packet is Amber so open QA can be recorded'
Assert-True (@($packet.'Open QA').Count -gt 0) 'Representative Amber packet contains open QA'
Assert-Equal @(Test-JsonSchemaNode $workPacketSchema $packet).Count 0 'Canonical packet validates against the complete work-packet schema'
$extraPacket = ($packet | ConvertTo-Json -Depth 20 | ConvertFrom-Json); $extraPacket | Add-Member -NotePropertyName 'Unexpected' -NotePropertyValue 'extra'
Assert-True (@(Test-JsonSchemaNode $workPacketSchema $extraPacket) -contains 'additionalProperties:$.Unexpected') 'Work-packet schema rejects extra properties'
$emptyPacket = ($packet | ConvertTo-Json -Depth 20 | ConvertFrom-Json); $emptyPacket.PSObject.Properties['Task ID'].Value = ''
Assert-True (@(Test-JsonSchemaNode $workPacketSchema $emptyPacket) -contains 'minLength:$.Task ID') 'Work-packet schema rejects empty required strings'
$badItemPacket = ($packet | ConvertTo-Json -Depth 20 | ConvertFrom-Json); $badItemPacket.PSObject.Properties['ReqIDs'].Value = @('REQ-OK', 7)
Assert-True (@(Test-JsonSchemaNode $workPacketSchema $badItemPacket) -contains 'type:$.ReqIDs[1]') 'Work-packet schema rejects invalid array item types'
$badIntegerPacket = ($packet | ConvertTo-Json -Depth 20 | ConvertFrom-Json); $badIntegerPacket.PSObject.Properties['Max-Repair-Cycles'].Value = 2.5
Assert-True (@(Test-JsonSchemaNode $workPacketSchema $badIntegerPacket) -contains 'type:$.Max-Repair-Cycles') 'Work-packet schema rejects non-integer repair cycles'
$badIntegerPacket.PSObject.Properties['Max-Repair-Cycles'].Value = '2'
Assert-True (@(Test-JsonSchemaNode $workPacketSchema $badIntegerPacket) -contains 'type:$.Max-Repair-Cycles') 'Work-packet schema rejects string repair cycles'
$patternSchema = '{"type":"string","pattern":"^[A-Z]+$"}' | ConvertFrom-Json
Assert-True (@(Test-JsonSchemaNode $patternSchema 'lower') -contains 'pattern:$') 'Schema validator enforces string patterns'
$greenPacket = ($packet | ConvertTo-Json -Depth 20 | ConvertFrom-Json)
$greenPacket.PSObject.Properties['Risk'].Value = 'Green'; $greenPacket.PSObject.Properties['Open QA'].Value = @()
foreach ($field in @('RT Impact Clear', 'Safety Impact Clear', 'Board Impact Clear', 'Driver Impact Clear', 'ABI Impact Clear', 'Build Impact Clear', 'Customer Branch Impact Clear', 'Clean Working Copy')) { $greenPacket.PSObject.Properties[$field].Value = 'YES' }
Assert-Equal @(Test-JsonSchemaNode $workPacketSchema $greenPacket).Count 0 'Green packet with clear impacts and clean copy validates'
$greenPacket.PSObject.Properties['Open QA'].Value = @('QA-OPEN')
Assert-True (@(Test-JsonSchemaNode $workPacketSchema $greenPacket) -contains 'maxItems:$.Open QA') 'Green packet rejects open QA'
$greenPacket.PSObject.Properties['Open QA'].Value = @()
foreach ($field in @('RT Impact Clear', 'Safety Impact Clear', 'Board Impact Clear', 'Driver Impact Clear', 'ABI Impact Clear', 'Build Impact Clear', 'Customer Branch Impact Clear', 'Clean Working Copy')) {
    $greenPacket.PSObject.Properties[$field].Value = 'NO'
    $expectedError = 'const:$.' + $field
    Assert-True (@(Test-JsonSchemaNode $workPacketSchema $greenPacket) -contains $expectedError) "Green packet rejects '$field' when it is not YES"
    $greenPacket.PSObject.Properties[$field].Value = 'YES'
}

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

. (Join-Path $PSScriptRoot 'Test-Tools.ps1')
