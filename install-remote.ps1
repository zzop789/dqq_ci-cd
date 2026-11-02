param([string]$Destination='C:\Services\zyf-cicd',[string]$GameRoot='C:\Services\kk-mid-server')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
if(!(New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Run this script in Administrator PowerShell on the REMOTE server.'}
# Local artifact deployment needs no remote Git or Go. They are optional for repository builds.
$Destination=[IO.Path]::GetFullPath($Destination)
$GameRoot=[IO.Path]::GetFullPath($GameRoot)
if($Destination.TrimEnd('\') -eq [IO.Path]::GetPathRoot($Destination).TrimEnd('\')){throw 'Destination must not be a drive root'}
if(Get-Service 'ZYF-CICD-Agent' -ErrorAction SilentlyContinue){throw 'Agent already installed. Stop after jobs finish, back up config/state, and upgrade files manually.'}
if(Get-Service 'kk-mid-server-staging' -ErrorAction SilentlyContinue){throw 'Existing game service found. Review its executable and install root before adopting; installer will not replace it.'}
if(Test-Path -LiteralPath (Join-Path $GameRoot 'state\deployment.json')){throw 'Existing deployment state found; installer will not overwrite an existing installation.'}
$gamePort=8080
if(Get-NetTCPConnection -State Listen -LocalPort $gamePort -ErrorAction SilentlyContinue){throw 'Game port 8080 is occupied. Stop/adopt the existing service explicitly before installation.'}
New-Item -ItemType Directory -Path $Destination -Force|Out-Null
foreach($name in @('zyf-cicd.exe','worker.ps1','native-worker.ps1','native-maintenance.ps1','native-release.ps1','native-migration.ps1','host-policy-worker.ps1','prepare-server-config.ps1','config.json','deploy')){
 $source=Join-Path $PSScriptRoot $name
 if(!(Test-Path -LiteralPath $source)){throw "Missing package file: $source"}
 Copy-Item -LiteralPath $source -Destination $Destination -Recurse -Force
}
$configPath=Join-Path $Destination 'config.json'
$config=Get-Content -LiteralPath $configPath -Raw -Encoding UTF8|ConvertFrom-Json
$config.root=$Destination;$config.install_root=$GameRoot
[IO.File]::WriteAllText($configPath,($config|ConvertTo-Json),(New-Object Text.UTF8Encoding($false)))
Write-Host 'Enter the REMOTE Windows account credential (e.g. COMPUTER\alw). SCM stores the service credential, not this script.'
$credential=Get-Credential -UserName "$env:COMPUTERNAME\alw" -Message 'Remote deployment service account'
if(!$credential){throw 'Credential cancelled'}
# This trusted-code staging account must have service-control and release-directory permissions.
$sid=(New-Object Security.Principal.NTAccount($credential.UserName)).Translate([Security.Principal.SecurityIdentifier]).Value
& icacls.exe $Destination /inheritance:r /grant:r "*${sid}:(OI)(CI)F" '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F'|Out-Null
if($LASTEXITCODE -ne 0){throw 'Failed to protect deployment directory'}
. (Join-Path $Destination 'deploy\common.ps1')
$layout=Get-DeploymentLayout -InstallRoot $GameRoot
Initialize-DeploymentLayout -Layout $layout
if(!(Test-Path -LiteralPath $layout.Environment)){
 @('APP_ENV=staging','HTTP_ADDR=:8080','PUBLIC_BASE_URL=http://192.168.2.7:8080',"LOG_DIR=$($layout.Logs)")|Set-Content -LiteralPath $layout.Environment -Encoding ASCII
}
$state=New-DeploymentState -RuntimeMode WindowsService
Save-DeploymentState -Layout $layout -State $state
# The executable is created by the first deployment. Service remains stopped until then.
New-Service -Name 'kk-mid-server-staging' -BinaryPathName ('"'+(Join-Path $layout.Current 'server.exe')+'"') -DisplayName 'KK Mid Server (Staging)' -StartupType Manual|Out-Null
try {
 New-Service -Name 'ZYF-CICD-Agent' -BinaryPathName ('"'+(Join-Path $Destination 'zyf-cicd.exe')+'" -agent -home "'+$Destination+'"') -DisplayName 'ZYF CICD Deployment Agent' -StartupType Automatic -Credential $credential|Out-Null
 Start-Service 'ZYF-CICD-Agent'
}catch {throw ('Game service was registered but agent failed: '+$_.Exception.Message+'. Check account log-on-as-service policy; do not reinstall blindly.')}
Write-Host 'Agent installed. Management API listens ONLY on 127.0.0.1:19090. No public API firewall rule is needed.'
Write-Host 'Game port 8080 firewall and automatic restart policy must be explicitly configured for your test network.'
Write-Host 'Under the service account, verify Git access once: git ls-remote <repo>. Do NOT forward your personal SSH agent.'
