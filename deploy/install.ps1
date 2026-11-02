[CmdletBinding()]
param(
    [string]$InstallRoot = "C:\Services\kk-mid-server",
    [ValidateSet("Process", "WindowsService")][string]$RuntimeMode = "Process",
    [string]$HTTPAddr = ":8080",
    [string]$AppEnvironment = "staging",
    [ValidateRange(1, 64)][int]$DuelTotalRounds = 6,
    [switch]$InstallWindowsService
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

# install 只初始化持久目录和运行方式，不部署业务版本。shared/.env 仅在
# 首次不存在时创建，后续升级和重新执行本脚本都不会覆盖现场配置。
$layout = Get-DeploymentLayout -InstallRoot $InstallRoot
Initialize-DeploymentLayout -Layout $layout

if (-not (Test-Path -LiteralPath $layout.Environment)) {
    @(
        "APP_ENV=$AppEnvironment",
        "HTTP_ADDR=$HTTPAddr",
        "DUEL_TOTAL_ROUNDS=$DuelTotalRounds",
        "LOG_DIR=$($layout.Logs)"
    ) | Set-Content -LiteralPath $layout.Environment -Encoding ASCII
}

$templateCandidates = @(
    (Join-Path $PSScriptRoot "..\..\.env.example"),
    (Join-Path $PSScriptRoot "..\.env.example")
)
foreach ($candidate in $templateCandidates) {
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        Copy-Item -LiteralPath $candidate -Destination $layout.EnvExample -Force
        break
    }
}

$state = Read-DeploymentState -Layout $layout
$state.runtime_mode = $RuntimeMode
$state.service_name = $script:DefaultServiceName
Save-DeploymentState -Layout $layout -State $state

if ($InstallWindowsService) {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Installing a Windows service requires an elevated PowerShell session."
    }
    $executable = Join-Path $layout.Current "server.exe"
    if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
        throw "Deploy a release before installing the Windows service: $executable"
    }
    $existingService = Get-Service -Name $script:DefaultServiceName -ErrorAction SilentlyContinue
    if (-not $existingService) {
        New-Service `
            -Name $script:DefaultServiceName `
            -BinaryPathName ('"{0}"' -f $executable) `
            -DisplayName "KK Mid Server (Staging)" `
            -Description "Dota auto-battler staging server" `
            -StartupType Automatic | Out-Null
    }
    & sc.exe failure $script:DefaultServiceName reset= 86400 actions= restart/5000/restart/15000/""/0 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to configure Windows service recovery."
    }
    $state.runtime_mode = "WindowsService"
    Save-DeploymentState -Layout $layout -State $state
}

Write-Host "Install root initialized: $($layout.Root)"
Write-Host "Runtime mode:            $($state.runtime_mode)"
Write-Host "Environment file:         $($layout.Environment)"
