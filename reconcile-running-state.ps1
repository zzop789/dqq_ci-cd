[CmdletBinding()]
param(
 [string]$AgentRoot='C:\Services\zyf-cicd',
 [Parameter(Mandatory=$true)][string]$ExpectedVersion,
 [Parameter(Mandatory=$true)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedCheckpointSHA256,
 [Parameter(Mandatory=$true)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedStateSHA256,
 [Parameter(Mandatory=$true)][int]$ExpectedProcessID,
 [switch]$Apply
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$AgentRoot=[IO.Path]::GetFullPath($AgentRoot)
$config=Get-Content -LiteralPath (Join-Path $AgentRoot 'config.json') -Raw -Encoding UTF8|ConvertFrom-Json
. (Join-Path $AgentRoot 'deploy/common.ps1')
. (Join-Path $AgentRoot 'native-release.ps1')
. (Join-Path $AgentRoot 'native-worker.ps1')
$layout=Get-DeploymentLayout $config.install_root
$checkpointPath=Join-Path $AgentRoot 'checkpoint.json'
$workerLock=$null;$deploymentLock=$null
try{
 $workerLock=[IO.File]::Open((Join-Path $AgentRoot 'worker.lock'),'OpenOrCreate','ReadWrite','None')
 $deploymentLock=Enter-DeploymentLock $layout
 function Assert-SourceMetadata {
  if((Get-NativeReleaseHash $checkpointPath) -cne $ExpectedCheckpointSHA256.ToLowerInvariant()){throw 'Checkpoint changed; no reconciliation allowed'}
  if((Get-NativeReleaseHash $layout.StateFile) -cne $ExpectedStateSHA256.ToLowerInvariant()){throw 'Deployment state changed; no reconciliation allowed'}
 }
 Assert-SourceMetadata
 $cp=Get-Content -LiteralPath $checkpointPath -Raw -Encoding UTF8|ConvertFrom-Json
 $oldState=Read-DeploymentState $layout
 if($cp.kind -cne 'native-v1' -or $cp.phase -cne 'backed_up' -or $cp.may_have_served -or $cp.target_version -cne $ExpectedVersion){throw 'Only the reviewed obsolete pre-switch checkpoint can be reconciled'}
 if($oldState.current_version -cne $cp.old_state.current_version -or $oldState.service_name -cne $cp.old_state.service_name -or $oldState.runtime_mode -cne 'WindowsService'){throw 'Unexpected source deployment state'}
 if($oldState.current_version -ceq $ExpectedVersion){throw 'State already matches; do not archive an unrelated checkpoint'}
 $identity=Test-NativeReleaseIdentity $layout.Current
 if($identity.version -cne $ExpectedVersion -or $identity.dll_sha256 -cne $cp.target_dll){throw 'Current release does not match reviewed checkpoint target'}
 $release=[IO.Path]::GetFullPath((Join-Path $layout.Releases $ExpectedVersion))
 Assert-ChildPath $layout.Releases $release
 $stored=Test-NativeReleaseIdentity $release
 foreach($field in @('version','dll_sha256','dll_build_id','verified_source_sha256','verification_audit_sha256')){
  if($identity.$field -cne $stored.$field){throw ('Installed/release identity differs: '+$field)}
 }
 $audit=Get-Content -LiteralPath (Join-Path $layout.Current 'verification.json') -Raw -Encoding UTF8|ConvertFrom-Json
 function Get-VerifiedRunning {
  $service=Get-CimInstance Win32_Service -Filter ("Name='"+$oldState.service_name+"'")
  if($service.State -cne 'Running' -or $service.ProcessId -ne $ExpectedProcessID){throw 'Running service/PID changed; no reconciliation allowed'}
  $process=Get-CimInstance Win32_Process -Filter ('ProcessId='+$ExpectedProcessID)
  $allowed=@((Join-Path $layout.Current 'server.exe'),(Join-Path $release 'server.exe'))
  if(!$process.ExecutablePath -or $process.ExecutablePath -notin $allowed){throw 'Running process is outside the verified installed release'}
  $ready=Invoke-RestMethod ($config.health_url.TrimEnd('/')+'/readyz') -TimeoutSec 5
  $version=Invoke-RestMethod ($config.health_url.TrimEnd('/')+'/version') -TimeoutSec 5
  if($ready.ready -ne $true -or $ready.engine -cne 'cpp' -or $version.version -cne $ExpectedVersion -or $version.dll_sha256 -cne $identity.dll_sha256 -or $version.module.build_id -cne $identity.dll_build_id -or $version.transport_profile -cne 'warcraft-round-v1'){throw 'Live version/health differs from verified release'}
  Assert-NativeRuntimeContract $version $audit
  return $version
 }
 $version=Get-VerifiedRunning
 $preview=[ordered]@{operation='adopt_verified_running_release';old_version=$oldState.current_version;current_version=$ExpectedVersion;process_id=$ExpectedProcessID;runtime_identity=$version.runtime_identity;checkpoint_sha256=$ExpectedCheckpointSHA256.ToLowerInvariant();old_state_sha256=$ExpectedStateSHA256.ToLowerInvariant();restart_required=$false}
 if(!$Apply){$preview|ConvertTo-Json -Depth 8;return}
 $backup=Join-Path $AgentRoot ('state-reconciliations/'+[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')+'-'+[guid]::NewGuid().ToString('N'))
 Assert-ChildPath $AgentRoot $backup
 [IO.Directory]::CreateDirectory($backup)|Out-Null
 [IO.File]::Copy($layout.StateFile,(Join-Path $backup 'deployment.before.json'),$false)
 [IO.File]::Copy($checkpointPath,(Join-Path $backup 'checkpoint.before.json'),$false)
 $oldBytes=[IO.File]::ReadAllBytes($layout.StateFile)
 Assert-SourceMetadata
 $null=Get-VerifiedRunning
 $next=($oldState|ConvertTo-Json -Depth 10)|ConvertFrom-Json
 $next.current_version=$ExpectedVersion
 # The old release was moved into a reset backup; do not advertise it as a rollback source.
 $next.previous_version=''
 $next.process_id=0
 $next.deployed_at_utc=[DateTime]::UtcNow.ToString('o')
 $preview['reconciled_at_utc']=$next.deployed_at_utc
 [IO.File]::WriteAllText((Join-Path $backup 'reconciliation.json'),($preview|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
 Save-DeploymentState $layout $next
 try{
  $saved=Read-DeploymentState $layout
  if($saved.current_version -cne $ExpectedVersion -or $saved.service_name -cne $oldState.service_name){throw 'Reconciled state read-back failed'}
  $null=Get-VerifiedRunning
  if((Get-NativeReleaseHash $checkpointPath) -cne $ExpectedCheckpointSHA256.ToLowerInvariant()){throw 'Checkpoint changed during reconciliation'}
  # Archive rather than delete; no game data, configuration, process or service is touched.
  [IO.File]::Move($checkpointPath,(Join-Path $backup 'checkpoint.archived.json'))
 }catch{[IO.File]::WriteAllBytes($layout.StateFile,$oldBytes);throw}
 [pscustomobject]@{result='metadata_reconciled';version=$ExpectedVersion;process_id=$ExpectedProcessID;backup=$backup;service_restarted=$false}|ConvertTo-Json -Compress
}finally{
 if($null -ne $deploymentLock){$deploymentLock.Dispose()}
 if($null -ne $workerLock){$workerLock.Dispose()}
}
