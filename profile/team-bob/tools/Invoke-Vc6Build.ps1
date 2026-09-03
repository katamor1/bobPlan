[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$WorkPacket,
    [Parameter(Mandatory = $true)][ValidateSet('Make', 'Rebuild')][string]$Action,
    [Parameter(Mandatory = $true)][ValidateRange(0, 2)][int]$Attempt
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'TeamBob-BuildCommon.ps1')
. (Join-Path $PSScriptRoot 'TeamBob-GovernanceCommon.ps1')
. (Join-Path $PSScriptRoot 'TeamBob-ComplianceCommon.ps1')

$exitCodes = @{ SUCCEEDED = 0; CODE_FAILED_RETRYABLE = 10; CODE_FAILED_STOP = 11; ENVIRONMENT_FAILED = 20; TIMED_OUT = 21; INTEGRITY_FAILED = 30 }
$result = [ordered]@{
    schemaVersion = '1.0'; status = 'ENVIRONMENT_FAILED'; exitCode = 20; message = ''; taskId = $null; action = $Action; attempt = $Attempt
    workPacket = $null; buildProfileId = $null; sandboxPath = $null; logDirectory = $null; stdoutPath = $null; stderrPath = $null
    outputLogPath = $null; processId = $null; processExitCode = $null; processStartedAt = $null; processFinishedAt = $null
    terminationComplete = $null; captureComplete = $null; preBazaarStatus = $null; postBazaarStatus = $null
    preBazaarBranch = $null; postBazaarBranch = $null; preBazaarRevision = $null; postBazaarRevision = $null
    preSourceInventory = @(); postSourceInventory = @(); preBzrInventory = @(); postBzrInventory = @()
    preAllowedHashes = @(); postAllowedHashes = @(); expectedArtifacts = @(); invokedArguments = @(); resultPath = $null
    workPacketSha256=$null;policyVersion=$null;policyBundleSha256=$null;roleLedgerSha256=$null;phaseStatePath=$null;phaseStateSha256=$null;phaseStateSemanticSha256=$null
    prerequisiteImpactResultPath=$null;prerequisiteImpactResultSha256=$null;implementationApprovalPath=$null;implementationApprovalSha256=$null
    makePredecessorPath=$null;makePredecessorSha256=$null;finalIntegrityVerified=$false
}
$resultPath = $null
$resultTrustedParentPhysical = $null
$protectedContext = $null
$protectedBaseline = $null

function Complete-TeamBobBuild {
    param([string]$Status, [string]$Message)
    $result.status = $Status
    $result.exitCode = [int]$exitCodes[$Status]
    $result.message = $Message
    if ($null -eq $resultPath) {
        if (-not [string]::IsNullOrWhiteSpace($Message)) { [Console]::Error.WriteLine($Message) }
        [Console]::Error.WriteLine('Build result path could not be established; durable result evidence is unavailable.')
        [Console]::Out.WriteLine('INTEGRITY_FAILED')
        exit 30
    }
    $result.resultPath = $resultPath
    try {
        Write-TeamBobUtf8File $resultPath (($result | ConvertTo-Json -Depth 20) + [Environment]::NewLine) $resultTrustedParentPhysical
    } catch {
        $result.status = 'INTEGRITY_FAILED'
        $result.exitCode = 30
        [Console]::Error.WriteLine("Failed to persist durable build result: $($_.Exception.Message)")
        [Console]::Out.WriteLine('INTEGRITY_FAILED')
        exit 30
    }
    if ($null -ne $protectedContext -and $null -ne $protectedBaseline) {
        try {
            Assert-TeamBobProtectedSnapshot $protectedBaseline (Get-TeamBobProtectedSnapshot $protectedContext) 'build result publication'
        } catch {
            $Status = 'INTEGRITY_FAILED'
            $result.status = $Status
            $result.exitCode = 30
            $result.finalIntegrityVerified = $false
            $result.message = 'Final protected-state proof failed after result publication: ' + $_.Exception.Message
            try {
                Write-TeamBobUtf8File $resultPath (($result | ConvertTo-Json -Depth 20) + [Environment]::NewLine) $resultTrustedParentPhysical
            } catch {
                [Console]::Error.WriteLine("Failed to persist the final integrity result: $($_.Exception.Message)")
                [Console]::Out.WriteLine('INTEGRITY_FAILED')
                exit 30
            }
        }
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
    $workPacketFull = Get-TeamBobCanonicalPath $WorkPacket 'Work packet' 'INTEGRITY_FAILED'
    if (-not (Test-Path -LiteralPath $workPacketFull -PathType Leaf)) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' "Work packet does not exist: $workPacketFull") }
    [void](Get-TeamBobPhysicalPath $workPacketFull 'Work packet' 'Leaf' 'INTEGRITY_FAILED')
    $result.workPacket = $workPacketFull
    $packet = Read-TeamBobCanonicalPacket $workPacketFull
    $executionGate = Get-TeamBobImplementationExecutionGate $PSScriptRoot $workPacketFull $packet
    $context = $executionGate.Context
    $makePredecessor=$null
    if($Action -eq 'Rebuild'){$makePredecessor=Get-TeamBobValidMakePredecessor $executionGate $Attempt}
    $result.taskId=$executionGate.TaskContext.TaskId;$result.workPacketSha256=$executionGate.WorkPacketSha256;$result.policyVersion=$executionGate.PolicyVersion
    $result.policyBundleSha256=$executionGate.PolicyBundleSha256;$result.roleLedgerSha256=$executionGate.RoleLedgerSha256
    $result.phaseStatePath=$executionGate.PhaseStatePath;$result.phaseStateSha256=$executionGate.PhaseStateSha256;$result.phaseStateSemanticSha256=$executionGate.PhaseStateSemanticSha256
    $result.prerequisiteImpactResultPath=$executionGate.ImpactResultPath;$result.prerequisiteImpactResultSha256=$executionGate.ImpactResultSha256
    $result.implementationApprovalPath=$executionGate.ImplementationApprovalPath;$result.implementationApprovalSha256=$executionGate.ImplementationApprovalSha256
    if($null -ne $makePredecessor){$result.makePredecessorPath=$makePredecessor.Path;$result.makePredecessorSha256=$makePredecessor.Hash}
    $resultsInfo = Get-TeamBobTaskResultsContext $context -Create
    $resultPath = Join-Path $resultsInfo.FullPath ('build-result-' + [DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ') + '-' + [guid]::NewGuid().ToString('N') + '.json')
    $resultTrustedParentPhysical = $context.TaskPhysical
    $result.taskId = $context.TaskId
    $result.buildProfileId = $context.BuildProfileId
    $profileRoot = Split-Path -Parent $PSScriptRoot
    $manifestPath = Join-Path $profileRoot 'profile-manifest.json'
    $workSchemaPath = Join-Path $profileRoot 'config/work-packet.schema.json'
    $buildSchemaPath = Join-Path $profileRoot 'config/vc6-build-targets.schema.json'
    $catalogPath = Join-Path $profileRoot 'config/vc6-build-targets.json'
    foreach ($path in @($manifestPath, $workSchemaPath, $buildSchemaPath, $catalogPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw (New-TeamBobFailure 'ENVIRONMENT_FAILED' "Installed profile contract is missing: $path") }
        [void](Get-TeamBobPhysicalPath $path 'Installed profile contract' 'Leaf' 'ENVIRONMENT_FAILED')
    }
    $environment = Get-TeamBobLocalEnvironment $manifestPath $workSchemaPath $buildSchemaPath -RootFailureStatus 'INTEGRITY_FAILED'
    $profile = Get-TeamBobBuildProfile $catalogPath $context.BuildProfileId ([string]$environment.pcId)

    $sourcePhysical = $context.BazaarPhysical
    $sandboxPhysical = Get-TeamBobPhysicalPath $environment.sandboxRoot 'Sandbox root' 'Container' 'INTEGRITY_FAILED'
    $logPhysical = Get-TeamBobPhysicalPath $environment.logRoot 'Log root' 'Container' 'INTEGRITY_FAILED'
    Assert-TeamBobPhysicalSeparation $sourcePhysical $sandboxPhysical 'Source and sandbox roots' 'INTEGRITY_FAILED'
    Assert-TeamBobPhysicalSeparation $sourcePhysical $logPhysical 'Source and log roots' 'INTEGRITY_FAILED'
    Assert-TeamBobPhysicalSeparation $sandboxPhysical $logPhysical 'Sandbox and log roots' 'INTEGRITY_FAILED'

    $project = ConvertTo-TeamBobRelativePath $context.BazaarRoot ([string]$profile.projectFile) 'Build profile projectFile' 'ENVIRONMENT_FAILED'
    foreach ($forbidden in $context.ForbiddenAreas) {
        if (Test-TeamBobRelativePathAtOrBelow $project.RelativePath $forbidden) { throw (New-TeamBobFailure 'ENVIRONMENT_FAILED' 'Qualified projectFile must not be at or below a Forbidden Area.') }
    }
    if ([System.IO.Path]::GetExtension($project.FullPath).ToLowerInvariant() -notin @('.dsw', '.dsp') -or -not (Test-Path -LiteralPath $project.FullPath -PathType Leaf)) { throw (New-TeamBobFailure 'ENVIRONMENT_FAILED' 'Qualified VC6 project file is invalid or missing.') }
    $projectPhysical = Get-TeamBobPhysicalPath $project.FullPath 'Qualified VC6 project file' 'Leaf' 'ENVIRONMENT_FAILED'
    $projectPhysicalRelative = Get-TeamBobPhysicalRelativePath $projectPhysical $sourcePhysical 'Qualified VC6 project file' 'ENVIRONMENT_FAILED'
    foreach ($forbidden in $context.ForbiddenAreas) {
        if (Test-TeamBobRelativePathAtOrBelow $projectPhysicalRelative $forbidden) { throw (New-TeamBobFailure 'ENVIRONMENT_FAILED' 'Qualified projectFile physically resolves at or below a Forbidden Area.') }
    }
    $project.RelativePath = $projectPhysicalRelative
    $expectedArtifacts = @()
    foreach ($entry in @($profile.expectedArtifacts)) {
        if (-not ($entry -is [string])) { throw (New-TeamBobFailure 'ENVIRONMENT_FAILED' 'Expected artifact entries must be strings.') }
        $artifact = ConvertTo-TeamBobRelativePath $context.BazaarRoot $entry 'Expected artifact' 'ENVIRONMENT_FAILED'
        foreach ($forbidden in $context.ForbiddenAreas) {
            if (Test-TeamBobRelativePathAtOrBelow $artifact.RelativePath $forbidden) { throw (New-TeamBobFailure 'ENVIRONMENT_FAILED' 'Expected artifacts must not be at or below a Forbidden Area.') }
        }
        $artifactParentInfo = Get-TeamBobProspectiveDirectory (Split-Path -Parent $artifact.FullPath) 'Expected artifact parent' 'ENVIRONMENT_FAILED' -RejectVolumeRoot
        $artifactParentRelative = Get-TeamBobPhysicalRelativePath $artifactParentInfo.PhysicalPath $sourcePhysical 'Expected artifact parent' 'ENVIRONMENT_FAILED'
        $artifactPhysicalRelative = ($artifactParentRelative.TrimEnd('/') + '/' + [System.IO.Path]::GetFileName($artifact.FullPath)).TrimStart('/')
        foreach ($forbidden in $context.ForbiddenAreas) {
            if (Test-TeamBobRelativePathAtOrBelow $artifactPhysicalRelative $forbidden) { throw (New-TeamBobFailure 'ENVIRONMENT_FAILED' 'Expected artifacts physically resolve at or below a Forbidden Area.') }
        }
        $expectedArtifacts += $artifactPhysicalRelative
    }
    $result.expectedArtifacts = @($expectedArtifacts)
    Assert-TeamBobAllowedEncoding $context.AllowedFiles

    $baseline = Get-TeamBobProtectedSnapshot $context
    $protectedContext = $context
    $protectedBaseline = $baseline
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
        $taskSandboxInfo = Get-TeamBobTrustedChildDirectory $environment.sandboxRoot $sandboxPhysical $context.TaskId 'Task sandbox directory' 'INTEGRITY_FAILED' -Create
        $taskLogInfo = Get-TeamBobTrustedChildDirectory $environment.logRoot $logPhysical $context.TaskId 'Task log directory' 'INTEGRITY_FAILED' -Create
        $sandboxInfo = Get-TeamBobTrustedChildDirectory $taskSandboxInfo.FullPath $taskSandboxInfo.PhysicalPath $invocationId 'Per-invocation sandbox directory' 'INTEGRITY_FAILED' -Create -RequireMissing
        $logInfo = Get-TeamBobTrustedChildDirectory $taskLogInfo.FullPath $taskLogInfo.PhysicalPath $invocationId 'Per-invocation log directory' 'INTEGRITY_FAILED' -Create -RequireMissing
        $sandboxPath = $sandboxInfo.FullPath
        $logDirectory = $logInfo.FullPath
        $result.sandboxPath = $sandboxPath
        $result.logDirectory = $logDirectory
        [void](Get-TeamBobPhysicalPath $sandboxPath 'New per-invocation sandbox directory' 'Container' 'INTEGRITY_FAILED')
        Copy-TeamBobSandboxTree $context.BazaarRoot $sandboxPath @($profile.excludePatterns) @($expectedArtifacts) @($context.ForbiddenAreas)

        $sandboxProject = Join-Path $sandboxPath ($project.RelativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
        if (-not (Test-Path -LiteralPath $sandboxProject -PathType Leaf)) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Sandbox project file is missing.') }
        $sandboxProjectPhysical = Get-TeamBobPhysicalPath $sandboxProject 'Sandbox project file' 'Leaf' 'INTEGRITY_FAILED'
        Assert-TeamBobPhysicalChild $sandboxProjectPhysical $sandboxInfo.PhysicalPath 'Sandbox project file' 'INTEGRITY_FAILED'
        if ((Get-TeamBobFileHash $sandboxProject) -ne (Get-TeamBobFileHash $project.FullPath)) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' 'Sandbox project file differs from the qualified source project.') }
        foreach ($allowedFile in $context.AllowedFiles) {
            $sandboxAllowed = Join-Path $sandboxPath ($allowedFile.RelativePath.Replace('/', [System.IO.Path]::DirectorySeparatorChar))
            if (-not (Test-Path -LiteralPath $sandboxAllowed -PathType Leaf)) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' "Sandbox Allowed File is missing: $($allowedFile.RelativePath)") }
            $sandboxAllowedPhysical = Get-TeamBobPhysicalPath $sandboxAllowed 'Sandbox Allowed File' 'Leaf' 'INTEGRITY_FAILED'
            Assert-TeamBobPhysicalChild $sandboxAllowedPhysical $sandboxInfo.PhysicalPath 'Sandbox Allowed File' 'INTEGRITY_FAILED'
            if ((Get-TeamBobFileHash $sandboxAllowed) -ne (Get-TeamBobFileHash $allowedFile.FullPath)) { throw (New-TeamBobFailure 'INTEGRITY_FAILED' "Sandbox Allowed File differs from source: $($allowedFile.RelativePath)") }
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
        Write-TeamBobUtf8File $stdoutPath $processResult.StandardOutput $taskLogInfo.PhysicalPath
        Write-TeamBobUtf8File $stderrPath $processResult.StandardError $taskLogInfo.PhysicalPath
        $result.stdoutPath = $stdoutPath
        $result.stderrPath = $stderrPath

        if ($processResult.TimedOut) {
            $pendingStatus = 'TIMED_OUT'
            $pendingMessage = if ($processResult.TerminationComplete) { 'MSDEV exceeded the qualified timeout; its owned process tree was terminated within the bounded grace period.' } else { 'MSDEV exceeded the qualified timeout; process-tree termination did not complete within the bounded grace period.' }
        } elseif (-not $processResult.CaptureComplete) {
            $pendingStatus = 'ENVIRONMENT_FAILED'; $pendingMessage = 'MSDEV exited but redirected output capture did not complete within the bounded grace period.'
        } else {
            $outputLogText = ''
            if (Test-Path -LiteralPath $outputLogPath -PathType Leaf) {
                $outputLogPhysical = Get-TeamBobPhysicalPath $outputLogPath 'VC6 output log' 'Leaf' 'INTEGRITY_FAILED'
                Assert-TeamBobPhysicalChild $outputLogPhysical $logInfo.PhysicalPath 'VC6 output log' 'INTEGRITY_FAILED'
                $outputLogText = Read-TeamBobStrictCp932File $outputLogPath
            }
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
                            $artifactPhysical = Get-TeamBobPhysicalPath $artifactPath 'Expected build artifact' 'Leaf' 'INTEGRITY_FAILED'
                            Assert-TeamBobPhysicalChild $artifactPhysical $sandboxInfo.PhysicalPath 'Expected build artifact' 'INTEGRITY_FAILED'
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
            if($pendingStatus -eq 'SUCCEEDED'){
                $postExecutionGate=Get-TeamBobImplementationExecutionGate $PSScriptRoot $workPacketFull $packet
                Assert-TeamBobExecutionGateUnchanged $executionGate $postExecutionGate
                if($Action -eq 'Rebuild'){
                    $postMakePredecessor=Get-TeamBobValidMakePredecessor $postExecutionGate $Attempt
                    if($postMakePredecessor.Path -cne $result.makePredecessorPath -or $postMakePredecessor.Hash -cne $result.makePredecessorSha256){throw(New-TeamBobComplianceFailure 30 'Make predecessor changed during Rebuild execution.')}
                }
                $result.finalIntegrityVerified=$true
            }
        } catch {
            $postflightFailure = $_.Exception.Message
        }
    }
    if ($null -ne $postflightFailure) { Complete-TeamBobBuild 'INTEGRITY_FAILED' ("Postflight integrity proof failed: $postflightFailure") }
    if($pendingStatus -ne 'SUCCEEDED'){$result.finalIntegrityVerified=$false}
    Complete-TeamBobBuild $pendingStatus $pendingMessage
} catch {
    if($null -eq $resultPath){
        [Console]::Error.WriteLine($_.Exception.Message)
        $earlyCode=30;$earlyToken='INTEGRITY_FAILED'
        if($_.Exception.Data['TeamBobStatus'] -eq 'GATE_FAILED'){$earlyCode=10;$earlyToken='GATE_FAILED'}
        elseif($_.Exception.Data['TeamBobStatus'] -eq 'GATE_UNRESOLVED'){$earlyCode=11;$earlyToken='GATE_UNRESOLVED'}
        elseif($_.Exception.Data['TeamBobStatus'] -in @('PACKET_VERSION_UNSUPPORTED','PACKET_SCHEMA_INVALID','CONTRACT_INVALID')){$earlyCode=20;$earlyToken='CONTRACT_INVALID'}
        [Console]::Out.WriteLine($earlyToken);exit $earlyCode
    }
    Complete-TeamBobBuild (Get-TeamBobExceptionStatus $_.Exception) $_.Exception.Message
}
