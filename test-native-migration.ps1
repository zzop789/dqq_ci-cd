# Explicit opt-in regression; never sourced by normal deployment/build.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'native-migration.ps1')
. (Join-Path $PSScriptRoot 'deploy/common.ps1')
function Assert-NativeStopped($State){if($script:Running){throw 'service running'}}
function Test-ReleaseChecksums {param($ReleaseRoot)}
function Test-NativeReleaseIdentity {param($PackageRoot,[switch]$AllowHistorical);return @{}}
function Save-DeploymentState {param($Layout,$State)}
function Start-ManagedRuntime {throw 'Migration recovery must never start a service'}
function Start-NativeRuntime {throw 'Migration recovery must never enter the native SCM adapter'}
$root=Join-Path ([IO.Path]::GetTempPath()) ('native-migration-regression-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root)|Out-Null
try{
 foreach($stage in @('prepared','archived','installed','config-partial')){
  $case=Join-Path $root $stage;$layout=@{Root=$case;Shared=(Join-Path $case 'shared');Current=(Join-Path $case 'current');Releases=(Join-Path $case 'releases')}
  $transaction=Join-Path $case 'transaction';$backup=Join-Path $transaction 'backup-shared';$candidate=Join-Path $transaction 'candidate';$checkpointPath=Join-Path $case 'checkpoint.json'
  foreach($dir in @($layout.Shared,(Join-Path $layout.Shared 'native-data'),(Join-Path $layout.Shared 'logs'),$transaction)){[IO.Directory]::CreateDirectory($dir)|Out-Null}
  [IO.File]::WriteAllText((Join-Path $layout.Shared 'host.json'),'old')
  [IO.File]::WriteAllText((Join-Path $layout.Shared 'native-data/rooms.wal'),'old WAL')
  $old=Copy-NativeStateTree $layout.Shared $backup;$null=Copy-NativeStateTree $layout.Shared $candidate
  [IO.File]::WriteAllText((Join-Path $candidate 'host.json'),'new')
  [IO.File]::WriteAllText((Join-Path $candidate 'native-data/rooms.wal'),'new WAL')
  $oldRelease=Join-Path $layout.Releases 'old';[IO.Directory]::CreateDirectory($oldRelease)|Out-Null
  [IO.File]::WriteAllText((Join-Path $oldRelease 'server.exe'),'old executable fixture')
  $null=Copy-MaintenanceTree $oldRelease (Join-Path $transaction 'backup-current')
  $cp=@{kind='native-migration-v1';phase=$stage;transaction=$transaction;old_state=@{current_version='old'};may_have_served=$false;source_tree=$old;old_config_tree=(Get-MigrationConfigTree $backup);new_config_tree=(Get-MigrationConfigTree $candidate);old_data_tree=(Get-NativeStateTreeJSON (Join-Path $backup 'native-data'));new_data_tree=(Get-NativeStateTreeJSON (Join-Path $candidate 'native-data'))}
  Write-MaintenanceState $checkpointPath $cp
  # Immutable release mismatch must be rejected before any old data/config move.
  [IO.File]::WriteAllText((Join-Path $oldRelease 'server.exe'),'unexpected executable')
  $sourceBeforeConflict=Get-NativeStateTreeJSON $layout.Shared
  $script:Running=$false;$conflictRejected=$false
  try{Recover-NativeMigration}catch{$conflictRejected=$true}
  if(!$conflictRejected -or (Get-NativeStateTreeJSON $layout.Shared) -cne $sourceBeforeConflict){throw 'Release mismatch was not rejected before mutation'}
  [IO.File]::WriteAllText((Join-Path $oldRelease 'server.exe'),'old executable fixture')
  if($stage -ne 'prepared'){[IO.Directory]::Move((Join-Path $layout.Shared 'native-data'),(Join-Path $transaction 'archived-native-data'))}
  if($stage -in @('installed','config-partial')){[IO.Directory]::Move((Join-Path $candidate 'native-data'),(Join-Path $layout.Shared 'native-data'))}
  if($stage -eq 'config-partial'){[IO.File]::WriteAllText((Join-Path $layout.Shared 'host.json'),'new')}
  $script:Running=$true;$rejected=$false;try{Recover-NativeMigration}catch{$rejected=$true};if(!$rejected){throw 'Running service accepted'}
  $script:Running=$false
  $log=[IO.File]::Open((Join-Path $layout.Shared 'logs/held.log'),'OpenOrCreate','ReadWrite','None')
  try{Recover-NativeMigration}finally{$log.Dispose()}
  if((Get-NativeStateTreeJSON $layout.Shared) -cne $old){throw ('Old state not restored: '+$stage)}
  if(Test-Path -LiteralPath $checkpointPath){throw 'Checkpoint not completed'}
  if([IO.File]::ReadAllText((Join-Path $layout.Current 'server.exe')) -cne 'old executable fixture'){throw 'Actual release boundary/switch did not restore old executable'}
 }
 Write-Host 'Offline migration recovery regressions passed'
}finally{
 $resolved=[IO.Path]::GetFullPath($root);$expected=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
 if(!$resolved.StartsWith($expected,[StringComparison]::OrdinalIgnoreCase) -or !(Split-Path $resolved -Leaf).StartsWith('native-migration-regression-')){throw 'Unsafe test cleanup'}
 Remove-Item -LiteralPath $resolved -Recurse -Force
}
