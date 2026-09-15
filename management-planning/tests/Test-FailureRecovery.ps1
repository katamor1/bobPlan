$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$cli=Join-Path $root 'tools/Invoke-ManagementPlanning.ps1'
$work=Join-Path (Split-Path $root -Parent) ('.superpowers/failure-recovery-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($work)
$project=Join-Path $work 'project';$script:count=0
function Assert($ok,$message){$script:count++;if(-not $ok){throw $message}}
function Run($arguments,$expected=0){
 $log=Join-Path $work ('stderr-'+[guid]::NewGuid().ToString('N')+'.log')
 $oldPreference=$ErrorActionPreference;$ErrorActionPreference='Continue'
 try{$output=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cli @arguments 2> $log;$code=$LASTEXITCODE}finally{$ErrorActionPreference=$oldPreference}
 Assert ($code -eq $expected) "Exit code $code, expected $expected. See $log"
 if($expected -eq 0){return ($output | ConvertFrom-Json)}
}
$n=Run @('-Action','New','-ProjectDirectory',$project,'-SeedDirectory',(Join-Path $root 'samples/normal'))
$state=Join-Path $project 'state.json';$baseline=$n.Workbook
$stateHash=(Get-FileHash $state).Hash;$bookHash=(Get-FileHash $baseline).Hash
$bad=Join-Path $work 'bad';[void][IO.Directory]::CreateDirectory($bad)
[IO.File]::WriteAllText((Join-Path $bad 'Tasks.csv'),'wrong,header')
Run @('-Action','Import','-ProjectDirectory',$project,'-DraftDirectory',$bad) 1
Assert ((Get-FileHash $state).Hash -eq $stateHash) 'Malformed CSV changed current state'
Assert ((Get-FileHash $baseline).Hash -eq $bookHash) 'Malformed CSV changed baseline'
Assert (-not (Test-Path (Join-Path $project 'plan-0002.xlsx'))) 'Failed import published a workbook'

# Force the final state publication to fail while allowing its read.
$lock=[IO.File]::Open($state,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
try{Run @('-Action','Import','-ProjectDirectory',$project,'-DraftDirectory',(Join-Path $root 'samples/draft')) 1}finally{$lock.Dispose()}
Assert ((Get-FileHash $state).Hash -eq $stateHash) 'State changed on failed commit'
Assert (-not (Test-Path (Join-Path $project 'plan-0002.xlsx'))) 'State failure published a completed version'
Assert (-not (Test-Path (Join-Path $project 'import-0002'))) 'State failure published completed import artifacts'

$pack=Run @('-Action','Prepare','-ProjectDirectory',$project,'-OutputDirectory',(Join-Path $work 'pack'))
Import-Module (Join-Path $root 'tools/Planning.Excel.psm1') -Force
Import-Module (Join-Path $root 'tools/Planning.Core.psm1') -Force
$data=Read-MpWorkbook $baseline
$data.Tasks[1].Title="Human revision, `"quoted`"`nsecond line"
$human=Join-Path $work 'human.xlsx'
Write-MpWorkbook -TemplatePath $baseline -Path $human -Data $data
[IO.File]::Copy($human,$baseline,$true)
$humanHash=(Get-FileHash $baseline).Hash
Run @('-Action','Import','-ProjectDirectory',$project,'-DraftDirectory',(Join-Path $root 'samples/draft'),'-ManifestPath',$pack.Manifest) 1
Assert ((Get-FileHash $baseline).Hash -eq $humanHash) 'Stale manifest changed human edits'
Assert ((Get-FileHash $state).Hash -eq $stateHash) 'Stale manifest advanced state'
$pack2=Run @('-Action','Prepare','-ProjectDirectory',$project,'-OutputDirectory',(Join-Path $work 'pack2'))
$draft=Join-Path $work 'draft';[void][IO.Directory]::CreateDirectory($draft)
Copy-Item (Join-Path $pack2.OutputDirectory 'Tasks.csv') (Join-Path $draft 'Tasks.csv')
$i=Run @('-Action','Import','-ProjectDirectory',$project,'-DraftDirectory',$draft,'-ManifestPath',$pack2.Manifest)
$back=Read-MpWorkbook $i.Workbook
Assert ($back.Tasks[1].Title -ceq $data.Tasks[1].Title) 'Human multiline edits lost after Excel save and reimport'
Assert ((Get-FileHash $baseline).Hash -eq $humanHash) 'Successful reimport changed original version'
$diff=@(Read-MpCsv -Path $i.Diff -Columns @('Table','Key','Change','Field','Before','After'))
Assert ($diff.Count -eq 0) 'Unchanged roundtrip unexpectedly reported differences'
Write-Output "PASS: $script:count failure/recovery assertions. Evidence: $work"
