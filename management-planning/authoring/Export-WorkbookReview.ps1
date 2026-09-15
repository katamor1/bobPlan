[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$Workbook,[Parameter(Mandatory=$true)][string]$OutputDirectory,[string[]]$SheetKeys)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$schema=Get-Content -Raw -Encoding UTF8 (Join-Path $root 'schema.json') | ConvertFrom-Json
$out=[IO.Path]::GetFullPath($OutputDirectory)
if(Test-Path $out){throw 'Choose a new review directory.'}
[void][IO.Directory]::CreateDirectory($out)
$app=$null;$books=$null;$book=$null;$sheets=$null
function Release($obj){if($null -ne $obj -and [Runtime.InteropServices.Marshal]::IsComObject($obj)){[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($obj)}}
try{
 $app=New-Object -ComObject Excel.Application
 $app.Visible=$false;$app.DisplayAlerts=$false;$app.AskToUpdateLinks=$false;$app.EnableEvents=$false;$app.AutomationSecurity=3
 $books=$app.Workbooks;$book=$books.Open([IO.Path]::GetFullPath($Workbook),0,$true);$sheets=$book.Worksheets
 $app.CalculateFull()
 foreach($def in $schema.tables){
  if($SheetKeys -and $SheetKeys -notcontains $def.key){continue}
  $sheet=$sheets.Item($def.sheet);$setup=$null;$used=$null
  try{
   $setup=$sheet.PageSetup;$setup.Orientation=2;$setup.PaperSize=9;$setup.Zoom=$false;$setup.FitToPagesWide=1;$setup.FitToPagesTall=1
   $setup.LeftMargin=18;$setup.RightMargin=18;$setup.TopMargin=18;$setup.BottomMargin=24
   $setup.CenterFooter=$def.sheet+' / native Excel review'
   $used=$sheet.UsedRange
   $lastRow=[math]::Min(14,[math]::Max(6,$used.Rows.Count));$last=[string][char](64+$def.columns.Count)
   $areas=@("A1:$last$lastRow")
   if($def.columns.Count -gt 7){$areas=@("A1:G$lastRow","H1:$last$lastRow")}
   for($i=0;$i -lt $areas.Count;$i++){
    $setup.PrintArea=$areas[$i]
    $sheet.ExportAsFixedFormat(0,(Join-Path $out ($def.key+'-'+($i+1)+'.pdf')))
   }
   Write-Output ('Rendered '+$def.key)
  }finally{Release $used;Release $setup;Release $sheet}
 }
 # Scan cached/recalculated values for actual Excel errors, independently from the preview importer.
 $errors=@()
 foreach($sheet in $sheets){
  $used=$sheet.UsedRange
  try{foreach($cell in $used.Cells){try{if($cell.Text -match '^#(REF!|DIV/0!|VALUE!|NAME\?|N/A|NUM!|NULL!|SPILL!|CALC!)$'){$errors+=($sheet.Name+'!'+$cell.Address())}}finally{Release $cell}}}finally{Release $used;Release $sheet}
 }
 if($errors.Count -gt 0){throw ('Excel errors: '+($errors -join ', '))}
 $tasks=$sheets.Item(($schema.tables | Where-Object key -eq Tasks).sheet);$estimate=$sheets.Item(($schema.tables | Where-Object key -eq EstimateView).sheet)
 try{
  $evidence=[ordered]@{Engine='Desktop Excel';Version=$app.Version;FormulaErrors=$errors;ParentInputHours=$tasks.Range('H5').Value2;AssigneeID=$tasks.Range('J6').Value2;ParentOutputHours=$estimate.Range('D5').Value2}
  $evidence | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 (Join-Path $out 'native-evidence.json')
 }finally{Release $estimate;Release $tasks}
}finally{
 Release $sheets
 if($book){$book.Close($false)};Release $book;Release $books
 if($app){$app.Quit()};Release $app
 [GC]::Collect();[GC]::WaitForPendingFinalizers()
}
Write-Output "Native review saved: $out"
