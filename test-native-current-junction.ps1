# Explicit opt-in Windows regression. Real temporary junctions, mocked runtime;
# never accesses SCM, starts an executable, loads a DLL or makes HTTP requests.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'deploy/common.ps1')
. (Join-Path $PSScriptRoot 'native-worker.ps1')
$script:fakeLinkType=''
$script:junctions=@()

# Release/content validation has separate tests. Keep real tree, link, backup,
# deployment and recovery operations here; fixtures only supply their identity.
function Test-NativeReleaseIdentity {
 param($PackageRoot,[switch]$AllowHistorical)
 return (Get-Content -LiteralPath (Join-Path $PackageRoot 'RELEASE_IDENTITY.json') -Raw -Encoding UTF8|ConvertFrom-Json)
}
function Get-Item {
 [CmdletBinding()]param([string]$LiteralPath,[switch]$Force)
 $item=Microsoft.PowerShell.Management\Get-Item -LiteralPath $LiteralPath -Force:$Force -ErrorAction Stop
 if($script:fakeLinkType -and $LiteralPath -ieq $layout.Current){
  return [pscustomobject]@{PSIsContainer=$true;LinkType=$script:fakeLinkType;Target=$item.Target;Attributes=$item.Attributes}
 }
 return $item
}
function Get-Service($Name){return [pscustomobject]@{Status=$script:runtime;StartType=$script:startup}}
function Set-Service($Name,$StartupType){$script:serviceWrites++;$script:startup=$StartupType}
function Stop-ManagedRuntime($Layout,$State){$script:stops++;$script:runtime='Stopped'}
function Start-NativeRuntime($State,$Identity){
 Assert-NativeStopped $State
 Assert-NativeStoredRelease $Identity
 if($State.current_version -cne $Identity.version){throw 'Fixture start identity mismatch'}
 $script:starts++;$script:runtime='Running';$script:runningVersion=$State.current_version
}
function Start-ManagedRuntime {throw 'Junction fixture must not enter the real runtime adapter'}
function Confirm-NativeRunning($State,$Identity){
 if($script:runtime -cne 'Running' -or $script:runningVersion -cne $State.current_version -or $Identity.version -cne $State.current_version){throw 'Fixture runtime identity mismatch'}
}
function Invoke-RestMethod {throw 'Junction fixture must not make HTTP requests'}
function Test-NativeWorkingCopy($Release,$Shared,$Identity){
 if($script:scenario -eq 'pre-switch-failure'){throw 'injected pre-switch failure'}
 return @{fixture_proof=$true}
}
function New-FixtureJunction([string]$Path,[string]$Target){
 Assert-ChildPath $root $Path;Assert-ChildPath $root $Target
 New-Item -ItemType Junction -Path $Path -Target $Target -ErrorAction Stop|Out-Null
 $script:junctions+= $Path
}

$root=Join-Path ([IO.Path]::GetTempPath()) ('zyf-native-current-junction-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root)|Out-Null
try{
 foreach($script:scenario in @('valid-upgrade','pre-switch-failure','switching-new-state-old-link','missing-current-recovery','wrong-target','outside-target','target-chain','nested-link','non-junction')){
  $case=Join-Path $root $script:scenario
  $layout=Get-DeploymentLayout (Join-Path $case 'game');Initialize-DeploymentLayout $layout
  $config=@{health_url='http://fixture.invalid'};$checkpointPath=Join-Path $case 'checkpoint.json'
  $JobID=[guid]::NewGuid().ToString('N');$job=@{action='package';maintenance=$true}
  $script:runtime='Running';$script:startup='Automatic';$script:runningVersion='A'
  $script:serviceWrites=0;$script:stops=0;$script:starts=0;$script:fakeLinkType=''
  foreach($version in @('A','B')){
   $release=Join-Path $layout.Releases $version
   [IO.Directory]::CreateDirectory($release)|Out-Null
   [IO.File]::WriteAllText((Join-Path $release 'server.exe'),('fixture-exe-'+$version))
   [IO.File]::WriteAllText((Join-Path $release 'gamecore.dll'),('fixture-dll-'+$version))
   $identity=@{version=$version;dll_sha256=(Get-NativeReleaseHash (Join-Path $release 'gamecore.dll'));dll_build_id=('b'*64);verified_source_sha256=('c'*64);verification_audit_sha256=('d'*64);deployment_admission='requires_native_maintenance_v1'}
   $identity|ConvertTo-Json|Set-Content (Join-Path $release 'RELEASE_IDENTITY.json') -Encoding UTF8
   @(Get-ChildItem -LiteralPath $release -File|ForEach-Object{(Get-NativeReleaseHash $_.FullName)+'  '+$_.Name})|Set-Content (Join-Path $release 'SHA256SUMS') -Encoding ASCII
  }
  $releaseA=Join-Path $layout.Releases 'A';$releaseB=Join-Path $layout.Releases 'B';$actualA=$releaseA
  $oldTree=Get-MaintenanceTreeJSON $releaseA
  foreach($name in @('host.json','gameplay.lua','economy.lua','.env')){[IO.File]::WriteAllText((Join-Path $layout.Shared $name),('live-'+$name))}
  [IO.Directory]::CreateDirectory((Join-Path $layout.Shared 'native-data'))|Out-Null
  [IO.File]::WriteAllText((Join-Path $layout.Shared 'native-data/rooms.wal'),'acknowledged-live-state')
  $sharedBefore=Get-NativeStateTreeJSON $layout.Shared
  $old=New-DeploymentState -RuntimeMode WindowsService -ServiceName 'junction-fixture';$old.current_version='A'
  Save-DeploymentState $layout $old
  $stateBefore=Get-NativeReleaseHash $layout.StateFile
  $linkTarget=$releaseA
  if($script:scenario -eq 'wrong-target'){$linkTarget=$releaseB}
  if($script:scenario -eq 'outside-target'){
   $linkTarget=Join-Path $case 'outside-release';[IO.Directory]::CreateDirectory($linkTarget)|Out-Null
   [IO.File]::WriteAllText((Join-Path $linkTarget 'sentinel'),'must-survive')
  }
  if($script:scenario -eq 'target-chain'){
   $actualA=Join-Path $layout.Releases 'A-physical'
   Assert-ChildPath $layout.Releases $releaseA;Assert-ChildPath $layout.Releases $actualA
   [IO.Directory]::Move($releaseA,$actualA)
   New-FixtureJunction $releaseA $actualA
  }
  if($script:scenario -eq 'nested-link'){
   $nestedTarget=Join-Path $case 'nested-target';[IO.Directory]::CreateDirectory($nestedTarget)|Out-Null
   New-FixtureJunction (Join-Path $releaseA 'nested') $nestedTarget
  }
  New-FixtureJunction $layout.Current $linkTarget
  if($script:scenario -eq 'non-junction'){$script:fakeLinkType='SymbolicLink'}
  $failure=''
  if($script:scenario -in @('switching-new-state-old-link','missing-current-recovery')){
   $transaction=Join-Path $layout.Root ('native-transactions/'+$JobID);[IO.Directory]::CreateDirectory($transaction)|Out-Null
   $null=Copy-NativeStateTree $layout.Shared (Join-Path $transaction 'backup-shared')
   $next=($old|ConvertTo-Json)|ConvertFrom-Json;$next.current_version='B';Save-DeploymentState $layout $next
   $cp=@{kind='native-v1';layout_version=2;phase='switching';transaction=$transaction;old_state=$old;startup='Automatic';was_running=$true;may_have_served=$false;shared_tree=$sharedBefore;candidate_tree=$sharedBefore;target_version='B';target_dll=(Get-NativeReleaseHash (Join-Path $releaseB 'gamecore.dll'))}
   Write-MaintenanceState $checkpointPath $cp
   $script:runtime='Stopped'
   if($script:scenario -eq 'missing-current-recovery'){
    # Simulate interruption after the verified link was removed but before copy.
    $null=Get-NativeCurrentSource $old
    [IO.Directory]::Delete($layout.Current,$false)
   }
   try{Recover-NativeCheckpoint}catch{$failure=$_.Exception.Message}
  }else{
   try{Deploy-NativeRelease $releaseB}catch{$failure=$_.Exception.Message}
  }
  if($script:scenario -in @('wrong-target','outside-target','target-chain','nested-link','non-junction')){
   $expectedReason=switch($script:scenario){
    'wrong-target' {'Native current junction does not target the trusted current release'}
    'outside-target' {'Native current junction does not target the trusted current release'}
    'target-chain' {'Native current junction target contains a reparse-point chain'}
    'nested-link' {'Reparse points are not allowed in maintenance snapshots'}
    'non-junction' {'Native current must be a directory or a managed release junction'}
   }
   if($failure -cne $expectedReason){throw ($script:scenario+': wrong rejection: '+$failure)}
   if($script:stops -ne 0 -or $script:starts -ne 0 -or $script:serviceWrites -ne 0 -or $script:runtime -cne 'Running'){throw ($script:scenario+': rejected link changed the service')}
   if((Get-NativeReleaseHash $layout.StateFile) -cne $stateBefore -or (Get-NativeStateTreeJSON $layout.Shared) -cne $sharedBefore -or (Test-Path -LiteralPath $checkpointPath)){throw ($script:scenario+': rejected link changed state/shared/checkpoint')}
   if(!([IO.File]::GetAttributes($layout.Current) -band [IO.FileAttributes]::ReparsePoint)){throw 'Rejected current link was removed'}
  }else{
   if($script:scenario -eq 'pre-switch-failure'){
    if($failure -cne 'injected pre-switch failure'){throw ('Unexpected maintenance failure: '+$failure)}
    if(!([IO.File]::GetAttributes($layout.Current) -band [IO.FileAttributes]::ReparsePoint)){throw 'Early recovery changed the old current junction'}
   }elseif($failure){throw ($script:scenario+': '+$failure)}
   elseif([IO.File]::GetAttributes($layout.Current) -band [IO.FileAttributes]::ReparsePoint){throw 'Completed switch did not normalize current to a real directory'}
   $expectedVersion=if($script:scenario -eq 'valid-upgrade'){'B'}else{'A'}
   if($script:runtime -cne 'Running' -or $script:startup -cne 'Automatic' -or $script:runningVersion -cne $expectedVersion -or (Read-DeploymentState $layout).current_version -cne $expectedVersion -or (Test-Path -LiteralPath $checkpointPath)){throw ($script:scenario+': runtime/state did not reach expected version')}
   if((Get-MaintenanceTreeJSON $actualA) -cne $oldTree){throw 'Switch or recovery modified the immutable old release'}
   if([IO.File]::ReadAllText((Join-Path $layout.Shared 'native-data/rooms.wal')) -cne 'acknowledged-live-state'){throw 'Switch or recovery modified acknowledged WAL'}
   if($script:scenario -in @('valid-upgrade','pre-switch-failure')){
    if((Get-MaintenanceTreeJSON (Join-Path $layout.Root ('native-transactions/'+$JobID+'/backup-current'))) -cne $oldTree){throw 'Current backup did not copy the actual immutable release'}
   }
  }
 }
 Write-Host 'PASS: validated current junction upgrades/recovery preserve releases; invalid links rejected before stopping.'
}finally{
 $script:fakeLinkType=''
 $resolved=[IO.Path]::GetFullPath($root)
 $prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\zyf-native-current-junction-'
 if(!$resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe junction fixture cleanup'}
 # Unlink only recorded entries, never recursively remove a remaining junction.
 for($i=$script:junctions.Count-1;$i -ge 0;$i--){
  $path=[IO.Path]::GetFullPath($script:junctions[$i]);Assert-ChildPath $resolved $path
  $entry=Microsoft.PowerShell.Management\Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
  if($entry -and ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint)){[IO.Directory]::Delete($path,$false)}
 }
 $null=Get-MaintenanceTreeJSON $resolved
 Remove-Item -LiteralPath $resolved -Recurse -Force
}
