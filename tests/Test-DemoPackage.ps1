$ErrorActionPreference = 'Stop'

$demoTestStandalone = $null -eq (Get-Command Assert-True -ErrorAction SilentlyContinue)
if ($demoTestStandalone) {
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
}

function Assert-DemoRequiredFile {
    param([string]$RepoRoot, [string]$RelativePath)

    $path = Join-Path $RepoRoot ($RelativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
    Assert-True (Test-Path -LiteralPath $path -PathType Leaf) "Required demo asset is missing: $RelativePath"
    return $path
}

function Get-DemoUtf8Text {
    param([string]$Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    Assert-True (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) "UTF-8 text has no BOM: $Path"
    $encoding = New-Object System.Text.UTF8Encoding($false, $true)
    return $encoding.GetString($bytes)
}

function Get-DemoCp932Encoding {
    try {
        return [System.Text.Encoding]::GetEncoding(
            932,
            (New-Object System.Text.EncoderExceptionFallback),
            (New-Object System.Text.DecoderExceptionFallback)
        )
    } catch {
        $providerType = [type]::GetType('System.Text.CodePagesEncodingProvider, System.Text.Encoding.CodePages')
        if ($null -ne $providerType) {
            [System.Text.Encoding]::RegisterProvider($providerType::Instance)
            return [System.Text.Encoding]::GetEncoding(
                932,
                (New-Object System.Text.EncoderExceptionFallback),
                (New-Object System.Text.DecoderExceptionFallback)
            )
        }
        throw
    }
}

function Get-DemoCp932Text {
    param([string]$Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    Assert-True (-not ($bytes.Length -ge 2 -and (($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) -or ($bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF)))) "CP932 source has no UTF-16 BOM: $Path"
    Assert-True (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) "CP932 source has no UTF-8 BOM: $Path"

    $encoding = Get-DemoCp932Encoding
    $text = $encoding.GetString($bytes)
    $roundTrip = $encoding.GetBytes($text)
    Assert-Equal $roundTrip.Length $bytes.Length "CP932 source round-trips without replacement: $Path"
    for ($index = 0; $index -lt $bytes.Length; $index++) {
        if ($bytes[$index] -ne $roundTrip[$index]) {
            Assert-True $false "CP932 source round-trips byte-for-byte at offset ${index}: $Path"
        }
    }
    Assert-True ($text -notmatch '(?<!\r)\n|\r(?!\n)') "CP932 source uses CRLF exclusively: $Path"
    Assert-True ($text.EndsWith("`r`n", [System.StringComparison]::Ordinal)) "CP932 source ends in CRLF: $Path"
    Assert-True ($text -match '[\u3041-\u30ff\u3400-\u9fff]') "CP932 source includes a Japanese comment: $Path"
    return $text
}

function Read-DemoZipPackage {
    param([string]$Path)

    Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $archive = New-Object System.IO.Compression.ZipArchive(
            $stream,
            [System.IO.Compression.ZipArchiveMode]::Read,
            $false
        )
        try {
            $names = @()
            $textByName = @{}
            foreach ($entry in $archive.Entries) {
                $names += $entry.FullName
                if ($entry.FullName -match '(?i)\.(xml|rels)$') {
                    $entryStream = $entry.Open()
                    try {
                        $reader = New-Object System.IO.StreamReader(
                            $entryStream,
                            (New-Object System.Text.UTF8Encoding($false, $true)),
                            $true
                        )
                        try { $textByName[$entry.FullName] = $reader.ReadToEnd() } finally { $reader.Dispose() }
                    } finally {
                        $entryStream.Dispose()
                    }
                }
            }
            return [pscustomobject]@{ Names = @($names); TextByName = $textByName }
        } finally {
            $archive.Dispose()
        }
    } finally {
        $stream.Dispose()
    }
}

function Assert-DemoZipEntries {
    param([object]$Package, [string[]]$RequiredEntries, [string]$Label)

    foreach ($entry in $RequiredEntries) {
        Assert-True ($Package.Names -contains $entry) "$Label contains OOXML entry '$entry'"
    }
    Assert-Equal (@($Package.Names | Sort-Object -Unique).Count) $Package.Names.Count "$Label has no duplicate ZIP entries"
}

function Get-DemoXml {
    param([object]$Package, [string]$EntryName)

    Assert-True $Package.TextByName.ContainsKey($EntryName) "OOXML entry '$EntryName' is readable UTF-8 XML"
    try { return [xml]$Package.TextByName[$EntryName] } catch { throw "Invalid XML in '$EntryName': $($_.Exception.Message)" }
}

function Get-DemoXmlText {
    param([xml]$Xml)

    return (($Xml.SelectNodes('//*[local-name()="t"]') | ForEach-Object { $_.InnerText }) -join '')
}

$demoRepoRoot = Split-Path -Parent $PSScriptRoot
$demoAssertionsBefore = $script:Assertions
$requiredFiles = @(
    'demo/.gitattributes',
    'demo/README.md',
    'demo/inputs/requirements-demo.docx',
    'demo/inputs/qa-demo.xlsx',
    'demo/CycleWatch/CycleWatch.dsp',
    'demo/CycleWatch/CycleWatch.vcxproj',
    'demo/CycleWatch/include/CycleWatch.h',
    'demo/CycleWatch/src/CycleWatch.cpp',
    'demo/CycleWatch/tests/CycleWatchTests.cpp',
    'demo/tools/New-DemoOfficeInputs.ps1'
)
$demoPaths = @{}
foreach ($relativePath in $requiredFiles) {
    $demoPaths[$relativePath] = Assert-DemoRequiredFile $demoRepoRoot $relativePath
}

$banner = 'MSBUILD DEMO ADAPTER ' + [char]0x2014 + ' NOT VC6 QUALIFICATION'
$legacyBanner = 'MSBUILD DEMO ADAPTER - NOT VC6 QUALIFICATION'

$attributesText = Get-DemoUtf8Text $demoPaths['demo/.gitattributes']
$attributeLines = @($attributesText -split '\r?\n' | Where-Object { $_ -ne '' })
$expectedAttributes = @(
    'inputs/*.docx binary',
    'inputs/*.xlsx binary',
    'CycleWatch/CycleWatch.dsp -text',
    'CycleWatch/include/CycleWatch.h -text',
    'CycleWatch/src/CycleWatch.cpp -text',
    'CycleWatch/tests/CycleWatchTests.cpp -text'
)
foreach ($line in $expectedAttributes) {
    Assert-True ($attributeLines -contains $line) ".gitattributes preserves required binary or CP932 bytes: $line"
}

$readmeText = Get-DemoUtf8Text $demoPaths['demo/README.md']
Assert-True ($readmeText -match [regex]::Escape($banner)) 'Demo README prominently carries the immutable NOT-VC6 banner'
Assert-True ($readmeText -match [regex]::Escape('Allowed File: `demo/CycleWatch/src/CycleWatch.cpp`')) 'Demo README names exactly the live-demo Allowed File'
Assert-True ($readmeText -match 'synthetic' -and $readmeText -match 'hardware' -and $readmeText -match 'network' -and $readmeText -match 'customer data') 'Demo README states synthetic-only isolation boundaries'
Assert-True ($readmeText -match 'word/document\.xml' -and $readmeText -match 'xl/tables/table1\.xml') 'Demo README identifies stable Office source anchors'
Assert-True ($readmeText -match 'CP932' -and $readmeText -match 'U\+2014' -and $readmeText -match 'ASCII hyphen') 'Demo README documents the CP932 banner fallback and its encoding reason'

$legacyRelativePaths = @(
    'demo/CycleWatch/CycleWatch.dsp',
    'demo/CycleWatch/include/CycleWatch.h',
    'demo/CycleWatch/src/CycleWatch.cpp',
    'demo/CycleWatch/tests/CycleWatchTests.cpp'
)
$legacyText = @{}
foreach ($relativePath in $legacyRelativePaths) {
    $legacyText[$relativePath] = Get-DemoCp932Text $demoPaths[$relativePath]
    Assert-True ($legacyText[$relativePath] -match [regex]::Escape($legacyBanner)) "$relativePath carries the documented CP932 banner fallback"
}

$headerText = $legacyText['demo/CycleWatch/include/CycleWatch.h']
Assert-True ($headerText -match 'enum class CycleStatus') 'CycleWatch header owns the public status type'
Assert-True ($headerText -match 'unsigned int consecutiveOverruns_;') 'CycleWatch header pre-allocates the consecutive-overrun state member'
Assert-True ($headerText -match 'CycleStatus status_;') 'CycleWatch header pre-allocates the status member so the repair changes no layout'
Assert-True ($headerText -match 'Observe\(const char\* customer, bool warmingUp, unsigned int cycleTimeUs\)') 'CycleWatch header exposes the fixed observation contract'

$sourceText = $legacyText['demo/CycleWatch/src/CycleWatch.cpp']
Assert-Equal ([regex]::Matches($sourceText, 'TEAM_BOB_DEMO_FAULT_BEGIN').Count) 1 'CycleWatch source has exactly one fault-block begin marker'
Assert-Equal ([regex]::Matches($sourceText, 'TEAM_BOB_DEMO_FAULT_END').Count) 1 'CycleWatch source has exactly one fault-block end marker'
Assert-Equal ([regex]::Matches($sourceText, '#if defined\(TEAM_BOB_DEMO_FAULT\)').Count) 1 'CycleWatch source has exactly one dedicated conditional fault block'
Assert-Equal ([regex]::Matches($sourceText, '#error\s+MSBUILD_DEMO_ADAPTER_INTENTIONAL_COMPILER_FAULT').Count) 1 'Fault injection yields a real MSVC fatal error Cxxxx diagnostic'
Assert-Equal ([regex]::Matches($sourceText, 'TEAM_BOB_DEMO_REPAIR_POINT').Count) 1 'CycleWatch source has exactly one repair marker'
Assert-True ($sourceText -match 'static const unsigned int kCycleOverrunThresholdUs = 8000U;') 'CycleWatch uses the fixed inclusive 8,000 microsecond threshold'
Assert-True ($sourceText -match 'strcmp\(customer, "Customer-A"\)') 'CycleWatch scopes observation to Customer-A'
Assert-True ($sourceText -match 'if \(warmingUp\)') 'CycleWatch handles warm-up explicitly'
Assert-True ($sourceText -match 'cycleTimeUs < kCycleOverrunThresholdUs') 'CycleWatch uses below-threshold immediate recovery'
Assert-True ($sourceText -match 'consecutiveOverruns_ >= 1U') 'Initial safe demo baseline intentionally warns on the first post-warm-up overrun'
Assert-True ($sourceText -notmatch '(?<![0-9])(?:900|1100)(?![0-9])') 'CycleWatch does not substitute a 900/1100 classifier'

$unitText = $legacyText['demo/CycleWatch/tests/CycleWatchTests.cpp']
foreach ($literal in @('Customer-A', 'Customer-B', '7999U', '8000U')) {
    Assert-True ($unitText -match [regex]::Escape($literal)) "CycleWatch tests encode required case '$literal'"
}
foreach ($caseMarker in @('BOUNDARY_7999_8000', 'THIRD_CONSECUTIVE', 'IMMEDIATE_RECOVERY', 'WARMUP_RESET', 'CUSTOMER_A_ONLY')) {
    Assert-True ($unitText -match $caseMarker) "CycleWatch tests encode intended behavior marker '$caseMarker'"
}
Assert-True ($unitText -match 'CycleStatus::Normal' -and $unitText -match 'CycleStatus::Warning') 'CycleWatch tests assert Normal and Warning outcomes'

$dspText = $legacyText['demo/CycleWatch/CycleWatch.dsp']
Assert-True ($dspText -match 'TEAM_BOB_MSBUILD_DEMO_PROTOCOL_V1_NOT_VC6') 'DSP token declares the adapter protocol marker'
Assert-True ($dspText -match 'NOT A VISUAL C\+\+ 6 PROJECT') 'DSP token carries an explicit NOT-VC6 banner'
Assert-True ($dspText -notmatch 'Microsoft Developer Studio Project File') 'DSP token cannot be mistaken for a Visual C++ 6 project'

$projectText = Get-DemoUtf8Text $demoPaths['demo/CycleWatch/CycleWatch.vcxproj']
Assert-True ($projectText -match [regex]::Escape($banner)) 'VCXPROJ carries the immutable NOT-VC6 banner'
Assert-True ($projectText -notmatch 'TEAM_BOB_DEMO_FAULT\s*[;\<]') 'VCXPROJ never defines fault injection by default'
$projectOperationalText = $projectText.Replace('http://schemas.microsoft.com/developer/msbuild/2003', '')
Assert-True ($projectOperationalText -notmatch '(?i)https?://|PackageReference|Restore|NuGet') 'VCXPROJ has no network or package-restore step'
[xml]$projectXml = $projectText
$projectNs = New-Object System.Xml.XmlNamespaceManager($projectXml.NameTable)
$projectNs.AddNamespace('m', $projectXml.DocumentElement.NamespaceURI)
$projectConfigurations = @($projectXml.SelectNodes('//m:ProjectConfiguration', $projectNs))
Assert-Equal $projectConfigurations.Count 1 'VCXPROJ declares exactly one project configuration'
Assert-Equal $projectConfigurations[0].Include 'Release|Win32' 'VCXPROJ is fixed to Release|Win32'
Assert-Equal $projectConfigurations[0].Configuration 'Release' 'VCXPROJ configuration is Release'
Assert-Equal $projectConfigurations[0].Platform 'Win32' 'VCXPROJ platform is Win32'
Assert-Equal (@($projectXml.SelectNodes('//m:ConfigurationType', $projectNs) | ForEach-Object { $_.InnerText } | Sort-Object -Unique) -join ',') 'Application' 'VCXPROJ builds an Application'
Assert-Equal (@($projectXml.SelectNodes('//m:PlatformToolset', $projectNs) | ForEach-Object { $_.InnerText } | Sort-Object -Unique) -join ',') 'v143' 'VCXPROJ uses PlatformToolset v143'
Assert-Equal (@($projectXml.SelectNodes('//m:WindowsTargetPlatformVersion', $projectNs) | ForEach-Object { $_.InnerText } | Sort-Object -Unique) -join ',') '10.0.22621.0' 'VCXPROJ uses the fixed Windows SDK'
Assert-Equal (@($projectXml.SelectNodes('//m:OutDir', $projectNs) | ForEach-Object { $_.InnerText } | Sort-Object -Unique) -join ',') 'bin\$(Configuration)\' 'VCXPROJ output stays in relative bin'
Assert-Equal (@($projectXml.SelectNodes('//m:IntDir', $projectNs) | ForEach-Object { $_.InnerText } | Sort-Object -Unique) -join ',') 'obj\$(Configuration)\' 'VCXPROJ intermediates stay in relative obj'
$compileIncludes = @($projectXml.SelectNodes('//m:ClCompile', $projectNs) | ForEach-Object { $_.Include } | Sort-Object)
Assert-Equal ($compileIncludes -join ',') 'src\CycleWatch.cpp,tests\CycleWatchTests.cpp' 'VCXPROJ compiles only implementation and deterministic test source'
$headerIncludes = @($projectXml.SelectNodes('//m:ClInclude', $projectNs) | ForEach-Object { $_.Include } | Sort-Object)
Assert-Equal ($headerIncludes -join ',') 'include\CycleWatch.h' 'VCXPROJ includes only the CycleWatch header'
$forbiddenProjectNodes = @($projectXml.SelectNodes('//*[local-name()="Exec" or local-name()="CustomBuild" or local-name()="PreBuildEvent" or local-name()="PreLinkEvent" or local-name()="PostBuildEvent"]'))
Assert-Equal $forbiddenProjectNodes.Count 0 'VCXPROJ has no Exec, custom, pre-link, pre-build, or post-build events'

$generatorText = Get-DemoUtf8Text $demoPaths['demo/tools/New-DemoOfficeInputs.ps1']
try { [void][scriptblock]::Create($generatorText); Assert-True $true 'Office generator parses with Windows PowerShell 5.1 grammar' } catch { throw "Office generator does not parse: $($_.Exception.Message)" }
Assert-True ($generatorText -notmatch '(?i)-ComObject|Word\.Application|Excel\.Application') 'Office generator does not use Word or Excel COM'
Assert-True ($generatorText -match [regex]::Escape($banner)) 'Office generator carries the immutable NOT-VC6 banner'

$docx = Read-DemoZipPackage $demoPaths['demo/inputs/requirements-demo.docx']
Assert-DemoZipEntries $docx @(
    '[Content_Types].xml', '_rels/.rels', 'docProps/core.xml', 'docProps/app.xml',
    'word/document.xml', 'word/styles.xml', 'word/_rels/document.xml.rels'
) 'requirements-demo.docx'
$docxRootRelationships = Get-DemoXml $docx '_rels/.rels'
$docxOfficeRelationships = @($docxRootRelationships.SelectNodes('//*[local-name()="Relationship" and @Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" and @Target="word/document.xml"]'))
Assert-Equal $docxOfficeRelationships.Count 1 'Requirements package root has exactly one internal office-document relationship'
$docxDocumentRelationships = Get-DemoXml $docx 'word/_rels/document.xml.rels'
$docxStyleRelationships = @($docxDocumentRelationships.SelectNodes('//*[local-name()="Relationship" and @Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" and @Target="styles.xml"]'))
Assert-Equal $docxStyleRelationships.Count 1 'Requirements document has exactly one internal styles relationship'
$docxDocument = Get-DemoXml $docx 'word/document.xml'
$wordNs = New-Object System.Xml.XmlNamespaceManager($docxDocument.NameTable)
$wordNs.AddNamespace('w', 'http://schemas.openxmlformats.org/wordprocessingml/2006/main')
$wordParagraphs = @($docxDocument.SelectNodes('//w:body/w:p', $wordNs) | ForEach-Object { ($_.SelectNodes('.//w:t', $wordNs) | ForEach-Object { $_.InnerText }) -join '' })
Assert-True ($wordParagraphs.Count -ge 6) 'Requirements document uses natural-language paragraphs'
Assert-Equal $wordParagraphs[0] $banner 'Requirements document starts with the immutable banner'
$wordVisibleText = $wordParagraphs -join "`n"
Assert-True ($wordVisibleText -match '[\u3041-\u30ff\u3400-\u9fff]') 'Requirements document contains Japanese natural language'
Assert-True ($wordVisibleText -match 'Customer-A') 'Requirements document scopes the request to Customer-A'
Assert-True ($wordVisibleText -match '8,000' -and $wordVisibleText -match '3') 'Requirements document states the 8,000 microsecond and three-cycle rule'
Assert-True ($wordVisibleText -match '7,999') 'Requirements document makes below-8,000 recovery concrete'
Assert-True ($wordVisibleText -match 'synthetic-only' -and $wordVisibleText -match 'hardware' -and $wordVisibleText -match 'network' -and $wordVisibleText -match 'customer data') 'Requirements document states synthetic-only safety limits'
Assert-True ($wordVisibleText -match 'board' -and $wordVisibleText -match 'driver' -and $wordVisibleText -match 'ABI' -and $wordVisibleText -match 'control period') 'Requirements document preserves board, driver, ABI, and control period'
Assert-True ($wordVisibleText -notmatch '(?i)ReqID|REQ-[0-9]|https?://|[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}|(?:password|credential|secret)\s*[:=]\s*\S+') 'Requirements visible text has no request IDs, person data, credential values, or external links'
Assert-Equal @($docxDocument.SelectNodes('//w:tbl|//w:numPr', $wordNs)).Count 0 'Requirements document is not a numbered ledger or table'

$xlsx = Read-DemoZipPackage $demoPaths['demo/inputs/qa-demo.xlsx']
Assert-DemoZipEntries $xlsx @(
    '[Content_Types].xml', '_rels/.rels', 'docProps/core.xml', 'docProps/app.xml',
    'xl/workbook.xml', 'xl/_rels/workbook.xml.rels', 'xl/worksheets/sheet1.xml',
    'xl/worksheets/_rels/sheet1.xml.rels', 'xl/sharedStrings.xml', 'xl/styles.xml',
    'xl/tables/table1.xml'
) 'qa-demo.xlsx'
$workbookXml = Get-DemoXml $xlsx 'xl/workbook.xml'
$workbookNs = New-Object System.Xml.XmlNamespaceManager($workbookXml.NameTable)
$workbookNs.AddNamespace('s', 'http://schemas.openxmlformats.org/spreadsheetml/2006/main')
$sheetNodes = @($workbookXml.SelectNodes('//s:sheets/s:sheet', $workbookNs))
Assert-Equal $sheetNodes.Count 1 'QA workbook has one focused worksheet'
Assert-Equal $sheetNodes[0].name 'QA' 'QA worksheet has a stable semantic name'
$sharedStringsXml = Get-DemoXml $xlsx 'xl/sharedStrings.xml'
$sharedNs = New-Object System.Xml.XmlNamespaceManager($sharedStringsXml.NameTable)
$sharedNs.AddNamespace('s', 'http://schemas.openxmlformats.org/spreadsheetml/2006/main')
$sharedStrings = @($sharedStringsXml.SelectNodes('//s:si', $sharedNs) | ForEach-Object { ($_.SelectNodes('.//s:t', $sharedNs) | ForEach-Object { $_.InnerText }) -join '' })
$sheetXml = Get-DemoXml $xlsx 'xl/worksheets/sheet1.xml'
$sheetNs = New-Object System.Xml.XmlNamespaceManager($sheetXml.NameTable)
$sheetNs.AddNamespace('s', 'http://schemas.openxmlformats.org/spreadsheetml/2006/main')
$rows = @($sheetXml.SelectNodes('//s:sheetData/s:row', $sheetNs))
Assert-Equal $rows.Count 6 'QA table has one header and five fixed clarification rows'
$visibleRows = @()
foreach ($row in $rows) {
    $values = @($row.SelectNodes('./s:c', $sheetNs) | ForEach-Object {
        $sharedStringIndex = [int]$_.SelectSingleNode('./s:v', $sheetNs).InnerText
        $sharedStrings[$sharedStringIndex]
    })
    Assert-Equal $values.Count 2 "QA row $($row.r) has exactly Question and Answer cells"
    $visibleRows += ,$values
}
Assert-Equal $visibleRows[0][0] 'Question' 'QA table first header is Question'
Assert-Equal $visibleRows[0][1] 'Answer' 'QA table second header is Answer'
$qaVisibleText = (($visibleRows | ForEach-Object { $_ -join "`t" }) -join "`n")
Assert-Equal ([regex]::Matches($qaVisibleText, 'Customer-A').Count) 1 'QA table scopes the synthetic case to Customer-A'
Assert-True ($qaVisibleText -match '8,000' -and $qaVisibleText -match 'inclusive') 'QA table clarifies the inclusive 8,000 microsecond threshold'
Assert-True ($qaVisibleText -match 'warm-up' -and $qaVisibleText -match 'reset' -and $qaVisibleText -match 'suppress') 'QA table clarifies warm-up reset and suppression'
Assert-True ($qaVisibleText -match 'below 8,000' -and $qaVisibleText -match 'immediately') 'QA table clarifies immediate below-threshold recovery'
Assert-True ($qaVisibleText -match 'board' -and $qaVisibleText -match 'driver' -and $qaVisibleText -match 'ABI' -and $qaVisibleText -match 'control period') 'QA table confirms no platform or period change'
Assert-True ($qaVisibleText -notmatch '(?i)ReqID|REQ-[0-9]|https?://|[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}|(?:password|credential|secret)\s*[:=]\s*\S+') 'QA visible text has no request IDs, person data, credential values, or external links'
$tableXml = Get-DemoXml $xlsx 'xl/tables/table1.xml'
$tableNs = New-Object System.Xml.XmlNamespaceManager($tableXml.NameTable)
$tableNs.AddNamespace('s', 'http://schemas.openxmlformats.org/spreadsheetml/2006/main')
Assert-Equal $tableXml.DocumentElement.name 'QATable' 'QA cells are represented by a semantic OOXML table'
Assert-Equal $tableXml.DocumentElement.ref 'A1:B6' 'QA table has the fixed source anchor A1:B6'
$tableColumnNames = @($tableXml.SelectNodes('//s:tableColumn', $tableNs) | ForEach-Object { $_.name })
Assert-Equal ($tableColumnNames -join ',') 'Question,Answer' 'QA table has no ID column'

foreach ($package in @($docx, $xlsx)) {
    Assert-True (-not (@($package.Names | Where-Object { $_ -match '(?i)vbaProject|macros|externalLinks|connections\.xml' }).Count)) 'Office package has no VBA, macro, connection, or external-link part'
    foreach ($relationshipName in @($package.Names | Where-Object { $_ -match '\.rels$' })) {
        $relationshipXml = Get-DemoXml $package $relationshipName
        Assert-Equal @($relationshipXml.SelectNodes('//*[local-name()="Relationship" and @TargetMode="External"]')).Count 0 "Office relationship '$relationshipName' has no external target"
    }
    $contentTypesText = $package.TextByName['[Content_Types].xml']
    Assert-True ($contentTypesText -notmatch '(?i)macroEnabled|vbaProject') 'Office content types are macro-free'
    $coreText = $package.TextByName['docProps/core.xml']
    Assert-True ($coreText -match '2026-01-01T00:00:00Z') 'Office package uses fixed synthetic metadata timestamps'
    $coreXml = Get-DemoXml $package 'docProps/core.xml'
    Assert-True ($coreXml.DocumentElement.InnerText -match [regex]::Escape($banner)) 'Office package metadata carries the immutable banner'
}

$catalog = Get-Content -Raw -LiteralPath (Join-Path $demoRepoRoot 'profile/team-bob/config/vc6-build-targets.json') | ConvertFrom-Json
Assert-Equal @($catalog.profiles).Count 0 'Production build catalog remains exactly empty'
$exampleCatalog = Get-Content -Raw -LiteralPath (Join-Path $demoRepoRoot 'profile/team-bob/config/vc6-build-targets.example.json') | ConvertFrom-Json
Assert-True (@($exampleCatalog.profiles).Count -gt 0) 'Production example catalog remains present'
foreach ($profile in @($exampleCatalog.profiles)) {
    Assert-True ($profile.enabled -eq $false) "Production example profile '$($profile.id)' remains disabled"
}

$demoRoot = Join-Path $demoRepoRoot 'demo'
$forbiddenDirectories = @('bin', 'obj', '.vs', 'Debug', 'Release')
$buildOutputDirectories = @(Get-ChildItem -LiteralPath $demoRoot -Directory -Force -Recurse | Where-Object { $forbiddenDirectories -contains $_.Name })
Assert-Equal $buildOutputDirectories.Count 0 'Demo tree contains no generated build-output directories'
$trackedDemoFiles = @(& git -C $demoRepoRoot ls-files -- demo)
Assert-Equal $LASTEXITCODE 0 'Git can enumerate tracked demo files'
$trackedBuildOutputs = @($trackedDemoFiles | Where-Object { $_ -match '(?i)(^|/)(bin|obj|\.vs|Debug|Release)/|\.(exe|dll|obj|pdb|ilk|tlog)$' })
Assert-Equal $trackedBuildOutputs.Count 0 'No generated build output is tracked under demo'

$demoAssertionCount = $script:Assertions - $demoAssertionsBefore
Write-Host "PASS: $demoAssertionCount demo package contract assertions succeeded."

if ($demoTestStandalone) { exit 0 }
