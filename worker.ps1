param([Parameter(Mandatory=$true)][string]$HomeDir,[Parameter(Mandatory=$true)][string]$JobID)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$OutputEncoding=[Console]::OutputEncoding
if($JobID -notmatch '^[a-f0-9]{32}$'){throw 'Invalid task ID'}
$config=Get-Content -LiteralPath (Join-Path $HomeDir 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$job=Get-Content -LiteralPath (Join-Path $HomeDir "jobs\$JobID.json") -Raw -Encoding UTF8 | ConvertFrom-Json
$gameEnv=Join-Path $config.install_root 'shared\.env'
if(Test-Path -LiteralPath $gameEnv){
 foreach($line in [IO.File]::ReadAllLines($gameEnv)){if($line -match '^HTTP_ADDR=.*:(\d+)\s*$'){$config.health_url='http://127.0.0.1:'+$Matches[1]}}
}
$workerLock=$null
$deploymentLock=$null
function Checked([string]$Program,[string[]]$Arguments){
 & $Program @Arguments | ForEach-Object { Write-Host $_ }
 if($LASTEXITCODE -ne 0){throw "$Program exited with code $LASTEXITCODE"}
}
function Save-Json([string]$Path,$Value){
 $temp="$Path.tmp-$JobID"
 [IO.File]::WriteAllText($temp,($Value|ConvertTo-Json -Depth 20),(New-Object Text.UTF8Encoding($false)))
 if(Test-Path -LiteralPath $Path){[IO.File]::Replace($temp,$Path,$null)}else{[IO.File]::Move($temp,$Path)}
}
function Get-CurrentVersion {
 $state=Read-DeploymentState -Layout $layout
 return [string]$state.current_version
}
function Assert-Expected {
 $current=Get-CurrentVersion
 if($current -ne [string]$job.expected){throw "Current release changed. Expected '$($job.expected)', actual '$current'. Refresh before retry."}
}
function Save-Checkpoint {
 $old=Read-DeploymentState -Layout $layout
 $service=Get-Service -Name $old.service_name
 $startup=[string]$service.StartType
 $wasRunning=([string]$service.Status -eq 'Running')
 $envPath=Join-Path $config.install_root 'shared\.env'
 $envBytes=$null
 if(Test-Path -LiteralPath $envPath){$envBytes=[Convert]::ToBase64String([IO.File]::ReadAllBytes($envPath))}
 Save-Json $checkpointPath ([ordered]@{job_id=$JobID;old_state=$old;startup=$startup;was_running=$wasRunning;environment=$envBytes;created=[DateTime]::UtcNow.ToString('o')})
}
function Restore-Checkpoint {
 if(!(Test-Path -LiteralPath $checkpointPath)){throw 'No recovery checkpoint exists.'}
 $checkpoint=Get-Content -LiteralPath $checkpointPath -Raw -Encoding UTF8|ConvertFrom-Json
 $old=$checkpoint.old_state
 foreach($candidate in @($layout.Current,(Join-Path $layout.Releases ([string]$old.current_version)))){
  if((Test-Path (Join-Path $candidate 'RELEASE_IDENTITY.json')) -or (Test-Path (Join-Path $candidate 'gamecore.dll'))){throw 'Native recovery requires consistent WAL/config/release recovery; legacy recovery is blocked'}
 }
 Set-Service -Name $old.service_name -StartupType $checkpoint.startup
 $now=Read-DeploymentState -Layout $layout
 Stop-ManagedRuntime -Layout $layout -State $now
 if($checkpoint.PSObject.Properties.Name -contains 'environment' -and $null -ne $checkpoint.environment){[IO.File]::WriteAllBytes((Join-Path $config.install_root 'shared\.env'),[Convert]::FromBase64String($checkpoint.environment))}
 if([string]::IsNullOrWhiteSpace([string]$old.current_version)){
  Save-DeploymentState -Layout $layout -State $old
  Write-Host 'No previous version: game remains stopped.'
 }else{
  $previous=Join-Path $layout.Releases ([string]$old.current_version)
  Assert-ChildPath -ParentPath $layout.Releases -ChildPath $previous
  Test-ReleaseChecksums -ReleaseRoot $previous
  Set-CurrentFromRelease -Layout $layout -ReleasePath $previous
  Save-DeploymentState -Layout $layout -State $old
  $restart=($checkpoint.PSObject.Properties.Name -contains 'was_running' -and $checkpoint.was_running)
  if($restart){
   Start-ManagedRuntime -Layout $layout -State $old
   Save-DeploymentState -Layout $layout -State $old
   Wait-ApplicationHealthy -HealthBaseURL $config.health_url -ExpectedVersion $old.current_version -TimeoutSeconds 30 | Out-Null
  }else{Write-Host 'Previous service was stopped (or legacy checkpoint state unknown); keeping it stopped.'}
 }
 Remove-Item -LiteralPath $checkpointPath -Force
 Write-Host 'RECOVERY SUCCEEDED'
}
try {
 # OS-held lock survives UI disconnects; only released when this worker exits.
 $workerLock=[IO.File]::Open((Join-Path $HomeDir 'worker.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
 . (Join-Path $HomeDir 'deploy\common.ps1')
 $layout=Get-DeploymentLayout -InstallRoot $config.install_root
 Initialize-DeploymentLayout -Layout $layout
 $checkpointPath=Join-Path $HomeDir 'checkpoint.json'
 if($job.action -eq 'recover'){
  $deploymentLock=Enter-DeploymentLock -Layout $layout
  $pending=Get-Content -LiteralPath $checkpointPath -Raw -Encoding UTF8|ConvertFrom-Json
  if($pending.PSObject.Properties.Name -contains 'kind' -and $pending.kind -eq 'native-migration-v1'){
   . (Join-Path $HomeDir 'native-migration.ps1');Recover-NativeMigration;exit 0
  }
  if($pending.PSObject.Properties.Name -contains 'kind' -and $pending.kind -eq 'native-v1'){
   . (Join-Path $HomeDir 'native-worker.ps1');Recover-NativeCheckpoint;exit 0
  }
  Restore-Checkpoint
  exit 0
 }
 if(Test-Path -LiteralPath $checkpointPath){throw 'Unfinished checkpoint exists. Run recovery first.'}
 Assert-Expected
 if($job.action -in @('package','migration')) {
  if($job.artifact -notmatch '^[a-f0-9]{64}$'){throw 'Invalid artifact SHA256'}
  $zip=Join-Path $HomeDir ("uploads\"+$job.artifact+'.zip')
  if((Get-Sha256Hex -Path $zip) -ne $job.artifact){throw 'Artifact checksum mismatch before deployment'}
  $unpack=Join-Path $HomeDir "artifacts\$JobID"
  if(Test-Path -LiteralPath $unpack){throw 'Extraction directory already exists'}
  New-Item -ItemType Directory -Path $unpack -Force|Out-Null
  Expand-SafeZipArchive -ZipPath $zip -Destination $unpack
  $entries=@(Get-ChildItem -LiteralPath $unpack -Force)
  if($entries.Count -ne 1 -or !$entries[0].PSIsContainer){throw 'Package must contain exactly one release directory'}
  $release=$entries[0].FullName
  Test-ReleaseChecksums -ReleaseRoot $release
  $info=Get-ReleaseVersion -ReleaseRoot $release
  if($info.BuildInfo.checks_skipped -or $info.BuildInfo.target -ne 'windows/amd64'){throw 'Package must pass checks and target windows/amd64'}
  Write-Host "LOCAL ARTIFACT VERIFIED: $($info.SafeVersion) dirty=$($info.BuildInfo.git_dirty) SHA256=$($job.artifact)"
 }
 if($job.action -in @('build','deploy')) {
  if($job.commit -notmatch '^[a-f0-9]{40}$'){throw 'Invalid commit SHA'}
  if([string]$config.branch -match '^[\-]' -or [string]$config.branch -match '[\s~^:?*\[\\]' -or [string]$config.branch -like '*..*'){throw 'Invalid branch'}
  $cache=Join-Path $HomeDir 'source-cache'
  if(!(Test-Path -LiteralPath $cache)) {Checked 'git' @('clone','--no-checkout','--',$config.repo,$cache)}
  $actualRemote=(& git -C $cache remote get-url origin).Trim()
  if($LASTEXITCODE -ne 0 -or $actualRemote -ne $config.repo){throw 'Unexpected source repository'}
  $refspec='+refs/heads/'+$config.branch+':refs/remotes/origin/'+$config.branch
  Write-Host 'FETCH: retrieving approved branch'
  Checked 'git' @('-C',$cache,'fetch','--prune','origin',$refspec)
  Checked 'git' @('-C',$cache,'merge-base','--is-ancestor',$job.commit,('refs/remotes/origin/'+$config.branch))
  $source=Join-Path $HomeDir "worktrees\$JobID"
  New-Item -ItemType Directory -Path (Split-Path $source -Parent) -Force|Out-Null
  Checked 'git' @('-C',$cache,'worktree','add','--detach',$source,$job.commit)
  $output=Join-Path $HomeDir "artifacts\$JobID"
  $version='cicd-'+$job.commit.Substring(0,12)+'-'+$JobID.Substring(0,8)
  Write-Host "BUILD: $version (the current game service is still running)"
  Push-Location $source
  try {
   # The checked game package entry generates content and runs the pinned
   # Go/C++ verification gate. Never bypass it with -SkipChecks.
   Checked 'powershell.exe' @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',(Join-Path $source 'scripts\package.ps1'),'-Version',$version,'-OutputRoot',$output)
  }finally {Pop-Location}
  $release=Join-Path $output "kk-mid-server-$version-windows-amd64"
  Test-ReleaseChecksums -ReleaseRoot $release
  $info=Get-ReleaseVersion -ReleaseRoot $release
  if($info.BuildInfo.git_commit -ne $job.commit){throw 'Build commit mismatch'}
  $zip="$release.zip"
  Test-ExternalPackageChecksum -PackageZip $zip -ChecksumFile "$zip.sha256"
  Write-Host ('ARTIFACT_SHA256='+ (Get-Sha256Hex -Path $zip))
  if($job.action -eq 'build'){Write-Host 'BUILD SUCCEEDED (not deployed)';exit 0}
 }
 $deploymentLock=Enter-DeploymentLock -Layout $layout
 Assert-Expected
 if($job.action -eq 'start'){
  if((Test-Path (Join-Path $layout.Current 'RELEASE_IDENTITY.json')) -or (Test-Path (Join-Path $layout.Current 'gamecore.dll'))){
   . (Join-Path $HomeDir 'native-worker.ps1')
   $identity=Test-NativeReleaseIdentity $layout.Current -AllowHistorical
   $state=Read-DeploymentState -Layout $layout
   if([string](Get-Service -Name $state.service_name).Status -ne 'Running'){
    Assert-NativeStopped $state
    $installed=Join-Path $layout.Releases ([string]$state.current_version)
    Assert-ChildPath -ParentPath $layout.Releases -ChildPath $installed
    Deploy-NativeRelease $installed -AllowHistorical
   }
   Confirm-NativeRunning $state $identity
   Set-Service -Name $state.service_name -StartupType Automatic
   Write-Host 'NATIVE START SUCCEEDED';exit 0
  }
  $state=Read-DeploymentState -Layout $layout
  if(!$state.current_version){throw 'No current release. Deploy first.'}
  Test-ReleaseChecksums -ReleaseRoot $layout.Current
  Start-ManagedRuntime -Layout $layout -State $state
  Save-DeploymentState -Layout $layout -State $state
  Wait-ApplicationHealthy -HealthBaseURL $config.health_url -ExpectedVersion $state.current_version -TimeoutSeconds 30|Out-Null
  Set-Service -Name $state.service_name -StartupType Automatic
  Write-Host 'START SUCCEEDED';exit 0
 }
 if($job.action -eq 'stop'){
  $state=Read-DeploymentState -Layout $layout
  Set-Service -Name $state.service_name -StartupType Manual
  Stop-ManagedRuntime -Layout $layout -State $state
  Save-DeploymentState -Layout $layout -State $state
  Write-Host 'STOP SUCCEEDED';exit 0
 }
 if($job.action -eq 'rollback'){
  $state=Read-DeploymentState -Layout $layout
  if(!$state.previous_version){throw 'No previous version to roll back to'}
  $release=Join-Path $layout.Releases ([string]$state.previous_version)
  Assert-ChildPath -ParentPath $layout.Releases -ChildPath $release
  Test-ReleaseChecksums -ReleaseRoot $release
  $info=Get-ReleaseVersion -ReleaseRoot $release
 }else{
  $staged=Join-Path $layout.Releases $info.SafeVersion
  Assert-ChildPath -ParentPath $layout.Releases -ChildPath $staged
  if(Test-Path -LiteralPath $staged){
   Test-ReleaseChecksums -ReleaseRoot $staged
   # Failed activation retains its immutable release. Reuse only identical bytes,
   # including metadata, checksum manifest and any additional files.
   $incomingFiles=@(Get-ChildItem -LiteralPath $release -File -Recurse -Force)
   $existingFiles=@(Get-ChildItem -LiteralPath $staged -File -Recurse -Force)
   if($incomingFiles.Count -ne $existingFiles.Count){throw 'Existing release contents differ; refusing to overwrite'}
   foreach($file in $incomingFiles){
    $relative=$file.FullName.Substring($release.Length+1)
    $existing=Join-Path $staged $relative
    Assert-ChildPath -ParentPath $staged -ChildPath $existing
    if(!(Test-Path -LiteralPath $existing -PathType Leaf) -or (Get-Sha256Hex -Path $file.FullName) -ne (Get-Sha256Hex -Path $existing)){throw "Existing release contents differ: $relative; refusing to overwrite"}
   }
   Write-Host "REUSING VERIFIED RELEASE: $($info.SafeVersion)"
  }else{
   New-Item -ItemType Directory -Path $staged|Out-Null
   Get-ChildItem -LiteralPath $release -Force|Copy-Item -Destination $staged -Recurse -Force
  }
  $release=$staged
  Test-ReleaseChecksums -ReleaseRoot $release
 }
 # Native packages require a separate maintenance/WAL transaction. Never run
 # their exclusive preflight through the legacy online/rollback path.
 if((Test-Path (Join-Path $layout.Current 'gamecore.dll')) -or (Test-Path (Join-Path $layout.Current 'RELEASE_IDENTITY.json')) -or (Test-Path -LiteralPath (Join-Path $release 'RELEASE_IDENTITY.json')) -or (Test-Path -LiteralPath (Join-Path $release 'gamecore.dll')) -or ($info.BuildInfo.PSObject.Properties.Name -contains 'production_gameplay' -and $info.BuildInfo.production_gameplay -eq 'cpp')){
  if($job.action -eq 'rollback'){throw 'Native rollback requires complete state compatibility evidence; use a validated forward deployment, not an old DLL against current WAL.'}
  . (Join-Path $HomeDir 'native-worker.ps1')
  if($job.action -eq 'migration'){. (Join-Path $HomeDir 'native-migration.ps1');Invoke-NativeMigration $release;exit 0}
  Deploy-NativeRelease $release
  exit 0
 }
 # External gameplay configuration belongs to the server, never to release rollback.
  . (Join-Path $HomeDir 'prepare-server-config.ps1')
  $serverConfig=Get-ManagedServerConfig -InstallRoot $config.install_root -ReleaseRoot $release
  $savedSelector=$env:SERVER_CONFIG_FILE
  try{
   $env:SERVER_CONFIG_FILE=$serverConfig
   Checked (Join-Path $release 'server.exe') @('-check-config')
  }finally{$env:SERVER_CONFIG_FILE=$savedSelector}
 # Save intent BEFORE stopping, so all post-stop exceptions and machine resets are recoverable.
 Save-Checkpoint
 try {
  $state=Read-DeploymentState -Layout $layout
  Write-Host 'MAINTENANCE: stopping current game; active in-memory rooms are not preserved'
  Set-Service -Name $state.service_name -StartupType Manual
  Stop-ManagedRuntime -Layout $layout -State $state
  Set-CurrentFromRelease -Layout $layout -ReleasePath $release
  if($state.current_version -ne $info.SafeVersion){$state.previous_version=$state.current_version}
  $state.current_version=$info.SafeVersion
  $state.runtime_mode='WindowsService'
  $state.deployed_at_utc=[DateTime]::UtcNow.ToString('o')
  Save-DeploymentState -Layout $layout -State $state
  Start-ManagedRuntime -Layout $layout -State $state
  Save-DeploymentState -Layout $layout -State $state
  $observed=Wait-ApplicationHealthy -HealthBaseURL $config.health_url -ExpectedVersion $info.SafeVersion -TimeoutSeconds 30
  if($job.action -eq 'deploy' -and $observed.git_commit -ne $job.commit){throw 'Running commit differs from requested commit'}
  if($job.action -eq 'package' -and $observed.git_commit -ne $info.BuildInfo.git_commit){throw 'Running commit differs from package metadata'}
  Set-Service -Name $state.service_name -StartupType Automatic
  Remove-Item -LiteralPath $checkpointPath -Force
  Write-Host "DEPLOYMENT SUCCEEDED: $($info.SafeVersion)"
 }catch {
  $reason=$_.Exception.Message
  Write-Host "DEPLOYMENT FAILED: $reason; attempting checkpoint recovery"
  try {Restore-Checkpoint}catch {Write-Host "RECOVERY FAILED: $($_.Exception.Message). Further deployment blocked."}
  throw $reason
 }
}catch {Write-Host "ERROR: $($_.Exception.Message)";exit 1}
finally {
 if($deploymentLock){$deploymentLock.Dispose()}
 if($workerLock){$workerLock.Dispose()}
}
