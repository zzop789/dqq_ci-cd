param([string]$Destination='C:\Services\zyf-cicd')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$Destination=[IO.Path]::GetFullPath($Destination)
if(!(Test-Path -LiteralPath (Join-Path $Destination 'config.json'))){throw 'Installed agent config not found'}
$files=@('native-worker.ps1','native-maintenance.ps1','native-release.ps1','native-migration.ps1')
$manifest=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'script-files.json') -Raw|ConvertFrom-Json
foreach($name in $files){
 if((Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $name)).Hash.ToLowerInvariant() -cne $manifest.$name){throw ('Script hash mismatch: '+$name)}
}
# Every worker holds this OS lock before loading native scripts. Replacement
# cannot race a deploy/recover, and scripts are reloaded for the next job.
$lock=[IO.File]::Open((Join-Path $Destination 'worker.lock'),'OpenOrCreate','ReadWrite','None')
$backup=Join-Path $Destination ('script-backup-'+[guid]::NewGuid().ToString('N'))
$written=@()
try{
 if(Test-Path -LiteralPath (Join-Path $Destination 'checkpoint.json')){throw 'Unfinished deployment checkpoint exists; finish recovery before installing this script update'}
 [IO.Directory]::CreateDirectory($backup)|Out-Null
 foreach($name in $files){if(Test-Path -LiteralPath (Join-Path $Destination $name)){[IO.File]::Copy((Join-Path $Destination $name),(Join-Path $backup $name),$false)}}
 foreach($name in $files){
  $written+=$name
  [IO.File]::Copy((Join-Path $PSScriptRoot $name),(Join-Path $Destination $name),$true)
  if((Get-FileHash -LiteralPath (Join-Path $Destination $name)).Hash.ToLowerInvariant() -cne $manifest.$name){throw ('Installed hash mismatch: '+$name)}
 }
 Write-Host ('Deployment scripts updated; next task uses them. No services restarted. Backup: '+$backup)
}catch{
 foreach($name in $written){$old=Join-Path $backup $name;$target=Join-Path $Destination $name;if(Test-Path -LiteralPath $old){[IO.File]::Copy($old,$target,$true)}else{[IO.File]::Delete($target)}}
 throw
}finally{$lock.Dispose()}
