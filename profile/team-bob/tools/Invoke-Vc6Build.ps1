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
    terminationComplete = $null; captureComplete = $null; preBazaarStatus = $null; postBazaarStatus = $null
    preBazaarBranch = $null; postBazaarBranch = $null; preBazaarRevision = $null; postBazaarRevision = $null
    preSourceInventory = @(); postSourceInventory = @(); preBzrInventory = @(); postBzrInventory = @()
    preAllowedHashes = @(); postAllowedHashes = @(); expectedArtifacts = @(); invokedArguments = @(); resultPath = $null
}
$resultPath = $null

function Complete-TeamBobBuild {
    param([string]$Status, [string]$Message)
    $result.status = $Status
    $result.exitCode = [int]$exitCodes[$Status]
    $result.message = $Message
    if ($null -eq $resultPath) {
        [Console]::Error.WriteLine('Build result path could not be established; durable result evidence is unavailable.')
        [Console]::Out.WriteLine('INTEGRITY_FAILED')
        exit 30
    }
    $result.resultPath = $resultPath
    try {
        Write-TeamBobUtf8File $resultPath (($result | ConvertTo-Json -Depth 20) + [Environment]::NewLine)
    } catch {
        $result.status = 'INTEGRITY_FAILED'
        $result.exitCode = 30
        [Console]::Error.WriteLine("Failed to persist durable build result: $($_.Exception.Message)")
        [Console]::Out.WriteLine('INTEGRITY_FAILED')
        exit 30
    }
    [Console]::Out.WriteLine($Status)
    exit ([int]$exitCodes[$Status])
}

function Get-TeamBobExceptionStatus {
    param([System.Exception]$Exception)
    if ($null -ne $Exception.Data['TeamBobStatus'] -and $exitCodes.ContainsKey([string]$Exception.Data['TeamBobStatus'])) { return [string]$Exception.Data['TeamBobStatus'] }
    return 'ENVIRONMENT_FAILED'
}

try {
    if (-not (Test-Path -LiteralPath $WorkPacket -PathType Leaf)) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' "Work packet does not exist: $WorkPacket") }
    $workPacketFull = Get-TeamBobCanonicalPath $WorkPacket
    $result.workPacket = $workPacketFull
    $resultDirectory = Join-Path (Split-Path -Parent $workPacketFull) 'results'
    if (Test-Path -LiteralPath $resultDirectory -PathType Leaf) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Task results path is an existing file.') }
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

    $sourcePhysical = Get-TeamBobPhysicalPath $context.BazaarRoot 'Bazaar source root'
    $sandboxPhysical = Get-TeamBobPhysicalPath $environment.sandboxRoot 'Sandbox root'
    $logPhysical = Get-TeamBobPhysicalPath $environment.logRoot 'Log root'
    if ((Test-TeamBobResolvedPathAtOrBelow $sandboxPhysical $sourcePhysical) -or (Test-TeamBobResolvedPathAtOrBelow $sourcePhysical $sandboxPhysical) -or
        (Test-TeamBobResolvedPathAtOrBelow $logPhysical $sourcePhysical) -or (Test-TeamBobResolvedPathAtOrBelow $sourcePhysical $logPhysical) -or
        (Test-TeamBobResolvedPathAtOrBelow $sandboxPhysical $logPhysical) -or (Test-TeamBobResolvedPathAtOrBelow $logPhysical $sandboxPhysical)) {
        throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Source, sandbox, and log roots physically overlap or alias each other.')
    }
    if (-not (Test-Path -LiteralPath $resultDirectory -PathType Container)) { [System.IO.Directory]::CreateDirectory($resultDirectory) | Out-Null }

    $project = ConvertTo-TeamBobRelativePath $context.BazaarRoot ([string]$profile.projectFile) 'Build profile projectFile' 'ENVIRONMENT_FAILED'
    if ([System.IO.Path]::GetExtension($project.FullPath).ToLowerInvariant() -notin @('.dsw', '.dsp') -or -not (Test-Path -LiteralPath $project.FullPath -PathType Leaf)) { throw (New-TeamBobFailure 'ENVIRONMENT_FAILED' 'Qualified VC6 project file is invalid or missing.') }
    $expectedArtifacts = @()
    foreach ($entry in @($profile.expectedArtifacts)) {
        if (-not ($entry -is [string])) { throw (New-TeamBobFailure 'ENVIRONMENT_FAILED' 'Expected artifact entries must be strings.') }
        $artifact = ConvertTo-TeamBobRelativePath $context.BazaarRoot $entry 'Expected artifact' 'ENVIRONMENT_FAILED'
        $expectedArtifacts += $artifact.RelativePath
    }
    $result.expectedArtifacts = @($expectedArtifacts)
    Assert-TeamBobAllowedEncoding $context.AllowedFiles

    $baseline = Get-TeamBobProtectedSnapshot $context
    $result.preAllowedHashes = @($baseline.AllowedHashes)
    $result.preSourceInventory = @($baseline.SourceInventory)
    $result.preBzrInventory = @($baseline.BzrInventory)
    $pendingStatus = 'ENVIRONMENT_FAILED'
    $pendingMessage = 'Build did not reach classification.'
    $preBazaarState = $null
    $preflightComplete = $false
    $postflightFailure = $null

    try {
        $preBazaarState = Get-TeamBobBuildBazaarState $environment $context
        $result.preBazaarStatus = $preBazaarState.Status
        $result.preBazaarBranch = $preBazaarState.Branch
        $result.preBazaarRevision = $preBazaarState.Revision
        Assert-TeamBobProtectedSnapshot $baseline (Get-TeamBobProtectedSnapshot $context) 'pre-build Bazaar queries'
        $preflightComplete = $true

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
        if (-not (Test-Path -LiteralPath $sandboxProject -PathType Leaf) -or (Get-TeamBobFileHash $sandboxProject) -ne (Get-TeamBobFileHash $project.FullPath)) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Sandbox project file is missing or differs from the qualified source project.') }
        foreach ($allowedFile in $context.AllowedFiles) {
            $sandboxAllowed = Join-Path $sandboxPath ($allowedFile.RelativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
            if (-not (Test-Path -LiteralPath $sandboxAllowed -PathType Leaf) -or (Get-TeamBobFileHash $sandboxAllowed) -ne (Get-TeamBobFileHash $allowedFile.FullPath)) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' "Sandbox Allowed File is missing or differs from source: $($allowedFile.RelativePath)") }
        }

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
        $result.terminationComplete = $processResult.TerminationComplete
        $result.captureComplete = $processResult.CaptureComplete
        $stdoutPath = Join-Path $logDirectory 'stdout.log'
        $stderrPath = Join-Path $logDirectory 'stderr.log'
        Write-TeamBobUtf8File $stdoutPath $processResult.StandardOutput
        Write-TeamBobUtf8File $stderrPath $processResult.StandardError
        $result.stdoutPath = $stdoutPath
        $result.stderrPath = $stderrPath

        if ($processResult.TimedOut) {
            $pendingStatus = 'TIMED_OUT'
            $pendingMessage = if ($processResult.TerminationComplete) { 'MSDEV exceeded the qualified timeout; its owned process tree was terminated within the bounded grace period.' } else { 'MSDEV exceeded the qualified timeout; process-tree termination did not complete within the bounded grace period.' }
        } elseif (-not $processResult.CaptureComplete) {
            $pendingStatus = 'ENVIRONMENT_FAILED'; $pendingMessage = 'MSDEV exited but redirected output capture did not complete within the bounded grace period.'
        } else {
            $outputLogText = ''
            if (Test-Path -LiteralPath $outputLogPath -PathType Leaf) { $outputLogText = Read-TeamBobStrictCp932File $outputLogPath }
            $combinedOutput = $processResult.StandardOutput + "`n" + $processResult.StandardError + "`n" + $outputLogText
            if ([regex]::IsMatch($combinedOutput, [string]$profile.environmentErrorPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
                $pendingStatus = 'ENVIRONMENT_FAILED'; $pendingMessage = 'MSDEV output matched the qualified environment-error pattern.'
            } else {
                $compileAttributed = Test-TeamBobFailureAttribution $combinedOutput ([string]$profile.compilerErrorPattern) $context.AllowedFiles $baseline.SourceInventory
                $linkAttributed = Test-TeamBobFailureAttribution $combinedOutput ([string]$profile.linkerErrorPattern) $context.AllowedFiles $baseline.SourceInventory
                if ($compileAttributed -or $linkAttributed) {
                    if ($Attempt -lt 2) { $pendingStatus = 'CODE_FAILED_RETRYABLE'; $pendingMessage = 'Qualified compiler/linker evidence is unambiguously attributable to an Allowed File and repair budget remains.' }
                    else { $pendingStatus = 'CODE_FAILED_STOP'; $pendingMessage = 'Qualified compiler/linker evidence is attributable to an Allowed File but the repair budget is exhausted.' }
                } else {
                    $containsCompileOrLink = [regex]::IsMatch($combinedOutput, [string]$profile.compilerErrorPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase) -or [regex]::IsMatch($combinedOutput, [string]$profile.linkerErrorPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
                    if ($processResult.ExitCode -ne 0 -or $containsCompileOrLink) { $pendingStatus = 'CODE_FAILED_STOP'; $pendingMessage = 'Build failure was unrelated to, ambiguous, or not attributable to an Allowed File.' }
                    elseif (-not [regex]::IsMatch($combinedOutput, [string]$profile.successPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) { $pendingStatus = 'ENVIRONMENT_FAILED'; $pendingMessage = 'Build returned success without the qualified success evidence.' }
                    else {
                        $missingArtifact = $null
                        foreach ($artifact in $expectedArtifacts) {
                            $artifactPath = Join-Path $sandboxPath ($artifact.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
                            if (-not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) { $missingArtifact = $artifact; break }
                        }
                        if ($null -ne $missingArtifact) { $pendingStatus = 'ENVIRONMENT_FAILED'; $pendingMessage = "Expected build artifact is missing: $missingArtifact" }
                        else { $pendingStatus = 'SUCCEEDED'; $pendingMessage = 'The requested VC6 action completed with qualified success evidence and expected artifacts.' }
                    }
                }
            }
        }
    } catch {
        $pendingStatus = Get-TeamBobExceptionStatus $_.Exception
        $pendingMessage = $_.Exception.Message
    } finally {
        try {
            $postSnapshot = Get-TeamBobProtectedSnapshot $context
            Assert-TeamBobProtectedSnapshot $baseline $postSnapshot 'build execution before postflight queries'
            if ($preflightComplete) {
                $postBazaarState = Get-TeamBobBuildBazaarState $environment $context
                $result.postBazaarStatus = $postBazaarState.Status
                $result.postBazaarBranch = $postBazaarState.Branch
                $result.postBazaarRevision = $postBazaarState.Revision
                if ($preBazaarState.Status -cne $postBazaarState.Status -or $preBazaarState.Branch -cne $postBazaarState.Branch -or $preBazaarState.Revision -cne $postBazaarState.Revision) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Bazaar status, branch, or full revision changed between preflight and postflight.') }
                $postSnapshot = Get-TeamBobProtectedSnapshot $context
                Assert-TeamBobProtectedSnapshot $baseline $postSnapshot 'post-build Bazaar queries'
            }
            $result.postAllowedHashes = @($postSnapshot.AllowedHashes)
            $result.postSourceInventory = @($postSnapshot.SourceInventory)
            $result.postBzrInventory = @($postSnapshot.BzrInventory)
        } catch {
            $postflightFailure = $_.Exception.Message
        }
    }
    if ($null -ne $postflightFailure) { Complete-TeamBobBuild 'INTEGRITY_FAILED' ("Postflight integrity proof failed: $postflightFailure") }
    Complete-TeamBobBuild $pendingStatus $pendingMessage
} catch {
    Complete-TeamBobBuild (Get-TeamBobExceptionStatus $_.Exception) $_.Exception.Message
}
