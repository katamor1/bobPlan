$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'tools/Planning.Excel.psm1') -Force
Import-Module (Join-Path $root 'tools/Planning.Core.psm1') -Force
$schema=Get-MpSchema;$count=0
$path=Join-Path $root 'samples/normal/reference-plan.xlsx'
$hash=(Get-FileHash $path).Hash
$actual=Read-MpWorkbook $path
foreach($def in $schema.tables | Where-Object role -eq input){
 $expected=@(Read-MpCsv -Path (Join-Path $root ('samples/normal/'+$def.key+'.csv')) -Columns $def.columns)
 if($expected.Count -ne $actual[$def.key].Count){throw ('Reference row count: '+$def.key)}
 for($i=0;$i -lt $expected.Count;$i++){foreach($col in $def.columns){
  $count++
  if([string]$expected[$i].($col.name) -cne [string]$actual[$def.key][$i].($col.name)){throw ('Reference value differs: '+$def.key+' row '+$i+' '+$col.name)}
 }}
}
$app=$null;$books=$null;$book=$null;$sheets=$null
function Release($obj){if($null -ne $obj -and [Runtime.InteropServices.Marshal]::IsComObject($obj)){[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($obj)}}
try{
 $app=New-Object -ComObject Excel.Application;$app.Visible=$false;$app.DisplayAlerts=$false;$app.AskToUpdateLinks=$false;$app.EnableEvents=$false;$app.AutomationSecurity=3
 $books=$app.Workbooks;$book=$books.Open([IO.Path]::GetFullPath($path),0,$true);$sheets=$book.Worksheets;$app.CalculateFull()
 foreach($key in @('EstimateView','WbsView')){
  $sheet=$sheets.Item(($schema.tables | Where-Object key -eq $key).sheet)
  try{
   $address='D5';if($key -eq 'WbsView'){$address='F5'}
   $cell=$sheet.Range($address);try{if($cell.Value2 -ne 26){throw ('Native parent total: '+$key)}}finally{Release $cell}
   $count++
  }finally{Release $sheet}
 }
 foreach($def in $schema.tables){
  $sheet=$sheets.Item($def.sheet);$used=$sheet.UsedRange
  try{
   foreach($cell in $used.Cells){try{if($cell.HasFormula){$count++;if($cell.Text -match '^#(REF!|DIV/0!|VALUE!|NAME\?|N/A|NUM!|NULL!|SPILL!|CALC!)$'){throw ('Native formula error: '+$sheet.Name+'!'+$cell.Address())}}}finally{Release $cell}}
  }finally{Release $used;Release $sheet}
 }
}finally{
 Release $sheets;if($book){$book.Close($false)};Release $book;Release $books
 if($app){$app.Quit()};Release $app
 [GC]::Collect();[GC]::WaitForPendingFinalizers()
}
if((Get-FileHash $path).Hash -cne $hash){throw 'Reference modified during verification'}
Write-Output "PASS: $count reference data and native formula assertions; file unchanged."
