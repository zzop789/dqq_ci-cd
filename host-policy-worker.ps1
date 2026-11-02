param(
 [Parameter(Mandatory=$true)][string]$HomeDir,
 [string]$JobID='',
 [string]$DraftID='',
 [ValidateSet('Validate','Apply','Recover')][string]$Mode='Apply'
)

# A host-only maintenance transaction. No Redis publication, Lua migration,
# release switch, or room restoration is performed by this worker.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$OutputEncoding=[Console]::OutputEncoding
. (Join-Path $PSScriptRoot 'deploy/common.ps1')
. (Join-Path $PSScriptRoot 'native-worker.ps1')

$script:HPStage='initialization'
$script:HPFields=@('pending_registration_seconds','queue_idle_seconds','suspect_offline_seconds','session_expire_seconds','lobby_heartbeat_seconds','lifecycle_sweep_seconds','room_failure_limit','room_failure_seconds')

function Assert-HPPlainPath([string]$Path) {
 for($p=[IO.Path]::GetFullPath($Path);$p;$p=[IO.Path]::GetDirectoryName($p)){
  if(Test-Path -LiteralPath $p){
   if((Get-Item -LiteralPath $p -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Reparse point in host-policy path'}
  }
 }
}
function Read-HPBytes([string]$Path) {
 Assert-HPPlainPath $Path
 $file=Get-Item -LiteralPath $Path -Force
 if($file.PSIsContainer -or $file.Length -lt 1 -or $file.Length -gt 1MB){throw 'Expected a regular file of at most 1 MiB'}
 return ,([IO.File]::ReadAllBytes($Path))
}
function Read-HPJSON([string]$Path) {
 try{
  $bytes=Read-HPBytes $Path
  $text=[Text.UTF8Encoding]::new($false,$true).GetString($bytes).TrimStart([char]0xFEFF)
  return ($text|ConvertFrom-Json -ErrorAction Stop)
 }catch{throw 'Invalid bounded UTF-8 JSON file'}
}
function Get-HPHash([string]$Path) {return (Get-NativeReleaseHashOfBytes (Read-HPBytes $Path))}
function Write-HPBytes([string]$Path,[byte[]]$Bytes) {
 Assert-HPPlainPath $Path
 $stream=[IO.File]::Open($Path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
 try{$stream.Write($Bytes,0,$Bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
}
function ConvertTo-HPCanonical($Value) {
 if($null -eq $Value){return 'null'}
 if($Value -is [System.Management.Automation.PSCustomObject]){
  $parts=foreach($p in @($Value.PSObject.Properties|Sort-Object Name -CaseSensitive)){
   (ConvertTo-Json -InputObject ([string]$p.Name) -Compress)+':'+(ConvertTo-HPCanonical $p.Value)
  }
  return '{'+($parts -join ',')+'}'
 }
 if($Value -is [array]){return '['+((@($Value|ForEach-Object {ConvertTo-HPCanonical $_})) -join ',')+']'}
 return (ConvertTo-Json -InputObject $Value -Depth 32 -Compress)
}
function Assert-HPValues($Values) {
 $names=@($Values.PSObject.Properties.Name)
 if($names.Count -ne 8){throw 'Eight lifecycle fields are required'}
 foreach($name in $script:HPFields){
  if($names -cnotcontains $name){throw 'Unknown or missing lifecycle field'}
  $value=$Values.$name;$maximum=86400;if($name -ceq 'room_failure_limit'){$maximum=100}
  if(($value -isnot [int] -and $value -isnot [long]) -or $value -lt 1 -or $value -gt $maximum){throw 'Lifecycle field is not a bounded integer'}
 }
 if($Values.suspect_offline_seconds -ge $Values.session_expire_seconds -or $Values.queue_idle_seconds -gt $Values.session_expire_seconds -or
    $Values.lobby_heartbeat_seconds -ge $Values.queue_idle_seconds -or $Values.lifecycle_sweep_seconds -gt $Values.queue_idle_seconds){throw 'Lifecycle interval ordering is invalid'}
}
function Read-HPDraft([string]$ID,[switch]$RequireValidated) {
 $script:HPStage='draft-integrity'
 if($ID -cnotmatch '^[a-f0-9]{32}$'){throw 'Invalid draft ID'}
 $dir=Join-Path $HomeDir ('host-policy/drafts/'+$ID)
 $draft=Read-HPJSON (Join-Path $dir 'draft.json')
 if($draft.schema_version -ne 1 -or $draft.id -cne $ID -or [string]$draft.expected_version -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'){throw 'Invalid draft identity'}
 foreach($name in @('base_sha256','candidate_sha256','release_identity_sha256')){if([string]$draft.$name -cnotmatch '^[a-f0-9]{64}$'){throw 'Invalid draft hash'}}
 if($draft.validated -isnot [bool] -or ($RequireValidated -and !$draft.validated)){throw 'Draft has not passed validation'}
 Assert-HPValues $draft.values
 $before=Join-Path $dir 'before-host.json';$candidate=Join-Path $dir 'host.json'
 if((Get-HPHash $before) -cne $draft.base_sha256 -or (Get-HPHash $candidate) -cne $draft.candidate_sha256){throw 'Draft bytes changed'}
 $old=Read-HPJSON $before;$new=Read-HPJSON $candidate
 if($old.config_version -ne 3 -or $new.config_version -ne 3){throw 'Host policy requires schema 3'}
 Assert-HPValues $new.runtime.client_lifecycle
 if((ConvertTo-HPCanonical $new.runtime.client_lifecycle) -cne (ConvertTo-HPCanonical $draft.values)){throw 'Draft values differ from candidate'}
 $old.runtime.PSObject.Properties.Remove('client_lifecycle');$new.runtime.PSObject.Properties.Remove('client_lifecycle')
 if((ConvertTo-HPCanonical $old) -cne (ConvertTo-HPCanonical $new)){throw 'Draft changes settings outside client_lifecycle'}
 return [pscustomobject]@{Metadata=$draft;Directory=$dir;Before=$before;Candidate=$candidate}
}
function Get-HPRelease($State,[string]$ExpectedVersion,[string]$ExpectedIdentity) {
 $script:HPStage='release-identity'
 if($State.runtime_mode -cne 'WindowsService' -or $State.current_version -cne $ExpectedVersion -or $State.service_name -cnotmatch '^[A-Za-z0-9_.-]+$'){throw 'Installed service or release differs from expected state'}
 $release=Join-Path $layout.Releases $ExpectedVersion
 Assert-HPPlainPath $release
 $null=Get-MaintenanceTree $release
 $identity=Test-NativeReleaseIdentity -PackageRoot $release -AllowHistorical
 if($identity.version -cne $ExpectedVersion -or !(Test-NativeEphemeralIdentity $identity) -or (Get-HPHash (Join-Path $release 'RELEASE_IDENTITY.json')) -cne $ExpectedIdentity){throw 'Release identity changed or is not ephemeral'}
 $current=Get-NativeCurrentSource $State
 if(!$current.Equals($release,[StringComparison]::OrdinalIgnoreCase)){
  $null=Get-MaintenanceTree $current
  $null=Test-NativeReleaseIdentity -PackageRoot $current -AllowHistorical
  if((Get-HPHash (Join-Path $current 'RELEASE_IDENTITY.json')) -cne $ExpectedIdentity){throw 'Current executable identity differs from stored release'}
 }
 return [pscustomobject]@{Path=$release;Identity=$identity}
}
function Get-HPService($State,$Release) {
 $script:HPStage='service-environment'
 if(@(Get-NativeRedisOverrides $State).Count){throw 'Redis environment overrides exist outside shared/.env'}
 $key=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(('SYSTEM\CurrentControlSet\Services\'+$State.service_name),$false)
 if($null -eq $key){throw 'Service registry entry is unavailable'}
 try{
  $image=[string]$key.GetValue('ImagePath','');$expected=Join-Path $layout.Current 'server.exe'
  if($image -ine $expected -and $image -ine ('"'+$expected+'"')){throw 'Service does not execute the managed current server'}
  $entries=@($key.GetValue('Environment',@()));$values=@{}
  foreach($entry in $entries){
   $position=([string]$entry).IndexOf('=');if($position -le 0){throw 'Malformed service environment entry'}
   $name=([string]$entry).Substring(0,$position)
   if($values.ContainsKey($name)){throw 'Duplicate service environment selector'}
   $values[$name]=([string]$entry).Substring($position+1)
  }
  $selectors=@{ENV_FILE=$layout.Environment;SERVER_CONFIG_FILE=(Join-Path $layout.Shared 'host.json');GAMECORE_DLL=(Join-Path $Release.Path 'gamecore.dll');GAMECORE_SHA256=$Release.Identity.dll_sha256;COMBAT_CONTENT_DIR=(Join-Path $Release.Path 'configs/combat');LOG_DIR=(Join-Path $layout.Shared 'logs')}
  foreach($name in $selectors.Keys){if(!$values.ContainsKey($name) -or $values[$name] -ine $selectors[$name]){throw 'Service selectors do not match the verified installation'}}
  $start=[int]$key.GetValue('Start',0);if($start -notin @(2,3)){throw 'Service startup mode must be Automatic or Manual'}
  $fingerprint=[Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject @($entries|Sort-Object -CaseSensitive) -Compress))
  return [pscustomobject]@{Start=$start;Delayed=[int]$key.GetValue('DelayedAutoStart',0);EnvironmentSHA=(Get-NativeReleaseHashOfBytes $fingerprint)}
 }finally{$key.Dispose()}
}
function Assert-HPEnvironment([string]$Release,[string]$WorkingDirectory) {
 $null=Read-HPBytes $layout.Environment
 # LoadEnvironment currently has fallbacks. Refuse every alternate existing
 # file rather than allowing omitted/invalid .env keys to select another DB.
 $paths=@((Join-Path $Release '.env'),(Join-Path $Release '../shared/.env'),(Join-Path $WorkingDirectory '.env'),
          (Join-Path $layout.Current '.env'),(Join-Path $layout.Current '../shared/.env'),(Join-Path ([Environment]::SystemDirectory) '.env'))
 foreach($path in $paths){
  $full=[IO.Path]::GetFullPath($path)
  if(!$full.Equals($layout.Environment,[StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $full)){throw 'An alternate environment fallback file exists'}
 }
}
function Set-HPHealthEndpoint {
 # Match the existing worker's shared HTTP_ADDR selection. This value is only
 # used for a loopback probe; the environment text itself is never logged.
 $bytes=Read-HPBytes $layout.Environment
 $text=[Text.UTF8Encoding]::new($false,$true).GetString($bytes).TrimStart([char]0xFEFF)
 foreach($line in ($text -split "`n")){
  if($line -match '^HTTP_ADDR=.*:(\d+)\s*$'){
   $port=[int]$Matches[1];if($port -lt 1 -or $port -gt 65535){throw 'Invalid configured HTTP port'}
   $config.health_url='http://127.0.0.1:'+([string]$port)
  }
 }
 $uri=[uri]$config.health_url
 if(!$uri.IsAbsoluteUri -or $uri.Scheme -cne 'http' -or !$uri.IsLoopback -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or $uri.AbsolutePath -cne '/'){throw 'Host-policy readiness requires a plain loopback HTTP endpoint'}
}
function Get-HPServicePID($State) {
 $service=Get-CimInstance -ClassName Win32_Service -Filter ("Name='"+$State.service_name+"'") -OperationTimeoutSec 10
 if($null -eq $service){throw 'Cannot inspect managed service process'}
 return [int]$service.ProcessId
}
function Assert-HPClosed($State,[int]$PreviousPID) {
 Assert-NativeStopped $State
 if((Get-HPServicePID $State) -ne 0){throw 'Stopped service still has a process'}
 if($PreviousPID -gt 0 -and (Get-Process -Id $PreviousPID -ErrorAction SilentlyContinue)){throw 'Previous host process has not exited; maintenance held'}
 $port=([uri]$config.health_url).Port
 # Get-NetTCPConnection reports no matching objects as a nonterminating error.
 # Enumerating listeners first distinguishes that ordinary empty result from
 # an inability to inspect TCP ownership.
 $listeners=@(Get-NetTCPConnection -State Listen -ErrorAction Stop|Where-Object {$_.LocalPort -eq $port})
 if($listeners.Count){throw 'The managed ingress port remains open; maintenance held'}
}
function Assert-HPRunningProcess($State) {
 $processID=Get-HPServicePID $State
 if($processID -le 0 -or [string](Get-Service -Name $State.service_name).Status -cne 'Running'){throw 'Managed service is not running'}
 $process=Get-Process -Id $processID -ErrorAction Stop
 $expected=Join-Path $layout.Current 'server.exe'
 $stored=Join-Path (Join-Path $layout.Releases $State.current_version) 'server.exe'
 if($process.Path -ine $expected -and $process.Path -ine $stored){throw 'Managed service process is not the verified host'}
 $port=([uri]$config.health_url).Port
 $listeners=@(Get-NetTCPConnection -State Listen -ErrorAction Stop|Where-Object {$_.LocalPort -eq $port})
 if(!$listeners.Count -or @($listeners|Where-Object {$_.OwningProcess -ne $processID}).Count){throw 'Readiness listener does not belong to the managed service'}
}
function Invoke-HPProof($Release,[string]$HostPath,[string]$HostHash,[switch]$Preflight) {
 $script:HPStage=if($Preflight){'preflight'}else{'validation'}
 $working=Split-Path $HostPath -Parent
 Assert-HPEnvironment $Release.Path $working
 if((Get-HPHash $HostPath) -cne $HostHash){throw 'Host changed before verification'}
 $start=New-Object Diagnostics.ProcessStartInfo
 $start.FileName=Join-Path $Release.Path 'server.exe';$start.WorkingDirectory=$working
 $start.Arguments=if($Preflight){'-preflight'}else{'-validate-config'}
 $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
 $start.StandardOutputEncoding=[Text.UTF8Encoding]::new($false,$true);$start.StandardErrorEncoding=[Text.UTF8Encoding]::new($false,$true)
 foreach($name in @($start.EnvironmentVariables.Keys)){if([string]$name -match '^(REDIS_|HTTP_ADDR$|PUBLIC_BASE_URL$)'){$start.EnvironmentVariables.Remove([string]$name)}}
 $fixed=@{ENV_FILE=$layout.Environment;SERVER_CONFIG_FILE=$HostPath;GAMECORE_DLL=(Join-Path $Release.Path 'gamecore.dll');GAMECORE_SHA256=$Release.Identity.dll_sha256;COMBAT_CONTENT_DIR=(Join-Path $Release.Path 'configs/combat');LOG_DIR=(Join-Path $working 'logs')}
 foreach($name in $fixed.Keys){$start.EnvironmentVariables[$name]=[string]$fixed[$name]}
 $process=New-Object Diagnostics.Process;$process.StartInfo=$start;$environmentLock=$null;$hostLock=$null
 try{
  $environmentLock=[IO.File]::Open($layout.Environment,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
  $hostLock=[IO.File]::Open($HostPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
  if(!$process.Start()){throw 'Cannot start verified validation executable'}
  # Drain both pipes incrementally: neither pipe may deadlock or grow without
  # a limit. Stderr is deliberately discarded, never copied into job logs.
  $stdout=New-Object Text.StringBuilder;$outBuffer=New-Object char[] 4096;$errBuffer=New-Object char[] 4096
  $outTask=$process.StandardOutput.ReadAsync($outBuffer,0,$outBuffer.Length);$errTask=$process.StandardError.ReadAsync($errBuffer,0,$errBuffer.Length)
  $outDone=$false;$errDone=$false;$errCount=0;$watch=[Diagnostics.Stopwatch]::StartNew()
  $timeout=if($Mode -ceq 'Validate'){30}else{120}
  while(!$outDone -or !$errDone -or !$process.HasExited){
   if($watch.Elapsed.TotalSeconds -ge $timeout){throw 'Host verification exceeded its time limit'}
   if(!$outDone -and $outTask.IsCompleted){
    $n=$outTask.GetAwaiter().GetResult();if($n -eq 0){$outDone=$true}else{
     if($stdout.Length+$n -gt 4MB){throw 'Host verification output exceeded its limit'}
     $null=$stdout.Append($outBuffer,0,$n);$outTask=$process.StandardOutput.ReadAsync($outBuffer,0,$outBuffer.Length)
    }
   }
   if(!$errDone -and $errTask.IsCompleted){
    $n=$errTask.GetAwaiter().GetResult();if($n -eq 0){$errDone=$true}else{
     $errCount+=$n;if($errCount -gt 65536){throw 'Host verification diagnostics exceeded their limit'}
     $errTask=$process.StandardError.ReadAsync($errBuffer,0,$errBuffer.Length)
    }
   }
   Start-Sleep -Milliseconds 20
  }
  if($process.ExitCode -ne 0){throw 'Installed host rejected the configuration; raw diagnostics are suppressed'}
  try{$proof=$stdout.ToString()|ConvertFrom-Json -ErrorAction Stop}catch{throw 'Host verification did not return valid UTF-8 JSON'}
  if($proof.engine -cne 'cpp' -or $proof.configuration_source -cne 'redis' -or [string]$proof.redis_configuration_version -cnotmatch '^[a-f0-9]{32}$' -or
     $proof.dll_sha256 -cne $Release.Identity.dll_sha256 -or $proof.module.build_id -cne $Release.Identity.dll_build_id -or
     $proof.listener_started -isnot [bool] -or $proof.listener_started -ne $false -or $proof.data_directory_accessed -isnot [bool] -or $proof.data_directory_accessed -ne $false -or
     $proof.recovery_checked -isnot [bool] -or $proof.recovery_checked -ne $false){throw 'Host verification receipt has an invalid safety or identity field'}
  if($Preflight){
   if($proof.preflight -cne 'passed' -or $proof.gameplay_commands_executed -ne 0 -or $proof.host_config -ine $HostPath){throw 'Preflight receipt is incomplete'}
   Assert-NativeEphemeralProof $proof
  }else{
   if($proof.validation -cne 'passed' -or $proof.scope -cne 'configuration-and-content' -or $proof.input_sha256.PSObject.Properties[$HostPath].Value -cne $HostHash){throw 'Validation receipt is not bound to candidate host bytes'}
  }
  if((Get-HPHash $HostPath) -cne $HostHash){throw 'Host changed during verification'}
  return [string]$proof.redis_configuration_version
 }finally{
  if($null -ne $process -and $null -ne $process.StartInfo){
   try{if(!$process.HasExited){$process.Kill();$null=$process.WaitForExit(5000)}}catch{}
  }
  if($null -ne $hostLock){$hostLock.Dispose()};if($null -ne $environmentLock){$environmentLock.Dispose()};$process.Dispose()
 }
}
function Assert-HPOwnership($Checkpoint) {
 $state=Read-DeploymentState $layout
 if($state.service_name -cne $Checkpoint.service_name){throw 'Service identity changed; recovery held'}
 $release=Get-HPRelease $state $Checkpoint.expected_version $Checkpoint.release_identity_sha256
 $service=Get-HPService $state $release
 if($service.EnvironmentSHA -cne $Checkpoint.service_environment_sha256 -or $service.Delayed -ne $Checkpoint.service_delayed_start -or
    $service.Start -notin @([int]$Checkpoint.service_start,3) -or (Get-HPHash $layout.Environment) -cne $Checkpoint.environment_sha256){throw 'Environment or service ownership changed; recovery held'}
 $liveHash=Get-HPHash (Join-Path $layout.Shared 'host.json')
 if($liveHash -cne $Checkpoint.base_sha256 -and $liveHash -cne $Checkpoint.candidate_sha256){throw 'A third party changed host.json; recovery held'}
 $transaction=Join-Path $HomeDir ('host-policy/transactions/'+$Checkpoint.job_id)
 if((Get-HPHash (Join-Path $transaction 'before-host.json')) -cne $Checkpoint.base_sha256 -or (Get-HPHash (Join-Path $transaction 'host.json')) -cne $Checkpoint.candidate_sha256){throw 'Transaction backup identity changed; recovery held'}
 return [pscustomobject]@{State=$state;Release=$release;Transaction=$transaction;LiveHash=$liveHash}
}
function Save-HPCheckpoint($Checkpoint,[string]$Phase) {
 $script:HPStage=$Phase
 $Checkpoint.phase=$Phase
 Write-MaintenanceState $checkpointPath $Checkpoint
}
function Set-HPHost([byte[]]$Bytes,[string]$ExpectedHash,[string]$TargetHash) {
 $hostPath=Join-Path $layout.Shared 'host.json'
 Assert-HPPlainPath $hostPath
 if((Get-HPHash $hostPath) -cne $ExpectedHash){throw 'Live host bytes changed before replacement'}
 $temp=Join-Path $layout.Shared ('host-policy-'+[guid]::NewGuid().ToString('N')+'.tmp')
 try{
  Write-HPBytes $temp $Bytes
  if((Get-HPHash $temp) -cne $TargetHash -or (Get-HPHash $hostPath) -cne $ExpectedHash){throw 'Host replacement hash mismatch'}
  [IO.File]::Replace($temp,$hostPath,$null)
  if((Get-HPHash $hostPath) -cne $TargetHash){throw 'Host replacement could not be confirmed'}
 }finally{if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Force}}
}
function Restore-HPStartup($Checkpoint) {
 $script:HPStage='restore-startup-policy'
 $startup=if($Checkpoint.service_start -eq 2){'Automatic'}else{'Manual'}
 Set-Service -Name $Checkpoint.service_name -StartupType $startup
 $key=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(('SYSTEM\CurrentControlSet\Services\'+$Checkpoint.service_name),$false)
 if($null -eq $key){throw 'Cannot verify restored service startup mode'}
 try{if([int]$key.GetValue('Start',0) -ne $Checkpoint.service_start -or [int]$key.GetValue('DelayedAutoStart',0) -ne $Checkpoint.service_delayed_start){throw 'Service startup policy was not restored'}}finally{$key.Dispose()}
}
function Complete-HPCheckpoint($Checkpoint,[string]$Outcome) {
 $script:HPStage='complete-checkpoint'
 $Checkpoint.phase=$Outcome
 $path=Join-Path $HomeDir ('host-policy/transactions/'+$Checkpoint.job_id+'/result.json')
 Write-MaintenanceState $path $Checkpoint
 Remove-Item -LiteralPath $checkpointPath -Force
}
function Recover-HPCheckpoint {
 $script:HPStage='recovery'
 $cp=Read-HPJSON $checkpointPath
 if($cp.kind -cne 'host-policy-v1' -or $cp.format -cne 'host-policy-v1' -or $cp.schema_version -ne 1 -or
    [string]$cp.job_id -cnotmatch '^[a-f0-9]{32}$' -or [string]$cp.draft_id -cnotmatch '^[a-f0-9]{32}$' -or
    $cp.was_running -isnot [bool] -or $cp.service_start -notin @(2,3) -or
    $cp.phase -cnotin @('prepared','stopping','stopped','replacing','candidate_written','start_intent','restoring','restore_start_intent')){throw 'Unsupported host-policy checkpoint; recovery held'}
 foreach($name in @('base_sha256','candidate_sha256','release_identity_sha256','environment_sha256','service_environment_sha256')){if([string]$cp.$name -cnotmatch '^[a-f0-9]{64}$'){throw 'Invalid checkpoint hash'}}
 if([string]$cp.expected_version -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$' -or [string]$cp.redis_configuration_version -cnotmatch '^[a-f0-9]{32}$'){throw 'Invalid checkpoint release or Redis identity'}
 $owned=Assert-HPOwnership $cp
 Set-HPHealthEndpoint
 $oldPID=Get-HPServicePID $owned.State
 Save-HPCheckpoint $cp 'restoring'
 Set-Service -Name $cp.service_name -StartupType Manual
 Stop-ManagedRuntime $layout $owned.State;Assert-HPClosed $owned.State $oldPID
 $owned=Assert-HPOwnership $cp
 if($owned.LiveHash -ceq $cp.candidate_sha256){Set-HPHost (Read-HPBytes (Join-Path $owned.Transaction 'before-host.json')) $cp.candidate_sha256 $cp.base_sha256}
 $redisID=Invoke-HPProof $owned.Release (Join-Path $layout.Shared 'host.json') $cp.base_sha256 -Preflight
 if($redisID -cne $cp.redis_configuration_version){throw 'Redis configuration changed; restored host remains stopped and recovery is held'}
 if($cp.was_running){
  Save-HPCheckpoint $cp 'restore_start_intent'
  Start-ManagedRuntime $layout $owned.State
  Confirm-NativeRunning $owned.State $owned.Release.Identity -RedisConfigurationID $redisID
  Assert-HPRunningProcess $owned.State
 }
 $null=Assert-HPOwnership $cp
 Restore-HPStartup $cp
 Complete-HPCheckpoint $cp 'recovered'
 return $cp
}

$workerLock=$null;$deploymentLock=$null;$checkpointCreated=$false;$exitCode=1
try{
 $HomeDir=[IO.Path]::GetFullPath($HomeDir).TrimEnd('\');Assert-HPPlainPath $HomeDir
 if(($JobID -and $JobID -cnotmatch '^[a-f0-9]{32}$') -or ($DraftID -and $DraftID -cnotmatch '^[a-f0-9]{32}$')){throw 'Invalid job or draft identifier'}
 $config=Read-HPJSON (Join-Path $HomeDir 'config.json')
 $layout=Get-DeploymentLayout $config.install_root
 foreach($path in @($layout.Root,$layout.Shared,$layout.State,$layout.Releases)){Assert-HPPlainPath $path;if(!(Test-Path -LiteralPath $path -PathType Container)){throw 'Installation layout is incomplete'}}
 $checkpointPath=Join-Path $HomeDir 'checkpoint.json'
 Assert-HPPlainPath (Join-Path $HomeDir 'worker.lock');Assert-HPPlainPath $layout.LockFile
 $workerLock=[IO.File]::Open((Join-Path $HomeDir 'worker.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
 $deploymentLock=Enter-DeploymentLock $layout
 $job=$null
 if($Mode -ne 'Validate'){
  if(!$JobID){throw 'A managed job is required'}
  $job=Read-HPJSON (Join-Path $HomeDir ('jobs/'+$JobID+'.json'))
  if($job.id -cne $JobID -or $job.maintenance -isnot [bool] -or !$job.maintenance){throw 'Explicit maintenance acknowledgement is required'}
  $expectedAction=if($Mode -eq 'Recover'){'recover'}else{'host-policy'}
  if($job.action -cne $expectedAction){throw 'Job action does not match worker mode'}
 }
 if($Mode -eq 'Recover'){
  $cp=Read-HPJSON $checkpointPath
  if($job.expected -cne $cp.expected_version){throw 'Recovery job expected version differs from checkpoint'}
  $recovered=Recover-HPCheckpoint
  [pscustomobject]@{status='recovered';draft_id=$recovered.draft_id;host_sha256=$recovered.base_sha256}|ConvertTo-Json -Compress
 }else{
  if(Test-Path -LiteralPath $checkpointPath){throw 'A maintenance checkpoint must be recovered first'}
  if($Mode -eq 'Apply'){
   if($DraftID -and $DraftID -cne $job.host_policy_draft){throw 'Job draft identity mismatch'}
   $DraftID=[string]$job.host_policy_draft
  }
  $draft=Read-HPDraft $DraftID -RequireValidated:($Mode -eq 'Apply');$meta=$draft.Metadata
  if($Mode -eq 'Apply' -and $job.expected -cne $meta.expected_version){throw 'Job expected version differs from draft'}
  $state=Read-DeploymentState $layout
  $release=Get-HPRelease $state $meta.expected_version $meta.release_identity_sha256
  $service=Get-HPService $state $release
  $script:HPStage='host-baseline'
  if((Get-HPHash (Join-Path $layout.Shared 'host.json')) -cne $meta.base_sha256){throw 'Live host configuration changed since draft creation'}
  $environmentSHA=Get-HPHash $layout.Environment
  $redisID=Invoke-HPProof $release $draft.Candidate $meta.candidate_sha256
  if($Mode -eq 'Validate'){
   [pscustomobject]@{status='validated';draft_id=$DraftID;candidate_sha256=$meta.candidate_sha256;redis_configuration_version=$redisID}|ConvertTo-Json -Compress
  }else{
   $script:HPStage='prepare-maintenance'
   Set-HPHealthEndpoint
   $status=[string](Get-Service -Name $state.service_name).Status
   if($status -cnotin @('Running','Stopped')){throw 'Service is changing state; retry after it settles'}
   $transaction=Join-Path $HomeDir ('host-policy/transactions/'+$JobID)
   Assert-HPPlainPath $transaction
   if(Test-Path -LiteralPath $transaction){throw 'Transaction directory already exists'}
   $null=New-Item -ItemType Directory -Path $transaction
   Write-HPBytes (Join-Path $transaction 'before-host.json') (Read-HPBytes $draft.Before)
   Write-HPBytes (Join-Path $transaction 'host.json') (Read-HPBytes $draft.Candidate)
   $cp=[pscustomobject]@{schema_version=1;kind='host-policy-v1';format='host-policy-v1';job_id=$JobID;draft_id=$DraftID;phase='prepared';expected_version=$meta.expected_version;release_identity_sha256=$meta.release_identity_sha256;base_sha256=$meta.base_sha256;candidate_sha256=$meta.candidate_sha256;environment_sha256=$environmentSHA;service_environment_sha256=$service.EnvironmentSHA;service_name=$state.service_name;service_start=$service.Start;service_delayed_start=$service.Delayed;was_running=($status -ceq 'Running');redis_configuration_version=$redisID;created=[DateTime]::UtcNow.ToString('o')}
   $null=Assert-HPOwnership $cp
   Save-HPCheckpoint $cp 'prepared';$checkpointCreated=$true
   $oldPID=Get-HPServicePID $state
   Save-HPCheckpoint $cp 'stopping'
   Set-Service -Name $state.service_name -StartupType Manual
   Stop-ManagedRuntime $layout $state;Assert-HPClosed $state $oldPID
   Save-HPCheckpoint $cp 'stopped'
   $owned=Assert-HPOwnership $cp
   if($owned.LiveHash -cne $cp.base_sha256){throw 'Host changed before candidate activation'}
   Save-HPCheckpoint $cp 'replacing'
   Set-HPHost (Read-HPBytes (Join-Path $transaction 'host.json')) $cp.base_sha256 $cp.candidate_sha256
   Save-HPCheckpoint $cp 'candidate_written'
   $checkedID=Invoke-HPProof $release (Join-Path $layout.Shared 'host.json') $cp.candidate_sha256 -Preflight
   if($checkedID -cne $redisID){throw 'Redis configuration changed during maintenance'}
   if($cp.was_running){
    Save-HPCheckpoint $cp 'start_intent'
    Start-ManagedRuntime $layout $state
    Confirm-NativeRunning $state $release.Identity -RedisConfigurationID $redisID
    Assert-HPRunningProcess $state
   }
   $null=Assert-HPOwnership $cp
   Restore-HPStartup $cp
   Complete-HPCheckpoint $cp 'applied';$checkpointCreated=$false
   [pscustomobject]@{status='applied';draft_id=$DraftID;host_sha256=$cp.candidate_sha256;service_running=$cp.was_running;redis_configuration_version=$redisID}|ConvertTo-Json -Compress
  }
 }
 $exitCode=0
}catch{
 # Even parser/tool exceptions can contain credential values. Publish only a
 # fixed stage and state; raw exception messages are not operational evidence.
 $failedStage=$script:HPStage;$restored=$false
 if($checkpointCreated){try{$null=Recover-HPCheckpoint;$restored=$true}catch{}}
 $held=$false;if(Get-Variable checkpointPath -ErrorAction SilentlyContinue){$held=Test-Path -LiteralPath $checkpointPath}
 [pscustomobject]@{status='error';code='host_policy_failed';stage=$failedStage;restored=$restored;checkpoint_held=$held;error='Host policy operation failed. Inspect the named stage and resolve any held maintenance checkpoint before retrying.'}|ConvertTo-Json -Compress
}finally{
 if($null -ne $deploymentLock){$deploymentLock.Dispose()};if($null -ne $workerLock){$workerLock.Dispose()}
}
exit $exitCode
