param([Parameter(Mandatory=$true)][string]$HomeDir,[Parameter(Mandatory=$true)][string]$StageDir)
# Explicitly approved, hash-bound configuration migration plus package deployment.
# This administrative entry uses the same locks/checkpoint/recovery as worker.ps1.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$OutputEncoding=[Console]::OutputEncoding
$manifest=Get-Content -LiteralPath (Join-Path $StageDir 'deployment-manifest.json') -Raw -Encoding UTF8|ConvertFrom-Json
$JobID=[string]$manifest.job_id
if($manifest.schema_version -ne 1 -or $JobID -cnotmatch '^[a-f0-9]{32}$' -or $manifest.artifact_sha256 -cnotmatch '^[a-f0-9]{64}$'){throw 'Invalid approved deployment manifest'}
$jobPath=Join-Path $HomeDir "jobs/$JobID.json"
if(Test-Path -LiteralPath $jobPath){throw 'Deployment task already exists; inspect it instead of running again'}
$job=[pscustomobject][ordered]@{id=$JobID;action='package';commit='';artifact=$manifest.artifact_sha256;maintenance=$true;expected=$manifest.expected_current_version;status='running';error='';created=[DateTime]::UtcNow.ToString('o');finished=''}
$workerLock=$null;$deploymentLock=$null;$exitCode=1
function Assert-FileHash([string]$Path,[string]$Expected){
 if($Expected -cnotmatch '^[a-f0-9]{64}$' -or (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $Expected){throw ('File differs from approved manifest: '+$Path)}
}
function Save-Task {
 $temp=$jobPath+'.tmp-'+[guid]::NewGuid().ToString('N')
 [IO.File]::WriteAllText($temp,($job|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
 if(Test-Path -LiteralPath $jobPath){[IO.File]::Replace($temp,$jobPath,$jobPath+'.previous')}else{[IO.File]::Move($temp,$jobPath)}
}
try{
 $workerLock=[IO.File]::Open((Join-Path $HomeDir 'worker.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
 $config=Get-Content -LiteralPath (Join-Path $HomeDir 'config.json') -Raw -Encoding UTF8|ConvertFrom-Json
 Assert-FileHash (Join-Path $HomeDir 'deploy/common.ps1') $manifest.common_sha256
 . (Join-Path $HomeDir 'deploy/common.ps1')
 $layout=Get-DeploymentLayout -InstallRoot $config.install_root
 $deploymentLock=Enter-DeploymentLock -Layout $layout
 $checkpointPath=Join-Path $HomeDir 'checkpoint.json'
 if(Test-Path -LiteralPath $checkpointPath){throw 'Unfinished checkpoint exists; recover it before a new deployment'}
 $state=Read-DeploymentState -Layout $layout
 if($state.current_version -cne $job.expected -or $state.service_name -cne $manifest.service_name){throw 'Installed release/service changed since approval'}
 Assert-FileHash (Join-Path $layout.Current 'gamecore.dll') $manifest.expected_current_dll_sha256
 $release=Join-Path $layout.Releases $manifest.release_version
 Assert-ChildPath $layout.Releases $release
 Assert-FileHash (Join-Path $HomeDir ('uploads/'+$job.artifact+'.zip')) $job.artifact
 Assert-FileHash (Join-Path $release 'RELEASE_IDENTITY.json') $manifest.release_identity_sha256
 Assert-FileHash (Join-Path $StageDir 'candidate/approval.json') $manifest.approval_sha256
 $helperNames=@('native-release.ps1','native-maintenance.ps1','native-worker.ps1')
 foreach($name in $helperNames){
  Assert-FileHash (Join-Path $HomeDir $name) $manifest.installed_helpers.$name
  Assert-FileHash (Join-Path $StageDir $name) $manifest.staged_helpers.$name
  $tokens=$null;$errors=$null
  $null=[Management.Automation.Language.Parser]::ParseFile((Join-Path $StageDir $name),[ref]$tokens,[ref]$errors)
  if($errors.Count){throw ('Helper syntax error: '+$name)}
 }
 # Validate everything with the staged helper set before installing any helper.
 . (Join-Path $StageDir 'native-worker.ps1')
 Test-ReleaseChecksums -ReleaseRoot $release
 $identity=Test-NativeReleaseIdentity $release
 if($identity.version -cne $manifest.release_version -or $identity.dll_sha256 -cne $manifest.dll_sha256){throw 'Release identity differs from approved target'}
 $null=Read-ApprovedNativeConfiguration (Join-Path $StageDir 'candidate') $identity $state
 foreach($line in [IO.File]::ReadAllLines((Join-Path $layout.Shared '.env'))){if($line -match '^HTTP_ADDR=.*:(\d+)\s*$'){$config.health_url='http://127.0.0.1:'+$Matches[1]}}
 Save-Task
 $backup=Join-Path $StageDir 'previous-helpers'
 if(Test-Path -LiteralPath $backup){throw 'Helper backup already exists; inspect the previous attempt'}
 [IO.Directory]::CreateDirectory($backup)|Out-Null
 foreach($name in $helperNames){Copy-Item -LiteralPath (Join-Path $HomeDir $name) -Destination (Join-Path $backup $name);Assert-FileHash (Join-Path $backup $name) $manifest.installed_helpers.$name}
 try{
  foreach($name in $helperNames){
   $destination=Join-Path $HomeDir $name;$temp=$destination+'.approved-'+$JobID
   Copy-Item -LiteralPath (Join-Path $StageDir $name) -Destination $temp
   Assert-FileHash $temp $manifest.staged_helpers.$name
   [IO.File]::Replace($temp,$destination,(Join-Path $backup ($name+'.replaced')))
  }
  foreach($name in $helperNames){Assert-FileHash (Join-Path $HomeDir $name) $manifest.staged_helpers.$name}
 }catch{
  $installError=$_.Exception.Message
  try{
   # No deployment checkpoint has been created yet. Restore the complete old
   # helper set before releasing locks if its installation was interrupted.
   foreach($name in $helperNames){
    $destination=Join-Path $HomeDir $name;$temp=$destination+'.restore-'+$JobID
    Assert-FileHash (Join-Path $backup $name) $manifest.installed_helpers.$name
    Copy-Item -LiteralPath (Join-Path $backup $name) -Destination $temp
    Assert-FileHash $temp $manifest.installed_helpers.$name
    [IO.File]::Replace($temp,$destination,(Join-Path $backup ($name+'.restore-replaced')))
   }
   foreach($name in $helperNames){Assert-FileHash (Join-Path $HomeDir $name) $manifest.installed_helpers.$name}
  }catch{throw ('HELPER RECOVERY HELD: '+$_.Exception.Message+'; original install failure: '+$installError)}
  throw ('Helper update failed; original helper set restored: '+$installError)
 }
 . (Join-Path $HomeDir 'native-worker.ps1')
 Write-Host ('APPROVED DEPLOYMENT: '+$manifest.release_version+' artifact='+$job.artifact)
 Deploy-NativeRelease -Release $release -ConfigurationCandidate (Join-Path $StageDir 'candidate')
 $job.status='succeeded';$exitCode=0
}catch{
 $job.status='failed';$job.error=$_.Exception.Message
 Write-Host ('ERROR: '+$job.error)
 Write-Host $_.ScriptStackTrace
}finally{
 $job.finished=[DateTime]::UtcNow.ToString('o')
 try{Save-Task}finally{if($deploymentLock){$deploymentLock.Dispose()};if($workerLock){$workerLock.Dispose()}}
}
exit $exitCode
