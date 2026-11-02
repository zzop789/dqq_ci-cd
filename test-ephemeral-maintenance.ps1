# Explicit opt-in regression source; ordinary build/deploy does not execute it.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'deploy/common.ps1')
. (Join-Path $PSScriptRoot 'native-worker.ps1')
function Expect-Rejected([scriptblock]$Action,[string]$Label){
 $rejected=$false;try{& $Action}catch{$rejected=$true}
 if(!$rejected){throw ('Expected rejection: '+$Label)}
}
# The mode is bound to both hashed metadata files, not just a manifest flag.
$modeRecord=[pscustomobject]@{room_state_mode='ephemeral'}
$oldRecord=[pscustomobject]@{}
Assert-NativeRoomStateMode $modeRecord $modeRecord $modeRecord
Assert-NativeRoomStateMode $oldRecord $oldRecord $oldRecord
Expect-Rejected {Assert-NativeRoomStateMode $modeRecord $oldRecord $modeRecord} 'audit missing room mode'
Expect-Rejected {Assert-NativeRoomStateMode $oldRecord $modeRecord $modeRecord} 'identity missing room mode'
Expect-Rejected {Assert-NativeRoomStateMode $modeRecord $modeRecord ([pscustomobject]@{room_state_mode='persistent'})} 'build mode mismatch'
# Only service/tool/identity-validation boundaries are mocked. The tree,
# preflight-proof, configuration-switch and checkpoint recovery code is real.
function Get-Service($Name){return [pscustomobject]@{Status='Stopped';StartType='Automatic'}}
function Set-Service($Name,$StartupType){$script:lastStartup=$StartupType;$script:serviceChanges++}
function Stop-ManagedRuntime($Layout,$State){$script:serviceChanges++}
function Start-NativeRuntime($State,$Identity){$script:starts++;throw 'Unexpected old-runtime start'}
function Start-ManagedRuntime($Layout,$State){$script:starts++;throw 'Unexpected legacy-runtime start'}
function Test-ReleaseChecksums($ReleaseRoot){}
function Test-NativeReleaseIdentity([string]$PackageRoot,[switch]$AllowHistorical){
 return Get-Content -LiteralPath (Join-Path $PackageRoot 'RELEASE_IDENTITY.json') -Raw -Encoding UTF8|ConvertFrom-Json
}
function Invoke-NativeTool($Executable,$Arguments,$Environment){
 $shared=Split-Path $Environment.SERVER_CONFIG_FILE -Parent
 if($script:createData){[IO.Directory]::CreateDirectory((Join-Path $shared 'native-data'))|Out-Null}
 return ([ordered]@{preflight='passed';listener_started=$false;gameplay_commands_executed=0;dll_sha256=('b'*64);module=@{build_id=('c'*64)};transport_profile='warcraft-round-v1';data_directory=(Join-Path $shared 'native-data');room_state_mode=$script:proofMode;history_loaded=$script:proofHistory}|ConvertTo-Json)
}
$root=Join-Path ([IO.Path]::GetTempPath()) ('zyf-ephemeral-maintenance-'+[guid]::NewGuid().ToString('N'))
$locks=@()
try{
 [IO.Directory]::CreateDirectory($root)|Out-Null
 $layout=Get-DeploymentLayout (Join-Path $root 'game');Initialize-DeploymentLayout $layout
 $transaction=Join-Path $layout.Root 'native-transactions/fixture';[IO.Directory]::CreateDirectory($transaction)|Out-Null
 foreach($name in @('host.json','gameplay.lua','economy.lua','.env')){[IO.File]::WriteAllText((Join-Path $layout.Shared $name),('original-'+$name))}
 foreach($relative in @('native-data/rooms.wal','native-data/content/corrupt.json','logs/server.log')){
  $path=Join-Path $layout.Shared $relative
  [IO.Directory]::CreateDirectory((Split-Path $path -Parent))|Out-Null
  [IO.File]::WriteAllText($path,'corrupt historical bytes; never parsed or hashed')
  $locks+=,[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
 }
 $backup=Join-Path $transaction 'backup-shared';$candidate=Join-Path $transaction 'candidate-shared'
 $before=Copy-NativeStateTree $layout.Shared $backup -ExcludeNativeData
 $null=Copy-NativeStateTree $backup $candidate -ExcludeNativeData
 if(Test-Path -LiteralPath (Join-Path $backup 'native-data')){throw 'Historical data entered snapshot'}
 if(Test-Path -LiteralPath (Join-Path $backup 'logs')){throw 'Logs entered snapshot'}
 [IO.File]::WriteAllText((Join-Path $candidate '.env'),'new-env')
 $after=Get-NativeStateTreeJSON $candidate -ExcludeNativeData
 Assert-NativeConfigTransition $layout.Shared $before $after -ExcludeNativeData
 Set-NativeConfigFiles $candidate $layout.Shared $transaction
 Assert-NativeConfigTransition $layout.Shared $before $after -ExcludeNativeData
 if((Get-NativeStateTreeJSON $layout.Shared -ExcludeNativeData) -cne $after){throw 'Configuration switch failed with locked historical files'}
 # The historical mode still detects a locked WAL, rather than silently skipping it.
 Expect-Rejected {Get-NativeStateTreeJSON $layout.Shared|Out-Null} 'legacy snapshot must include WAL'
 $identity=[pscustomobject]@{version='B';dll_sha256=('b'*64);dll_build_id=('c'*64);room_state_mode='ephemeral'}
 $script:proofMode='ephemeral';$script:proofHistory=$false;$script:createData=$false
 $null=Test-NativeWorkingCopy $layout.Releases $backup $identity -ExcludeNativeData
 Expect-Rejected {Test-NativeWorkingCopy $layout.Releases $backup $identity|Out-Null} 'identity/snapshot mode mismatch'
 $script:proofMode='persistent'
 Expect-Rejected {Test-NativeWorkingCopy $layout.Releases $backup $identity -ExcludeNativeData|Out-Null} 'identity/preflight mode mismatch'
 $script:proofMode='ephemeral';$script:proofHistory=$true
 Expect-Rejected {Test-NativeWorkingCopy $layout.Releases $backup $identity -ExcludeNativeData|Out-Null} 'history was loaded'
 $script:proofHistory='false'
 Expect-Rejected {Assert-NativeEphemeralProof ([pscustomobject]@{room_state_mode='ephemeral';history_loaded='false'})} 'proof must use a boolean'
 $script:proofHistory=$false;$script:createData=$true
 Expect-Rejected {Test-NativeWorkingCopy $layout.Releases $backup $identity -ExcludeNativeData|Out-Null} 'preflight must not create native-data'
 $script:createData=$false
 foreach($version in @('A','B')){
  $release=Join-Path $layout.Releases $version;[IO.Directory]::CreateDirectory($release)|Out-Null
  [IO.File]::WriteAllText((Join-Path $release 'server.exe'),'fixture')
  $releaseIdentity=[ordered]@{version=$version;dll_sha256=('b'*64);dll_build_id=('c'*64)}
  if($version -eq 'B'){$releaseIdentity['room_state_mode']='ephemeral'}
  [IO.File]::WriteAllText((Join-Path $release 'RELEASE_IDENTITY.json'),($releaseIdentity|ConvertTo-Json))
 }
 Set-CurrentFromRelease $layout (Join-Path $layout.Releases 'B')
 $old=New-DeploymentState -RuntimeMode WindowsService;$old.current_version='A'
 $next=New-DeploymentState -RuntimeMode WindowsService;$next.current_version='B';Save-DeploymentState $layout $next
 $checkpointPath=Join-Path $root 'checkpoint.json'
 $cp=[ordered]@{kind='native-v1';layout_version=3;room_state_mode='persistent';phase='activated';transaction=$transaction;old_state=$old;startup='Automatic';was_running=$true;may_have_served=$false;shared_tree=$before;candidate_tree=$after;target_version='B';target_dll=('b'*64)}
 $script:starts=0;$script:serviceChanges=0;$script:lastStartup=''
 Write-MaintenanceState $checkpointPath $cp
 Expect-Rejected {Recover-NativeCheckpoint} 'checkpoint/release mode mismatch'
 if($script:serviceChanges -ne 0 -or $script:starts -ne 0){throw 'Unbound mode changed service state'}
 $cp.room_state_mode='ephemeral';Write-MaintenanceState $checkpointPath $cp
 Recover-NativeCheckpoint
 if($script:starts -ne 0 -or $script:lastStartup -ne 'Manual'){throw 'Layout 3 automatically restarted persistent history loader'}
 if((Read-DeploymentState $layout).current_version -cne 'A' -or (Test-Path -LiteralPath $checkpointPath)){throw 'Pre-start recovery did not restore old release metadata'}
 if((Get-NativeStateTreeJSON $layout.Shared -ExcludeNativeData) -cne $before){throw 'Pre-start recovery did not preserve configuration'}
 foreach($held in $locks){$held.Dispose()};$locks=@()
 foreach($relative in @('native-data/rooms.wal','native-data/content/corrupt.json','logs/server.log')){
  if([IO.File]::ReadAllText((Join-Path $layout.Shared $relative)) -cne 'corrupt historical bytes; never parsed or hashed'){throw 'Historical bytes changed'}
 }
 Write-Host 'PASS: ephemeral snapshots ignore locked history, proofs bind modes, and old persistent recovery stays stopped.'
}finally{
 foreach($held in $locks){$held.Dispose()}
 $resolved=[IO.Path]::GetFullPath($root)
 $prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\zyf-ephemeral-maintenance-'
 if(!$resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe cleanup'}
 if(Test-Path -LiteralPath $resolved){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
