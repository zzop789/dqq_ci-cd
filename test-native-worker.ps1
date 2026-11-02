Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'deploy/common.ps1')
. (Join-Path $PSScriptRoot 'native-worker.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('zyf-native-worker-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root|Out-Null
function Get-Service($Name){return [pscustomobject]@{Status=$script:runtime;StartType='Manual'}}
function Set-Service($Name,$StartupType){}
function Stop-ManagedRuntime($Layout,$State){$script:runtime='Stopped'}
function Start-ManagedRuntime($Layout,$State){
 $script:runtime='Running'
 if($State.current_version -eq 'B' -and $script:scenario -eq 'start-failure'){
  [IO.File]::WriteAllText((Join-Path $Layout.Shared 'native-data/rooms.wal'),'confirmed-new-write')
  throw 'injected uncertain start'
 }
}
# Substitute the SCM boundary itself: mocking Start-ManagedRuntime alone would
# let Start-NativeRuntime write the real service registry before reaching us.
function Start-NativeRuntime($State,$Identity){
 Assert-NativeStopped $State
 if($State.current_version -cne $Identity.version){throw 'Fixture native start identity mismatch'}
 Assert-NativeStoredRelease $Identity
 Start-ManagedRuntime $layout $State
}
function Wait-ApplicationHealthy($HealthBaseURL,$ExpectedVersion,$TimeoutSeconds){return @{version=$ExpectedVersion}}
function Confirm-NativeRunning($State,$Identity){if($script:scenario -eq 'health-failure'){throw 'injected health failure'}}
function Invoke-NativeTool($Executable,$Arguments,$Environment){
 if($Executable.EndsWith('configmigrate.exe')){
  if($script:scenario -eq 'migration-failure'){throw 'injected migration failure'}
  $out=$Arguments[$Arguments.Count-1];Write-Host ('  [mock] migration out: '+$out+' | working arg: '+$Arguments[3]);New-Item -ItemType Directory -Path $out|Out-Null
  foreach($name in @('host.json','gameplay.lua','economy.lua')){[IO.File]::WriteAllText((Join-Path $out $name),'migrated-live-values')}
  return ''
 }
 if($script:scenario -eq 'activation-failure' -and $Executable -match '[\\/]current[\\/]'){throw 'injected post-switch preflight failure'}
 if($script:scenario -eq 'recovery-failure'){throw 'incompatible checkpoint'}
 $shared=Split-Path $Environment.SERVER_CONFIG_FILE -Parent
 $data=Join-Path $shared 'native-data';New-Item -ItemType Directory -Path $data -Force|Out-Null
 if(!(Test-Path (Join-Path $data 'rooms.wal'))){[IO.File]::WriteAllText((Join-Path $data 'rooms.wal'),'original-wal')}
 if($script:scenario -eq 'preflight-mutation'){[IO.File]::WriteAllText((Join-Path $data 'rooms.wal'),'preflight-rewrote-wal')}
 return (@{preflight='passed';listener_started=$false;gameplay_commands_executed=0;dll_sha256=$Environment.GAMECORE_SHA256;module=@{build_id=('b'*64)};transport_profile='warcraft-round-v1';data_directory=$data}|ConvertTo-Json)
}
try{
 foreach($script:scenario in @('legacy-migration-success','legacy-success','native-success','package-config-partial','migration-failure','recovery-failure','activation-failure','preflight-mutation','start-failure','health-failure')){
  # A package that carries the complete configuration set owns the live files.
  # The two migration scenarios need a package without it.
  $withPackageConfig=$script:scenario -notin @('legacy-migration-success','migration-failure')
  $case=Join-Path $root $script:scenario;New-Item -ItemType Directory -Path $case|Out-Null
  $layout=Get-DeploymentLayout (Join-Path $case 'game');Initialize-DeploymentLayout $layout
  $config=@{health_url='http://127.0.0.1:8080'};$JobID=[guid]::NewGuid().ToString('N');$job=@{action='package';maintenance=$true}
  $checkpointPath=Join-Path $case 'checkpoint.json';$script:runtime='Stopped'
  foreach($version in @('A','B')){
   $r=Join-Path $layout.Releases $version;New-Item -ItemType Directory -Path (Join-Path $r 'configs/combat') -Force|Out-Null
   foreach($name in @('server.exe','gamecore.dll','configmigrate.exe','nativearchiveaudit.exe','toolchain.lock.json','BUILD_INFO.json')){[IO.File]::WriteAllText((Join-Path $r $name),'fixture-'+$name)}
   @{version='demo-skill-runtime-v14'}|ConvertTo-Json|Set-Content (Join-Path $r 'configs/combat/ruleset.json') -Encoding UTF8
   @{schema_version=4;version='match-economy-v4'}|ConvertTo-Json|Set-Content (Join-Path $r 'configs/combat/economy.json') -Encoding UTF8
   @{protocol_version='9';contract_version=26;ruleset_version='demo-skill-runtime-v14';current_ruleset_version='demo-skill-runtime-v14';current_economy_version='match-economy-v4';current_transport_profile='warcraft-round-v1';client_migration_required=$true}|ConvertTo-Json|Set-Content (Join-Path $r 'client-contract.json') -Encoding UTF8
   if($withPackageConfig -and ($version -eq 'B' -or $script:scenario -eq 'native-success')){
    $names=@('host.json','gameplay.lua','economy.lua')
    if($script:scenario -eq 'package-config-partial' -and $version -eq 'B'){$names=@('host.json')}
    foreach($name in $names){[IO.File]::WriteAllText((Join-Path $r $name),('package-'+$version+'-'+$name))}
   }
   $audit=@{status='passed';stage='M4-native-core-and-host-verification';production_gameplay='cpp';source=@{sha256=('a'*64)};current_client_contract=@{profile='warcraft-round-v1';protocol='9';contract=26;ruleset='demo-skill-runtime-v14';economy='match-economy-v4';economy_schema=4;contract_sha256=(Get-NativeReleaseHash (Join-Path $r 'client-contract.json'));new_authentication_required=$false;client_request_changes_required=$true};native=@(@{configuration='Release';ctest='passed';go_integration='passed';probe='passed';sha256=(Get-NativeReleaseHash (Join-Path $r 'gamecore.dll'));build_id=('b'*64)})}
   $audit|ConvertTo-Json -Depth 8|Set-Content (Join-Path $r 'verification.json') -Encoding UTF8
   New-NativeReleaseIdentity $r (Join-Path $r 'verification.json') $version
   @(Get-ChildItem $r -File -Recurse|ForEach-Object{(Get-NativeReleaseHash $_.FullName)+'  '+$_.FullName.Substring($r.Length+1).Replace('\','/')})|Set-Content (Join-Path $r 'SHA256SUMS') -Encoding ASCII
  }
  Set-CurrentFromRelease $layout (Join-Path $layout.Releases 'A')
  [IO.File]::WriteAllText((Join-Path $layout.Shared 'server.json'),'actual-server-values')
  New-Item -ItemType Directory -Path (Join-Path $layout.Shared 'native-data') -Force|Out-Null
  [IO.File]::WriteAllText((Join-Path $layout.Shared 'native-data/rooms.wal'),'live-wal')
  [IO.File]::WriteAllText((Join-Path $layout.Shared '.env'),'HTTP_ADDR=:8080')
  if($script:scenario -eq 'native-success'){
   foreach($name in @('host.json','gameplay.lua','economy.lua')){[IO.File]::WriteAllText((Join-Path $layout.Shared $name),'hand-made-live-values')}
  }
  $state=New-DeploymentState -RuntimeMode WindowsService;$state.current_version='A';Save-DeploymentState $layout $state
  $before=Get-MaintenanceTreeJSON $layout.Shared;$dataBefore=Get-MaintenanceTreeJSON (Join-Path $layout.Shared 'native-data')
  $failed=$false;try{Deploy-NativeRelease (Join-Path $layout.Releases 'B')}catch{$failed=$true;Write-Host ($script:scenario+': '+$_.Exception.Message)}
  if($script:scenario -like '*success'){
   if($failed -or (Test-Path $checkpointPath) -or (Read-DeploymentState $layout).current_version -ne 'B'){throw "Expected successful native upgrade: $script:scenario"}
   if([IO.File]::ReadAllText((Join-Path $layout.Shared 'server.json')) -cne 'actual-server-values'){throw 'Transitional server.json was rewritten'}
   if($script:scenario -in @('legacy-migration-success','legacy-success')){
    foreach($name in @('host.json','gameplay.lua','economy.lua')){if([IO.File]::ReadAllText((Join-Path $layout.Shared $name)) -cne 'migrated-live-values'){throw "One-way migration did not supply $name"}}
   }else{
    foreach($name in @('host.json','gameplay.lua','economy.lua')){if([IO.File]::ReadAllText((Join-Path $layout.Shared $name)) -cne 'hand-made-live-values'){throw "Package configuration did not replace $name"}}
   }
   if((Get-MaintenanceTreeJSON (Join-Path $layout.Shared 'native-data')) -cne $dataBefore){throw 'Live player data changed during deployment'}
   if(!(Test-Path -LiteralPath (Join-Path $layout.Shared 'RULES.md'))){throw 'Managed configuration rules were not published'}
   if(!([IO.File]::ReadAllText((Join-Path $layout.Shared '.env')) -match 'CONFIG_POLICY')){throw 'Environment did not declare the configuration policy'}
  }elseif($script:scenario -eq 'package-config-partial'){
   if(!$failed -or (Get-MaintenanceTreeJSON $layout.Shared) -cne $before -or $script:runtime -ne 'Stopped' -or (Read-DeploymentState $layout).current_version -ne 'A'){throw 'Partial package configuration was not rejected before maintenance'}
  }elseif($script:scenario -in @('migration-failure','recovery-failure','activation-failure','preflight-mutation')){
   if(!$failed -or (Test-Path $checkpointPath) -or (Get-MaintenanceTreeJSON $layout.Shared) -cne $before -or $script:runtime -ne 'Stopped'){
    Write-Host ('  shared before: '+$before)
    Write-Host ('  shared after : '+(Get-MaintenanceTreeJSON $layout.Shared))
    throw 'Pre-start failure did not preserve stopped old state'
   }
  }else{
   if(!$failed -or !(Test-Path $checkpointPath) -or (Read-DeploymentState $layout).current_version -ne 'B'){throw 'Uncertain start incorrectly rolled back'}
   $wal=[IO.File]::ReadAllText((Join-Path $layout.Shared 'native-data/rooms.wal'))
   $script:scenario='forward-retry';Recover-NativeCheckpoint
   if((Test-Path $checkpointPath) -or [IO.File]::ReadAllText((Join-Path $layout.Shared 'native-data/rooms.wal')) -cne $wal){throw 'Forward recovery lost data'}
   if([IO.File]::ReadAllText((Join-Path $layout.Shared 'host.json')) -cne 'migrated-live-values'){throw 'Forward recovery discarded the deployed package configuration'}
  }
 }
 Write-Host 'PASS: authoritative configuration preserved, legacy values migrated, live data unchanged, stopped and uncertain recovery preserved.'
}finally{
 $resolved=[IO.Path]::GetFullPath($root);$prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\zyf-native-worker-'
 if(!$resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe test cleanup'}
 Remove-Item -LiteralPath $resolved -Recurse -Force
}
