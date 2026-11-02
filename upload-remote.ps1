Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$c=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'config.json') -Raw -Encoding UTF8|ConvertFrom-Json
$target=$c.user+'@'+$c.host
$zip=Join-Path $PSScriptRoot 'remote-package.zip'
if(!(Test-Path -LiteralPath $zip)){throw 'Run build.ps1 first'}
$stage='zyf-cicd-update-'+[DateTime]::UtcNow.ToString('yyyyMMddHHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)
$remoteZip=$stage+'.zip'
& scp.exe -o BatchMode=yes -o StrictHostKeyChecking=yes -o IdentitiesOnly=yes -i $c.key -P $c.port $zip "${target}:$remoteZip"
if($LASTEXITCODE -ne 0){throw 'Upload failed. Run setup-connection.ps1 first.'}
$sshOptions=@('-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','-o','IdentitiesOnly=yes','-i',$c.key,'-p',[string]$c.port,$target)
$hash=(Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
$remoteHash=& ssh.exe @sshOptions ('certutil.exe -hashfile '+$remoteZip+' SHA256')
if($LASTEXITCODE -ne 0 -or @($remoteHash|Where-Object {$_.Trim().ToLowerInvariant() -eq $hash}).Count -ne 1){throw 'Uploaded archive checksum mismatch'}
# Avoid SSH PowerShell execution, which is denied on this server. These safe
# generated basenames contain only ASCII letters, digits and hyphens.
& ssh.exe @sshOptions ('cmd.exe /c mkdir '+$stage)
if($LASTEXITCODE -ne 0){throw 'Remote staging directory could not be created'}
& ssh.exe @sshOptions ('tar.exe -xf '+$remoteZip+' -C '+$stage)
if($LASTEXITCODE -ne 0){throw 'Remote extraction failed'}
$remotePath=& ssh.exe @sshOptions ('cmd.exe /c echo %USERPROFILE%\'+$stage)
if($LASTEXITCODE -ne 0){throw 'Cannot resolve remote staging path'}
Write-Host 'Upload verified. Run once in REMOTE Administrator PowerShell to update the existing Agent only:'
Write-Host ('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "'+(($remotePath -join '').Trim())+'\update-remote.ps1"')
