$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$cli=Join-Path $root 'tools/Invoke-ManagementPlanning.ps1'
$work=Join-Path (Split-Path $root -Parent) ('.superpowers/bob-trial-replay-'+[guid]::NewGuid().ToString('N'))
$seed=Join-Path $work 'seed';$project=Join-Path $work 'project'
Import-Module (Join-Path $root 'tools/Planning.Excel.psm1') -Force
Import-Module (Join-Path $root 'tools/Planning.Core.psm1') -Force
$schema=Get-Content -Raw -Encoding UTF8 (Join-Path $root 'schema.json') | ConvertFrom-Json
$script:count=0
function Assert($condition,$message){$script:count++;if(-not $condition){throw $message}}
function Run($arguments){
 $result=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cli @arguments
 if($LASTEXITCODE -ne 0){throw "CLI failed ($LASTEXITCODE): $arguments"}
 return ($result | ConvertFrom-Json)
}
[void][IO.Directory]::CreateDirectory($seed)
foreach($def in $schema.tables | Where-Object role -eq input){
 $rows=@()
 if($def.key -notin @('Requirements','Tasks','Allocations','Questions')){
  $rows=@(Read-MpCsv -Path (Join-Path $root ('samples/normal/'+$def.key+'.csv')) -Columns $def.columns)
 }
 if($def.key -eq 'Sources'){
  foreach($source in $rows){$source.Path=[IO.Path]::GetFullPath((Join-Path $root ('samples/normal/'+$source.Path)))}
 }
 Write-MpCsv -Path (Join-Path $seed ($def.key+'.csv')) -Columns $def.columns -Rows $rows
}
$n=Run @('-Action','New','-ProjectDirectory',$project,'-SeedDirectory',$seed)
$current=$n.Workbook
$expectedErrors=@(0,8,2,0);$expectedWarnings=@(7,28,5,7)
foreach($stage in 1..4){
 $beforeHash=(Get-FileHash -LiteralPath $current).Hash
 $p=Run @('-Action','Prepare','-ProjectDirectory',$project,'-OutputDirectory',(Join-Path $work ('pack-'+$stage)))
 $i=Run @('-Action','Import','-ProjectDirectory',$project,'-DraftDirectory',(Join-Path $root ('samples/bob-ide-trial/stage-'+$stage.ToString('00'))),'-ManifestPath',$p.Manifest)
 Assert ($i.Errors -eq $expectedErrors[$stage-1]) "Stage $stage error count"
 Assert ($i.Warnings -eq $expectedWarnings[$stage-1]) "Stage $stage warning count"
 Assert ((Get-FileHash -LiteralPath $current).Hash -ceq $beforeHash) "Stage $stage changed its baseline"
 Assert ($i.Workbook -cne $current) "Stage $stage did not create a version"
 $current=$i.Workbook
 if($stage -eq 3){
  $checks=@(Import-Csv -LiteralPath (Join-Path (Split-Path $i.Diff -Parent) 'checks.csv') -Encoding UTF8 | Where-Object Severity -eq Error)
  Assert ((@($checks.Code | Sort-Object) -join ',') -ceq 'OVER_CAPACITY,UNAVAILABLE_DAY') 'The actual unavailable-day error was not reproduced'
  Assert (@($checks | Where-Object Entity -ne '002|2026-09-11').Count -eq 0) 'Unexpected invalid assignment'
 }
}
$c=Run @('-Action','Check','-ProjectDirectory',$project)
Assert ($c.Errors -eq 0 -and $c.Warnings -eq 7) 'Final checks changed'
$e=Run @('-Action','Export','-ProjectDirectory',$project,'-OutputDirectory',(Join-Path $work 'export'))
$data=Read-MpWorkbook -Path (Join-Path $e.OutputDirectory 'plan.xlsx')
Assert ($data.Requirements.Count -eq 5 -and $data.Tasks.Count -eq 9 -and $data.Allocations.Count -eq 8) 'Final table counts changed'
Assert (@($data.Questions | Where-Object Status -eq Open).Count -eq 5) 'Unresolved questions lost'
Assert (@($data.Requirements | Where-Object QAStatus -eq Open).Count -eq 2) 'Requirement QA corrections lost'
Assert (($data.Capacity | Where-Object { $_.MemberID -eq '002' -and $_.Date -eq '2026-09-11' }).AvailableHours -eq '0') 'Capacity was modified to hide the error'
Assert (($data.Tasks | Where-Object TaskID -eq 'T-031').StartDate -eq '2026-09-14') 'Code review date not repaired'
Assert (($data.Tasks | Where-Object TaskID -eq 'T-050').EndDate -eq '2026-09-17') 'Dependent release date not repaired'
Assert (($data.Tasks | Where-Object TaskID -eq 'T-010').AssigneeID -ceq '001') 'Text assignee ID lost'
$view=Get-MpViews $data
Assert (($view.EstimateView | Where-Object TaskID -eq 'T-001').Hours -eq 26) 'Estimate parent total'
Assert (($view.WbsView | Where-Object TaskID -eq 'T-001').Hours -eq 26) 'WBS parent total'
Assert (($view.ScheduleView | Measure-Object Hours -Sum).Sum -eq 26) 'Daily schedule total'
$tickets=@(Read-MpCsv -Path (Join-Path $e.OutputDirectory 'redmine.csv') -Columns ($schema.tables | Where-Object key -eq RedmineView).columns)
Assert ($tickets.Count -eq 9 -and ($tickets | Measure-Object EstimatedHours -Sum).Sum -eq 26) 'Redmine row count/total'
Assert ([string]::IsNullOrEmpty([string](($tickets | Where-Object TaskID -eq 'T-001').EstimatedHours))) 'Parent ticket duplicates leaf effort'
Write-Output ("PASS: $script:count assertions; saved real Bob CSV replay, 4 imports, 26 hours, 7 unresolved warnings. Evidence: $work")
