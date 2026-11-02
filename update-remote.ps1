param([string]$Destination='C:\Services\zyf-cicd',[string]$ExpectedCheckpointSHA256='')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$Destination=[IO.Path]::GetFullPath($Destination)
$principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if(!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Run on the remote machine in Administrator PowerShell'}
$service=Get-CimInstance Win32_Service -Filter "Name='ZYF-CICD-Agent'"
if(!$service -or !$service.PathName.StartsWith(('"'+(Join-Path $Destination 'zyf-cicd.exe')+'"'),[StringComparison]::OrdinalIgnoreCase)){throw 'Installed agent path does not match Destination'}
$manifest=Get-Content (Join-Path $PSScriptRoot 'agent-files.json') -Raw|ConvertFrom-Json
$files=@('zyf-cicd.exe','worker.ps1','native-worker.ps1','native-maintenance.ps1','native-release.ps1','native-migration.ps1','host-policy-worker.ps1','prepare-server-config.ps1','deploy/common.ps1')
foreach($name in $files){
 $hash=(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $name) -Algorithm SHA256).Hash.ToLowerInvariant()
 if($manifest.$name -cne $hash){throw "Update file hash mismatch: $name"}
}
$lock=[IO.File]::Open((Join-Path $Destination 'worker.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
try{
 $pending=Join-Path $Destination 'checkpoint.json'
 if(Test-Path -LiteralPath $pending){
  if($ExpectedCheckpointSHA256 -cnotmatch '^[a-f0-9]{64}$' -or (Get-FileHash -LiteralPath $pending).Hash.ToLowerInvariant() -cne $ExpectedCheckpointSHA256){throw 'Pending checkpoint: review it and pass its exact SHA256 to update without deleting it'}
  $checkpoint=Get-Content -LiteralPath $pending -Raw -Encoding UTF8|ConvertFrom-Json
  if($checkpoint.PSObject.Properties.Name -notcontains 'kind' -or $checkpoint.kind -notin @('native-v1','native-migration-v1')){throw 'Unsupported pending checkpoint; cannot promise compatible recovery'}
 }elseif($ExpectedCheckpointSHA256){throw 'Expected checkpoint disappeared'}
}catch{$lock.Dispose();throw}
$backup=Join-Path $Destination ('agent-backup-'+[DateTime]::UtcNow.ToString('yyyyMMddHHmmss')+'-'+[guid]::NewGuid().ToString('N'))
try{
 Stop-Service 'ZYF-CICD-Agent' -ErrorAction Stop
 (Get-Service 'ZYF-CICD-Agent').WaitForStatus([ServiceProcess.ServiceControllerStatus]::Stopped,[TimeSpan]::FromSeconds(30))
 New-Item -ItemType Directory -Path $backup|Out-Null
 foreach($name in $files){$old=Join-Path $Destination $name;if(Test-Path $old){$saved=Join-Path $backup $name;New-Item -ItemType Directory -Path (Split-Path $saved -Parent) -Force|Out-Null;Copy-Item -LiteralPath $old -Destination $saved}}
 foreach($name in $files){Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination (Join-Path $Destination $name) -Force;if((Get-FileHash -LiteralPath (Join-Path $Destination $name)).Hash.ToLowerInvariant() -cne $manifest.$name){throw ('Installed update hash mismatch: '+$name)}}
 Start-Service 'ZYF-CICD-Agent' -ErrorAction Stop
 (Get-Service 'ZYF-CICD-Agent').WaitForStatus([ServiceProcess.ServiceControllerStatus]::Running,[TimeSpan]::FromSeconds(30))
 Write-Host 'Agent updated. Existing config, keys, jobs and game service were preserved.'
}catch{
 $failure=$_.Exception.Message
 Stop-Service 'ZYF-CICD-Agent' -ErrorAction SilentlyContinue
 foreach($name in $files){$saved=Join-Path $backup $name;if(Test-Path $saved){Copy-Item -LiteralPath $saved -Destination (Join-Path $Destination $name) -Force}}
 Start-Service 'ZYF-CICD-Agent' -ErrorAction SilentlyContinue
 throw $failure
}finally{$lock.Dispose()}
