[CmdletBinding()]
param(
    [string]$InstallRoot = "C:\Services\kk-mid-server",
    [string]$HealthBaseURL = "http://127.0.0.1:8080"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

# previous/current 在成功回滚后互换，因此可以再次执行实现 A/B 往返；
# releases 目录始终保留完整校验过的版本，不依赖临时 ZIP。
$layout = Get-DeploymentLayout -InstallRoot $InstallRoot
$lock = Enter-DeploymentLock -Layout $layout
try {
    $state = Read-DeploymentState -Layout $layout
    if ([string]::IsNullOrWhiteSpace([string]$state.previous_version)) {
        throw "No previous release is recorded."
    }

    $targetVersion = [string]$state.previous_version
    $targetSafeVersion = (($targetVersion -replace '[^0-9A-Za-z._-]', '-') -replace '-+', '-').Trim('-', '.')
    $releasePath = [System.IO.Path]::GetFullPath((Join-Path $layout.Releases $targetSafeVersion))
    Assert-ChildPath -ParentPath $layout.Releases -ChildPath $releasePath
    Test-ReleaseChecksums -ReleaseRoot $releasePath

    Stop-ManagedRuntime -Layout $layout -State $state
    Set-CurrentFromRelease -Layout $layout -ReleasePath $releasePath

    $oldCurrent = [string]$state.current_version
    $state.current_version = $targetVersion
    $state.previous_version = $oldCurrent
    $state.process_id = 0
    $state.deployed_at_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    Save-DeploymentState -Layout $layout -State $state
    Start-ManagedRuntime -Layout $layout -State $state
    Save-DeploymentState -Layout $layout -State $state
    $versionResponse = Wait-ApplicationHealthy `
        -HealthBaseURL $HealthBaseURL `
        -ExpectedVersion $targetSafeVersion `
        -TimeoutSeconds 20

    Write-Host "Rollback completed: $oldCurrent -> $($versionResponse.version)"
} finally {
    $lock.Dispose()
}
