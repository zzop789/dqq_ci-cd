# Explicit opt-in regression. No service, registry, HTTP, DLL or host is used.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'deploy/common.ps1')
. (Join-Path $PSScriptRoot 'native-worker.ps1')

# This test isolates recovery ownership; release byte validation is covered by
# the native release/package tests. Keep the real recovery and ownership code.
function Test-NativeReleaseIdentity {
 param($PackageRoot,[switch]$AllowHistorical)
 return (Get-Content -LiteralPath (Join-Path $PackageRoot 'RELEASE_IDENTITY.json') -Raw -Encoding UTF8|ConvertFrom-Json)
}
function Get-Service($Name){return [pscustomobject]@{Status=$script:runtime;StartType=$script:startup}}
function Set-Service($Name,$StartupType){$script:serviceWrites++;$script:startup=$StartupType}
function Stop-ManagedRuntime($Layout,$State){$script:stops++;$script:runtime='Stopped'}
function Start-ManagedRuntime($Layout,$State){$script:starts++;$script:runtime='Running';$script:live.version=$State.current_version}
function Start-NativeRuntime($State,$Identity){
 $script:nativeStarts++
 Assert-NativeStopped $State
 Assert-NativeStoredRelease $Identity
 Start-ManagedRuntime $layout $State
}
function Confirm-NativeRunning($State,$Identity){
 if($script:runtime -cne 'Running' -or $script:live.version -cne $State.current_version -or $script:live.dll_sha256 -cne $Identity.dll_sha256){throw 'Fixture native runtime differs'}
}
function Wait-ApplicationHealthy($HealthBaseURL,$ExpectedVersion,$TimeoutSeconds){
 if($script:runtime -cne 'Running' -or $script:live.version -cne $ExpectedVersion){throw 'Fixture legacy runtime differs'}
 return @{version=$ExpectedVersion}
}
function Invoke-RestMethod($Uri,$TimeoutSec){
 if($Uri -cne ($config.health_url+'/version')){throw 'Unexpected recovery HTTP probe'}
 $script:probes++
 return $script:live
}

$root=Join-Path ([IO.Path]::GetTempPath()) ('zyf-native-recovery-ownership-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root)|Out-Null
try{
 foreach($scenario in @('stale-state','stale-current','stale-live-version','stale-live-dll','matching-native','matching-legacy')){
  $case=Join-Path $root $scenario
  $layout=Get-DeploymentLayout (Join-Path $case 'game');Initialize-DeploymentLayout $layout
  $config=@{health_url='http://fixture.invalid'}
  $checkpointPath=Join-Path $case 'checkpoint.json'
  $native=$scenario -cne 'matching-legacy'
  foreach($version in @('A','B')){
   $release=Join-Path $layout.Releases $version
   [IO.Directory]::CreateDirectory($release)|Out-Null
   [IO.File]::WriteAllText((Join-Path $release 'server.exe'),('fixture-'+$version))
   @{version=$version}|ConvertTo-Json|Set-Content (Join-Path $release 'BUILD_INFO.json') -Encoding UTF8
   if($native){
    $identity=@{version=$version;dll_sha256=($version.ToLowerInvariant()*64);dll_build_id=($version.ToLowerInvariant()*64);verified_source_sha256=('c'*64);verification_audit_sha256=('d'*64)}
    $identity|ConvertTo-Json|Set-Content (Join-Path $release 'RELEASE_IDENTITY.json') -Encoding UTF8
   }
   @(Get-ChildItem -LiteralPath $release -File|ForEach-Object{(Get-NativeReleaseHash $_.FullName)+'  '+$_.Name})|Set-Content (Join-Path $release 'SHA256SUMS') -Encoding ASCII
  }
  $installed=if($scenario -in @('stale-state','stale-current')){'B'}else{'A'}
  Set-CurrentFromRelease $layout (Join-Path $layout.Releases $installed)
  [IO.Directory]::CreateDirectory((Join-Path $layout.Shared 'native-data'))|Out-Null
  [IO.File]::WriteAllText((Join-Path $layout.Shared 'native-data/rooms.wal'),'acknowledged-live-state')
  [IO.File]::WriteAllText((Join-Path $layout.Shared '.env'),'preserve-selectors')
  $old=New-DeploymentState -RuntimeMode WindowsService -ServiceName 'ownership-fixture';$old.current_version='A'
  $state=($old|ConvertTo-Json)|ConvertFrom-Json
  if($scenario -eq 'stale-state'){$state.current_version='B'}
  Save-DeploymentState $layout $state
  $transaction=Join-Path $layout.Root 'native-transactions/checkpoint-fixture'
  [IO.Directory]::CreateDirectory($transaction)|Out-Null
  $cp=@{kind='native-v1';layout_version=2;phase='backed_up';transaction=$transaction;old_state=$old;startup='Automatic';was_running=$true;may_have_served=$false;shared_tree=(Get-NativeStateTreeJSON $layout.Shared);candidate_tree='';target_version='B';target_dll=('b'*64)}
  Write-MaintenanceState $checkpointPath $cp
  $script:runtime='Running';$script:startup='Automatic'
  $script:serviceWrites=0;$script:stops=0;$script:starts=0;$script:nativeStarts=0;$script:probes=0
  $script:live=@{version=$installed;dll_sha256=($installed.ToLowerInvariant()*64);module=@{build_id=($installed.ToLowerInvariant()*64)}}
  if($scenario -eq 'stale-live-version'){$script:live.version='B'}
  if($scenario -eq 'stale-live-dll'){$script:live.dll_sha256='b'*64;$script:live.module.build_id='b'*64}
  $treeBefore=Get-MaintenanceTreeJSON $layout.Root
  $checkpointBefore=Get-NativeReleaseHash $checkpointPath
  $errorMessage=''
  try{Recover-NativeCheckpoint}catch{$errorMessage=$_.Exception.Message}
  if($scenario -like 'stale-*'){
   $expectedReason=switch($scenario){
    'stale-state' {'Stale recovery checkpoint: deployment state changed'}
    'stale-current' {'Stale recovery checkpoint: current release B differs from checkpoint A'}
    'stale-live-version' {'Stale recovery checkpoint: live version differs'}
    'stale-live-dll' {'Stale recovery checkpoint: live DLL differs'}
   }
   if(!$errorMessage.StartsWith($expectedReason,[StringComparison]::Ordinal)){throw ($scenario+': expected ownership rejection, got '+$errorMessage)}
   if($script:serviceWrites -ne 0 -or $script:stops -ne 0 -or $script:starts -ne 0 -or $script:nativeStarts -ne 0 -or $script:runtime -cne 'Running' -or $script:startup -cne 'Automatic'){throw ($scenario+': stale recovery changed the running service')}
   if((Get-MaintenanceTreeJSON $layout.Root) -cne $treeBefore){throw ($scenario+': stale recovery changed state/current/config/WAL or transaction evidence')}
   if(!(Test-Path -LiteralPath $checkpointPath) -or (Get-NativeReleaseHash $checkpointPath) -cne $checkpointBefore){throw ($scenario+': stale recovery consumed or rewrote the checkpoint')}
   $expectedProbes=if($scenario -like 'stale-live-*'){1}else{0}
   if($script:probes -ne $expectedProbes){throw ($scenario+': ownership checks ran in the wrong order')}
  }else{
   if($errorMessage){throw ($scenario+': matching recovery failed: '+$errorMessage)}
   if((Test-Path -LiteralPath $checkpointPath) -or $script:runtime -cne 'Running' -or $script:startup -cne 'Automatic' -or $script:stops -ne 1 -or $script:starts -ne 1 -or $script:serviceWrites -ne 2 -or $script:probes -ne 1){throw ($scenario+': matching recovery did not preserve the intended runtime lifecycle')}
   $expectedNativeStarts=if($native){1}else{0}
   if($script:nativeStarts -ne $expectedNativeStarts -or (Read-DeploymentState $layout).current_version -cne 'A'){throw ($scenario+': recovery used the wrong runtime adapter or state')}
   if((Get-NativeStateTreeJSON $layout.Shared) -cne $cp.shared_tree){throw ($scenario+': recovery modified live shared state')}
  }
 }
 Write-Host 'PASS: stale state/current/live identity rejected before mutation; matching native and legacy recovery preserved.'
}finally{
 $resolved=[IO.Path]::GetFullPath($root)
 $prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\zyf-native-recovery-ownership-'
 if(!$resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe recovery fixture cleanup'}
 Remove-Item -LiteralPath $resolved -Recurse -Force
}
