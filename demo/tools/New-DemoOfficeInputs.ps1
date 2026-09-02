# MSBUILD DEMO ADAPTER — NOT VC6 QUALIFICATION
[CmdletBinding()]
param(
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path (Split-Path -Parent (Split-Path -Parent $PSCommandPath)) 'inputs'
}

function New-OfficeEntry {
    param([string]$Name, [string]$Text)
    return [pscustomobject]@{ Name = $Name; Text = $Text }
}

function Write-OfficePackage {
    param([string]$Path, [object[]]$Entries)

    $stream = New-Object System.IO.FileStream(
        $Path,
        [System.IO.FileMode]::Create,
        [System.IO.FileAccess]::ReadWrite,
        [System.IO.FileShare]::None
    )
    try {
        $archive = New-Object System.IO.Compression.ZipArchive(
            $stream,
            [System.IO.Compression.ZipArchiveMode]::Create,
            $true
        )
        try {
            $timestamp = [DateTimeOffset]::Parse('2026-01-01T00:00:00Z', [Globalization.CultureInfo]::InvariantCulture)
            $encoding = New-Object System.Text.UTF8Encoding($false)
            foreach ($entrySpec in $Entries) {
                $entry = $archive.CreateEntry($entrySpec.Name, [System.IO.Compression.CompressionLevel]::Optimal)
                $entry.LastWriteTime = $timestamp
                $entryStream = $entry.Open()
                try {
                    $writer = New-Object System.IO.StreamWriter($entryStream, $encoding)
                    try { $writer.Write($entrySpec.Text) } finally { $writer.Dispose() }
                } finally {
                    $entryStream.Dispose()
                }
            }
        } finally {
            $archive.Dispose()
        }
    } finally {
        $stream.Dispose()
    }
}

$bannerEntity = 'MSBUILD DEMO ADAPTER &#x2014; NOT VC6 QUALIFICATION'
$coreProperties = @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><dc:title>MSBUILD DEMO ADAPTER &#x2014; NOT VC6 QUALIFICATION</dc:title><dc:subject>Synthetic Office input only</dc:subject><dc:creator>Team Bob synthetic generator</dc:creator><cp:keywords>synthetic;offline;not-vc6</cp:keywords><dcterms:created xsi:type="dcterms:W3CDTF">2026-01-01T00:00:00Z</dcterms:created><dcterms:modified xsi:type="dcterms:W3CDTF">2026-01-01T00:00:00Z</dcterms:modified></cp:coreProperties>
'@
$appProperties = @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes"><Application>Team Bob synthetic generator</Application><AppVersion>1.0</AppVersion></Properties>
'@

$docxEntries = @(
    (New-OfficeEntry '[Content_Types].xml' @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/><Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/><Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/></Types>
'@),
    (New-OfficeEntry '_rels/.rels' @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/></Relationships>
'@),
    (New-OfficeEntry 'docProps/core.xml' $coreProperties),
    (New-OfficeEntry 'docProps/app.xml' $appProperties),
    (New-OfficeEntry 'word/_rels/document.xml.rels' @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>
'@),
    (New-OfficeEntry 'word/styles.xml' @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:rPr><w:lang w:val="ja-JP"/></w:rPr></w:style></w:styles>
'@),
    (New-OfficeEntry 'word/document.xml' @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>
<w:p><w:r><w:t>MSBUILD DEMO ADAPTER &#x2014; NOT VC6 QUALIFICATION</w:t></w:r></w:p>
<w:p><w:r><w:t>&#x30b5;&#x30a4;&#x30af;&#x30eb;&#x76e3;&#x8996;&#x306e;&#x6539;&#x5584;&#x3092;&#x304a;&#x9858;&#x3044;&#x3057;&#x307e;&#x3059;&#x3002;&#x5bfe;&#x8c61;&#x306f;&#x5408;&#x6210;&#x30b1;&#x30fc;&#x30b9;&#x306e; Customer-A &#x306e;&#x307f;&#x3067;&#x3059;&#x3002;</w:t></w:r></w:p>
<w:p><w:r><w:t>warm-up &#x4e2d;&#x306f; cycle-overrun &#x306e; Warning &#x3092;&#x6291;&#x6b62;&#x3057;&#x3001;&#x9023;&#x7d9a;&#x8d85;&#x904e;&#x56de;&#x6570;&#x3092; reset &#x3057;&#x3066;&#x304f;&#x3060;&#x3055;&#x3044;&#x3002;</w:t></w:r></w:p>
<w:p><w:r><w:t>warm-up &#x5f8c;&#x306f; cycle time &#x304c; 8,000 microseconds &#x4ee5;&#x4e0a;&#x306e;&#x72b6;&#x614b;&#x304c; 3 consecutive cycles &#x7d9a;&#x3044;&#x305f;&#x5834;&#x5408;&#x306b;&#x3060;&#x3051; Warning &#x3078;&#x9077;&#x79fb;&#x3057;&#x3066;&#x304f;&#x3060;&#x3055;&#x3044;&#x3002;8,000 &#x306f; inclusive threshold &#x3067;&#x3059;&#x3002;</w:t></w:r></w:p>
<w:p><w:r><w:t>cycle time &#x304c; 8,000 microseconds &#x672a;&#x6e80;&#xff08;&#x305f;&#x3068;&#x3048;&#x3070; 7,999&#xff09;&#x306b;&#x306a;&#x3063;&#x305f;&#x3089;&#x3001;&#x76f4;&#x3061;&#x306b; Normal &#x3078;&#x623b;&#x3057;&#x3066;&#x56de;&#x6570;&#x3092; reset &#x3057;&#x3066;&#x304f;&#x3060;&#x3055;&#x3044;&#x3002;</w:t></w:r></w:p>
<w:p><w:r><w:t>&#x3053;&#x306e;&#x8cc7;&#x6599;&#x306f; synthetic-only &#x3067;&#x3059;&#x3002;machine-control hardware&#x3001;control network&#x3001;production repository&#x3001;credentials&#x3001;customer data &#x306b;&#x306f;&#x63a5;&#x7d9a;&#x3057;&#x307e;&#x305b;&#x3093;&#x3002;</w:t></w:r></w:p>
<w:p><w:r><w:t>board&#x3001;driver&#x3001;ABI&#x3001;control period &#x306f;&#x5909;&#x66f4;&#x3057;&#x307e;&#x305b;&#x3093;&#x3002;</w:t></w:r></w:p>
<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440"/></w:sectPr>
</w:body></w:document>
'@)
)

$xlsxEntries = @(
    (New-OfficeEntry '[Content_Types].xml' @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/><Override PartName="/xl/tables/table1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.table+xml"/><Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/><Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/></Types>
'@),
    (New-OfficeEntry '_rels/.rels' @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/></Relationships>
'@),
    (New-OfficeEntry 'docProps/core.xml' $coreProperties),
    (New-OfficeEntry 'docProps/app.xml' $appProperties),
    (New-OfficeEntry 'xl/workbook.xml' @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><bookViews><workbookView activeTab="0"/></bookViews><sheets><sheet name="QA" sheetId="1" r:id="rId1"/></sheets><calcPr calcId="0" calcMode="manual"/></workbook>
'@),
    (New-OfficeEntry 'xl/_rels/workbook.xml.rels' @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>
'@),
    (New-OfficeEntry 'xl/worksheets/sheet1.xml' @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><dimension ref="A1:B6"/><sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews><cols><col min="1" max="1" width="42" customWidth="1"/><col min="2" max="2" width="76" customWidth="1"/></cols><sheetData>
<row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c></row>
<row r="2"><c r="A2" t="s"><v>2</v></c><c r="B2" t="s"><v>3</v></c></row>
<row r="3"><c r="A3" t="s"><v>4</v></c><c r="B3" t="s"><v>5</v></c></row>
<row r="4"><c r="A4" t="s"><v>6</v></c><c r="B4" t="s"><v>7</v></c></row>
<row r="5"><c r="A5" t="s"><v>8</v></c><c r="B5" t="s"><v>9</v></c></row>
<row r="6"><c r="A6" t="s"><v>10</v></c><c r="B6" t="s"><v>11</v></c></row>
</sheetData><autoFilter ref="A1:B6"/><tableParts count="1"><tablePart r:id="rId1"/></tableParts></worksheet>
'@),
    (New-OfficeEntry 'xl/worksheets/_rels/sheet1.xml.rels' @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/table" Target="../tables/table1.xml"/></Relationships>
'@),
    (New-OfficeEntry 'xl/sharedStrings.xml' @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="12" uniqueCount="12">
<si><t>Question</t></si><si><t>Answer</t></si>
<si><t>MSBUILD DEMO ADAPTER &#x2014; NOT VC6 QUALIFICATION: &#x3057;&#x304d;&#x3044;&#x5024;&#x306f;&#x542b;&#x307e;&#x308c;&#x307e;&#x3059;&#x304b;&#xff1f;</t></si><si><t>8,000 microseconds is inclusive. 8,000 &#x4ee5;&#x4e0a;&#x3092; overrun &#x3068;&#x3057;&#x307e;&#x3059;&#x3002;</t></si>
<si><t>warm-up &#x4e2d;&#x306e;&#x6271;&#x3044;&#x306f;&#xff1f;</t></si><si><t>warm-up &#x4e2d;&#x306f; Warning &#x3092; suppress &#x3057;&#x3001;&#x9023;&#x7d9a;&#x56de;&#x6570;&#x3092; reset &#x3057;&#x307e;&#x3059;&#x3002;</t></si>
<si><t>below 8,000 &#x306b;&#x623b;&#x3063;&#x305f;&#x5834;&#x5408;&#x306f;&#xff1f;</t></si><si><t>immediately Normal &#x3078;&#x623b;&#x3057;&#x3001;&#x9023;&#x7d9a;&#x56de;&#x6570;&#x3092; reset &#x3057;&#x307e;&#x3059;&#x3002;</t></si>
<si><t>&#x5bfe;&#x8c61;&#x306e;&#x5408;&#x6210;&#x30b1;&#x30fc;&#x30b9;&#x306f;&#xff1f;</t></si><si><t>Customer-A only &#x3067;&#x3059;&#x3002;&#x4ed6;&#x306e;&#x5bfe;&#x8c61;&#x306b;&#x306f;&#x9069;&#x7528;&#x3057;&#x307e;&#x305b;&#x3093;&#x3002;</t></si>
<si><t>&#x30d7;&#x30e9;&#x30c3;&#x30c8;&#x30d5;&#x30a9;&#x30fc;&#x30e0;&#x5909;&#x66f4;&#x306f;&#xff1f;</t></si><si><t>board, driver, ABI, and control period remain unchanged.</t></si>
</sst>
'@),
    (New-OfficeEntry 'xl/styles.xml' @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="1"><font><sz val="11"/><name val="Meiryo"/></font></fonts><fills count="1"><fill><patternFill patternType="none"/></fill></fills><borders count="1"><border/></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0" applyAlignment="1"><alignment wrapText="1" vertical="top"/></xf></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>
'@),
    (New-OfficeEntry 'xl/tables/table1.xml' @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<table xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" id="1" name="QATable" displayName="QATable" ref="A1:B6" totalsRowShown="0"><autoFilter ref="A1:B6"/><tableColumns count="2"><tableColumn id="1" name="Question"/><tableColumn id="2" name="Answer"/></tableColumns><tableStyleInfo name="TableStyleMedium2" showFirstColumn="0" showLastColumn="0" showRowStripes="1" showColumnStripes="0"/></table>
'@)
)

$resolvedOutput = [System.IO.Path]::GetFullPath($OutputDirectory)
if (-not [System.IO.Directory]::Exists($resolvedOutput)) {
    [void][System.IO.Directory]::CreateDirectory($resolvedOutput)
}

$docxPath = Join-Path $resolvedOutput 'requirements-demo.docx'
$xlsxPath = Join-Path $resolvedOutput 'qa-demo.xlsx'
Write-OfficePackage $docxPath $docxEntries
Write-OfficePackage $xlsxPath $xlsxEntries

$banner = 'MSBUILD DEMO ADAPTER ' + [char]0x2014 + ' NOT VC6 QUALIFICATION'
Write-Host "$banner`nWROTE: $docxPath`nWROTE: $xlsxPath"
