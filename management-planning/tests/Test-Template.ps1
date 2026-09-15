[CmdletBinding()]
param([string]$TemplatePath)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $TemplatePath) { $TemplatePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'templates/management-template.xlsx' }
Add-Type -AssemblyName System.IO.Compression.FileSystem
$schema = Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'schema.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$zip = [System.IO.Compression.ZipFile]::OpenRead($TemplatePath)
$script:assertions = 0
function Assert-Template($condition, [string]$message) {
    if (-not $condition) { throw $message }
    $script:assertions++
}
function Read-ZipXml([string]$name) {
    $entry = $zip.GetEntry($name)
    if ($null -eq $entry) { throw "Missing XLSX part: $name" }
    $reader = New-Object System.IO.StreamReader($entry.Open())
    try { return [xml]$reader.ReadToEnd() } finally { $reader.Dispose() }
}
function Cell-Text($cell, $strings) {
    if ($null -eq $cell) { return '' }
    if ($cell.GetAttribute('t') -eq 's') { return $strings[[int]$cell.SelectSingleNode('./*[local-name()="v"]').InnerText] }
    if ($cell.GetAttribute('t') -eq 'inlineStr') { return $cell.InnerText }
    return $cell.InnerText
}
try {
    $book = Read-ZipXml 'xl/workbook.xml'
    $rels = Read-ZipXml 'xl/_rels/workbook.xml.rels'
    $sheets = @($book.SelectNodes('//*[local-name()="sheet"]'))
    Assert-Template ($sheets.Count -eq $schema.tables.Count) 'Sheet count differs from schema.'
    $strings = @()
    if ($null -ne $zip.GetEntry('xl/sharedStrings.xml')) {
        $shared = Read-ZipXml 'xl/sharedStrings.xml'
        $strings = @($shared.SelectNodes('//*[local-name()="si"]') | ForEach-Object { $_.InnerText })
    }
    for ($i = 0; $i -lt $schema.tables.Count; $i++) {
        $definition = $schema.tables[$i]
        $sheet = $sheets[$i]
        Assert-Template ($sheet.GetAttribute('name') -ceq $definition.sheet) "Unexpected sheet at position $i."
        $relationId = $sheet.GetAttribute('id', 'http://schemas.openxmlformats.org/officeDocument/2006/relationships')
        $relation = $rels.SelectSingleNode("//*[local-name()='Relationship' and @Id='$relationId']")
        $target = $relation.GetAttribute('Target')
        $sheetPath = if ($target.StartsWith('/')) { $target.TrimStart('/') } else { 'xl/' + $target }
        $xml = Read-ZipXml $sheetPath
        $header = @($xml.SelectNodes("//*[local-name()='row' and @r='$($schema.headerRow)']/*[local-name()='c']"))
        Assert-Template ($header.Count -eq $definition.columns.Count) "Header count: $($definition.key)"
        for ($c = 0; $c -lt $header.Count; $c++) {
            Assert-Template ((Cell-Text $header[$c] $strings) -ceq $definition.columns[$c].label) "Header mismatch: $($definition.key)/$c"
        }
        $dataCells = @($xml.SelectNodes("//*[local-name()='row' and number(@r)>=$($schema.dataRow)]/*[local-name()='c']"))
        foreach ($cell in $dataCells) { Assert-Template ([string]::IsNullOrEmpty((Cell-Text $cell $strings))) "Template contains a data record: $($definition.key)" }
        Assert-Template ($xml.SelectNodes('//*[local-name()="f"]').Count -eq 0) "Unexpected template formula: $($definition.key)"
        Assert-Template ($xml.SelectNodes('//*[local-name()="pane" and @ySplit="4"]').Count -eq 1) "Missing frozen header: $($definition.key)"
        Assert-Template ($xml.SelectNodes('//*[local-name()="tablePart"]').Count -eq 1) "Table count: $($definition.key)"
        $tableEntry = @($zip.Entries | Where-Object { $_.FullName -match '^xl/tables/table\d+\.xml$' } | Where-Object {
            $tableXml = Read-ZipXml $_.FullName
            $tableXml.DocumentElement.GetAttribute('name') -ceq $definition.table
        })
        Assert-Template ($tableEntry.Count -eq 1) "Named table missing: $($definition.table)"
        $tableXml = Read-ZipXml $tableEntry[0].FullName
        $lastColumn = [char](64 + $definition.columns.Count)
        Assert-Template ($tableXml.DocumentElement.GetAttribute('ref') -eq "A4:$($lastColumn)5") "Table needs one empty data row: $($definition.key)"
        $tableColumns = @($tableXml.SelectNodes('//*[local-name()="tableColumn"]'))
        for ($c = 0; $c -lt $definition.columns.Count; $c++) {
            Assert-Template ($tableColumns[$c].GetAttribute('name') -ceq $definition.columns[$c].label) "Table column mismatch: $($definition.key)/$c"
        }
    }
    Assert-Template (@($zip.Entries | Where-Object { $_.FullName -match 'vbaProject|externalLinks/' }).Count -eq 0) 'Unexpected macro or external link.'
    Write-Output "Template checks passed: $($schema.tables.Count) sheets, $script:assertions assertions."
} finally { $zip.Dispose() }
