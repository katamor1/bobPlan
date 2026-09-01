[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$WorkPacket,
    [Parameter(Mandatory = $true)][ValidateSet('Make', 'Rebuild')][string]$Action,
    [Parameter(Mandatory = $true)][ValidateRange(0, 2)][int]$Attempt
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TeamBob-BuildCommon.ps1')

$exitCodes = @{ SUCCEEDED = 0; CODE_FAILED_RETRYABLE = 10; CODE_FAILED_STOP = 11; ENVIRONMENT_FAILED = 20; TIMED_OUT = 21; INTEGRITY_FAILED = 30 }
$result = [ordered]@{
    schemaVersion = '1.0'; status = 'ENVIRONMENT_FAILED'; exitCode = 20; message = ''; taskId = $null; action = $Action; attempt = $Attempt
    workPacket = $null; buildProfileId = $null; sandboxPath = $null; logDirectory = $null; stdoutPath = $null; stderrPath = $null
    outputLogPath = $null; processId = $null; processExitCode = $null; processStartedAt = $null; processFinishedAt = $null
    preBazaarStatus = $null; postBazaarStatus = $null; preSourceInventory = @(); postSourceInventory = @(); preBzrInventory = @(); postBzrInventory = @()
    preAllowedHashes = @(); postAllowedHashes = @(); expectedArtifacts = @(); invokedArguments = @(); resultPath = $null
}
$resultDirectory = $null
$resultPath = $null

function Complete-TeamBobBuild {
    param([string]$Status, [string]$Message)
    $result.status = $Status
    $result.exitCode = [int]$exitCodes[$Status]
    $result.message = $Message
    if ($null -ne $resultPath) {
        $result.resultPath = $resultPath
        try { Write-TeamBobUtf8File $resultPath (($result | ConvertTo-Json -Depth 20) + [Environment]::NewLine) } catch { [Console]::Error.WriteLine("Failed to persist build result: $($_.Exception.Message)") }
    } else {
        [Console]::Error.WriteLine('Build result path could not be established from the Work Packet.')
    }
    [Console]::Out.WriteLine($Status)
    exit ([int]$exitCodes[$Status])
}

try {
    if (-not (Test-Path -LiteralPath $WorkPacket -PathType Leaf)) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' "Work packet does not exist: $WorkPacket") }
    $workPacketFull = Get-TeamBobCanonicalPath $WorkPacket
    $result.workPacket = $workPacketFull
    $resultDirectory = Join-Path (Split-Path -Parent $workPacketFull) 'results'
    if (Test-Path -LiteralPath $resultDirectory -PathType Leaf) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Task results path is an existing file.') }
    if (-not (Test-Path -LiteralPath $resultDirectory -PathType Container)) { [System.IO.Directory]::CreateDirectory($resultDirectory) | Out-Null }
    $resultPath = Join-Path $resultDirectory ('build-result-' + [DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ') + '-' + [guid]::NewGuid().ToString('N') + '.json')

    $packet = Read-TeamBobCanonicalPacket $workPacketFull
    $context = Get-TeamBobPacketContext $packet $workPacketFull
    $result.taskId = $context.TaskId
    $result.buildProfileId = $context.BuildProfileId
    $profileRoot = Split-Path -Parent $PSScriptRoot
    $manifestPath = Join-Path $profileRoot 'profile-manifest.json'
    $workSchemaPath = Join-Path $profileRoot 'config/work-packet.schema.json'
    $buildSchemaPath = Join-Path $profileRoot 'config/vc6-build-targets.schema.json'
    $catalogPath = Join-Path $profileRoot 'config/vc6-build-targets.json'
    foreach ($path in @($manifestPath, $workSchemaPath, $buildSchemaPath, $catalogPath)) { if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw (New-TeamBobFailure 'ENVIRONMENT_FAILED' "Installed profile contract is missing: $path") } }
    $environment = Get-TeamBobLocalEnvironment $manifestPath $workSchemaPath $buildSchemaPath
    $profile = Get-TeamBobBuildProfile $catalogPath $context.BuildProfileId ([string]$environment.pcId)

    if ((Test-TeamBobPathAtOrBelow $environment.sandboxRoot $context.BazaarRoot) -or (Test-TeamBobPathAtOrBelow $context.BazaarRoot $environment.sandboxRoot) -or
        (Test-TeamBobPathAtOrBelow $environment.logRoot $context.BazaarRoot) -or (Test-TeamBobPathAtOrBelow $context.BazaarRoot $environment.logRoot) -or
        (Test-TeamBobPathAtOrBelow $environment.sandboxRoot $environment.logRoot) -or (Test-TeamBobPathAtOrBelow $environment.logRoot $environment.sandboxRoot)) {
        throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Source, sandbox, and log roots must be external, distinct, and mutually non-nested.')
    }

    $project = ConvertTo-TeamBobRelativePath $context.BazaarRoot ([string]$profile.projectFile) 'Build profile projectFile' 'ENVIRONMENT_FAILED'
    if ([System.IO.Path]::GetExtension($project.FullPath).ToLowerInvariant() -notin @('.dsw', '.dsp') -or -not (Test-Path -LiteralPath $project.FullPath -PathType Leaf)) {
        throw (New-TeamBobFailure 'ENVIRONMENT_FAILED' 'Qualified VC6 project file is invalid or missing.')
    }
    $expectedArtifacts = @()
    foreach ($entry in @($profile.expectedArtifacts)) {
        if (-not ($entry -is [string])) { throw (New-TeamBobFailure 'ENVIRONMENT_FAILED' 'Expected artifact entries must be strings.') }
        $artifact = ConvertTo-TeamBobRelativePath $context.BazaarRoot $entry 'Expected artifact' 'ENVIRONMENT_FAILED'
        $expectedArtifacts += $artifact.RelativePath
    }
    $result.expectedArtifacts = @($expectedArtifacts)

    Assert-TeamBobAllowedEncoding $context.AllowedFiles
    $preStatusQuery = Invoke-TeamBobBazaarQuery $environment.bazaarPath $context.BazaarRoot @('status', '--short')
    $preStatus = Get-TeamBobNormalizedProcessText $preStatusQuery.Output
    Assert-TeamBobBazaarStatus $preStatus $context.AllowedFiles
    $result.preBazaarStatus = $preStatus
    $result.preAllowedHashes = @(Get-TeamBobAllowedHashes $context.AllowedFiles)
    $result.preSourceInventory = @(Get-TeamBobInventory $context.BazaarRoot @('.bzr', 'team-bob-work'))
    $result.preBzrInventory = @(Get-TeamBobInventory (Join-Path $context.BazaarRoot '.bzr'))

    $invocationId = 'attempt-' + $Attempt + '-' + $Action.ToLowerInvariant() + '-' + [guid]::NewGuid().ToString('N')
    $taskSandboxRoot = Join-Path $environment.sandboxRoot $context.TaskId
    $taskLogRoot = Join-Path $environment.logRoot $context.TaskId
    if (-not (Test-Path -LiteralPath $taskSandboxRoot -PathType Container)) { [System.IO.Directory]::CreateDirectory($taskSandboxRoot) | Out-Null }
    if (-not (Test-Path -LiteralPath $taskLogRoot -PathType Container)) { [System.IO.Directory]::CreateDirectory($taskLogRoot) | Out-Null }
    $sandboxPath = Join-Path $taskSandboxRoot $invocationId
    $logDirectory = Join-Path $taskLogRoot $invocationId
    if (Test-Path -LiteralPath $logDirectory) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Per-invocation log directory already exists.') }
    [System.IO.Directory]::CreateDirectory($logDirectory) | Out-Null
    $result.sandboxPath = $sandboxPath
    $result.logDirectory = $logDirectory
    Copy-TeamBobSandboxTree $context.BazaarRoot $sandboxPath @($profile.excludePatterns) @($expectedArtifacts)

    $sandboxProject = Join-Path $sandboxPath ($project.RelativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
    if (-not (Test-Path -LiteralPath $sandboxProject -PathType Leaf)) { throw (New-TeamBobFailure 'ENVIRONMENT_FAILED' 'Sandbox copy does not contain the qualified project file.') }
    $outputLogPath = Join-Path $logDirectory 'build.log'
    if (-not [regex]::IsMatch($outputLogPath, [string]$profile.outputLogPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) { throw (New-TeamBobFailure 'ENVIRONMENT_FAILED' 'Fixed /OUT log path does not satisfy the qualified outputLogPattern.') }
    $switch = if ($Action -eq 'Make') { '/MAKE' } else { '/REBUILD' }
    $arguments = @($sandboxProject, $switch, [string]$profile.target, '/OUT', $outputLogPath)
    $result.invokedArguments = @($arguments)
    $result.outputLogPath = $outputLogPath
    $processResult = Invoke-TeamBobProcess $environment.msdevPath $arguments $sandboxPath ([int]$profile.timeoutSeconds)
    $result.processId = $processResult.ProcessId
    $result.processExitCode = $processResult.ExitCode
    $result.processStartedAt = $processResult.StartedAt
    $result.processFinishedAt = $processResult.FinishedAt
    $stdoutPath = Join-Path $logDirectory 'stdout.log'
    $stderrPath = Join-Path $logDirectory 'stderr.log'
    Write-TeamBobUtf8File $stdoutPath $processResult.StandardOutput
    Write-TeamBobUtf8File $stderrPath $processResult.StandardError
    $result.stdoutPath = $stdoutPath
    $result.stderrPath = $stderrPath

    $postStatusQuery = Invoke-TeamBobBazaarQuery $environment.bazaarPath $context.BazaarRoot @('status', '--short')
    $postStatus = Get-TeamBobNormalizedProcessText $postStatusQuery.Output
    Assert-TeamBobBazaarStatus $postStatus $context.AllowedFiles
    $result.postBazaarStatus = $postStatus
    $result.postAllowedHashes = @(Get-TeamBobAllowedHashes $context.AllowedFiles)
    $result.postSourceInventory = @(Get-TeamBobInventory $context.BazaarRoot @('.bzr', 'team-bob-work'))
    $result.postBzrInventory = @(Get-TeamBobInventory (Join-Path $context.BazaarRoot '.bzr'))
    if (($result.preBazaarStatus -cne $result.postBazaarStatus) -or
        (($result.preAllowedHashes -join "`n") -cne ($result.postAllowedHashes -join "`n")) -or
        (($result.preSourceInventory -join "`n") -cne ($result.postSourceInventory -join "`n")) -or
        (($result.preBzrInventory -join "`n") -cne ($result.postBzrInventory -join "`n"))) {
        throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Original working-tree bytes, inventory, .bzr metadata, or Bazaar status changed during the build wrapper invocation.')
    }
    if ($processResult.TimedOut) { Complete-TeamBobBuild 'TIMED_OUT' 'MSDEV exceeded the qualified timeout and only the spawned process was terminated.' }

    $outputLogText = ''
    if (Test-Path -LiteralPath $outputLogPath -PathType Leaf) { $outputLogText = [System.IO.File]::ReadAllText($outputLogPath) }
    $combinedOutput = $processResult.StandardOutput + "`n" + $processResult.StandardError + "`n" + $outputLogText
    if ([regex]::IsMatch($combinedOutput, [string]$profile.environmentErrorPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
        Complete-TeamBobBuild 'ENVIRONMENT_FAILED' 'MSDEV output matched the qualified environment-error pattern.'
    }
    $compileAttributed = Test-TeamBobFailureAttribution $combinedOutput ([string]$profile.compilerErrorPattern) $context.AllowedFiles
    $linkAttributed = Test-TeamBobFailureAttribution $combinedOutput ([string]$profile.linkerErrorPattern) $context.AllowedFiles
    if ($compileAttributed -or $linkAttributed) {
        if ($Attempt -lt 2) { Complete-TeamBobBuild 'CODE_FAILED_RETRYABLE' 'Qualified compiler/linker evidence is attributable to an Allowed File and repair budget remains.' }
        Complete-TeamBobBuild 'CODE_FAILED_STOP' 'Qualified compiler/linker evidence is attributable to an Allowed File but the repair budget is exhausted.'
    }
    $containsCompileOrLink = [regex]::IsMatch($combinedOutput, [string]$profile.compilerErrorPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase) -or [regex]::IsMatch($combinedOutput, [string]$profile.linkerErrorPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($processResult.ExitCode -ne 0 -or $containsCompileOrLink) { Complete-TeamBobBuild 'CODE_FAILED_STOP' 'Build failure was unrelated to, or could not be classified as attributable to, an Allowed File.' }
    if (-not [regex]::IsMatch($combinedOutput, [string]$profile.successPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) { Complete-TeamBobBuild 'ENVIRONMENT_FAILED' 'Build returned success without the qualified success evidence.' }
    foreach ($artifact in $expectedArtifacts) {
        $artifactPath = Join-Path $sandboxPath ($artifact.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
        if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) { Complete-TeamBobBuild 'ENVIRONMENT_FAILED' "Expected build artifact is missing: $artifact" }
    }
    Complete-TeamBobBuild 'SUCCEEDED' 'The requested VC6 action completed with qualified success evidence and expected artifacts.'
} catch {
    $status = 'ENVIRONMENT_FAILED'
    if ($null -ne $_.Exception.Data['TeamBobStatus'] -and $exitCodes.ContainsKey([string]$_.Exception.Data['TeamBobStatus'])) { $status = [string]$_.Exception.Data['TeamBobStatus'] }
    Complete-TeamBobBuild $status $_.Exception.Message
}
