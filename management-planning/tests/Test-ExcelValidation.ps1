$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'tools/Planning.Excel.psm1') -Force
Import-Module (Join-Path $root 'tools/Planning.Core.psm1') -Force
$s=Get-MpSchema;$data=@{};$script:tests=0
function Assert($value,$message){$script:tests++;if(-not $value){throw $message}}
foreach($t in $s.tables | Where-Object role -eq input){$data[$t.key]=@(Read-MpCsv -Path (Join-Path $root ('samples/normal/'+$t.key+'.csv')) -Columns $t.columns)}
foreach($source in $data.Sources){$source.Path=[IO.Path]::GetFullPath((Join-Path (Join-Path $root 'samples/normal') $source.Path))}
$temp=Join-Path (Split-Path $root -Parent) ('.superpowers/excel-validation-'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($temp)
$out=Join-Path $temp 'plan.xlsx'
Write-MpWorkbook -TemplatePath (Join-Path $root 'templates/management-template.xlsx') -Path $out -Data $data
$values=& (Get-Module Planning.Excel) {
 param($path)
 Invoke-MpExcel {
  param($app)
  $books=$app.Workbooks;$book=$null;$sheets=$null
  try{
   $book=$books.Open($path,0,$false);$sheets=$book.Worksheets
   $s=Get-MpSchema
   $estimate=$sheets.Item(($s.tables | Where-Object key -eq EstimateView).sheet)
   $tasks=$sheets.Item(($s.tables | Where-Object key -eq Tasks).sheet)
   $wbs=$sheets.Item(($s.tables | Where-Object key -eq WbsView).sheet)
   $out=[ordered]@{Parent=$estimate.Range('D5').Value2;Leaf=$estimate.Range('D7').Value2;Wbs=$wbs.Range('F5').Value2;Numeric=($tasks.Range('H7').Value2 -is [double]);HasFormula=$estimate.Range('D5').HasFormula}
   # Missing estimate must not turn the parent into a known zero-inclusive sum.
   $tasks.Range('H7').ClearContents() | Out-Null;$app.CalculateFull()
   $out.MissingParent=$estimate.Range('D5').Value2;$out.MissingLeaf=$estimate.Range('D7').Value2
   $tasks.Range('H7').Value2=[double]4
   # Sorting the source rows must keep each report ID linked to its own hours.
   $tasks.Range('A4:N13').Sort($tasks.Range('A5'),2,[Type]::Missing,[Type]::Missing,1,[Type]::Missing,1,1) | Out-Null
   $app.CalculateFull();$out.SortedParent=$estimate.Range('D5').Value2;$out.SortedLeaf=$estimate.Range('D7').Value2
   Release-MpCom $wbs;Release-MpCom $tasks;Release-MpCom $estimate
   return [pscustomobject]$out
  }finally{Release-MpCom $sheets;if($book){$book.Close($false)};Release-MpCom $book;Release-MpCom $books}
 }
} $out
Assert ($values.Parent -eq 26) 'Excel parent hours must equal 26'
Assert ($values.Leaf -eq 4) 'Excel leaf hours must equal 4'
Assert ($values.Wbs -eq 26) 'Excel WBS hours must match'
Assert $values.Numeric 'Input hours must be stored as numeric values'
Assert $values.HasFormula 'Parent should have a formula'
Assert ([string]::IsNullOrEmpty([string]$values.MissingParent)) 'Missing descendant leaves parent blank'
Assert ([string]::IsNullOrEmpty([string]$values.MissingLeaf)) 'Missing leaf is blank'
Assert ($values.SortedParent -eq 26 -and $values.SortedLeaf -eq 4) 'ID matching survives source table sorting'
$foreign=$null;$books=$null;$book=$null
try{
 $foreign=New-Object -ComObject Excel.Application;$foreign.Visible=$false;$books=$foreign.Workbooks;$book=$books.Add()
 $ignore=Read-MpWorkbook -Path $out
 Assert ($foreign.Workbooks.Count -eq 1) 'Unrelated Excel instance must remain open'
}finally{
 if($book){$book.Close($false);[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($book)}
 if($books){[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($books)}
 if($foreign){$foreign.Quit();[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($foreign)}
 [GC]::Collect();[GC]::WaitForPendingFinalizers()
}
foreach($scenario in Get-ChildItem -LiteralPath (Join-Path $root 'samples/negative') -Directory){
 $changed=@{};foreach($key in $data.Keys){$changed[$key]=$data[$key]}
 foreach($file in Get-ChildItem -LiteralPath $scenario.FullName -Filter '*.csv' -File){$def=$s.tables | Where-Object key -ceq $file.BaseName;$changed[$def.key]=@(Read-MpCsv -Path $file.FullName -Columns $def.columns)}
 $codes=@(Test-MpData $changed | ForEach-Object Code)
 foreach($expected in ((Get-Content -LiteralPath (Join-Path $scenario.FullName 'expected.txt') -Raw).Trim() -split ';')){Assert ($codes -contains $expected) ("Scenario "+$scenario.Name+" must report "+$expected)}
}
Write-Output "PASS: $script:tests Excel formula, isolation and scenario assertions. Evidence: $temp"
