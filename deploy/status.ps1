[CmdletBinding()]
param(
    [string]$InstallRoot = "C:\Services\kk-mid-server",
    [string]$HealthBaseURL = "http://127.0.0.1:8080"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

# status 是只读诊断入口：同时报告部署状态、操作系统运行状态和 HTTP
# 实际版本，三者不一致时可直接看出状态文件过期或端口被旧进程占用。
$layout = Get-DeploymentLayout -InstallRoot $InstallRoot
$state = Read-DeploymentState -Layout $layout
$runtimeStatus = "stopped"
if ($state.runtime_mode -eq "WindowsService") {
    $service = Get-Service -Name $state.service_name -ErrorAction SilentlyContinue
    if ($service) {
        $runtimeStatus = [string]$service.Status
    } else {
        $runtimeStatus = "service_not_installed"
    }
} elseif ([int]$state.process_id -gt 0) {
    $process = Get-Process -Id ([int]$state.process_id) -ErrorAction SilentlyContinue
    if ($process) {
        $runtimeStatus = "running"
    }
}

$healthStatus = "unreachable"
$reportedVersion = ""
try {
    $health = Invoke-RestMethod -Method Get -Uri ($HealthBaseURL.TrimEnd('/') + "/healthz") -TimeoutSec 2
    $version = Invoke-RestMethod -Method Get -Uri ($HealthBaseURL.TrimEnd('/') + "/version") -TimeoutSec 2
    $healthStatus = [string]$health.status
    $reportedVersion = [string]$version.version
} catch {
    $healthStatus = "unreachable"
}

[pscustomobject]@{
    InstallRoot      = $layout.Root
    RuntimeMode      = $state.runtime_mode
    RuntimeStatus    = $runtimeStatus
    CurrentVersion   = $state.current_version
    PreviousVersion  = $state.previous_version
    ProcessID        = $state.process_id
    Health           = $healthStatus
    ReportedVersion  = $reportedVersion
    DeployedAtUTC    = $state.deployed_at_utc
}
