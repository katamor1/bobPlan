[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$TaskId,
    [Parameter(Mandatory=$true)][string]$BazaarRoot,
    [Parameter(Mandatory=$true)][string]$Difficulty,
    [Parameter(Mandatory=$true)][ValidateSet('Green','Amber','Red')][string]$Classification,
    [Parameter(Mandatory=$true)][string]$Customer,
    [Parameter(Mandatory=$true)][string[]]$ReqIds,
    [Parameter(Mandatory=$true)][string]$WordBaseline,
    [Parameter(Mandatory=$true)][string]$QaBaseline,
    [Parameter(Mandatory=$true)][string]$SpecBaseline,
    [Parameter(Mandatory=$true)][string[]]$AllowedFiles,
    [Parameter(Mandatory=$true)][string]$BuildProfileId,
    [Parameter(Mandatory=$true)][string]$SpecificationAssignmentId,
    [Parameter(Mandatory=$true)][string]$ImplementationAssignmentId,
    [Parameter(Mandatory=$true)][string]$IndependentReviewerAssignmentId,
    [string[]]$ForbiddenAreas=@('actual-machine','control-network','mainline','secrets'),
    [string]$RTImpact='No assessed RT impact.',[string]$SafetyImpact='No assessed safety impact.',[string]$BoardImpact='No assessed board impact.',[string]$DriverImpact='No assessed driver impact.',[string]$ABIImpact='No assessed ABI impact.',[string]$BuildImpact='No assessed build impact.',[string]$CustomerBranchImpact='No assessed customer-branch impact.',
    [ValidateSet('YES','NO')][string]$RTImpactClear='NO',[ValidateSet('YES','NO')][string]$SafetyImpactClear='NO',[ValidateSet('YES','NO')][string]$BoardImpactClear='NO',[ValidateSet('YES','NO')][string]$DriverImpactClear='NO',[ValidateSet('YES','NO')][string]$ABIImpactClear='NO',[ValidateSet('YES','NO')][string]$BuildImpactClear='NO',[ValidateSet('YES','NO')][string]$CustomerBranchImpactClear='NO',
    [string[]]$OpenQa=@(),[int]$MaxRepairCycles=2
)

$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'TeamBob-BuildCommon.ps1')
. (Join-Path $PSScriptRoot 'TeamBob-GovernanceCommon.ps1')
. (Join-Path $PSScriptRoot 'TeamBob-ComplianceCommon.ps1')
$stageRoot=$null

function Invoke-TeamBobStartBazaarRead {
    param([string]$Executable,[string]$WorkingDirectory,[string[]]$Arguments)
    Push-Location -LiteralPath $WorkingDirectory
    try { $lines=@(& $Executable @Arguments 2>&1);$exitCode=$LASTEXITCODE } finally { Pop-Location }
    if($exitCode -ne 0){throw "Bazaar command failed with exit code ${exitCode}: $($Arguments -join ' ')"}
    return (($lines|ForEach-Object{$_.ToString()})-join [Environment]::NewLine).Trim()
}

try {
    if($TaskId -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$'){throw 'TaskId contains unsupported characters or length.'}
    foreach($value in @($Difficulty,$Customer,$WordBaseline,$QaBaseline,$SpecBaseline,$BuildProfileId,$SpecificationAssignmentId,$ImplementationAssignmentId,$IndependentReviewerAssignmentId)){if([string]::IsNullOrWhiteSpace($value)){throw 'Required task metadata must not be empty.'}}
    if(@($ReqIds).Count -eq 0 -or @($ReqIds|Where-Object{[string]::IsNullOrWhiteSpace($_)}).Count -gt 0){throw 'ReqIds must contain non-empty values.'}
    foreach($impact in @($RTImpact,$SafetyImpact,$BoardImpact,$DriverImpact,$ABIImpact,$BuildImpact,$CustomerBranchImpact)){if([string]::IsNullOrWhiteSpace($impact)){throw 'Impact evidence fields must not be empty.'}}
    if(@($OpenQa|Where-Object{[string]::IsNullOrWhiteSpace($_)}).Count -gt 0){throw 'OpenQa entries must be non-empty strings.'}
    if($MaxRepairCycles -ne 2){throw 'MaxRepairCycles is fixed to 2.'}

    # Governance and role selection are validated before task directories or Bazaar/native commands.
    $teamBobRoot=Split-Path -Parent $PSScriptRoot
    $profileRoot=Split-Path -Parent $teamBobRoot
    $governanceRoot=Join-Path $profileRoot '.bob\governance'
    $governanceErrors=@(Test-TeamBobGovernancePackage -GovernanceRoot $governanceRoot)
    if($governanceErrors.Count -gt 0){throw ('Governance package is invalid: '+($governanceErrors -join '; '))}
    $policy=Get-TeamBobGovernanceJson (Join-Path $governanceRoot 'policy-manifest.json')
    $roles=Get-TeamBobGovernanceJson (Join-Path $governanceRoot 'roles.json')
    $policyHash=Get-TeamBobPolicyBundleHash $governanceRoot
    $roleHash=Get-TeamBobRoleLedgerHash $governanceRoot
    $rolePacket=[pscustomobject]@{'Specification Assignment ID'=$SpecificationAssignmentId;'Implementation Assignment ID'=$ImplementationAssignmentId;'Independent Reviewer Assignment ID'=$IndependentReviewerAssignmentId}
    [void](Get-TeamBobSelectedAssignments $rolePacket $roles $TaskId -RequireActive)

    if(-not(Test-TeamBobAbsolutePath $BazaarRoot)-or-not(Test-Path -LiteralPath $BazaarRoot -PathType Container)){throw 'BazaarRoot must be an absolute existing directory.'}
    $bazaarRootFull=Get-TeamBobCanonicalPath $BazaarRoot 'BazaarRoot' 'INTEGRITY_FAILED';Assert-TeamBobNotVolumeRoot $bazaarRootFull 'BazaarRoot' 'INTEGRITY_FAILED'
    $bazaarRootPhysical=Get-TeamBobPhysicalPath $bazaarRootFull 'BazaarRoot' 'Container' 'INTEGRITY_FAILED'
    if(-not(Test-Path -LiteralPath (Join-Path $bazaarRootFull '.bzr') -PathType Container)){throw 'BazaarRoot must itself contain a .bzr directory.'}
    $bzrPhysical=Get-TeamBobPhysicalPath (Join-Path $bazaarRootFull '.bzr') 'Bazaar metadata root' 'Container' 'INTEGRITY_FAILED';Assert-TeamBobPhysicalChild $bzrPhysical $bazaarRootPhysical 'Bazaar metadata root' 'INTEGRITY_FAILED'
    $normalizedForbidden=@(ConvertTo-TeamBobForbiddenAreas @($ForbiddenAreas) 'INTEGRITY_FAILED' $bazaarRootFull $bazaarRootPhysical)
    $taskDirectory=Join-Path (Join-Path $bazaarRootFull 'team-bob-work') $TaskId
    if(Test-Path -LiteralPath $taskDirectory){throw "Task directory already exists: $taskDirectory"}

    $supportedExtensions=@('.c','.cc','.cpp','.cxx','.h','.hh','.hpp','.hxx','.inl');$normalizedAllowed=@();$seenAllowed=@{}
    foreach($allowed in @($AllowedFiles)){
        if([string]::IsNullOrWhiteSpace($allowed)){throw 'AllowedFiles must contain non-empty values.'}
        $resolved=ConvertTo-TeamBobRelativePath $bazaarRootFull $allowed 'Allowed File' 'INTEGRITY_FAILED'
        if($supportedExtensions -notcontains [System.IO.Path]::GetExtension($resolved.FullPath).ToLowerInvariant()){throw "Allowed file extension is unsupported: $allowed"}
        if(-not(Test-Path -LiteralPath $resolved.FullPath -PathType Leaf)){throw "Allowed file does not exist as a file: $allowed"}
        $allowedPhysical=Get-TeamBobPhysicalPath $resolved.FullPath "Allowed File '$allowed'" 'Leaf' 'INTEGRITY_FAILED'
        $relative=Get-TeamBobPhysicalRelativePath $allowedPhysical $bazaarRootPhysical "Allowed File '$allowed'" 'INTEGRITY_FAILED'
        foreach($forbidden in $normalizedForbidden){if((Test-TeamBobRelativePathAtOrBelow $resolved.RelativePath $forbidden)-or(Test-TeamBobRelativePathAtOrBelow $relative $forbidden)){throw "Allowed file is below Forbidden Areas '$forbidden': $allowed"}}
        $key=$relative.ToLowerInvariant();if($seenAllowed.ContainsKey($key)){throw "Allowed file is duplicated: $allowed"};$seenAllowed[$key]=$true;$normalizedAllowed+=$relative
    }
    if($normalizedAllowed.Count -eq 0){throw 'AllowedFiles must contain at least one supported file.'}
    if($Classification -eq 'Green'){
        if(@($OpenQa).Count -gt 0){throw 'Green tasks cannot contain OpenQa items.'}
        foreach($clear in @($RTImpactClear,$SafetyImpactClear,$BoardImpactClear,$DriverImpactClear,$ABIImpactClear,$BuildImpactClear,$CustomerBranchImpactClear)){if($clear -cne 'YES'){throw 'Green tasks require YES for every impact-clear gate.'}}
    }

    $manifestPath=Join-Path $teamBobRoot 'profile-manifest.json';$workSchemaPath=Join-Path $teamBobRoot 'config\work-packet.schema.json';$buildSchemaPath=Join-Path $teamBobRoot 'config\vc6-build-targets.schema.json'
    $environment=Get-TeamBobLocalEnvironment $manifestPath $workSchemaPath $buildSchemaPath -BazaarOnly
    $sandboxPhysical=Get-TeamBobPhysicalPath $environment.sandboxRoot 'Registered sandbox root' 'Container' 'INTEGRITY_FAILED';$logPhysical=Get-TeamBobPhysicalPath $environment.logRoot 'Registered log root' 'Container' 'INTEGRITY_FAILED'
    Assert-TeamBobPhysicalSeparation $bazaarRootPhysical $sandboxPhysical 'Bazaar and sandbox roots' 'INTEGRITY_FAILED';Assert-TeamBobPhysicalSeparation $bazaarRootPhysical $logPhysical 'Bazaar and log roots' 'INTEGRITY_FAILED';Assert-TeamBobPhysicalSeparation $sandboxPhysical $logPhysical 'Sandbox and log roots' 'INTEGRITY_FAILED'
    $status=Invoke-TeamBobStartBazaarRead $environment.bazaarPath $bazaarRootFull @('status','--short');if(-not[string]::IsNullOrWhiteSpace($status)){throw 'Bazaar working tree is not clean.'}
    $branch=Invoke-TeamBobStartBazaarRead $environment.bazaarPath $bazaarRootFull @('nick');if([string]::IsNullOrWhiteSpace($branch)){throw 'Bazaar branch nick is empty.'}
    $revision=Invoke-TeamBobStartBazaarRead $environment.bazaarPath $bazaarRootFull @('version-info','--custom','--template={revision_id}');if([string]::IsNullOrWhiteSpace($revision)){throw 'Bazaar full revision id is empty.'}

    $packet=[ordered]@{'Profile Version'='0.2.0-poc';'Policy Version'='0.2.0-poc';'Policy Bundle SHA256'=$policyHash;'Role Ledger SHA256'=$roleHash;'Task ID'=$TaskId;Difficulty=$Difficulty;Risk=$Classification;Customer=$Customer;ReqIDs=@($ReqIds);'Word Baseline'=$WordBaseline;'QA Baseline'=$QaBaseline;'Spec Baseline'=$SpecBaseline;'Bazaar Root'=$bazaarRootFull;'Bazaar Branch'=$branch;'Bazaar Full Revision ID'=$revision;'Allowed Files'=@($normalizedAllowed);'Forbidden Areas'=@($normalizedForbidden);'RT Impact'=$RTImpact;'Safety Impact'=$SafetyImpact;'Board Impact'=$BoardImpact;'Driver Impact'=$DriverImpact;'ABI Impact'=$ABIImpact;'Build Impact'=$BuildImpact;'Customer Branch Impact'=$CustomerBranchImpact;'RT Impact Clear'=$RTImpactClear;'Safety Impact Clear'=$SafetyImpactClear;'Board Impact Clear'=$BoardImpactClear;'Driver Impact Clear'=$DriverImpactClear;'ABI Impact Clear'=$ABIImpactClear;'Build Impact Clear'=$BuildImpactClear;'Customer Branch Impact Clear'=$CustomerBranchImpactClear;'Clean Working Copy'='YES';'Open QA'=@($OpenQa);'Build Profile ID'=$BuildProfileId;'Max-Repair-Cycles'=2;'Specification Assignment ID'=$SpecificationAssignmentId;'Implementation Assignment ID'=$ImplementationAssignmentId;'Independent Reviewer Assignment ID'=$IndependentReviewerAssignmentId}
    Assert-TeamBobWorkPacketContract ([pscustomobject]$packet)
    $templatePath=Join-Path $teamBobRoot 'templates\work-packet.md';$template=Read-TeamBobUtf8File $templatePath 'Work-packet template' 'INTEGRITY_FAILED'
    $pattern='(?s)(<!-- canonical-work-packet-json:start -->\s*```json\s*)\{.*?\}(\s*```\s*<!-- canonical-work-packet-json:end -->)';if(-not[regex]::IsMatch($template,$pattern)){throw 'Work-packet template canonical JSON block is malformed.'}
    $packetJson=$packet|ConvertTo-Json -Depth 20;$document=[regex]::Replace($template,$pattern,[System.Text.RegularExpressions.MatchEvaluator]{param($m)$m.Groups[1].Value+$packetJson+$m.Groups[2].Value},1)

    $workRoot=Join-Path $bazaarRootFull 'team-bob-work';if(-not(Test-Path -LiteralPath $workRoot -PathType Container)){[void][System.IO.Directory]::CreateDirectory($workRoot)}
    $workPhysical=Get-TeamBobPhysicalPath $workRoot 'team-bob-work root' 'Container' 'INTEGRITY_FAILED';Assert-TeamBobPhysicalChild $workPhysical $bazaarRootPhysical 'team-bob-work root' 'INTEGRITY_FAILED'
    $stageRoot=Join-Path $workRoot ('STAGE-'+$TaskId+'-'+[guid]::NewGuid().ToString('N'));[void][System.IO.Directory]::CreateDirectory($stageRoot)
    foreach($child in @('drafts','approvals','results','state')){[void][System.IO.Directory]::CreateDirectory((Join-Path $stageRoot $child))}
    $stagePacket=Join-Path $stageRoot 'work-packet.md';Write-TeamBobCreateOnlyText $stagePacket $document;$packetHash=Get-TeamBobGovernanceFileHash $stagePacket
    $state=[ordered]@{schemaVersion='1.0';profileVersion='0.2.0-poc';policyVersion='0.2.0-poc';taskId=$TaskId;currentPhase='requirements';completedPhases=@();workPacketPath=(Join-Path $taskDirectory 'work-packet.md');workPacketSha256=$packetHash;policyBundleSha256=$policyHash;roleLedgerSha256=$roleHash;latestResultPath=$null;latestResultSha256=$null;updatedAtUtc=[datetimeoffset]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')}
    Write-TeamBobCreateOnlyJson (Join-Path $stageRoot 'state\phase-state.json') $state
    if(Test-Path -LiteralPath $taskDirectory){throw "Task directory appeared before publication: $taskDirectory"}
    [System.IO.Directory]::Move($stageRoot,$taskDirectory);$stageRoot=$null
    [Console]::Out.WriteLine("CREATED $(Join-Path $taskDirectory 'work-packet.md')");exit 0
}catch{
    if($null -ne $stageRoot -and (Test-Path -LiteralPath $stageRoot -PathType Container)){[System.IO.Directory]::Delete($stageRoot,$true)}
    Write-Error $_.Exception.Message;exit 1
}
