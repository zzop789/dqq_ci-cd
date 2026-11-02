[CmdletBinding()]
param([string]$InstallRoot = "C:\Services\kk-mid-server")

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

# stop 根据状态文件选择 Process 或 WindowsService，并复用 common.ps1 的
# PID 路径校验/SCM 等待逻辑，不使用模糊进程名批量结束程序。
$layout = Get-DeploymentLayout -InstallRoot $InstallRoot
$lock = Enter-DeploymentLock -Layout $layout
try {
    $state = Read-DeploymentState -Layout $layout
    Stop-ManagedRuntime -Layout $layout -State $state
    Save-DeploymentState -Layout $layout -State $state
    Write-Host "Server stopped."
} finally {
    $lock.Dispose()
}
