Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$testRoot=Join-Path $PSScriptRoot ('test-results\worker-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot -Force|Out-Null
function Json($path,$value){[IO.File]::WriteAllText($path,($value|ConvertTo-Json -Depth 10),(New-Object Text.UTF8Encoding($false)))}
$mock=@'
function Get-DeploymentLayout($InstallRoot){return [pscustomobject]@{Root=$InstallRoot;Releases=(Join-Path $InstallRoot 'releases');Current=(Join-Path $InstallRoot 'current');StateFile=(Join-Path $InstallRoot 'state.json')}}
function Initialize-DeploymentLayout($Layout){}
function Read-DeploymentState($Layout){return Get-Content -LiteralPath $Layout.StateFile -Raw|ConvertFrom-Json}
function Save-DeploymentState($Layout,$State){[IO.File]::WriteAllText($Layout.StateFile,($State|ConvertTo-Json))}
function Enter-DeploymentLock($Layout){return [IO.File]::Open((Join-Path $Layout.Root 'deploy.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}
function Assert-ChildPath($ParentPath,$ChildPath){if(!$ChildPath.StartsWith($ParentPath+'\')){throw 'unsafe'}}
function Test-ReleaseChecksums($ReleaseRoot){if(!(Test-Path -LiteralPath (Join-Path $ReleaseRoot 'server.exe'))){throw 'missing release'}}
function Get-ReleaseVersion($ReleaseRoot){$v=Split-Path $ReleaseRoot -Leaf;return [pscustomobject]@{SafeVersion=$v;Version=$v;BuildInfo=[pscustomobject]@{schema_version=1}}}
function Stop-ManagedRuntime($Layout,$State){[IO.File]::WriteAllText((Join-Path $Layout.Root 'runtime.txt'),'stopped')}
function Start-ManagedRuntime($Layout,$State){[IO.File]::WriteAllText((Join-Path $Layout.Root 'runtime.txt'),$State.current_version)}
function Set-CurrentFromRelease($Layout,$ReleasePath){if((Test-Path -LiteralPath (Join-Path $Layout.Root 'fail-switch')) -and (Split-Path $ReleasePath -Leaf) -eq 'B'){throw 'injected switch failure after stop'};[IO.File]::WriteAllText((Join-Path $Layout.Root 'current.txt'),(Split-Path $ReleasePath -Leaf))}
function Wait-ApplicationHealthy($HealthBaseURL,$ExpectedVersion,$TimeoutSeconds){if((Get-Content -LiteralPath (Join-Path $config.install_root 'runtime.txt')) -ne $ExpectedVersion){throw 'wrong running release'};return @{version=$ExpectedVersion}}
function Get-Service($Name){return @{StartType='Automatic';Status='Running'}}
function Set-Service($Name,$StartupType){}
function Checked($Program,$Arguments){}
'@
$results=@()
foreach($scenario in @('rollback-success','rollback-failure','stale-version','checkpoint-block','exclusive-lock')){
 $caseRoot=Join-Path $testRoot $scenario
 foreach($dir in @('deploy','jobs','game\releases\A','game\releases\B')){New-Item -ItemType Directory -Path (Join-Path $caseRoot $dir) -Force|Out-Null}
 [IO.File]::WriteAllText((Join-Path $caseRoot 'deploy\common.ps1'),$mock)
 Copy-Item (Join-Path $PSScriptRoot 'prepare-server-config.ps1') $caseRoot
 New-Item -ItemType Directory (Join-Path $caseRoot 'game\shared') -Force|Out-Null
 [IO.File]::WriteAllText((Join-Path $caseRoot 'game\shared\server.json'),'{}')
 foreach($version in @('A','B')){[IO.File]::WriteAllText((Join-Path $caseRoot "game\releases\$version\server.exe"),'fixture')}
 [IO.File]::WriteAllText((Join-Path $caseRoot 'game\runtime.txt'),'A')
 Json (Join-Path $caseRoot 'config.json') @{install_root=(Join-Path $caseRoot 'game');health_url='http://127.0.0.1:1'}
 Json (Join-Path $caseRoot 'game\state.json') @{current_version='A';previous_version='B';service_name='fixture';runtime_mode='WindowsService';deployed_at_utc=''}
 $id='a'*32
 $expected='A';if($scenario -eq 'stale-version'){$expected='wrong'}
 Json (Join-Path $caseRoot "jobs\$id.json") @{id=$id;action='rollback';expected=$expected;maintenance=$true}
 if($scenario -eq 'rollback-failure'){[IO.File]::WriteAllText((Join-Path $caseRoot 'game\fail-switch'),'1')}
 if($scenario -eq 'checkpoint-block'){Json (Join-Path $caseRoot 'checkpoint.json') @{pending=$true}}
 $held=$null
 if($scenario -eq 'exclusive-lock'){$held=[IO.File]::Open((Join-Path $caseRoot 'worker.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}
 try {& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'worker.ps1') -HomeDir $caseRoot -JobID $id *> (Join-Path $caseRoot 'log.txt');$code=$LASTEXITCODE}finally{if($held){$held.Dispose()}}
 $state=Get-Content -LiteralPath (Join-Path $caseRoot 'game\state.json') -Raw|ConvertFrom-Json
 $runtime=Get-Content -LiteralPath (Join-Path $caseRoot 'game\runtime.txt')
 if($scenario -eq 'rollback-success'){if($code -ne 0 -or $state.current_version -ne 'B' -or $runtime -ne 'B'){throw "$scenario failed"}}
 else {if($code -eq 0 -or $state.current_version -ne 'A' -or $runtime -ne 'A'){throw "$scenario failed"}}
 if($scenario -eq 'rollback-failure' -and (Test-Path -LiteralPath (Join-Path $caseRoot 'checkpoint.json'))){throw 'successful recovery left a checkpoint'}
 $results+= [pscustomobject]@{scenario=$scenario;passed=$true;exit_code=$code}
}
Json (Join-Path $testRoot 'results.json') $results
$results|Format-Table -AutoSize
Write-Host "Evidence: $testRoot"
