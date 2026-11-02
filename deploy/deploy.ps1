[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PackageZip,
    [Parameter(Mandatory = $true)][string]$ChecksumFile,
    [string]$InstallRoot = "C:\Services\kk-mid-server",
    [string]$RuntimeMode = "",
    [string]$HealthBaseURL = "http://127.0.0.1:8080"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

# 部署事务边界：校验和解压发生在停止旧进程之前；一旦切换 current，
# 后续任一步失败都会使用切换前的完整状态恢复旧版本。
$PackageZip = [System.IO.Path]::GetFullPath($PackageZip)
$ChecksumFile = [System.IO.Path]::GetFullPath($ChecksumFile)
if (-not (Test-Path -LiteralPath $PackageZip -PathType Leaf)) {
    throw "Package ZIP not found: $PackageZip"
}
if (-not (Test-Path -LiteralPath $ChecksumFile -PathType Leaf)) {
    throw "Package checksum file not found: $ChecksumFile"
}
if ($RuntimeMode -and $RuntimeMode -notin @("Process", "WindowsService")) {
    throw "RuntimeMode must be Process or WindowsService."
}

$layout = Get-DeploymentLayout -InstallRoot $InstallRoot
Initialize-DeploymentLayout -Layout $layout
$lock = Enter-DeploymentLock -Layout $layout
$extractRoot = Join-Path $layout.Incoming ("extract-" + [guid]::NewGuid().ToString("N"))
$switched = $false
$oldState = $null
$newState = $null

try {
    Write-Host "[1/8] Verifying package SHA256..."
    Test-ExternalPackageChecksum -PackageZip $PackageZip -ChecksumFile $ChecksumFile

    Write-Host "[2/8] Extracting package..."
    Expand-SafeZipArchive -ZipPath $PackageZip -Destination $extractRoot
    $serverFiles = @(Get-ChildItem -LiteralPath $extractRoot -Recurse -File -Filter "server.exe")
    if ($serverFiles.Count -ne 1) {
        throw "Expected exactly one server.exe in package, found $($serverFiles.Count)."
    }
    $packageRoot = $serverFiles[0].Directory.FullName
    Test-ReleaseChecksums -ReleaseRoot $packageRoot
    $releaseInfo = Get-ReleaseVersion -ReleaseRoot $packageRoot

    Write-Host "[3/8] Staging release $($releaseInfo.Version)..."
    $releasePath = [System.IO.Path]::GetFullPath((Join-Path $layout.Releases $releaseInfo.SafeVersion))
    Assert-ChildPath -ParentPath $layout.Releases -ChildPath $releasePath
    if (Test-Path -LiteralPath $releasePath) {
        Test-ReleaseChecksums -ReleaseRoot $releasePath
        $existingInfo = Get-ReleaseVersion -ReleaseRoot $releasePath
        if ($existingInfo.Version -ne $releaseInfo.Version) {
            throw "Release directory collision for $($releaseInfo.SafeVersion)."
        }
        # 版本号是不可变制品标识。允许同一个包幂等重部署，但同名版本的
        # SHA256SUMS 不同必须拒绝，不能悄悄复用旧文件或覆盖审计证据。
        $incomingManifestHash = Get-Sha256Hex -Path (Join-Path $packageRoot "SHA256SUMS")
        $existingManifestHash = Get-Sha256Hex -Path (Join-Path $releasePath "SHA256SUMS")
        if ($incomingManifestHash -ne $existingManifestHash) {
            throw "Release version '$($releaseInfo.Version)' already exists with different content. Use a new version."
        }
    } else {
        New-Item -ItemType Directory -Path $releasePath | Out-Null
        Get-ChildItem -LiteralPath $packageRoot -Force | Copy-Item -Destination $releasePath -Recurse -Force
        Test-ReleaseChecksums -ReleaseRoot $releasePath
    }

    $oldState = Read-DeploymentState -Layout $layout
    $oldState = ($oldState | ConvertTo-Json | ConvertFrom-Json)
    $newState = Read-DeploymentState -Layout $layout
    if ($RuntimeMode) {
        $newState.runtime_mode = $RuntimeMode
    }

    Write-Host "[4/8] Stopping current runtime..."
    Stop-ManagedRuntime -Layout $layout -State $newState

    Write-Host "[5/8] Switching current release..."
    Set-CurrentFromRelease -Layout $layout -ReleasePath $releasePath
    if ($newState.current_version -ne $releaseInfo.Version) {
        $newState.previous_version = $newState.current_version
    }
    $newState.current_version = $releaseInfo.Version
    $newState.process_id = 0
    $newState.deployed_at_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    Save-DeploymentState -Layout $layout -State $newState
    $switched = $true

    Write-Host "[6/8] Starting release..."
    Start-ManagedRuntime -Layout $layout -State $newState
    Save-DeploymentState -Layout $layout -State $newState

    Write-Host "[7/8] Waiting for health and version..."
    $versionResponse = Wait-ApplicationHealthy `
        -HealthBaseURL $HealthBaseURL `
        -ExpectedVersion $releaseInfo.SafeVersion `
        -TimeoutSeconds 20

    Write-Host "[8/8] Deployment completed."
    Write-Host "Version:      $($versionResponse.version)"
    Write-Host "Install root: $($layout.Root)"
    Write-Host "Runtime mode: $($newState.runtime_mode)"
} catch {
    $deploymentError = $_
    if ($switched -and $null -ne $oldState) {
        # oldState 是切换前的深拷贝，包含旧版本、运行模式和 PID 信息。
        # 回滚后重新跑健康+版本验收，不能只凭“进程已启动”宣告成功。
        Write-Warning "Deployment failed; attempting rollback to '$($oldState.current_version)'."
        try {
            if ($null -ne $newState) {
                Stop-ManagedRuntime -Layout $layout -State $newState
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$oldState.current_version)) {
                $oldSafeVersion = (([string]$oldState.current_version -replace '[^0-9A-Za-z._-]', '-') -replace '-+', '-').Trim('-', '.')
                $oldReleasePath = [System.IO.Path]::GetFullPath((Join-Path $layout.Releases $oldSafeVersion))
                Set-CurrentFromRelease -Layout $layout -ReleasePath $oldReleasePath
                Save-DeploymentState -Layout $layout -State $oldState
                Start-ManagedRuntime -Layout $layout -State $oldState
                Save-DeploymentState -Layout $layout -State $oldState
                Wait-ApplicationHealthy `
                    -HealthBaseURL $HealthBaseURL `
                    -ExpectedVersion $oldSafeVersion `
                    -TimeoutSeconds 20 | Out-Null
                Write-Warning "Rollback succeeded."
            } else {
                Save-DeploymentState -Layout $layout -State $oldState
            }
        } catch {
            Write-Error "Automatic rollback also failed: $($_.Exception.Message)"
        }
    }
    throw $deploymentError
} finally {
    if (Test-Path -LiteralPath $extractRoot) {
        Assert-ChildPath -ParentPath $layout.Incoming -ChildPath $extractRoot
        Remove-Item -LiteralPath $extractRoot -Recurse -Force
    }
    $lock.Dispose()
}
