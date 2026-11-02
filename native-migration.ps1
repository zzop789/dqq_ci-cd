# Explicit offline data-generation migration. Ordinary package jobs never enter here.
. (Join-Path $PSScriptRoot 'native-worker.ps1')
function Get-MigrationConfigTree([string]$Root){
 return ConvertTo-Json -InputObject @(Get-MaintenanceTree $Root -ExcludeLogs|Where-Object {$_.path -cne 'native-data' -and !$_.path.StartsWith('native-data/')}) -Depth 5 -Compress
}
function Assert-MigrationConfigTransition([string]$Root,[string]$Old,[string]$New){
 # Reuse the config-only compare on a temporary view of the tree, never ignore
 # unapproved files outside native-data. Data is independently checked below.
 $oldMap=@{};$newMap=@{};$live=@{}
 foreach($e in (ConvertFrom-Json -InputObject $Old)){$oldMap[$e.path]=($e|ConvertTo-Json -Compress)}
 foreach($e in (ConvertFrom-Json -InputObject $New)){$newMap[$e.path]=($e|ConvertTo-Json -Compress)}
 foreach($e in (ConvertFrom-Json -InputObject (Get-MigrationConfigTree $Root))){$live[$e.path]=($e|ConvertTo-Json -Compress)}
 foreach($key in @(@($oldMap.Keys)+@($newMap.Keys)+@($live.Keys)|Select-Object -Unique)){
  if($key -in $script:NativeSwitchFiles){if($live[$key] -cne $oldMap[$key] -and $live[$key] -cne $newMap[$key]){throw ('Migration config conflict: '+$key)}}
  elseif($oldMap[$key] -cne $newMap[$key] -or $live[$key] -cne $oldMap[$key]){throw ('Migration unrelated state changed: '+$key)}
 }
}
function Assert-MigrationTree([string]$Path,[string]$Expected){
 if(!(Test-Path -LiteralPath $Path) -or (Get-NativeStateTreeJSON $Path) -cne $Expected){throw ('Migration tree conflict: '+$Path)}
}
function Recover-NativeMigration {
 $cp=Get-Content -LiteralPath $checkpointPath -Raw -Encoding UTF8|ConvertFrom-Json
 if($cp.kind -cne 'native-migration-v1' -or $cp.may_have_served -ne $false){throw 'Migration recovery requires offline checkpoint; never restore old data after serving'}
 Assert-ChildPath $layout.Root $cp.transaction
 # Never stop an unexpectedly running service and pretend that it had no writes.
 Assert-NativeStopped $cp.old_state
 # Resolve the immutable release inside the real releases boundary before any
 # data/config restoration. backup-current is evidence, never a switch target.
 $oldRelease=Join-Path $layout.Releases ([string]$cp.old_state.current_version)
 Assert-ChildPath -ParentPath $layout.Releases -ChildPath $oldRelease
 $backupRelease=Join-Path $cp.transaction 'backup-current'
 Test-ReleaseChecksums -ReleaseRoot $oldRelease
 Test-ReleaseChecksums -ReleaseRoot $backupRelease
 $oldIdentity=Test-NativeReleaseIdentity $oldRelease -AllowHistorical
 $backupIdentity=Test-NativeReleaseIdentity $backupRelease -AllowHistorical
 if((Get-MaintenanceTreeJSON $oldRelease) -cne (Get-MaintenanceTreeJSON $backupRelease)){throw 'Original immutable release differs from recovery backup'}
 $backup=Join-Path $cp.transaction 'backup-shared';$archive=Join-Path $cp.transaction 'archived-native-data';$live=Join-Path $layout.Shared 'native-data'
 Assert-MigrationTree $backup $cp.source_tree
 Assert-MigrationConfigTransition $layout.Shared $cp.old_config_tree $cp.new_config_tree
 if(Test-Path -LiteralPath $archive){
  Assert-MigrationTree $archive $cp.old_data_tree
  if(Test-Path -LiteralPath $live){
   Assert-MigrationTree $live $cp.new_data_tree
   $retained=Join-Path $cp.transaction 'retained-new-native-data'
   if(Test-Path -LiteralPath $retained){throw 'Retained new generation already exists; refusing overwrite'}
   [IO.Directory]::Move($live,$retained)
  }
  [IO.Directory]::Move($archive,$live)
 }else{Assert-MigrationTree $live $cp.old_data_tree}
 Set-NativeConfigFiles $backup $layout.Shared $cp.transaction
 Assert-MigrationTree $layout.Shared $cp.source_tree
 Set-CurrentFromRelease -Layout $layout -ReleasePath $oldRelease
 Save-DeploymentState -Layout $layout -State $cp.old_state
 # Offline migration never starts services, including recovery.
 Complete-NativeCheckpoint $cp
 Write-Host 'MIGRATION RECOVERED: original generation/config/release retained; service remains stopped'
}
function Invoke-NativeMigration([string]$Release){
 if($job.migration -cnotmatch '^[a-f0-9]{64}$' -or !$job.maintenance){throw 'Explicit migration job required'}
 $path=Join-Path $HomeDir ('migrations/'+$job.migration+'.json')
 if((Get-NativeReleaseHash $path) -cne $job.migration){throw 'Migration import hash changed'}
 $request=Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json
 if($request.schema_version -ne 1 -or $request.artifact_sha256 -cne $job.artifact -or $request.ingress_closed -ne $true -or $request.session_rejoin_approved -ne $true -or !$request.approval_ref){throw 'Migration target/approval mismatch'}
 if((Get-NativeReleaseHashOfBytes ([Convert]::FromBase64String($request.approval_document))) -cne $request.approval_sha256){throw 'Approval document hash mismatch'}
 $state=Read-DeploymentState -Layout $layout;Assert-NativeStopped $state
 $service=Get-Service -Name $state.service_name
 if([string]$service.StartType -cne 'Manual'){throw 'Migration requires stopped Manual service and closed ingress'}
 $identity=Test-NativeReleaseIdentity $Release
 if(Test-NativeEphemeralIdentity $identity){throw 'Ephemeral packages start empty and do not migrate historical room data. Use ordinary package deployment; historical files remain untouched.'}
 $audit=Get-Content -LiteralPath (Join-Path $Release 'verification.json') -Raw -Encoding UTF8|ConvertFrom-Json
 Assert-NativeCurrentContractAudit $audit
 $oldIdentity=Test-NativeReleaseIdentity $layout.Current -AllowHistorical
 if($oldIdentity.dll_sha256 -cne $request.old_dll_sha256){throw 'Old DLL identity changed'}
 if((Get-NativeStateTreeJSON $layout.Shared) -cne $request.source_tree){throw 'Reviewed server state changed; regenerate candidate and approval'}
 $transaction=Join-Path $layout.Root ('migration-'+$JobID);Assert-ChildPath $layout.Root $transaction
 if(Test-Path -LiteralPath $transaction){throw 'Migration transaction already exists'}
 [IO.Directory]::CreateDirectory($transaction)|Out-Null
 [IO.File]::Copy($path,(Join-Path $transaction 'approved-request.json'),$false)
 $backup=Join-Path $transaction 'backup-shared';$null=Copy-NativeStateTree $layout.Shared $backup
 if((Get-NativeStateTreeJSON $backup) -cne $request.source_tree){throw 'Backup changed from approved source'}
 $null=Copy-MaintenanceTree $layout.Current (Join-Path $transaction 'backup-current')
 # Run the hash-bound old DLL against an immutable backup; no journal.Open.
 $terminal=(Invoke-NativeTool (Join-Path $Release 'nativearchiveaudit.exe') @('-data',(Join-Path $backup 'native-data'),'-dll',(Join-Path $transaction 'backup-current/gamecore.dll'),'-expected-dll-sha256',$request.old_dll_sha256,'-expected-source-sha256',$request.source_data_sha256) @{})|ConvertFrom-Json
 if($terminal.status -cne 'all_terminal' -or $terminal.source_sha256 -cne $request.source_data_sha256 -or $terminal.dll_sha256 -cne $request.old_dll_sha256){throw 'Terminal proof mismatch'}
 Write-MaintenanceState (Join-Path $transaction 'terminal-proof.json') $terminal
 $candidate=Join-Path $transaction 'candidate-shared';[IO.Directory]::CreateDirectory($candidate)|Out-Null
 foreach($entry in Get-ChildItem -LiteralPath $backup -Force){if($entry.Name -ine 'native-data'){Copy-Item -LiteralPath $entry.FullName -Destination $candidate -Recurse}}
 foreach($name in $script:NativeConfigNames){
  $sourceHash=Get-NativeReleaseHash (Join-Path $backup $name)
  if($request.report.sources_sha256.$name -cne $sourceHash){throw ('Candidate source mismatch: '+$name)}
  $bytes=[Convert]::FromBase64String($request.files.$name)
  if((Get-NativeReleaseHashOfBytes $bytes) -cne $request.report.files_sha256.$name){throw ('Candidate hash mismatch: '+$name)}
  [IO.File]::WriteAllBytes((Join-Path $candidate $name),$bytes)
 }
 if($request.report.schema_version -ne 2 -or $request.report.status -cne 'candidate_only_not_activated'){throw 'Unsupported candidate report'}
 Set-NativeEnvironment $candidate $identity
 [IO.Directory]::CreateDirectory((Join-Path $candidate 'native-data'))|Out-Null
 $proof=Test-NativeWorkingCopy $Release $candidate $identity
 Write-MaintenanceState (Join-Path $transaction 'new-generation-proof.json') $proof
 $cp=[ordered]@{kind='native-migration-v1';phase='prepared';transaction=$transaction;old_state=$state;may_have_served=$false;source_tree=$request.source_tree;old_config_tree=(Get-MigrationConfigTree $backup);new_config_tree=(Get-MigrationConfigTree $candidate);old_data_tree=(Get-NativeStateTreeJSON (Join-Path $backup 'native-data'));new_data_tree=(Get-NativeStateTreeJSON (Join-Path $candidate 'native-data'));migration_sha256=$job.migration;target_version=$identity.version;target_dll=$identity.dll_sha256}
 Assert-NativeStopped $state
 if((Get-NativeStateTreeJSON $layout.Shared) -cne $cp.source_tree){throw 'State changed after validation'}
 Write-MaintenanceState $checkpointPath $cp
 try{
  $cp.phase='archive_intent';Write-MaintenanceState $checkpointPath $cp
  [IO.Directory]::Move((Join-Path $layout.Shared 'native-data'),(Join-Path $transaction 'archived-native-data'))
  $cp.phase='install_generation_intent';Write-MaintenanceState $checkpointPath $cp
  [IO.Directory]::Move((Join-Path $candidate 'native-data'),(Join-Path $layout.Shared 'native-data'))
  $cp.phase='config_intent';Write-MaintenanceState $checkpointPath $cp
  Assert-MigrationConfigTransition $layout.Shared $cp.old_config_tree $cp.new_config_tree
  Set-NativeConfigFiles $candidate $layout.Shared $transaction
  if((Get-MigrationConfigTree $layout.Shared) -cne $cp.new_config_tree){throw 'Installed config mismatch'}
  Assert-MigrationTree (Join-Path $layout.Shared 'native-data') $cp.new_data_tree
  Set-CurrentFromRelease -Layout $layout -ReleasePath $Release
  $next=($state|ConvertTo-Json -Depth 10)|ConvertFrom-Json
  $next.previous_version=$state.current_version;$next.current_version=$identity.version;$next.deployed_at_utc=[DateTime]::UtcNow.ToString('o')
  Save-DeploymentState -Layout $layout -State $next
  Complete-NativeCheckpoint $cp
  Write-Host 'MIGRATION INSTALLED OFFLINE: old generation archived; game remains stopped. Start and reopen ingress only after separate acceptance.'
 }catch{Write-Host 'MIGRATION HELD: preserve checkpoint and archives; use recovery while service is stopped';throw}
}
