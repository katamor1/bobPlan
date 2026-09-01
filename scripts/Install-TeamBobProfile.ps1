[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$TargetPath,

    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'

function Get-TeamBobSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        try { return ([BitConverter]::ToString($sha256.ComputeHash($stream)).Replace('-', '')) } finally { $stream.Dispose() }
    } finally { $sha256.Dispose() }
}

function Test-TeamBobAbsolutePath {
    param([string]$Path)
    return $Path -match '^(?:[A-Za-z]:[\\/]|\\\\[^\\/]+[\\/][^\\/]+)'
}

try {
    $sourcePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'profile'
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Container)) { throw "Profile source directory does not exist: $sourcePath" }
    if (-not (Test-TeamBobAbsolutePath $TargetPath)) { throw 'TargetPath must be an absolute directory path.' }

    $sourcePath = [System.IO.Path]::GetFullPath($sourcePath)
    $targetFullPath = [System.IO.Path]::GetFullPath($TargetPath)
    $sourcePrefix = $sourcePath.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    if ($targetFullPath.Equals($sourcePath, [System.StringComparison]::OrdinalIgnoreCase) -or
        $targetFullPath.StartsWith($sourcePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'TargetPath must not be the profile source directory or a directory beneath it.'
    }
    if (Test-Path -LiteralPath $targetFullPath -PathType Leaf) { throw "TargetPath is an existing file: $targetFullPath" }

    $directories = @(Get-ChildItem -LiteralPath $sourcePath -Directory -Force -Recurse | Sort-Object FullName)
    $files = @(Get-ChildItem -LiteralPath $sourcePath -File -Force -Recurse | Sort-Object FullName)
    $plans = New-Object System.Collections.Generic.List[object]
    $hasConflict = $false

    $rootAction = if (Test-Path -LiteralPath $targetFullPath -PathType Container) { 'IDENTICAL' } else { 'CREATE' }
    $plans.Add([pscustomobject]@{ Action = $rootAction; Kind = 'directory'; Path = $targetFullPath })

    foreach ($directory in $directories) {
        $relative = $directory.FullName.Substring($sourcePath.Length).TrimStart('\', '/')
        $destination = Join-Path $targetFullPath $relative
        if (Test-Path -LiteralPath $destination -PathType Leaf) {
            $plans.Add([pscustomobject]@{ Action = 'CONFLICT'; Kind = 'directory'; Path = $destination })
            $hasConflict = $true
        } elseif (Test-Path -LiteralPath $destination -PathType Container) {
            $plans.Add([pscustomobject]@{ Action = 'IDENTICAL'; Kind = 'directory'; Path = $destination })
        } else {
            $plans.Add([pscustomobject]@{ Action = 'CREATE'; Kind = 'directory'; Path = $destination })
        }
    }

    foreach ($file in $files) {
        $relative = $file.FullName.Substring($sourcePath.Length).TrimStart('\', '/')
        $destination = Join-Path $targetFullPath $relative
        if (Test-Path -LiteralPath $destination -PathType Container) {
            $plans.Add([pscustomobject]@{ Action = 'CONFLICT'; Kind = 'file'; Path = $destination; Source = $file.FullName })
            $hasConflict = $true
        } elseif (Test-Path -LiteralPath $destination -PathType Leaf) {
            $sourceHash = Get-TeamBobSha256 $file.FullName
            $destinationHash = Get-TeamBobSha256 $destination
            if ($sourceHash -eq $destinationHash) {
                $plans.Add([pscustomobject]@{ Action = 'IDENTICAL'; Kind = 'file'; Path = $destination; Source = $file.FullName })
            } else {
                $plans.Add([pscustomobject]@{ Action = 'CONFLICT'; Kind = 'file'; Path = $destination; Source = $file.FullName })
                $hasConflict = $true
            }
        } else {
            $plans.Add([pscustomobject]@{ Action = 'CREATE'; Kind = 'file'; Path = $destination; Source = $file.FullName })
        }
    }

    foreach ($plan in $plans) { Write-Output ("{0} {1} {2}" -f $plan.Action, $plan.Kind, $plan.Path) }
    if ($hasConflict) { throw 'Installation preflight found one or more conflicts; no files were written.' }
    if ($WhatIf) { exit 0 }

    foreach ($plan in @($plans | Where-Object { $_.Action -eq 'CREATE' -and $_.Kind -eq 'directory' })) {
        New-Item -ItemType Directory -Path $plan.Path | Out-Null
    }
    foreach ($plan in @($plans | Where-Object { $_.Action -eq 'CREATE' -and $_.Kind -eq 'file' })) {
        $parent = Split-Path -Parent $plan.Path
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        Copy-Item -LiteralPath $plan.Source -Destination $plan.Path
    }
    exit 0
} catch {
    Write-Error $_.Exception.Message
    exit 1
}
