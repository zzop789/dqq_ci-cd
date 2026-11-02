Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'prepare-server-config.ps1')
$root=Join-Path $PSScriptRoot ('test-results\server-config-'+[guid]::NewGuid().ToString('N'))
$release=Join-Path $root 'release'
New-Item -ItemType Directory -Path (Join-Path $release 'configs') -Force|Out-Null
$template=Join-Path $release 'configs\server.json'
[IO.File]::WriteAllText($template,'{"game":{"match_players":4}}')
$saved=$env:SERVER_CONFIG_FILE
try{
 $env:SERVER_CONFIG_FILE=$null
 $target=Join-Path $root 'shared\server.json'
 $rejected=$false
 try{$null=Get-ManagedServerConfig -InstallRoot $root -ReleaseRoot $release}catch{$rejected=$true}
 if(!$rejected -or (Test-Path $target)){throw 'Deployment initialized missing configuration'}
 New-Item -ItemType Directory (Split-Path $target -Parent) -Force|Out-Null
 [IO.File]::WriteAllText($target,'{"game":{"match_players":8}}')
 $before=[IO.File]::ReadAllBytes($target)
 $null=Get-ManagedServerConfig -InstallRoot $root -ReleaseRoot $release
 if([Convert]::ToBase64String($before) -cne [Convert]::ToBase64String([IO.File]::ReadAllBytes($target))){throw 'Existing configuration overwritten'}
 $env:SERVER_CONFIG_FILE=Join-Path $root 'custom\server.json'
 New-Item -ItemType Directory (Split-Path $env:SERVER_CONFIG_FILE -Parent) -Force|Out-Null
 [IO.File]::WriteAllText($env:SERVER_CONFIG_FILE,'{}')
 $custom=Get-ManagedServerConfig -InstallRoot $root -ReleaseRoot $release
 if($custom -ne $env:SERVER_CONFIG_FILE -or !(Test-Path $custom)){throw 'Explicit selector ignored'}
 $env:SERVER_CONFIG_FILE='relative.json';$rejected=$false
 try{$null=Get-ManagedServerConfig -InstallRoot $root -ReleaseRoot $release}catch{$rejected=$true}
 if(!$rejected){throw 'Relative selector accepted'}
 Write-Host 'PASS: missing rejected without creation, existing preserved, explicit path honored, relative path rejected; no service started.'
}finally{$env:SERVER_CONFIG_FILE=$saved}
