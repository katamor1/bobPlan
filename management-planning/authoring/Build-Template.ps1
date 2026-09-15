[CmdletBinding()]
param(
    [string]$RuntimeNode = "$env:USERPROFILE/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/bin/node.exe",
    [string]$RuntimePackages = "$env:USERPROFILE/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules",
    [string]$MarkerScript
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $MarkerScript) {
    $pluginRoot = Join-Path $env:USERPROFILE '.codex/plugins/cache/openai-primary-runtime/spreadsheets'
    $installed = Get-ChildItem -LiteralPath $pluginRoot -Directory | Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
    if ($null -eq $installed) { throw 'Supply -MarkerScript for the installed spreadsheet runtime.' }
    $MarkerScript = Join-Path $installed.FullName 'skills/spreadsheets/container_tools/mark_artifact_operation_started.mjs'
}
$packageRoot = Split-Path $PSScriptRoot -Parent
$repoRoot = Split-Path $packageRoot -Parent
$runDirectory = Join-Path $repoRoot '.superpowers/template-authoring'
$previewDirectory = Join-Path $runDirectory 'previews'
foreach ($requiredPath in @($RuntimeNode, $RuntimePackages, $MarkerScript)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) { throw "Bundled runtime path not found: $requiredPath. Resolve paths with load_workspace_dependencies and supply the parameters." }
}
[void][System.IO.Directory]::CreateDirectory($runDirectory)
$junction = Join-Path $runDirectory 'node_modules'
if (-not (Test-Path -LiteralPath $junction)) { [void](New-Item -ItemType Junction -Path $junction -Target $RuntimePackages) }
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'build-template.mjs') -Destination (Join-Path $runDirectory 'build-template.mjs') -Force
& $RuntimeNode $MarkerScript --operation-kind create --expected-output-count 1 --output-format xlsx
if ($LASTEXITCODE -ne 0) { throw 'Artifact operation marker failed.' }
& $RuntimeNode (Join-Path $runDirectory 'build-template.mjs') (Join-Path $packageRoot 'schema.json') (Join-Path $packageRoot 'templates/management-template.xlsx') $previewDirectory
if ($LASTEXITCODE -ne 0) { throw 'Template authoring failed.' }
