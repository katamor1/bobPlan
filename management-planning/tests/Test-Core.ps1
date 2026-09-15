$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../tools/Planning.Core.psm1') -Force
$schema = Get-Content -Raw -Encoding UTF8 (Join-Path $PSScriptRoot '../schema.json') | ConvertFrom-Json
$script:count = 0
function Assert($condition, $message) { $script:count++; if (-not $condition) { throw $message } }
function Row($key, $values) {
  $r = [ordered]@{}
  foreach ($c in ($schema.tables | Where-Object key -eq $key).columns) { $r[$c.name] = '' }
  foreach ($k in $values.Keys) { $r[$k] = [string]$values[$k] }
  [pscustomobject]$r
}
function Fixture {
 $d = @{}; foreach($t in $schema.tables | Where-Object role -eq 'input') { $d[$t.key] = @() }
 $d.Project = @(Row Project @{Key='ProjectID';Value='TEST'}; Row Project @{Key='StartDate';Value='2026-09-07'}; Row Project @{Key='DueDate';Value='2026-09-30'})
 $d.Sources = @(Row Sources @{SourceID='SRC';Path='source.docx';Kind='DOCX'})
 $d.Requirements = @(Row Requirements @{ReqID='R1';SourceID='SRC';SourceAnchor='paragraph:1';Interpretation='Requirement';AcceptanceCriteria='Accepted';QAStatus='Resolved'})
 $d.People = @(Row People @{MemberID='001';Name='Person';Phases='Design;Test'})
 $d.Capacity = @(Row Capacity @{MemberID='001';Date='2026-09-07';AvailableHours='4'};Row Capacity @{MemberID='001';Date='2026-09-08';AvailableHours='4'})
 $d.Tasks = @(
 Row Tasks @{TaskID='P';Title='Parent';Status='Draft'}
 Row Tasks @{TaskID='T1';ParentTaskID='P';ReqIDs='R1';Title='Design';Phase='Design';Deliverable='Spec';AcceptanceCriteria='Reviewed';EstimatedHours='4';EstimateBasis='Fixture';AssigneeID='001';StartDate='2026-09-07';EndDate='2026-09-07';Status='Draft'}
 Row Tasks @{TaskID='T2';ParentTaskID='P';ReqIDs='R1';Title='Test';Phase='Test';Deliverable='Report';AcceptanceCriteria='Pass';EstimatedHours='2';EstimateBasis='Fixture';AssigneeID='001';StartDate='2026-09-08';EndDate='2026-09-08';PredecessorIDs='T1';Status='Draft'}
 )
 $d.Allocations = @(Row Allocations @{TaskID='T1';Date='2026-09-07';Hours='4'};Row Allocations @{TaskID='T2';Date='2026-09-08';Hours='2'})
 return $d
}
function HasCode($d,$code) { @((Test-MpData -Data $d) | Where-Object Code -eq $code).Count -gt 0 }
$d=Fixture
Assert (@(Test-MpData -Data $d).Count -eq 0) 'valid fixture has no findings'
$v=Get-MpViews -Data $d
Assert (($v.EstimateView | Where-Object TaskID -eq P).Hours -eq 6) 'parent sums leaves'
Assert (($v.WbsView | Where-Object TaskID -eq P).Hours -eq 6) 'WBS matches estimate'
Assert (($v.RedmineView | Where-Object TaskID -eq T1).EstimatedHours -eq 4) 'ticket hours match'
Assert (($v.ScheduleView | Measure-Object Hours -Sum).Sum -eq 6) 'allocation view conserves hours'
$d=Fixture; $d.Tasks[1].EstimatedHours=''; Assert (HasCode $d 'MISSING_ESTIMATE') 'missing estimate flagged'
Assert (($null -eq (Get-MpViews $d).EstimateView[0].Hours) -or [string]::IsNullOrWhiteSpace([string](Get-MpViews $d).EstimateView[0].Hours)) 'unknown descendant leaves parent blank'
$d=Fixture; $d.Tasks += $d.Tasks[1]; Assert (HasCode $d 'DUPLICATE_ID') 'duplicate task'
$d=Fixture; $d.Tasks[0].ParentTaskID='T1'; Assert (HasCode $d 'PARENT_CYCLE') 'parent cycle'
$d=Fixture; $d.Tasks[1].PredecessorIDs='T2'; Assert (HasCode $d 'DEPENDENCY_CYCLE') 'dependency cycle'
$d=Fixture; $d.Tasks[1].ParentTaskID='none'; Assert (HasCode $d 'UNKNOWN_PARENT') 'unknown parent'
$d=Fixture; $d.Tasks[1].PredecessorIDs='none'; Assert (HasCode $d 'UNKNOWN_PREDECESSOR') 'unknown predecessor'
$d=Fixture; $d.Tasks[1].ReqIDs='none'; Assert (HasCode $d 'UNKNOWN_REQUIREMENT') 'unknown requirement'
$d=Fixture; $d.Requirements += (Row Requirements @{ReqID='R2';SourceID='SRC';SourceAnchor='p2';Interpretation='extra';AcceptanceCriteria='ok';QAStatus='Resolved'}); Assert (HasCode $d 'UNCOVERED_REQUIREMENT') 'uncovered requirement'
$d=Fixture; $d.Tasks[1].AssigneeID='none'; Assert (HasCode $d 'UNKNOWN_ASSIGNEE') 'unknown person'
$d=Fixture; $d.Tasks[1].AssigneeID=''; Assert (HasCode $d 'MISSING_ASSIGNEE') 'missing person'
$d=Fixture; $d.Tasks[1].Phase='Unknown'; Assert (HasCode $d 'PHASE_MISMATCH') 'phase mismatch'
$d=Fixture; $d.Allocations[0].Hours='3'; Assert (HasCode $d 'ALLOCATION_MISMATCH') 'allocation sum'
$d=Fixture; $d.Capacity[0].AvailableHours='3'; Assert (HasCode $d 'OVER_CAPACITY') 'capacity over'
$d=Fixture; $d.Capacity[0].AvailableHours='0'; Assert (HasCode $d 'UNAVAILABLE_DAY') 'zero capacity'
$d=Fixture; $d.Capacity=@($d.Capacity[1]); Assert (HasCode $d 'MISSING_CAPACITY') 'unknown capacity not zero'
$d=Fixture; $d.Allocations[0].Date='2026-09-08'; Assert (HasCode $d 'OUTSIDE_TASK_DATES') 'outside task dates'
$d=Fixture; $d.Tasks[2].StartDate='2026-09-07'; Assert (HasCode $d 'DEPENDENCY_DATE') 'same-day dependency'
$d=Fixture; $d.Tasks[1].EstimatedHours='NaN'; Assert (HasCode $d 'INVALID_NUMBER') 'nonfinite number'
$d=Fixture; $d.Tasks[1].StartDate='2026-02-30'; Assert (HasCode $d 'INVALID_DATE') 'invalid date'
$d=Fixture; $d.Tasks[0].EstimatedHours='99'; Assert (HasCode $d 'PARENT_OWN_WORK') 'parent cannot duplicate effort'
$d=Fixture; $d.Allocations += (Row Allocations @{TaskID='P';Date='2026-09-07';Hours='1'}); Assert (HasCode $d 'PARENT_ALLOCATION') 'parent cannot allocate'
$d=Fixture; $d.Tasks[1].EstimatedHours='-2'; Assert (HasCode $d 'INVALID_NUMBER') 'negative estimate'
$d=Fixture; $d.Requirements[0].SourceID='none'; Assert (HasCode $d 'UNKNOWN_SOURCE') 'unknown source'
$d=Fixture; $d.Tasks[1].ParentTaskID='p'; $d.Tasks[2].PredecessorIDs='t1'
Assert (@(Test-MpData $d).Count -eq 0) 'ID references use Excel-compatible case-insensitive matching'
$d=Fixture; $extra=Row Tasks @{TaskID='t1';Title='duplicate case'}; $d.Tasks+=$extra
Assert (HasCode $d 'DUPLICATE_ID') 'case-only IDs are duplicates'
$d=Fixture; $d.Tasks[1].TaskID='T*'; Assert (HasCode $d 'INVALID_ID') 'Excel wildcard is not an identifier'
$d=Fixture; $d.Tasks[1].TaskID=' T1'; Assert (HasCode $d 'INVALID_ID') 'whitespace cannot silently alter ID references'
$tmp=Join-Path ([IO.Path]::GetTempPath()) ('mp-core-'+[guid]::NewGuid().ToString('N')); [void][IO.Directory]::CreateDirectory($tmp)
$cols=($schema.tables | Where-Object key -eq Tasks).columns
$d=Fixture; $d.Tasks[1].Title = 'Japanese ' + [char]0x8981 + [char]0x6c42 + ", quoted ""text""" + "`nsecond line"
$d.Tasks[1].EstimateBasis='=1+1'
$p=Join-Path $tmp 'roundtrip.csv'; Write-MpCsv -Path $p -Columns $cols -Rows $d.Tasks
$back=@(Read-MpCsv -Path $p -Columns $cols)
Assert ($back.Count -eq 3) 'CSV row count'
Assert ($back[1].AssigneeID -ceq '001') 'leading zero retained'
Assert ($back[1].Title -ceq $d.Tasks[1].Title) 'quoted multiline Unicode roundtrip'
Assert ($back[1].EstimateBasis -ceq '=1+1') 'canonical CSV literal retained'
Write-MpCsv -Path $p -Columns $cols -Rows @()
Assert (@(Read-MpCsv -Path $p -Columns $cols).Count -eq 0) 'header only CSV clears table'
[IO.File]::WriteAllText($p,'wrong,header',[Text.UTF8Encoding]::new($false))
$failed=$false;try{Read-MpCsv -Path $p -Columns $cols | Out-Null}catch{$failed=$true}
Assert $failed 'wrong header rejected'
Write-Output "PASS: $script:count core assertions"
