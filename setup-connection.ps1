Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$config=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'config.json') -Raw -Encoding UTF8|ConvertFrom-Json
$key=[string]$config.key
if(!(Test-Path -LiteralPath $key)){
 New-Item -ItemType Directory -Path (Split-Path $key -Parent) -Force|Out-Null
 Write-Host 'Generating a dedicated deployment key. For unattended use, press Enter twice for an empty passphrase; protect this file.'
 & ssh-keygen.exe -t ed25519 -f $key -C 'zyf-cicd-management'
 if($LASTEXITCODE -ne 0){throw 'Key generation failed'}
}
$publicKey=(Get-Content -LiteralPath "$key.pub" -Raw).Trim()
$public64=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($publicKey))
$remote=@'
$ErrorActionPreference='Stop'
$pub=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__PUBLIC__'))
$id=[Security.Principal.WindowsIdentity]::GetCurrent()
$admin=(New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if($admin){$path=Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'}else{$dir=Join-Path $env:USERPROFILE '.ssh';New-Item -ItemType Directory -Path $dir -Force|Out-Null;$path=Join-Path $dir 'authorized_keys'}
if(!(Test-Path -LiteralPath $path)){New-Item -ItemType File -Path $path -Force|Out-Null}
$lines=@(Get-Content -LiteralPath $path)
if($lines -notcontains $pub){Add-Content -LiteralPath $path -Value $pub -Encoding ASCII}
if($admin){icacls.exe $path /inheritance:r /grant:r '*S-1-5-32-544:F' '*S-1-5-18:F'|Out-Null}else{icacls.exe $path /inheritance:r /grant:r ($id.Name+':F') '*S-1-5-18:F' '*S-1-5-32-544:F'|Out-Null}
if($LASTEXITCODE -ne 0){throw 'Key ACL setup failed'}
Write-Output ('Public key installed at '+$path)
'@
$remote=$remote.Replace('__PUBLIC__',$public64)
$encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($remote))
$target=$config.user+'@'+$config.host
Write-Host 'The following SSH prompt is the remote Windows password. Nothing is stored in this app.'
& ssh.exe -o StrictHostKeyChecking=yes -p $config.port $target powershell.exe -NoProfile -NonInteractive -EncodedCommand $encoded
if($LASTEXITCODE -ne 0){
 Write-Host 'Public key exists locally, but remote installation failed. Do not regenerate it.'
 Write-Host 'On the REMOTE server, open Administrator PowerShell and run remote-authorize-key.ps1 from this software folder (copy that PUBLIC-key-only script over first).'
 throw 'Remote public-key installation needs an elevated remote terminal. UAC and global SSH policy were not changed.'
}
& ssh.exe -o BatchMode=yes -o StrictHostKeyChecking=yes -o IdentitiesOnly=yes -i $key -p $config.port $target whoami
if($LASTEXITCODE -ne 0){throw 'Key authentication still failed. Check remote sshd_config Match rules and ACLs.'}
Write-Host 'Key authentication succeeded.'
