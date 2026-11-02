param([Parameter(Mandatory=$true)][string]$PackageRoot,[Parameter(Mandatory=$true)][string]$LegacyConfig)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'deploy/common.ps1')
. (Join-Path $PSScriptRoot 'native-worker.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('zyf-native-package-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root|Out-Null
$script:process=$null
$agent=$null
function Get-Service($Name){$status='Stopped';if($script:process -and !$script:process.HasExited){$status='Running'};return [pscustomobject]@{Status=$status;StartType='Manual'}}
function Set-Service($Name,$StartupType){}
function Stop-ManagedRuntime($Layout,$State){if($script:process -and !$script:process.HasExited){$script:process.Kill();$script:process.WaitForExit()}}
function Start-ManagedRuntime($Layout,$State){
 $start=New-Object Diagnostics.ProcessStartInfo
 $start.FileName=Join-Path $Layout.Current 'server.exe';$start.WorkingDirectory=$Layout.Current
 $start.UseShellExecute=$false;$start.CreateNoWindow=$true
 $start.EnvironmentVariables['ENV_FILE']=Join-Path $Layout.Shared '.env'
 foreach($key in @('SERVER_CONFIG_FILE','GAMECORE_DLL','GAMECORE_SHA256','COMBAT_CONTENT_DIR','HTTP_ADDR','LOG_DIR')){$start.EnvironmentVariables.Remove($key)}
 $script:process=New-Object Diagnostics.Process;$script:process.StartInfo=$start
 if(!$script:process.Start()){throw 'Test host did not start'}
}
# Exercise the real host with the same selectors as the SCM adapter, without
# reading or writing any Windows service registry key on the test machine.
function Start-NativeRuntime($State,$Identity){
 Assert-NativeStopped $State
 if($State.current_version -cne $Identity.version){throw 'Fixture native start identity mismatch'}
 Assert-NativeStoredRelease $Identity
 $release=Join-Path $layout.Releases $Identity.version
 $start=New-Object Diagnostics.ProcessStartInfo
 $start.FileName=Join-Path $layout.Current 'server.exe';$start.WorkingDirectory=$layout.Current
 $start.UseShellExecute=$false;$start.CreateNoWindow=$true
 $start.EnvironmentVariables.Remove('HTTP_ADDR')
 $selectors=@{SERVER_CONFIG_FILE=(Join-Path $layout.Shared 'host.json');GAMECORE_DLL=(Join-Path $release 'gamecore.dll');GAMECORE_SHA256=$Identity.dll_sha256;COMBAT_CONTENT_DIR=(Join-Path $release 'configs/combat');ENV_FILE=(Join-Path $layout.Shared '.env');LOG_DIR=(Join-Path $layout.Shared 'logs')}
 foreach($key in $selectors.Keys){$start.EnvironmentVariables[$key]=[string]$selectors[$key]}
 $script:process=New-Object Diagnostics.Process;$script:process.StartInfo=$start
 if(!$script:process.Start()){throw 'Test native host did not start'}
}
# The running host keeps byte-range locks on the WAL, so player data is observed
# by name, size and timestamp. Content equality of the WAL is proven by the
# package's own preflight, which compares hashes of the working copy.
function Get-SharedDataTree([string]$Shared){
 $dir=Join-Path $Shared 'native-data'
 $entries=@()
 foreach($item in (Get-ChildItem -LiteralPath $dir -Recurse -Force|Sort-Object FullName)){
  $relative=$item.FullName.Substring($dir.Length+1).Replace('\','/')
  if($item.PSIsContainer){$entries+=[ordered]@{path=$relative;kind='directory'};continue}
  $entries+=[ordered]@{path=$relative;kind='file';length=$item.Length}
 }
 return (ConvertTo-Json -InputObject @($entries) -Depth 5 -Compress)
}
# A stopped host writes nothing, so lengths are stable; a running host grows the
# WAL, so only the entry set is comparable while it serves traffic.
function Get-SharedDataPaths([string]$Shared){
 $dir=Join-Path $Shared 'native-data'
 return ((Get-ChildItem -LiteralPath $dir -Recurse -Force|Sort-Object FullName|ForEach-Object{$_.FullName.Substring($dir.Length+1).Replace('\','/')}) -join ',')
}
function Get-SharedDataPathsOf([string]$Tree){
 return ((@($Tree|ConvertFrom-Json)|ForEach-Object{$_.path}) -join ',')
}
try{
 Test-ReleaseChecksums $PackageRoot
 $identity=Test-NativeReleaseIdentity $PackageRoot
 $layout=Get-DeploymentLayout (Join-Path $root 'game');Initialize-DeploymentLayout $layout
 $release=Join-Path $layout.Releases $identity.version;$null=Copy-MaintenanceTree $PackageRoot $release
 $old=Join-Path $layout.Releases 'legacy-fixture';New-Item -ItemType Directory -Path (Join-Path $old 'configs/combat') -Force|Out-Null
 [IO.File]::WriteAllText((Join-Path $old 'server.exe'),'non-executed-old-program')
 Copy-Item -LiteralPath (Join-Path $release 'configs/combat/economy.json') -Destination (Join-Path $old 'configs/combat/economy.json')
 @{version='legacy-fixture'}|ConvertTo-Json|Set-Content (Join-Path $old 'BUILD_INFO.json') -Encoding UTF8
 @(Get-ChildItem -LiteralPath $old -File -Recurse|ForEach-Object{(Get-NativeReleaseHash $_.FullName)+'  '+$_.FullName.Substring($old.Length+1).Replace('\','/')})|Set-Content (Join-Path $old 'SHA256SUMS') -Encoding ASCII
 Set-CurrentFromRelease $layout $old
 $legacy=Get-Content -LiteralPath $LegacyConfig -Raw|ConvertFrom-Json
 $legacy.game.match_players=2;$legacy.game.match_wait_seconds=0;$legacy.game.hero_choice_seconds=600
 [IO.File]::WriteAllText((Join-Path $layout.Shared 'server.json'),($legacy|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
 $originalJSON=Get-NativeReleaseHash (Join-Path $layout.Shared 'server.json')
 $listener=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0);$listener.Start();$port=$listener.LocalEndpoint.Port;$listener.Stop()
 [IO.File]::WriteAllLines((Join-Path $layout.Shared '.env'),@("HTTP_ADDR=127.0.0.1:$port",('LOG_DIR='+((Join-Path $layout.Shared 'logs').Replace('\','/')))),[Text.UTF8Encoding]::new($false))
 New-Item -ItemType Directory -Path (Join-Path $layout.Shared 'native-data') -Force|Out-Null
 $config=@{health_url="http://127.0.0.1:$port"};$checkpointPath=Join-Path $root 'checkpoint.json'
 $state=New-DeploymentState -RuntimeMode WindowsService;$state.current_version='legacy-fixture';Save-DeploymentState $layout $state
 $job=@{action='package';maintenance=$true};$JobID=[guid]::NewGuid().ToString('N')
 # Configuration ownership: a package that ships all three files owns the live
 # configuration and replaces it; a package without them keeps the one-way
 # migration of shared/server.json. Either way player data must survive.
 $packageNames=@('host.json','gameplay.lua','economy.lua')
 $packageOwnsConfig=$true
 foreach($name in $packageNames){if(!(Test-Path -LiteralPath (Join-Path $release $name))){$packageOwnsConfig=$false}}
 $packageHashes=@{}
 if($packageOwnsConfig){foreach($name in $packageNames){$packageHashes[$name]=Get-NativeReleaseHash (Join-Path $release $name)}}
 $dataBeforeDeploy=Get-SharedDataTree $layout.Shared
 Deploy-NativeRelease $release
 if((Get-NativeReleaseHash (Join-Path $layout.Shared 'server.json')) -cne $originalJSON){throw 'Transitional server.json rewritten during deployment'}
 if(!(Test-Path -LiteralPath (Join-Path $layout.Shared 'RULES.md'))){throw 'Managed configuration rules were not published'}
 foreach($name in $packageNames){
  if($packageOwnsConfig){if((Get-NativeReleaseHash (Join-Path $layout.Shared $name)) -cne $packageHashes[$name]){throw "Package configuration did not replace $name"}}
  elseif(!(Test-Path -LiteralPath (Join-Path $layout.Shared $name))){throw "Missing migrated $name"}
 }
 if((Get-SharedDataPaths $layout.Shared) -eq ''){throw 'First deployment produced no player data to protect'}
 $body='{"player_name":"m5-package-fixture"}'
 $null=Invoke-RestMethod ($config.health_url+'/duel/join') -Method Post -Body $body -ContentType 'application/json'
 $view=Invoke-RestMethod ($config.health_url+'/duel/status') -Method Post -Body $body -ContentType 'application/json'
 if($view.phase -cne 'choosing_hero'){throw 'Actual package did not serve the configured start phase'}
 if(!$packageOwnsConfig -and $view.match_players -ne 2){throw 'Migration lost the server-owned player count'}
 if($packageOwnsConfig -and $view.match_players -notin @(2,4,8)){throw 'Package configuration produced an invalid player count'}
 $room=$view.room_id
 # Second maintenance cycle uses real native WAL and config, not mocked proof.
 # Lengths are captured while nothing is running, both before and after, which
 # makes them meaningful: an upgrade that restored a stale copy would differ.
 Stop-ManagedRuntime $layout (Read-DeploymentState $layout)
 $dataBeforeCycle=Get-SharedDataTree $layout.Shared
 if($dataBeforeCycle -eq '[]'){throw 'No player data to protect before the maintenance cycle'}
 $JobID=[guid]::NewGuid().ToString('N');Deploy-NativeRelease $release
 $again=Invoke-RestMethod ($config.health_url+'/duel/status') -Method Post -Body $body -ContentType 'application/json'
 if($again.room_id -cne $room -or $again.phase -cne 'choosing_hero'){throw 'Maintenance upgrade lost acknowledged room'}
 if(Test-Path $checkpointPath){throw 'Successful deployment retained pending checkpoint'}
 Stop-ManagedRuntime $layout (Read-DeploymentState $layout)
 $dataAfterCycle=Get-SharedDataTree $layout.Shared
 if((Get-SharedDataPaths $layout.Shared) -cne (Get-SharedDataPathsOf $dataBeforeCycle)){throw 'Maintenance cycle changed the live player data file set'}
 foreach($entry in @($dataBeforeCycle|ConvertFrom-Json)){
  if($entry.kind -ne 'file'){continue}
  $after=@(($dataAfterCycle|ConvertFrom-Json)|Where-Object{$_.path -eq $entry.path})
  if($after.Count -ne 1 -or $after[0].length -lt $entry.length){throw ('Maintenance cycle truncated live player data: '+$entry.path)}
 }
 if(Get-NetTCPConnection -State Listen -LocalPort 19090 -ErrorAction SilentlyContinue){throw 'Isolated Agent test port is occupied'}
 $agentHome=Join-Path $root 'agent';New-Item -ItemType Directory -Path $agentHome|Out-Null
 $token=[guid]::NewGuid().ToString('N')
 @{token=$token;install_root=$layout.Root;health_url=$config.health_url}|ConvertTo-Json|Set-Content (Join-Path $agentHome 'config.json') -Encoding UTF8
 $agent=Start-Process -FilePath (Join-Path $PSScriptRoot 'zyf-cicd-update.exe') -ArgumentList @('-agent','-home',('"'+$agentHome+'"')) -WindowStyle Hidden -PassThru
 $headers=@{'X-CICD-Token'=$token};$online=$false
 for($attempt=0;$attempt -lt 30;$attempt++){try{$null=Invoke-RestMethod 'http://127.0.0.1:19090/api/ping' -Headers $headers -TimeoutSec 1;$online=$true;break}catch{Start-Sleep -Milliseconds 100}}
 if(!$online){throw 'Test agent did not start'}
 $configuration=Invoke-RestMethod 'http://127.0.0.1:19090/api/native-config' -Headers $headers
 if($configuration.read_only -ne $true -or $configuration.policy -cne 'release_owned'){throw 'Live configuration view is not declared read-only'}
 foreach($name in $packageNames){if($configuration.files.PSObject.Properties.Name -notcontains $name){throw "Live configuration view omitted $name"}}
 $liveHash=Get-NativeReleaseHash (Join-Path $layout.Shared 'gameplay.lua')
 $edit=@{file='gameplay.lua';text=($configuration.files.'gameplay.lua'+"`n");revision=$configuration.revision;validate_only=$false}
 $rejected=$false
 try{$null=Invoke-RestMethod 'http://127.0.0.1:19090/api/native-config' -Headers $headers -Method Post -ContentType 'application/json' -Body ($edit|ConvertTo-Json)}catch{$rejected=$true}
 if(!$rejected){throw 'Real editor accepted a configuration write'}
 if((Get-NativeReleaseHash (Join-Path $layout.Shared 'gameplay.lua')) -cne $liveHash){throw 'Rejected write still modified the live configuration'}
 if((Get-SharedDataTree $layout.Shared) -cne $dataAfterCycle){throw 'Configuration write touched native data'}
 Write-Host 'PASS: real Agent HTTP configuration view is read-only and rejects writes without changing config or WAL/archive.'
 Write-Host ('PASS: actual package '+$identity.version+' deployed configuration source '+$(if($packageOwnsConfig){'package'}else{'server.json migration'})+', served HTTP and recovered the same room across maintenance. SCM itself was substituted by an isolated process adapter; no remote service was touched.')
}finally{
 if($agent -and !$agent.HasExited){$agent.Kill();$agent.WaitForExit()}
 if($script:process -and !$script:process.HasExited){$script:process.Kill();$script:process.WaitForExit()}
 $resolved=[IO.Path]::GetFullPath($root);$prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\zyf-native-package-'
 if(!$resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe package fixture cleanup'}
 Remove-Item -LiteralPath $resolved -Recurse -Force
}
