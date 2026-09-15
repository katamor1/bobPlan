Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$script:Culture=[Globalization.CultureInfo]::InvariantCulture
function Read-MpCsv {
 param([string]$Path,[object[]]$Columns)
 Add-Type -AssemblyName Microsoft.VisualBasic
 $enc=New-Object Text.UTF8Encoding($false,$true)
 $reader=New-Object IO.StringReader($enc.GetString([IO.File]::ReadAllBytes($Path)).TrimStart([char]0xfeff))
 $p=New-Object Microsoft.VisualBasic.FileIO.TextFieldParser($reader)
 try{
  $p.TextFieldType='Delimited';$p.SetDelimiters(',');$p.HasFieldsEnclosedInQuotes=$true;$p.TrimWhiteSpace=$false
  if($p.EndOfData){throw "CSV header missing: $Path"}
  $heads=$p.ReadFields();$names=@($Columns | ForEach-Object {if($_ -is [string]){$_}else{$_.name}})
  if($heads.Count -ne $names.Count){throw "CSV column count differs: $Path"}
  for($i=0;$i -lt $names.Count;$i++){if($heads[$i] -cne $names[$i]){throw "CSV column $i must be $($names[$i]): $Path"}}
  while(-not $p.EndOfData){$fields=$p.ReadFields();if($fields.Count -ne $names.Count){throw "CSV row column count differs: $Path"}
   $row=[ordered]@{};for($i=0;$i -lt $names.Count;$i++){$row[$names[$i]]=$fields[$i]};[pscustomobject]$row
  }
 }finally{$p.Dispose();$reader.Dispose()}
}
function Write-MpCsv {
 param([string]$Path,[object[]]$Columns,[AllowEmptyCollection()][object[]]$Rows=@())
 $names=@($Columns | ForEach-Object {if($_ -is [string]){$_}else{$_.name}})
 $lines=New-Object 'Collections.Generic.List[string]'
 $lines.Add((($names | ForEach-Object {'"'+$_.Replace('"','""')+'"'}) -join ','))
 foreach($r in $Rows){$cells=foreach($n in $names){$v=$r.$n;if($null -eq $v){$s=''}elseif($v -is [IFormattable]){$s=$v.ToString($null,$script:Culture)}else{$s=[string]$v};'"'+$s.Replace('"','""')+'"'};$lines.Add(($cells -join ','))}
 [IO.File]::WriteAllText($Path,($lines -join [Environment]::NewLine)+[Environment]::NewLine,(New-Object Text.UTF8Encoding($false)))
}
function Num($v){$n=0.0;if([string]::IsNullOrWhiteSpace([string]$v)){return $null};if([double]::TryParse([string]$v,[Globalization.NumberStyles]::Float,$script:Culture,[ref]$n) -and -not [double]::IsNaN($n) -and -not [double]::IsInfinity($n) -and $n -ge 0){return $n};return $null}
function Day($v){$d=[datetime]::MinValue;if([datetime]::TryParseExact([string]$v,'yyyy-MM-dd',$script:Culture,[Globalization.DateTimeStyles]::None,[ref]$d)){return $d};return $null}
function Ids($v){@(([string]$v -split ';') | ForEach-Object {$_.Trim()} | Where-Object {$_ -ne ''})}
function Finding($f,$severity,$code,$entity,$field,$message){$f.Add([pscustomobject]@{Severity=$severity;Code=$code;Entity=$entity;Field=$field;Message=$message})}
function Index($rows,$field,$f,$table){
 $map=New-Object 'Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
 foreach($r in @($rows)){$id=[string]$r.$field
  if([string]::IsNullOrWhiteSpace($id)){if($null -ne $f){Finding $f Error MISSING_ID $table $field 'Identifier is required.'};continue}
  if($id -match '[\s;|#*?~]'){if($null -ne $f){Finding $f Error INVALID_ID $id $field 'Identifier cannot contain whitespace, list/key separators, or Excel wildcard characters.'}}
  if($map.ContainsKey($id)){if($null -ne $f){Finding $f Error DUPLICATE_ID $id $field 'Duplicate identifier.'}}else{$map.Add($id,$r)}
 };return ,$map
}
function Cycles($tasks,$field,$code,$f){
 $degree=@{};$edges=@{}
 foreach($id in $tasks.Keys){$degree[$id]=0;$edges[$id]=New-Object 'Collections.Generic.List[string]'}
 foreach($id in $tasks.Keys){foreach($to in @(Ids $tasks[$id].$field)){if($tasks.ContainsKey($to)){$degree[$to]++;$edges[$id].Add($to)}}}
 $q=New-Object 'Collections.Generic.Queue[string]'
 foreach($id in $tasks.Keys){if($degree[$id] -eq 0){$q.Enqueue($id)}}
 while($q.Count -gt 0){$id=$q.Dequeue();foreach($to in $edges[$id]){$degree[$to]--;if($degree[$to] -eq 0){$q.Enqueue($to)}}}
 $bad=@($tasks.Keys | Where-Object {$degree[$_] -gt 0} | Sort-Object)
 if($bad.Count -gt 0){Finding $f Error $code ($bad -join ';') $field 'Relationship graph contains a cycle.'}
}
function Test-MpData {
 param([hashtable]$Data)
 $f=New-Object 'Collections.Generic.List[object]';$idx=@{}
 foreach($pair in @(@('Project','Key'),@('Sources','SourceID'),@('Standards','RuleID'),@('Requirements','ReqID'),@('People','MemberID'),@('Tasks','TaskID'),@('Questions','QuestionID'))){$idx[$pair[0]]=Index @($Data[$pair[0]]) $pair[1] $f $pair[0]}
 $tasks=$idx.Tasks;$people=$idx.People;$reqs=$idx.Requirements
 $parents=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
 foreach($t in $tasks.Values){if($t.ParentTaskID -ne ''){[void]$parents.Add($t.ParentTaskID)}}
 foreach($r in $reqs.Values){
  if(-not $idx.Sources.ContainsKey([string]$r.SourceID)){Finding $f Error UNKNOWN_SOURCE $r.ReqID SourceID 'Source not found.'}
  foreach($field in @('SourceAnchor','Interpretation','AcceptanceCriteria')){if([string]::IsNullOrWhiteSpace($r.$field)){Finding $f Warning MISSING_REQUIREMENT_DETAIL $r.ReqID $field 'Requirement evidence or acceptance is incomplete.'}}
  if($r.QAStatus -ne 'Resolved'){Finding $f Warning OPEN_REQUIREMENT_QA $r.ReqID QAStatus 'Requirement confirmation is unresolved.'}
 }
 foreach($r in @($Data.Standards)){if($null -eq (Num $r.UnitHours)){Finding $f Warning INVALID_STANDARD $r.RuleID UnitHours 'Standard hours missing or invalid.'};if($r.Provisional -ne 'No'){Finding $f Info PROVISIONAL_STANDARD $r.RuleID Provisional 'Reference hours are provisional; synthetic hours are not production evidence.'}}
 $schema=Get-Content -Raw -Encoding UTF8 (Join-Path $PSScriptRoot '../schema.json') | ConvertFrom-Json
 foreach($table in $schema.tables | Where-Object role -eq input){foreach($r in @($Data[$table.key])){foreach($c in $table.columns){
  $v=[string]$r.($c.name);$entity=[string]$r.($table.columns[0].name)
  if($v -ne '' -and $c.type -eq 'number' -and $null -eq (Num $v)){Finding $f Error INVALID_NUMBER $entity $c.name 'Hours must be a finite nonnegative number.'}
  if($v -ne '' -and $c.type -eq 'date' -and $null -eq (Day $v)){Finding $f Error INVALID_DATE $entity $c.name 'Date must be a valid yyyy-MM-dd.'}
 }}}
 $projectStart=$null;$projectDue=$null
 foreach($key in @('StartDate','DueDate')){if($idx.Project.ContainsKey($key)){$d=Day $idx.Project[$key].Value;if($null -eq $d){Finding $f Warning INVALID_PROJECT_DATE Project $key 'Project date missing or invalid.'};if($key -eq 'StartDate'){$projectStart=$d}else{$projectDue=$d}}}
 $covered=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
 foreach($t in $tasks.Values){
  $id=$t.TaskID;$parent=$parents.Contains($id)
  if($t.ParentTaskID -ne '' -and -not $tasks.ContainsKey([string]$t.ParentTaskID)){Finding $f Error UNKNOWN_PARENT $id ParentTaskID 'Parent task not found.'}
  foreach($rid in @(Ids $t.ReqIDs)){if(-not $reqs.ContainsKey($rid)){Finding $f Error UNKNOWN_REQUIREMENT $id ReqIDs "Requirement not found: $rid"}elseif(-not $parent){[void]$covered.Add($rid)}}
  if($t.Title -eq ''){Finding $f Warning MISSING_TITLE $id Title 'Task title is required.'}
  if($parent){if($t.EstimatedHours -ne '' -or $t.AssigneeID -ne ''){Finding $f Error PARENT_OWN_WORK $id EstimatedHours 'Parent tasks only aggregate leaves; effort and assignee must be blank.'}}
  else{
   if(@(Ids $t.ReqIDs).Count -eq 0){Finding $f Warning MISSING_REQUIREMENT_LINK $id ReqIDs 'Reference a requirement or a project-level management requirement.'}
   if($t.EstimatedHours -eq ''){Finding $f Warning MISSING_ESTIMATE $id EstimatedHours 'Estimate is unresolved.'}
   if($t.EstimateBasis -eq ''){Finding $f Warning MISSING_ESTIMATE_BASIS $id EstimateBasis 'Estimate basis is required.'}
   if($t.AssigneeID -eq ''){Finding $f Warning MISSING_ASSIGNEE $id AssigneeID 'Assignee is unresolved.'}
   elseif(-not $people.ContainsKey([string]$t.AssigneeID)){Finding $f Error UNKNOWN_ASSIGNEE $id AssigneeID 'Assignee not found.'}
   elseif(-not (@(Ids $people[$t.AssigneeID].Phases) -ccontains $t.Phase)){Finding $f Warning PHASE_MISMATCH $id Phase 'No matching permitted phase for assignee.'}
   foreach($field in @('Phase','Deliverable','AcceptanceCriteria')){if($t.$field -eq ''){Finding $f Warning MISSING_TASK_DETAIL $id $field 'Task definition is incomplete.'}}
   foreach($field in @('StartDate','EndDate')){if($t.$field -eq ''){Finding $f Warning MISSING_TASK_DATE $id $field 'Task date is unresolved.'}}
  }
  $start=Day $t.StartDate;$end=Day $t.EndDate
  if($null -ne $start -and $null -ne $end -and $start -gt $end){Finding $f Error REVERSED_DATES $id StartDate 'Start is after end date.'}
  if(($null -ne $projectStart -and $null -ne $start -and $start -lt $projectStart) -or ($null -ne $projectDue -and $null -ne $end -and $end -gt $projectDue)){Finding $f Warning OUTSIDE_PROJECT_DATES $id StartDate 'Task is outside the project window.'}
  foreach($pre in @(Ids $t.PredecessorIDs)){
   if(-not $tasks.ContainsKey($pre)){Finding $f Error UNKNOWN_PREDECESSOR $id PredecessorIDs "Predecessor not found: $pre";continue}
   if($parent -or $parents.Contains($pre)){Finding $f Error PARENT_DEPENDENCY $id PredecessorIDs 'v1 dependencies connect leaf tasks only.';continue}
   $pe=Day $tasks[$pre].EndDate;if($null -ne $start -and $null -ne $pe -and $start -le $pe){Finding $f Error DEPENDENCY_DATE $id StartDate "Start must be after predecessor end: $pre"}
  }
 }
 foreach($rid in $reqs.Keys){if(-not $covered.Contains($rid)){Finding $f Warning UNCOVERED_REQUIREMENT $rid ReqID 'Requirement has no leaf task.'}}
 Cycles $tasks ParentTaskID PARENT_CYCLE $f;Cycles $tasks PredecessorIDs DEPENDENCY_CYCLE $f
 $cap=@{};$keys=@{};$daily=@{};$sum=@{};$invalid=@{}
 foreach($c in @($Data.Capacity)){$k=$c.MemberID+'|'+$c.Date;if($cap.ContainsKey($k)){Finding $f Error DUPLICATE_CAPACITY $k Date 'Duplicate member/day capacity.'}else{$cap[$k]=$c}
  if(-not $people.ContainsKey([string]$c.MemberID)){Finding $f Error UNKNOWN_CAPACITY_MEMBER $c.MemberID MemberID 'Member not found.'}
  if($c.AvailableHours -eq ''){Finding $f Warning MISSING_CAPACITY_HOURS $k AvailableHours 'Capacity is unknown.'}
 }
 foreach($a in @($Data.Allocations)){
  $k=$a.TaskID+'|'+$a.Date;if($keys.ContainsKey($k)){Finding $f Error DUPLICATE_ALLOCATION $k Date 'Duplicate task/day allocation.'};$keys[$k]=$true
  if(-not $tasks.ContainsKey([string]$a.TaskID)){Finding $f Error UNKNOWN_ALLOCATION_TASK $a.TaskID TaskID 'Task not found.';continue}
  $t=$tasks[$a.TaskID];$h=Num $a.Hours;$d=Day $a.Date
  if($parents.Contains($a.TaskID)){Finding $f Error PARENT_ALLOCATION $a.TaskID Hours 'Allocate leaves only.'}
  if($null -eq $h){$invalid[$a.TaskID]=$true;if($a.Hours -eq ''){Finding $f Warning MISSING_ALLOCATION_HOURS $k Hours 'Allocation hours unresolved.'}}
  else{
   if(-not $sum.ContainsKey($a.TaskID)){$sum[$a.TaskID]=0.0};$sum[$a.TaskID]+=$h
   $mk=$t.AssigneeID+'|'+$a.Date;if(-not $daily.ContainsKey($mk)){$daily[$mk]=0.0};$daily[$mk]+=$h
   if(-not $cap.ContainsKey($mk)){Finding $f Warning MISSING_CAPACITY $mk Date 'No explicit member/day capacity.'}
   elseif((Num $cap[$mk].AvailableHours) -eq 0 -and $h -gt 0){Finding $f Error UNAVAILABLE_DAY $mk Hours 'Work on unavailable day.'}
  }
  $s=Day $t.StartDate;$e=Day $t.EndDate
  if($a.Date -eq ''){Finding $f Warning MISSING_ALLOCATION_DATE $k Date 'Date unresolved.'}
  if($null -ne $d -and (($null -ne $s -and $d -lt $s) -or ($null -ne $e -and $d -gt $e))){Finding $f Error OUTSIDE_TASK_DATES $k Date 'Allocation outside task dates.'}
 }
 foreach($id in $tasks.Keys){if($parents.Contains($id)){continue};$expected=Num $tasks[$id].EstimatedHours;if($null -eq $expected -or $invalid.ContainsKey($id)){continue}
  $actual=0.0;if($sum.ContainsKey($id)){$actual=$sum[$id]}
  if([math]::Abs($expected-$actual) -gt 0.000001){Finding $f Error ALLOCATION_MISMATCH $id Hours "Allocated $actual h differs from estimate $expected h."}
 }
 foreach($k in $daily.Keys){if($cap.ContainsKey($k)){$available=Num $cap[$k].AvailableHours;if($null -ne $available -and $daily[$k] -gt $available+0.000001){Finding $f Error OVER_CAPACITY $k Hours "Allocated $($daily[$k]) h exceeds available $available h."}}}
 foreach($q in @($Data.Questions)){if($q.Status -ne 'Resolved'){Finding $f Warning OPEN_QUESTION $q.QuestionID Status $q.Question};if($q.EntityID -ne '' -and -not $tasks.ContainsKey([string]$q.EntityID) -and -not $reqs.ContainsKey([string]$q.EntityID)){Finding $f Error UNKNOWN_QUESTION_ENTITY $q.QuestionID EntityID 'Question target not found.'}}
 return @($f.ToArray())
}
function Rollup($id,$tasks,$children,$visiting,$memo){
 if($memo.ContainsKey($id)){return $memo[$id]}
 if($visiting.Contains($id)){return [pscustomobject]@{Hours=$null;StartDate='';EndDate=''}}
 [void]$visiting.Add($id)
 if(-not $children.ContainsKey($id)){$t=$tasks[$id];$r=[pscustomobject]@{Hours=(Num $t.EstimatedHours);StartDate=$t.StartDate;EndDate=$t.EndDate}}
 else{
  $sum=0.0;$unknown=$false;$starts=@();$ends=@();$du=$false
  foreach($child in $children[$id]){$v=Rollup $child $tasks $children $visiting $memo;if($null -eq $v.Hours){$unknown=$true}else{$sum+=$v.Hours};if($null -eq (Day $v.StartDate) -or $null -eq (Day $v.EndDate)){$du=$true};$starts+=$v.StartDate;$ends+=$v.EndDate}
  $h=$sum;if($unknown){$h=$null};$s='';$e='';if(-not $du){$s=$starts | Sort-Object | Select-Object -First 1;$e=$ends | Sort-Object | Select-Object -Last 1}
  $r=[pscustomobject]@{Hours=$h;StartDate=$s;EndDate=$e}
 }
 [void]$visiting.Remove($id);$memo[$id]=$r;return $r
}
function Get-MpViews {
 param([hashtable]$Data)
 $tasks=Index @($Data.Tasks) TaskID $null Tasks;$children=@{}
 foreach($t in $tasks.Values){if($t.ParentTaskID -ne '' -and $tasks.ContainsKey([string]$t.ParentTaskID)){if(-not $children.ContainsKey($t.ParentTaskID)){$children[$t.ParentTaskID]=New-Object 'Collections.Generic.List[string]'};$children[$t.ParentTaskID].Add($t.TaskID)}}
 $memo=@{};$visiting=New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
 $estimate=New-Object 'Collections.Generic.List[object]';$wbs=New-Object 'Collections.Generic.List[object]';$redmine=New-Object 'Collections.Generic.List[object]'
 foreach($t in @($Data.Tasks)){
  if(-not $tasks.ContainsKey([string]$t.TaskID)){continue};$r=Rollup $t.TaskID $tasks $children $visiting $memo
  $roll='No';if($children.ContainsKey($t.TaskID)){$roll='Yes'}
  $estimate.Add([pscustomobject]@{TaskID=$t.TaskID;Title=$t.Title;Phase=$t.Phase;Hours=$r.Hours;Basis=$t.EstimateBasis;Rollup=$roll})
  $wbs.Add([pscustomobject]@{TaskID=$t.TaskID;ParentTaskID=$t.ParentTaskID;ReqIDs=$t.ReqIDs;Title=$t.Title;Deliverable=$t.Deliverable;Hours=$r.Hours;AssigneeID=$t.AssigneeID;StartDate=$r.StartDate;EndDate=$r.EndDate;PredecessorIDs=$t.PredecessorIDs})
  $desc=@("Requirements: $($t.ReqIDs)","Deliverable: $($t.Deliverable)","Acceptance: $($t.AcceptanceCriteria)","Estimate basis: $($t.EstimateBasis)","Internal predecessor task IDs: $($t.PredecessorIDs)") -join [Environment]::NewLine
  $h=$r.Hours;if($roll -eq 'Yes'){$h=$null}
  $redmine.Add([pscustomobject]@{TaskID=$t.TaskID;ParentTaskID=$t.ParentTaskID;Subject=$t.Title;Description=$desc;EstimatedHours=$h;AssigneeID=$t.AssigneeID;StartDate=$r.StartDate;DueDate=$r.EndDate;ReqIDs=$t.ReqIDs})
 }
 $cap=@{};foreach($c in @($Data.Capacity)){$cap[$c.MemberID+'|'+$c.Date]=Num $c.AvailableHours}
 $daily=@{};$invalid=@{}
 foreach($a in @($Data.Allocations)){if($tasks.ContainsKey([string]$a.TaskID)){$k=$tasks[$a.TaskID].AssigneeID+'|'+$a.Date;$h=Num $a.Hours;if($null -eq $h){$invalid[$k]=$true}else{if(-not $daily.ContainsKey($k)){$daily[$k]=0.0};$daily[$k]+=$h}}}
 $schedule=New-Object 'Collections.Generic.List[object]'
 foreach($a in @($Data.Allocations)){
  $member='';if($tasks.ContainsKey([string]$a.TaskID)){$member=$tasks[$a.TaskID].AssigneeID}
  $k=$member+'|'+$a.Date;$total=$null;$available=$null
  if($daily.ContainsKey($k) -and -not $invalid.ContainsKey($k)){$total=$daily[$k]};if($cap.ContainsKey($k)){$available=$cap[$k]}
  $schedule.Add([pscustomobject]@{TaskID=$a.TaskID;AssigneeID=$member;Date=$a.Date;Hours=(Num $a.Hours);DailyTotal=$total;AvailableHours=$available})
 }
 return @{EstimateView=@($estimate.ToArray());WbsView=@($wbs.ToArray());ScheduleView=@($schedule.ToArray());RedmineView=@($redmine.ToArray());Checks=@(Test-MpData $Data)}
}
Export-ModuleMember -Function Read-MpCsv,Write-MpCsv,Test-MpData,Get-MpViews
