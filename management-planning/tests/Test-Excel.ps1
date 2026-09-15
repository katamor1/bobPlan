$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot '../tools/Planning.Excel.psm1') -Force
$schema=Get-MpSchema
$template=Join-Path $PSScriptRoot '../templates/management-template.xlsx'
$d=Read-MpWorkbook -Path $template
if($d.Count -ne 9){throw 'Template input count'}
foreach($k in $d.Keys){if(@($d[$k]).Count -ne 0){throw "Template table not empty: $k"}}
$r=[ordered]@{};foreach($c in ($schema.tables | Where-Object key -eq People).columns){$r[$c.name]=''}
$r.MemberID='001';$r.Name='=1+1';$r.Phases='Design';$d.People=@([pscustomobject]$r)
$tmp=Join-Path ([IO.Path]::GetTempPath()) ('mp-excel-'+[guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($tmp)
$out=Join-Path $tmp 'plan.xlsx'
$hash=(Get-FileHash -LiteralPath $template).Hash
Write-MpWorkbook -TemplatePath $template -Path $out -Data $d
$back=Read-MpWorkbook -Path $out
if($back.People[0].MemberID -cne '001'){throw 'ID leading zeros lost'}
if($back.People[0].Name -cne '=1+1'){throw 'Text became formula'}
if((Get-FileHash -LiteralPath $template).Hash -ne $hash){throw 'Template changed'}
Write-Output ('PASS: Excel template/roundtrip/text safety; '+$out)
