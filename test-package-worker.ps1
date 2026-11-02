Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Join-Path $PSScriptRoot ('test-results\package-'+[guid]::NewGuid().ToString('N'))
$mock=@'
function Get-Service($Name){$status='Running';if(Test-Path (Join-Path $config.install_root 'was-stopped')){$status='Stopped'};return @{StartType='Automatic';Status=$status}}
function Set-Service($Name,$StartupType){}
function Stop-ManagedRuntime($Layout,$State){[IO.File]::WriteAllText((Join-Path $Layout.Root 'runtime.txt'),'stopped')}
function Start-ManagedRuntime($Layout,$State){[IO.File]::WriteAllText((Join-Path $Layout.Root 'runtime.txt'),$State.current_version)}
function Wait-ApplicationHealthy($HealthBaseURL,$ExpectedVersion,$TimeoutSeconds){if((Get-Content -LiteralPath (Join-Path $config.install_root 'runtime.txt')) -ne $ExpectedVersion){throw 'wrong runtime'};if((Test-Path (Join-Path $config.install_root 'fail-probe')) -and $ExpectedVersion -eq 'B'){throw 'injected unhealthy package'};return @{version=$ExpectedVersion;git_commit=('a'*40)}}
'@
. (Join-Path $PSScriptRoot 'deploy\common.ps1')
$results=@()
foreach($scenario in @('success','corrupt-zip','corrupt-file','probe-failure','existing-identical','existing-different','stopped-probe-failure','config-valid','config-invalid','config-missing','native-blocked')){
 $case=Join-Path $root $scenario
 foreach($dir in @('deploy','jobs','uploads','fixture\A','fixture\B')){New-Item -ItemType Directory -Path (Join-Path $case $dir) -Force|Out-Null}
 $real=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'deploy\common.ps1'))
 [IO.File]::WriteAllText((Join-Path $case 'deploy\common.ps1'),($real+"`n"+$mock),[Text.UTF8Encoding]::new($true))
 Copy-Item (Join-Path $PSScriptRoot 'prepare-server-config.ps1') $case
 & {
  Add-Content -LiteralPath (Join-Path $case 'deploy\common.ps1') -Value @'
function Checked($Program,$Arguments){
 if($Arguments[0] -ne '-check-config'){throw 'unexpected preflight arguments'}
 if((Get-Content (Join-Path $config.install_root 'runtime.txt')) -notin @('A','stopped')){throw 'preflight executed after stop'}
 if(!(Test-Path $env:SERVER_CONFIG_FILE)){throw 'missing preflight config'}
 if($config.install_root -like '*config-invalid*'){throw 'injected invalid gameplay config'}
}
'@
 }
 $layout=Get-DeploymentLayout -InstallRoot (Join-Path $case 'game');Initialize-DeploymentLayout -Layout $layout
 foreach($v in @('A','B')){
  $release=Join-Path $case "fixture\$v"
  [IO.File]::WriteAllText((Join-Path $release 'server.exe'),'fixture-'+$v)
  @{version=$v;git_commit=('a'*40);git_dirty=$true;checks_skipped=$false;target='windows/amd64'}|ConvertTo-Json|Set-Content (Join-Path $release 'BUILD_INFO.json') -Encoding UTF8
  if($scenario -like 'config-*' -and $v -eq 'B'){New-Item -ItemType Directory (Join-Path $release 'configs')|Out-Null;[IO.File]::WriteAllText((Join-Path $release 'configs\server.json'),'{}')}
  if($scenario -eq 'native-blocked' -and $v -eq 'B'){[IO.File]::WriteAllText((Join-Path $release 'gamecore.dll'),'native-fixture')}
  $sums=Get-ChildItem $release -File -Recurse|ForEach-Object{(Get-Sha256Hex $_.FullName)+'  '+$_.FullName.Substring($release.Length+1)}
  $sums|Set-Content (Join-Path $release 'SHA256SUMS') -Encoding ASCII
 }
 if($scenario -ne 'config-missing'){[IO.File]::WriteAllText((Join-Path (Join-Path $layout.Root 'shared') 'server.json'),'{}')}
 Copy-Item (Join-Path $case 'fixture\A') $layout.Releases -Recurse
 Set-CurrentFromRelease -Layout $layout -ReleasePath (Join-Path $layout.Releases 'A')
 $state=New-DeploymentState -RuntimeMode WindowsService;$state.current_version='A';Save-DeploymentState -Layout $layout -State $state
 [IO.File]::WriteAllText((Join-Path $layout.Root 'runtime.txt'),'A')
 if($scenario -eq 'stopped-probe-failure'){
  [IO.File]::WriteAllText((Join-Path $layout.Root 'runtime.txt'),'stopped')
  New-Item (Join-Path $layout.Root 'was-stopped') -ItemType File|Out-Null
 }
 if($scenario -eq 'corrupt-file'){Add-Content (Join-Path $case 'fixture\B\server.exe') 'tampered'}
 $zip=Join-Path $case 'fixture.zip';Compress-Archive -LiteralPath (Join-Path $case 'fixture\B') -DestinationPath $zip
 $hash=Get-Sha256Hex $zip;Copy-Item $zip (Join-Path $case "uploads\$hash.zip")
 if($scenario -like 'existing-*'){
  Copy-Item (Join-Path $case 'fixture\B') $layout.Releases -Recurse
  if($scenario -eq 'existing-different'){[IO.File]::WriteAllText((Join-Path $layout.Releases 'B\unexpected.txt'),'keep-existing')}
 }
 if($scenario -eq 'corrupt-zip'){Add-Content (Join-Path $case "uploads\$hash.zip") 'tampered'}
 if($scenario -in @('probe-failure','stopped-probe-failure')){New-Item (Join-Path $layout.Root 'fail-probe') -ItemType File|Out-Null}
 @{install_root=$layout.Root;health_url='http://127.0.0.1:1'}|ConvertTo-Json|Set-Content (Join-Path $case 'config.json') -Encoding UTF8
 $id='b'*32
 @{id=$id;action='package';artifact=$hash;expected='A';maintenance=$true}|ConvertTo-Json|Set-Content (Join-Path $case "jobs\$id.json")
 & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'worker.ps1') -HomeDir $case -JobID $id *> (Join-Path $case 'log.txt')
 $code=$LASTEXITCODE;$after=Read-DeploymentState -Layout $layout;$runtime=Get-Content (Join-Path $layout.Root 'runtime.txt')
 $want='A';if($scenario -in @('success','existing-identical','config-valid')){$want='B';if($code -ne 0){throw "$scenario failed; $case"}}elseif($code -eq 0){throw "$scenario wrongly succeeded"}
 $wantRuntime=$want;if($scenario -eq 'stopped-probe-failure'){$wantRuntime='stopped'}
 if($after.current_version -ne $want -or $runtime -ne $wantRuntime){throw "$scenario failed to preserve/recover expected version and runtime"}
 if(Test-Path (Join-Path $case 'checkpoint.json')){throw "$scenario left unresolved checkpoint"}
 $results+=@{scenario=$scenario;passed=$true}
}
$results|ConvertTo-Json|Set-Content (Join-Path $root 'results.json')
$results|Format-Table
Write-Host "Evidence: $root"
