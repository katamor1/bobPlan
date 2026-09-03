[CmdletBinding()]
param(
    [string]$GovernanceRoot,
    [switch]$Strict
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TeamBob-GovernanceCommon.ps1')

if ([string]::IsNullOrWhiteSpace($GovernanceRoot)) {
    $profileRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $GovernanceRoot = Join-Path $profileRoot '.bob\governance'
}

$errors = @(Test-TeamBobGovernancePackage -GovernanceRoot $GovernanceRoot)
if ($Strict -and $errors.Count -eq 0) { $errors += @(Test-TeamBobGovernanceStrictReadiness -GovernanceRoot $GovernanceRoot) }
if ($errors.Count -eq 0) {
    Write-Output ('PASS Governance package - PolicyBundleSHA256=' + (Get-TeamBobPolicyBundleHash -GovernanceRoot $GovernanceRoot))
    Write-Output ('PASS Role ledger - RoleLedgerSHA256=' + (Get-TeamBobRoleLedgerHash -GovernanceRoot $GovernanceRoot))
    exit 0
}
foreach ($errorMessage in $errors) { Write-Output "FAIL Governance package - $errorMessage" }
exit 1
