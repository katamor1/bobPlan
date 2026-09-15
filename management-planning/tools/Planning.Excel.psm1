Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Planning.Core.psm1') -Force
function Get-MpSchema {Get-Content -Raw -Encoding UTF8 (Join-Path $PSScriptRoot '../schema.json') | ConvertFrom-Json}
function Release-MpCom($obj){if($null -ne $obj -and [Runtime.InteropServices.Marshal]::IsComObject($obj)){[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($obj)}}
function Invoke-MpExcel([scriptblock]$Body){
 $app=$null
 try{
  $app=New-Object -ComObject Excel.Application
  $app.Visible=$false;$app.DisplayAlerts=$false;$app.AskToUpdateLinks=$false;$app.EnableEvents=$false;$app.AutomationSecurity=3;$app.ScreenUpdating=$false
  & $Body $app
 }finally{
  if($null -ne $app){try{$app.Quit()}finally{Release-MpCom $app}}
  [GC]::Collect();[GC]::WaitForPendingFinalizers()
 }
}
function Get-MpCellString($value,$type,$date1904){
 if($null -eq $value){return ''}
 if($type -eq 'date' -and $value -is [double]){if($date1904){$value+=1462};return [datetime]::FromOADate($value).ToString('yyyy-MM-dd')}
 if($value -is [IFormattable]){return $value.ToString($null,[Globalization.CultureInfo]::InvariantCulture)}
 return [string]$value
}
function Read-MpWorkbook {
 param([string]$Path)
 $full=[IO.Path]::GetFullPath($Path)
 if([IO.Path]::GetExtension($full) -ine '.xlsx'){throw 'Only macro-free .xlsx workbooks are supported.'}
 $schema=Get-MpSchema
 Invoke-MpExcel {
  param($app)
  $books=$null;$book=$null;$sheets=$null
  try{
   $books=$app.Workbooks;$book=$books.Open($full,0,$true);$sheets=$book.Worksheets;$data=@{}
   foreach($def in $schema.tables | Where-Object role -eq input){
    $sheet=$null;$tables=$null;$table=$null;$range=$null;$headers=$null
    try{
     $sheet=$sheets.Item($def.sheet);$tables=$sheet.ListObjects;$table=$tables.Item($def.table)
     $headers=$table.HeaderRowRange;$heads=$headers.Value2
     if($headers.Columns.Count -ne $def.columns.Count -or $headers.Row -ne $schema.headerRow){throw "Workbook table layout changed: $($def.key)"}
     for($c=0;$c -lt $def.columns.Count;$c++){if([string]$heads[1,($c+1)] -cne $def.columns[$c].label){throw "Workbook header changed: $($def.key)/$($def.columns[$c].name)"}}
     $rows=New-Object 'Collections.Generic.List[object]';$range=$table.DataBodyRange
     if($null -ne $range){
      $values=$range.Value2;$count=$range.Rows.Count
      for($i=1;$i -le $count;$i++){
       $row=[ordered]@{};$nonempty=$false
       for($c=0;$c -lt $def.columns.Count;$c++){
        $col=$def.columns[$c];$v=Get-MpCellString $values[$i,($c+1)] $col.type $book.Date1904
        $row[$col.name]=$v;if($v -ne ''){$nonempty=$true}
       }
       if($nonempty){$rows.Add([pscustomobject]$row)}
      }
     }
     $data[$def.key]=@($rows.ToArray())
    }finally{Release-MpCom $headers;Release-MpCom $range;Release-MpCom $table;Release-MpCom $tables;Release-MpCom $sheet}
   }
   return $data
  }finally{Release-MpCom $sheets;if($null -ne $book){$book.Close($false)};Release-MpCom $book;Release-MpCom $books}
 }
}
function Set-MpTable($sheet,$def,$rows,$date1904){
 $objects=$null;$table=$null;$old=$null;$range=$null;$cells=$null
 try{
  $objects=$sheet.ListObjects;$table=$objects.Item($def.table);$old=$table.DataBodyRange
  if($null -ne $old){[void]$old.ClearContents()}
  $n=[math]::Max(1,@($rows).Count);$cols=$def.columns.Count
  $cells=$sheet.Cells;$start=$cells.Item(4,1);$end=$cells.Item((4+$n),$cols)
  try{$range=$sheet.Range($start,$end);$table.Resize($range)}finally{Release-MpCom $end;Release-MpCom $start}
  for($c=0;$c -lt $cols;$c++){
   $col=$def.columns[$c];$a=$cells.Item(5,($c+1));$z=$cells.Item((4+$n),($c+1));$column=$null
   try{
    $column=$sheet.Range($a,$z);$column.NumberFormat='@'
    $matrix=New-Object 'object[,]' $n,1
    for($i=0;$i -lt @($rows).Count;$i++){
     $v=$rows[$i].($col.name);if($null -eq $v -or [string]$v -eq ''){$matrix[$i,0]='';continue}
     $number=0.0;$date=[datetime]::MinValue
     if($col.type -eq 'number' -and [double]::TryParse([string]$v,[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$number) -and -not [double]::IsNaN($number) -and -not [double]::IsInfinity($number)){
      $matrix[$i,0]=$number
     }elseif($col.type -eq 'date' -and [datetime]::TryParseExact([string]$v,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$date)){
      $serial=$date.ToOADate();if($date1904){$serial-=1462};$matrix[$i,0]=$serial
     }else{$matrix[$i,0]=[string]$v}
    }
    $column.Value2=$matrix
    if($col.type -eq 'number'){$column.NumberFormat='#,##0.######'}
    elseif($col.type -eq 'date'){$column.NumberFormat='yyyy-mm-dd'}
    $column.WrapText=$true
   }finally{Release-MpCom $column;Release-MpCom $z;Release-MpCom $a}
  }
  $body=$table.DataBodyRange
  try{
   $body.VerticalAlignment=-4160;$bodyRows=$body.Rows
   try{
    [void]$bodyRows.AutoFit()
    for($rowIndex=1;$rowIndex -le $bodyRows.Count;$rowIndex++){
     $bodyRow=$bodyRows.Item($rowIndex)
     try{if($bodyRow.RowHeight -lt 26){$bodyRow.RowHeight=26}}finally{Release-MpCom $bodyRow}
    }
   }finally{Release-MpCom $bodyRows}
  }finally{Release-MpCom $body}
 }finally{Release-MpCom $cells;Release-MpCom $range;Release-MpCom $old;Release-MpCom $table;Release-MpCom $objects}
}
function Set-MpOutputFormulas($book,$schema,$data,$views){
 # Quantitative report cells remain linked to inputs. Invalid snapshots retain explicit blanks.
 if(@($views.Checks | Where-Object Severity -eq Error).Count -gt 0){return}
 $sheets=$book.Worksheets;$estimate=$null;$wbs=$null;$sched=$null
 try{
  $estimate=$sheets.Item(($schema.tables | Where-Object key -eq EstimateView).sheet)
  $wbs=$sheets.Item(($schema.tables | Where-Object key -eq WbsView).sheet)
  $sched=$sheets.Item(($schema.tables | Where-Object key -eq ScheduleView).sheet)
  $taskDef=$schema.tables | Where-Object key -eq Tasks
  $estimateDef=$schema.tables | Where-Object key -eq EstimateView
  $taskSheet=$taskDef.sheet.Replace("'","''");$estimateSheet=$estimateDef.sheet.Replace("'","''")
  $lastTask=4+@($data.Tasks).Count
  $taskHoursRange="'"+$taskSheet+"'!"+'$H$5:$H$'+$lastTask
  $taskIdRange="'"+$taskSheet+"'!"+'$A$5:$A$'+$lastTask
  $estimateHoursRange="'"+$estimateSheet+"'!"+'$D$5:$D$'+$lastTask
  $estimateIdRange="'"+$estimateSheet+"'!"+'$A$5:$A$'+$lastTask
  for($i=0;$i -lt @($data.Tasks).Count;$i++){
   $row=5+$i;$task=$data.Tasks[$i];$formula='';$childRows=@()
   for($j=0;$j -lt @($data.Tasks).Count;$j++){
    if($data.Tasks[$j].ParentTaskID -ieq $task.TaskID){
     $childId=$data.Tasks[$j].TaskID.Replace('"','""')
     $childRows+=('INDEX('+$estimateHoursRange+',MATCH("'+$childId+'",'+$estimateIdRange+',0))')
    }
   }
   if($childRows.Count -gt 0){$refs=$childRows -join ',';$formula='=IF(COUNT('+ $refs +')='+$childRows.Count+',SUM('+$refs+'),"")'}
   else{$source='INDEX('+$taskHoursRange+',MATCH(A'+$row+','+$taskIdRange+',0))';$formula='=IF(COUNT('+$source+')=1,'+$source+',"")'}
   $cell=$estimate.Cells.Item($row,4);try{$cell.Formula=$formula}finally{Release-MpCom $cell}
   $source='INDEX('+$estimateHoursRange+',MATCH(A'+$row+','+$estimateIdRange+',0))'
   $cell=$wbs.Cells.Item($row,6);try{$cell.Formula='=IF(COUNT('+$source+')=1,'+$source+',"")'}finally{Release-MpCom $cell}
  }
  for($i=0;$i -lt @($views.ScheduleView).Count;$i++){
   $row=5+$i;$last=4+@($views.ScheduleView).Count
   $cell=$sched.Cells.Item($row,5)
   try{if($null -ne $views.ScheduleView[$i].DailyTotal){$cell.Formula='=SUMIFS(D$5:D$'+$last+',B$5:B$'+$last+',B'+$row+',C$5:C$'+$last+',C'+$row+')'}}finally{Release-MpCom $cell}
  }
 }finally{Release-MpCom $sched;Release-MpCom $wbs;Release-MpCom $estimate;Release-MpCom $sheets}
}
function Write-MpWorkbook {
 param([string]$TemplatePath,[string]$Path,[hashtable]$Data)
 $target=[IO.Path]::GetFullPath($Path)
 if(Test-Path -LiteralPath $target){throw "Output already exists: $target"}
 if([IO.Path]::GetExtension($target) -ine '.xlsx'){throw 'Output must be .xlsx'}
 [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))
 $stage=Join-Path ([IO.Path]::GetDirectoryName($target)) ('.partial-'+[guid]::NewGuid().ToString('N')+'.xlsx')
 $schema=Get-MpSchema;$views=Get-MpViews -Data $Data
 try{
  Invoke-MpExcel {
   param($app)
   $books=$null;$book=$null;$sheets=$null
   try{
    $books=$app.Workbooks;$book=$books.Open([IO.Path]::GetFullPath($TemplatePath),0,$true);$sheets=$book.Worksheets
    foreach($def in $schema.tables){
     $rows=@();if($def.role -eq 'input'){$rows=@($Data[$def.key])}else{$rows=@($views[$def.key])}
     $sheet=$sheets.Item($def.sheet)
     try{Set-MpTable $sheet $def $rows $book.Date1904}finally{Release-MpCom $sheet}
    }
    Set-MpOutputFormulas $book $schema $Data $views
    $book.ForceFullCalculation=$true;$app.CalculateFull()
    $book.SaveAs($stage,51)
   }finally{Release-MpCom $sheets;if($null -ne $book){$book.Close($false)};Release-MpCom $book;Release-MpCom $books}
  }
  [IO.File]::Move($stage,$target)
 }finally{if([IO.File]::Exists($stage)){[IO.File]::Delete($stage)}}
}
function Read-MpSourceRange {
 param([string]$Path,[string]$Sheet,[string]$Range)
 Import-Module (Join-Path $PSScriptRoot 'Planning.Source.psm1') -Force
 Read-MpXlsxSource -Path $Path -Sheet $Sheet -Range $Range
}
Export-ModuleMember -Function Get-MpSchema,Read-MpWorkbook,Write-MpWorkbook,Read-MpSourceRange
