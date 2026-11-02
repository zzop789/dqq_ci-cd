# Run on the REMOTE server in Administrator PowerShell. Contains a PUBLIC key only.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
if(!(New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Open Administrator PowerShell on the remote server first.'}
$publicKey='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBr8Gn9tf9TJX45W095WJC8o6Ee55g8lSxhm5zOEXwJf zyf-cicd-management'
$path=Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'
New-Item -ItemType Directory -Path (Split-Path $path -Parent) -Force|Out-Null
$lines=@()
if(Test-Path -LiteralPath $path){$lines=@(Get-Content -LiteralPath $path);Copy-Item -LiteralPath $path -Destination ($path+'.backup-'+[DateTime]::Now.ToString('yyyyMMddHHmmss'))}
if($lines -notcontains $publicKey){($lines+$publicKey)|Set-Content -LiteralPath $path -Encoding ASCII}
& icacls.exe $path /inheritance:r /grant:r '*S-1-5-32-544:F' '*S-1-5-18:F'
if($LASTEXITCODE -ne 0){throw 'ACL update failed'}
Write-Host 'PUBLIC KEY INSTALLED. No SSH service restart is required.'
