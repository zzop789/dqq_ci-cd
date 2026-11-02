[CmdletBinding()]
param(
    [string]$InstallRoot = "C:\Services\kk-mid-server",
    [string]$HealthBaseURL = "http://127.0.0.1:8080"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

# start 只启动 deployment.json 指向的 current 版本，并在返回成功前验证
# health 和 version；它不负责切换 release。
$layout = Get-DeploymentLayout -InstallRoot $InstallRoot
$lock = Enter-DeploymentLock -Layout $layout
try {
    $state = Read-DeploymentState -Layout $layout
    if ([string]::IsNullOrWhiteSpace([string]$state.current_version)) {
        throw "No release has been deployed."
    }
    Start-ManagedRuntime -Layout $layout -State $state
    Save-DeploymentState -Layout $layout -State $state
    $safeVersion = (([string]$state.current_version -replace '[^0-9A-Za-z._-]', '-') -replace '-+', '-').Trim('-', '.')
    $versionResponse = Wait-ApplicationHealthy `
        -HealthBaseURL $HealthBaseURL `
        -ExpectedVersion $safeVersion `
        -TimeoutSeconds 20
    Write-Host "Server started: version=$($versionResponse.version) mode=$($state.runtime_mode)"
} finally {
    $lock.Dispose()
}
