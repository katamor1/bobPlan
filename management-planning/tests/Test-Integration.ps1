$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$cli=Join-Path $root 'tools/Invoke-ManagementPlanning.ps1'
$work=Join-Path (Split-Path $root -Parent) ('.superpowers/integration-'+[guid]::NewGuid().ToString('N'))
$project=Join-Path $work 'project'
function Run($arguments){
 $text=& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cli @arguments
 if($LASTEXITCODE -ne 0){throw "CLI failed ($LASTEXITCODE): $arguments"}
 return ($text | ConvertFrom-Json)
}
$n=Run @('-Action','New','-ProjectDirectory',$project,'-SeedDirectory',(Join-Path $root 'samples/normal'))
$baseline=$n.Workbook;$hash=(Get-FileHash -LiteralPath $baseline).Hash
$p=Run @('-Action','Prepare','-ProjectDirectory',$project,'-OutputDirectory',(Join-Path $work 'pack'))
if(-not (Test-Path -LiteralPath $p.Manifest)){throw 'No manifest'}
$evidence=Get-Content -LiteralPath (Join-Path $p.OutputDirectory 'sources.md') -Raw -Encoding UTF8
if($evidence -notmatch 'paragraph:3' -or $evidence -notmatch 'QA!B2'){throw 'Source anchors missing'}
$c=Run @('-Action','Check','-ProjectDirectory',$project)
if($c.Errors -ne 0 -or $c.Warnings -ne 0){throw 'Fixture checks failed'}
$i=Run @('-Action','Import','-ProjectDirectory',$project,'-DraftDirectory',(Join-Path $root 'samples/draft'),'-ManifestPath',$p.Manifest)
if($i.Workbook -eq $baseline){throw 'Import overwrote baseline'}
if((Get-FileHash -LiteralPath $baseline).Hash -ne $hash){throw 'Baseline bytes changed'}
$e=Run @('-Action','Export','-ProjectDirectory',$project,'-OutputDirectory',(Join-Path $work 'export'))
if(-not (Test-Path -LiteralPath (Join-Path $e.OutputDirectory 'plan.xlsx'))){throw 'No exported workbook'}
Import-Module (Join-Path $root 'tools/Planning.Core.psm1') -Force
$s=Get-Content -Raw -Encoding UTF8 (Join-Path $root 'schema.json') | ConvertFrom-Json
$r=@(Read-MpCsv -Path (Join-Path $e.OutputDirectory 'redmine.csv') -Columns ($s.tables | Where-Object key -eq RedmineView).columns)
if($r.Count -ne 9){throw 'Ticket row count'}
if(($r | Measure-Object EstimatedHours -Sum).Sum -ne 26){throw 'Ticket total differs'}
if(($r | Where-Object TaskID -eq T-002).AssigneeID -cne '001'){throw 'Assignee ID changed'}
Write-Output ('PASS: 5 actions, source anchors, versioning, 26 hours, 9 tickets. Evidence: '+$work)
