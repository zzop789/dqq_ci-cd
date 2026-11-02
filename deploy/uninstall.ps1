[CmdletBinding()]
param(
    [string]$InstallRoot = "C:\Services\kk-mid-server",
    [switch]$RemoveData
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

# 默认只停止并移除托管，不删除 release、日志、状态或 .env。
# -RemoveData 是唯一会递归删除安装根的入口，且仍经过安全根目录校验。
$layout = Get-DeploymentLayout -InstallRoot $InstallRoot
Initialize-DeploymentLayout -Layout $layout
$lock = Enter-DeploymentLock -Layout $layout
try {
    $state = Read-DeploymentState -Layout $layout
    Stop-ManagedRuntime -Layout $layout -State $state

    $service = Get-Service -Name $script:DefaultServiceName -ErrorAction SilentlyContinue
    if ($service) {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            throw "Removing the Windows service requires an elevated PowerShell session."
        }
        & sc.exe delete $script:DefaultServiceName | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to remove Windows service '$script:DefaultServiceName'."
        }
    }
} finally {
    $lock.Dispose()
}

if ($RemoveData) {
    $safeRoot = Resolve-SafeInstallRoot -InstallRoot $InstallRoot
    if (Test-Path -LiteralPath $safeRoot) {
        Remove-Item -LiteralPath $safeRoot -Recurse -Force
        Write-Host "Installation data permanently removed: $safeRoot"
    }
} else {
    Write-Host "Runtime uninstalled. Releases, logs, state, and .env were preserved at $($layout.Root)."
}
