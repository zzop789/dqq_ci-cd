# Local maintenance primitives. No service/network adapter or production
# activation entry is provided here. Callers must supply verified observations.
. (Join-Path $PSScriptRoot 'native-release.ps1')

function Get-MaintenanceTree([string]$Root,[switch]$ExcludeLogs,[switch]$ExcludeNativeData) {
 $rootPath=[IO.Path]::GetFullPath($Root).TrimEnd('\')
 $queue=New-Object 'Collections.Generic.Queue[string]';$queue.Enqueue($rootPath)
 $entries=@()
 while($queue.Count){
  $dir=$queue.Dequeue();$info=Get-Item -LiteralPath $dir -Force
  if($info.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Reparse points are not allowed in maintenance snapshots'}
  foreach($item in Get-ChildItem -LiteralPath $dir -Force){
   if($ExcludeLogs -and $dir -eq $rootPath -and $item.Name -ieq 'logs'){continue}
   # Skip the root entry before inspecting links or descending into historical data.
   if($ExcludeNativeData -and $dir -eq $rootPath -and $item.Name -ieq 'native-data'){continue}
   if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Reparse points are not allowed in maintenance snapshots'}
   $relative=$item.FullName.Substring($rootPath.Length+1).Replace('\','/')
   if($item.PSIsContainer){$entries+= [ordered]@{path=$relative;kind='directory'};$queue.Enqueue($item.FullName)}
   else{$entries+=[ordered]@{path=$relative;kind='file';length=$item.Length;sha256=(Get-NativeReleaseHash $item.FullName)}}
  }
 }
 return @($entries|Sort-Object {$_.path})
}
function Get-NativeStateTreeJSON([string]$Root,[switch]$ExcludeNativeData) {
 return ConvertTo-Json -InputObject @(Get-MaintenanceTree $Root -ExcludeLogs -ExcludeNativeData:$ExcludeNativeData) -Depth 5 -Compress
}
function Copy-NativeStateTree([string]$Source,[string]$Destination,[switch]$ExcludeNativeData) {
 if(Test-Path -LiteralPath $Destination){throw 'State snapshot already exists'}
 $before=Get-NativeStateTreeJSON $Source -ExcludeNativeData:$ExcludeNativeData
 [IO.Directory]::CreateDirectory($Destination)|Out-Null
 foreach($item in Get-ChildItem -LiteralPath $Source -Force){
  if($item.Name -ieq 'logs'){continue}
  if($ExcludeNativeData -and $item.Name -ieq 'native-data'){continue}
  Copy-Item -LiteralPath $item.FullName -Destination $Destination -Recurse -Force
 }
 if((Get-NativeStateTreeJSON $Source -ExcludeNativeData:$ExcludeNativeData) -cne $before -or (Get-NativeStateTreeJSON $Destination -ExcludeNativeData:$ExcludeNativeData) -cne $before){throw 'State changed during snapshot'}
 return $before
}
# These are the only files a v2 maintenance transaction may replace. Persistent
# data and logs keep their directory identity for the lifetime of the server.
$script:NativeSwitchFiles=@('.env','host.json','gameplay.lua','economy.lua','RULES.md')
function Assert-NativeConfigTransition([string]$Shared,[string]$OldJSON,[string]$NewJSON,[switch]$ExcludeNativeData) {
 $old=@{};$new=@{};$live=@{}
 foreach($e in (ConvertFrom-Json $OldJSON)){$old[$e.path]=$e}
 foreach($e in (ConvertFrom-Json $NewJSON)){$new[$e.path]=$e}
 foreach($e in @(Get-MaintenanceTree $Shared -ExcludeLogs -ExcludeNativeData:$ExcludeNativeData)){$live[$e.path]=$e}
 foreach($path in @(@($old.Keys)+@($new.Keys)+@($live.Keys)|Select-Object -Unique)){
  $actual=if($live.ContainsKey($path)){$live[$path]|ConvertTo-Json -Compress}else{''}
  $before=if($old.ContainsKey($path)){$old[$path]|ConvertTo-Json -Compress}else{''}
  $after=if($new.ContainsKey($path)){$new[$path]|ConvertTo-Json -Compress}else{''}
  if($path -in $script:NativeSwitchFiles){
   if($actual -cne $before -and $actual -cne $after){throw ('Config transition conflict: '+$path)}
  }elseif($before -cne $after -or $actual -cne $before){throw ('Persistent state changed: '+$path)}
 }
}
function Set-NativeConfigFiles([string]$Source,[string]$Shared,[string]$Transaction) {
 foreach($name in $script:NativeSwitchFiles){
  $from=Join-Path $Source $name;$target=Join-Path $Shared $name
  if(Test-Path -LiteralPath $from){
   if((Test-Path -LiteralPath $target) -and (Get-NativeReleaseHash $from) -ceq (Get-NativeReleaseHash $target)){continue}
   $temp=Join-Path $Transaction ('config-write-'+[guid]::NewGuid().ToString('N'))
   [IO.File]::Copy($from,$temp,$false)
   if(Test-Path -LiteralPath $target){[IO.File]::Replace($temp,$target,($temp+'.previous'))}else{[IO.File]::Move($temp,$target)}
  }elseif(Test-Path -LiteralPath $target){
   # Only rollback can remove a newly introduced selector. Caller has checked
   # that every live byte is exactly the old or candidate value.
   [IO.File]::Delete($target)
  }
 }
}
function Get-MaintenanceTreeJSON([string]$Root) {
 return ConvertTo-Json -InputObject @(Get-MaintenanceTree $Root) -Depth 5 -Compress
}
function Move-MaintenanceDirectory([string]$Source,[string]$Destination) {
 # Directory.Move performs a same-volume rename. PowerShell Move-Item may
 # recursively move children, leaving a split tree when a file is locked.
 Assert-MaintenanceSeparate @($Source,$Destination)
 if(Test-Path -LiteralPath $Destination){throw 'Rename destination already exists'}
 if([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Source)) -ine [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Destination))){throw 'Maintenance rename must remain on one volume'}
 $null=Get-MaintenanceTreeJSON $Source
 $deadline=[DateTime]::UtcNow.AddSeconds(15)
 while($true){
  try{[IO.Directory]::Move([IO.Path]::GetFullPath($Source),[IO.Path]::GetFullPath($Destination));return}
  catch{
   $cause=$_.Exception.GetBaseException();$code=$cause.HResult -band 65535
   # Only retry a failed atomic rename with the original source still present.
   # No copy/delete fallback, no ACL changes, and no termination of lock owners.
   if($code -notin @(5,32,33) -or [DateTime]::UtcNow -ge $deadline -or !(Test-Path -LiteralPath $Source) -or (Test-Path -LiteralPath $Destination)){
    throw ('Atomic directory rename failed: source='+$Source+' destination='+$Destination+' win32='+$code+' reason='+$cause.Message)
   }
   Write-Host ('DIRECTORY RENAME WAIT: win32='+$code+' source='+$Source)
   Start-Sleep -Milliseconds 500
  }
 }
}
function Restore-SplitMaintenanceTree([string]$Live,[string]$Retired,[string]$ExpectedJSON) {
 # Repair only the exact union of the recorded old tree. Never overwrite a
 # differing file, accept new files, or infer which copy is newer.
 Assert-MaintenanceSeparate @($Live,$Retired)
 $expected=ConvertFrom-Json -InputObject $ExpectedJSON;$index=@{}
 foreach($entry in $expected){$index[$entry.path]=$entry}
 $seen=@{}
 foreach($root in @($Live,$Retired)){
  foreach($entry in @(Get-MaintenanceTree $root)){
   if(!$index.ContainsKey($entry.path)){throw ('Unexpected split-state path: '+$entry.path)}
   $want=$index[$entry.path]
   if($entry.kind -cne $want.kind){throw ('Split-state type differs: '+$entry.path)}
   if($entry.kind -eq 'file' -and ($entry.length -ne $want.length -or $entry.sha256 -cne $want.sha256)){throw ('Split-state content differs: '+$entry.path)}
   $seen[$entry.path]=$true
  }
 }
 if($seen.Count -ne $index.Count){throw 'Split-state union is incomplete'}
 foreach($entry in $expected){
  $target=Join-Path $Live $entry.path
  if(Test-Path -LiteralPath $target){continue}
  if($entry.kind -eq 'directory'){[IO.Directory]::CreateDirectory($target)|Out-Null}
  else{[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target))|Out-Null;[IO.File]::Copy((Join-Path $Retired $entry.path),$target,$false)}
 }
 if((Get-MaintenanceTreeJSON $Live) -cne $ExpectedJSON){throw 'Reassembled old state verification failed'}
 # Retired remains evidence; a subsequent recovery is idempotent.
}
function Write-MaintenanceState([string]$Path,$Value) {
 $temp=$Path+'.tmp-'+[guid]::NewGuid().ToString('N')
 $bytes=[Text.Encoding]::UTF8.GetBytes(($Value|ConvertTo-Json -Depth 12))
 $stream=[IO.File]::Open($temp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write)
 try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
 if(Test-Path -LiteralPath $Path){[IO.File]::Replace($temp,$Path,$Path+'.previous')}else{[IO.File]::Move($temp,$Path)}
}
function Assert-MaintenanceClosed([scriptblock]$Observe) {
 $status=& $Observe
 foreach($field in @('runtime_stopped','ingress_closed','confirmed_writes_quiescent')){if($status.$field -isnot [bool]){throw 'Maintenance observations must be explicit booleans'}}
 if($status.runtime_stopped -cne $true -or $status.ingress_closed -cne $true -or $status.confirmed_writes_quiescent -cne $true){throw 'Maintenance requires stopped runtime, closed ingress and quiescent confirmed writes'}
}
function Assert-MaintenanceSeparate([string[]]$Paths) {
 $full=@($Paths|ForEach-Object {[IO.Path]::GetFullPath($_).TrimEnd('\')})
 for($i=0;$i -lt $full.Count;$i++){for($j=$i+1;$j -lt $full.Count;$j++){
  if($full[$i].Equals($full[$j],[StringComparison]::OrdinalIgnoreCase) -or $full[$i].StartsWith($full[$j]+'\',[StringComparison]::OrdinalIgnoreCase) -or $full[$j].StartsWith($full[$i]+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Maintenance roots must be disjoint'}
 }}
}
function Copy-MaintenanceTree([string]$Source,[string]$Destination) {
 if(Test-Path -LiteralPath $Destination){throw 'Snapshot destination already exists'}
 $before=Get-MaintenanceTreeJSON $Source
 New-Item -ItemType Directory -Path $Destination|Out-Null
 foreach($item in Get-ChildItem -LiteralPath $Source -Force){Copy-Item -LiteralPath $item.FullName -Destination $Destination -Recurse -Force}
 if((Get-MaintenanceTreeJSON $Source) -cne $before -or (Get-MaintenanceTreeJSON $Destination) -cne $before){throw 'Source changed or snapshot copy is incomplete'}
 return $before
}
function New-NativeMaintenanceSnapshot {
 param([string]$ConfigRoot,[string]$ReleaseRoot,[string]$Destination,[string]$ExpectedReleaseIdentitySHA256,[scriptblock]$Observe)
 Assert-MaintenanceSeparate @($ConfigRoot,$ReleaseRoot,$Destination)
 Assert-MaintenanceClosed $Observe
 if(Test-Path -LiteralPath $Destination){throw 'Maintenance transaction already exists'}
 foreach($name in @('host.json','gameplay.lua','economy.lua','native-data')){if(!(Test-Path -LiteralPath (Join-Path $ConfigRoot $name))){throw "Missing complete active state: $name"}}
 $identity=Join-Path $ReleaseRoot 'RELEASE_IDENTITY.json'
 if((Get-NativeReleaseHash $identity) -cne $ExpectedReleaseIdentitySHA256){throw 'Old release identity changed'}
 # Reject reparse points before creating any transaction output.
 $configBefore=Get-MaintenanceTreeJSON $ConfigRoot;$releaseBefore=Get-MaintenanceTreeJSON $ReleaseRoot
 New-Item -ItemType Directory -Path $Destination|Out-Null
 $state=[ordered]@{schema_version=1;phase='copying';traffic_ever_opened=$false;live_data_touched=$false;release_identity_sha256=$ExpectedReleaseIdentitySHA256;config_root=[IO.Path]::GetFullPath($ConfigRoot);release_root=[IO.Path]::GetFullPath($ReleaseRoot);config_tree=$configBefore;release_tree=$releaseBefore}
 $journal=Join-Path $Destination 'transaction.json';Write-MaintenanceState $journal $state
 try{
  $null=Copy-MaintenanceTree $ConfigRoot (Join-Path $Destination 'backup-config')
  $null=Copy-MaintenanceTree $ReleaseRoot (Join-Path $Destination 'backup-release')
  Assert-MaintenanceClosed $Observe
  if((Get-MaintenanceTreeJSON $ConfigRoot) -cne $configBefore -or (Get-MaintenanceTreeJSON $ReleaseRoot) -cne $releaseBefore){throw 'State changed during consistent backup'}
  $state.phase='snapshot_complete';Write-MaintenanceState $journal $state
 }catch{$state.phase='manual_hold';$state['error']=$_.Exception.Message;Write-MaintenanceState $journal $state;throw}
 return $state
}
function Invoke-NativeMaintenanceRehearsal {
 param([string]$TransactionRoot,[string]$ExpectedDLLSHA256,[string]$ExpectedBuildID,[scriptblock]$Observe,[scriptblock]$PreflightCopy)
 $lock=[IO.File]::Open((Join-Path $TransactionRoot 'transaction.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
 try{return Invoke-NativeMaintenanceRehearsalLocked @PSBoundParameters}finally{$lock.Dispose()}
}
function Invoke-NativeMaintenanceRehearsalLocked {
 param([string]$TransactionRoot,[string]$ExpectedDLLSHA256,[string]$ExpectedBuildID,[scriptblock]$Observe,[scriptblock]$PreflightCopy)
 if($ExpectedDLLSHA256 -cnotmatch '^[a-f0-9]{64}$' -or $ExpectedBuildID -cnotmatch '^[a-f0-9]{64}$'){throw 'Explicit verified target DLL identity is required'}
 $journal=Join-Path $TransactionRoot 'transaction.json';$state=Get-Content -LiteralPath $journal -Raw|ConvertFrom-Json
 if($state.phase -ne 'snapshot_complete'){throw 'Complete snapshot required; interrupted trials must be reviewed'}
 Assert-MaintenanceClosed $Observe
 if((Get-MaintenanceTreeJSON (Join-Path $TransactionRoot 'backup-config')) -cne $state.config_tree -or (Get-MaintenanceTreeJSON (Join-Path $TransactionRoot 'backup-release')) -cne $state.release_tree){throw 'Immutable backup changed'}
 $working=Join-Path $TransactionRoot 'rehearsal-config'
 $null=Copy-MaintenanceTree (Join-Path $TransactionRoot 'backup-config') $working
 $state.phase='rehearsal_running';Write-MaintenanceState $journal $state
 try{
  # The adapter receives the working copy only, never the active data path.
  $proof=& $PreflightCopy $working
  if($proof.preflight -cne 'passed' -or $proof.listener_started -cne $false -or $proof.gameplay_commands_executed -ne 0){throw 'Recovery rehearsal did not provide a non-serving preflight proof'}
  if($proof.engine -cne 'cpp' -or $proof.production_gameplay -cne $true -or $proof.dll_sha256 -cne $ExpectedDLLSHA256 -or $proof.module.build_id -cne $ExpectedBuildID -or $proof.transport_profile -cne 'warcraft-round-v1'){throw 'Recovery proof does not match verified target identity'}
  if(![IO.Path]::GetFullPath($proof.data_directory).Equals([IO.Path]::GetFullPath((Join-Path $working 'native-data')),[StringComparison]::OrdinalIgnoreCase)){throw 'Recovery preflight did not use the working-copy data directory'}
  Assert-MaintenanceClosed $Observe
  if((Get-MaintenanceTreeJSON $state.config_root) -cne $state.config_tree -or (Get-MaintenanceTreeJSON $state.release_root) -cne $state.release_tree){throw 'Active state changed during rehearsal'}
  if((Get-MaintenanceTreeJSON (Join-Path $TransactionRoot 'backup-config')) -cne $state.config_tree -or (Get-MaintenanceTreeJSON (Join-Path $TransactionRoot 'backup-release')) -cne $state.release_tree){throw 'Backup changed during rehearsal'}
  $state|Add-Member -NotePropertyName rehearsal_after -NotePropertyValue (Get-MaintenanceTreeJSON $working)
  $state|Add-Member -NotePropertyName recovery_proof -NotePropertyValue $proof
  $state.phase='rehearsal_passed_not_activated';Write-MaintenanceState $journal $state
 }catch{$state.phase='manual_hold';$state|Add-Member -NotePropertyName error -NotePropertyValue $_.Exception.Message -Force;Write-MaintenanceState $journal $state;throw}
 return $state
}
function Assert-NativeAutomaticRollbackAllowed {
 param($State,$Observation)
 if($State.traffic_ever_opened -isnot [bool]){throw 'Traffic admission history is unknown'}
 foreach($field in @('ingress_never_opened','no_new_confirmed_writes','runtime_stopped','full_state_restore_verified')){if($Observation.$field -isnot [bool]){throw 'Rollback observations must be explicit booleans'}}
 # Unknown/crashed admission state is treated as possibly serving traffic.
 if($State.traffic_ever_opened -cne $false -or $Observation.ingress_never_opened -cne $true -or $Observation.no_new_confirmed_writes -cne $true -or $Observation.runtime_stopped -cne $true -or $Observation.full_state_restore_verified -cne $true){throw 'Automatic rollback forbidden: complete old state and no new confirmed writes must be proven'}
}
function New-NativeRollbackCandidate {
 param([string]$TransactionRoot,[string]$Destination,$Observation)
 $lock=[IO.File]::Open((Join-Path $TransactionRoot 'transaction.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
 try{New-NativeRollbackCandidateLocked @PSBoundParameters}finally{$lock.Dispose()}
}
function New-NativeRollbackCandidateLocked {
 param([string]$TransactionRoot,[string]$Destination,$Observation)
 $state=Get-Content -LiteralPath (Join-Path $TransactionRoot 'transaction.json') -Raw|ConvertFrom-Json
 Assert-NativeAutomaticRollbackAllowed $state $Observation
 Assert-MaintenanceSeparate @($TransactionRoot,$Destination,$state.config_root,$state.release_root)
 if(Test-Path -LiteralPath $Destination){throw 'Rollback candidate must not replace existing state'}
 if((Get-MaintenanceTreeJSON (Join-Path $TransactionRoot 'backup-config')) -cne $state.config_tree -or (Get-MaintenanceTreeJSON (Join-Path $TransactionRoot 'backup-release')) -cne $state.release_tree){throw 'Rollback backup identity mismatch'}
 New-Item -ItemType Directory -Path $Destination|Out-Null
 $null=Copy-MaintenanceTree (Join-Path $TransactionRoot 'backup-config') (Join-Path $Destination 'config')
 $null=Copy-MaintenanceTree (Join-Path $TransactionRoot 'backup-release') (Join-Path $Destination 'release')
 Write-MaintenanceState (Join-Path $Destination 'rollback-candidate.json') ([ordered]@{phase='complete_old_state_candidate_not_activated';old_release_identity=$state.release_identity_sha256;config_tree=$state.config_tree;release_tree=$state.release_tree})
 # Deliberately no move onto active paths and no service start. A production
 # adapter must establish traffic isolation and verify recovery independently.
}
