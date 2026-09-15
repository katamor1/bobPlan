[CmdletBinding()]
param([string]$OutputPath)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'tools/Planning.Excel.psm1') -Force
Import-Module (Join-Path $root 'tools/Planning.Core.psm1') -Force
$schema=Get-MpSchema;$data=@{}
foreach($def in $schema.tables | Where-Object role -eq input){
 $data[$def.key]=@(Read-MpCsv -Path (Join-Path $root ('samples/normal/'+$def.key+'.csv')) -Columns $def.columns)
}
if(-not $OutputPath){$OutputPath=Join-Path $root 'samples/normal/reference-plan.xlsx'}
# The bundled reference stays next to the seed CSVs so source paths remain portable.
Write-MpWorkbook -TemplatePath (Join-Path $root 'templates/management-template.xlsx') -Path $OutputPath -Data $data
Write-Output "Saved $OutputPath"
