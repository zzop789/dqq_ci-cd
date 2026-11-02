Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# 共享库集中维护部署目录、安全检查、运行时启停和探针轮询。
# install/deploy/rollback 等入口脚本只编排流程，不各自复制这些规则。
$script:DefaultServiceName = "kk-mid-server-staging"

function Resolve-SafeInstallRoot {
    param([Parameter(Mandatory = $true)][string]$InstallRoot)

    if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
        throw "InstallRoot must not be empty."
    }
    if (-not [System.IO.Path]::IsPathRooted($InstallRoot)) {
        $InstallRoot = Join-Path (Get-Location).Path $InstallRoot
    }
    $fullPath = [System.IO.Path]::GetFullPath($InstallRoot)
    $pathRoot = [System.IO.Path]::GetPathRoot($fullPath)
    # 后续流程会递归替换 current，根目录必须先收窄，不能允许磁盘根或用户目录。
    if ($fullPath.TrimEnd('\', '/') -eq $pathRoot.TrimEnd('\', '/')) {
        throw "InstallRoot must not be a filesystem root: $fullPath"
    }
    $userProfile = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::UserProfile)
    if ($userProfile -and $fullPath.TrimEnd('\', '/') -eq $userProfile.TrimEnd('\', '/')) {
        throw "InstallRoot must not be the user profile directory: $fullPath"
    }
    return $fullPath
}

function Get-DeploymentLayout {
    param([Parameter(Mandatory = $true)][string]$InstallRoot)

    $root = Resolve-SafeInstallRoot -InstallRoot $InstallRoot
    return [pscustomobject]@{
        Root         = $root
        Current      = Join-Path $root "current"
        Releases     = Join-Path $root "releases"
        Incoming     = Join-Path $root "incoming"
        Shared       = Join-Path $root "shared"
        Logs         = Join-Path $root "shared\logs"
        State        = Join-Path $root "state"
        StateFile    = Join-Path $root "state\deployment.json"
        LockFile     = Join-Path $root "state\deployment.lock"
        ProcessFile  = Join-Path $root "state\server.pid"
        Environment  = Join-Path $root "shared\.env"
        EnvExample   = Join-Path $root "shared\.env.example"
    }
}

function Assert-ChildPath {
    param(
        [Parameter(Mandatory = $true)][string]$ParentPath,
        [Parameter(Mandatory = $true)][string]$ChildPath
    )

    $parentFull = [System.IO.Path]::GetFullPath($ParentPath)
    $childFull = [System.IO.Path]::GetFullPath($ChildPath)
    $separator = [System.IO.Path]::DirectorySeparatorChar
    $prefix = $parentFull.TrimEnd($separator, [System.IO.Path]::AltDirectorySeparatorChar) + $separator
    if (-not $childFull.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Path is outside the expected root: $childFull"
    }
}

function Initialize-DeploymentLayout {
    param([Parameter(Mandatory = $true)]$Layout)

    foreach ($directory in @($Layout.Root, $Layout.Releases, $Layout.Incoming, $Layout.Shared, $Layout.Logs, $Layout.State)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
}

function Get-Sha256Hex {
    param([Parameter(Mandatory = $true)][string]$Path)

    $stream = [System.IO.File]::Open(
        $Path,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::Read
    )
    $algorithm = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $algorithm.ComputeHash($stream)
        return (($bytes | ForEach-Object { $_.ToString("x2") }) -join "")
    } finally {
        $algorithm.Dispose()
        $stream.Dispose()
    }
}

function Test-ExternalPackageChecksum {
    param(
        [Parameter(Mandatory = $true)][string]$PackageZip,
        [Parameter(Mandatory = $true)][string]$ChecksumFile
    )

    $checksumLine = (Get-Content -LiteralPath $ChecksumFile -ErrorAction Stop | Select-Object -First 1).Trim()
    if ($checksumLine -notmatch '^([0-9a-fA-F]{64})\s+') {
        throw "Checksum file does not contain a SHA256 entry: $ChecksumFile"
    }
    $expected = $Matches[1].ToLowerInvariant()
    $actual = Get-Sha256Hex -Path $PackageZip
    if ($actual -ne $expected) {
        throw "Package SHA256 mismatch. Expected $expected but got $actual."
    }
}

function Expand-SafeZipArchive {
    param(
        [Parameter(Mandatory = $true)][string]$ZipPath,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    # Expand-Archive 之前逐项检查目标路径，拒绝 ../ 逃逸的恶意或损坏 ZIP。
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $expandedBytes = [long]0
        foreach ($entry in $archive.Entries) {
            $expandedBytes += $entry.Length
            if ($expandedBytes -gt 2147483648 -or $archive.Entries.Count -gt 20000) {
                throw 'Archive exceeds extraction size or entry limit.'
            }
            if ([string]::IsNullOrEmpty($entry.FullName)) {
                continue
            }
            $candidate = [System.IO.Path]::GetFullPath((Join-Path $Destination $entry.FullName))
            Assert-ChildPath -ParentPath $Destination -ChildPath $candidate
        }
    } finally {
        $archive.Dispose()
    }
    Expand-Archive -LiteralPath $ZipPath -DestinationPath $Destination -Force
}

function Test-ReleaseChecksums {
    param([Parameter(Mandatory = $true)][string]$ReleaseRoot)

    $checksumPath = Join-Path $ReleaseRoot "SHA256SUMS"
    if (-not (Test-Path -LiteralPath $checksumPath -PathType Leaf)) {
        throw "SHA256SUMS is missing from release: $ReleaseRoot"
    }

    foreach ($line in Get-Content -LiteralPath $checksumPath) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        if ($line -notmatch '^([0-9a-fA-F]{64})\s{2}(.+)$') {
            throw "Invalid SHA256SUMS line: $line"
        }
        $expected = $Matches[1].ToLowerInvariant()
        $relativePath = $Matches[2] -replace '/', '\'
        $filePath = [System.IO.Path]::GetFullPath((Join-Path $ReleaseRoot $relativePath))
        Assert-ChildPath -ParentPath $ReleaseRoot -ChildPath $filePath
        if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
            throw "Release file listed in SHA256SUMS is missing: $relativePath"
        }
        $actual = Get-Sha256Hex -Path $filePath
        if ($actual -ne $expected) {
            throw "Release file SHA256 mismatch: $relativePath"
        }
    }
}

function New-DeploymentState {
    param(
        [ValidateSet("Process", "WindowsService")][string]$RuntimeMode = "Process",
        [string]$ServiceName = $script:DefaultServiceName
    )

    return [pscustomobject][ordered]@{
        schema_version   = 1
        current_version  = ""
        previous_version = ""
        runtime_mode     = $RuntimeMode
        service_name     = $ServiceName
        process_id       = 0
        deployed_at_utc  = ""
    }
}

function Read-DeploymentState {
    param([Parameter(Mandatory = $true)]$Layout)

    if (-not (Test-Path -LiteralPath $Layout.StateFile -PathType Leaf)) {
        return (New-DeploymentState)
    }
    try {
        $state = Get-Content -Raw -LiteralPath $Layout.StateFile | ConvertFrom-Json
    } catch {
        throw "Invalid deployment state file $($Layout.StateFile): $($_.Exception.Message)"
    }
    foreach ($property in @("schema_version", "current_version", "previous_version", "runtime_mode", "service_name", "process_id", "deployed_at_utc")) {
        if ($null -eq $state.PSObject.Properties[$property]) {
            throw "Deployment state is missing property '$property'."
        }
    }
    return $state
}

function Save-DeploymentState {
    param(
        [Parameter(Mandatory = $true)]$Layout,
        [Parameter(Mandatory = $true)]$State
    )

    $temporaryPath = $Layout.StateFile + ".tmp-" + [guid]::NewGuid().ToString("N")
    Assert-ChildPath -ParentPath $Layout.State -ChildPath $temporaryPath
    try {
        $State | ConvertTo-Json | Set-Content -LiteralPath $temporaryPath -Encoding UTF8
        Move-Item -LiteralPath $temporaryPath -Destination $Layout.StateFile -Force
    } finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

function Enter-DeploymentLock {
    param([Parameter(Mandatory = $true)]$Layout)

    Initialize-DeploymentLayout -Layout $Layout
    try {
        return [System.IO.File]::Open(
            $Layout.LockFile,
            [System.IO.FileMode]::OpenOrCreate,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None
        )
    } catch {
        throw "Another deployment operation is already running for $($Layout.Root)."
    }
}

function Set-CurrentFromRelease {
    param(
        [Parameter(Mandatory = $true)]$Layout,
        [Parameter(Mandatory = $true)][string]$ReleasePath
    )

    # current 是运行副本；releases/<version> 是不可变回滚源。永远不覆盖
    # releases 中的旧版本，也不尝试覆盖仍在运行的 server.exe。
    Assert-ChildPath -ParentPath $Layout.Releases -ChildPath $ReleasePath
    if (-not (Test-Path -LiteralPath (Join-Path $ReleasePath "server.exe") -PathType Leaf)) {
        throw "Release does not contain server.exe: $ReleasePath"
    }
    Assert-ChildPath -ParentPath $Layout.Root -ChildPath $Layout.Current
    if (Test-Path -LiteralPath $Layout.Current) {
        Remove-Item -LiteralPath $Layout.Current -Recurse -Force
    }
    New-Item -ItemType Directory -Path $Layout.Current | Out-Null
    Get-ChildItem -LiteralPath $ReleasePath -Force | Copy-Item -Destination $Layout.Current -Recurse -Force
}

function Stop-ManagedRuntime {
    param(
        [Parameter(Mandatory = $true)]$Layout,
        [Parameter(Mandatory = $true)]$State
    )

    if ($State.runtime_mode -eq "WindowsService") {
        $service = Get-Service -Name $State.service_name -ErrorAction SilentlyContinue
        if ($service -and $service.Status -ne [System.ServiceProcess.ServiceControllerStatus]::Stopped) {
            Stop-Service -Name $State.service_name -ErrorAction Stop
            $service.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Stopped, [TimeSpan]::FromSeconds(30))
        }
        return
    }

    # Process 模式只允许停止安装根目录内名为 server.exe 的已记录 PID，
    # 避免过期 PID 被系统复用后误杀其他程序。
    $processID = [int]$State.process_id
    if ($processID -le 0 -and (Test-Path -LiteralPath $Layout.ProcessFile)) {
        $processID = [int](Get-Content -LiteralPath $Layout.ProcessFile | Select-Object -First 1)
    }
    if ($processID -gt 0) {
        $process = Get-Process -Id $processID -ErrorAction SilentlyContinue
        if ($process) {
            $processPath = $process.Path
            Assert-ChildPath -ParentPath $Layout.Root -ChildPath $processPath
            if ([System.IO.Path]::GetFileName($processPath) -ne "server.exe") {
                throw "Refusing to stop unexpected process $processID at $processPath"
            }
            Stop-Process -Id $processID -ErrorAction Stop
            if (-not $process.WaitForExit(10000)) {
                throw "Managed process $processID did not stop within 10 seconds."
            }
        }
    }
    if (Test-Path -LiteralPath $Layout.ProcessFile) {
        Remove-Item -LiteralPath $Layout.ProcessFile -Force
    }
    $State.process_id = 0
}

function Start-ManagedRuntime {
    param(
        [Parameter(Mandatory = $true)]$Layout,
        [Parameter(Mandatory = $true)]$State
    )

    $executable = Join-Path $Layout.Current "server.exe"
    if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
        throw "Current server executable is missing: $executable"
    }

    if ($State.runtime_mode -eq "WindowsService") {
        $service = Get-Service -Name $State.service_name -ErrorAction SilentlyContinue
        if (-not $service) {
            throw "Windows service '$($State.service_name)' is not installed."
        }
        Start-Service -Name $State.service_name -ErrorAction Stop
        $service.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Running, [TimeSpan]::FromSeconds(30))
        $State.process_id = 0
        return
    }

    # 重复 start 必须幂等。先确认状态文件中的 PID 仍是安装根内的
    # server.exe；是则复用，不是则清理陈旧 PID 后再启动。
    $existingProcessID = [int]$State.process_id
    if ($existingProcessID -le 0 -and (Test-Path -LiteralPath $Layout.ProcessFile)) {
        $existingProcessID = [int](Get-Content -LiteralPath $Layout.ProcessFile | Select-Object -First 1)
    }
    if ($existingProcessID -gt 0) {
        $existingProcess = Get-Process -Id $existingProcessID -ErrorAction SilentlyContinue
        if ($existingProcess) {
            $existingPath = $existingProcess.Path
            Assert-ChildPath -ParentPath $Layout.Root -ChildPath $existingPath
            if ([System.IO.Path]::GetFileName($existingPath) -ne "server.exe") {
                throw "Refusing to reuse unexpected process $existingProcessID at $existingPath"
            }
            $State.process_id = $existingProcessID
            return
        }
        if (Test-Path -LiteralPath $Layout.ProcessFile) {
            Remove-Item -LiteralPath $Layout.ProcessFile -Force
        }
        $State.process_id = 0
    }

    $process = Start-Process -FilePath $executable -WorkingDirectory $Layout.Current -WindowStyle Hidden -PassThru
    Set-Content -LiteralPath $Layout.ProcessFile -Value $process.Id -Encoding ASCII
    $State.process_id = $process.Id
}

function Wait-ApplicationHealthy {
    param(
        [Parameter(Mandatory = $true)][string]$HealthBaseURL,
        [string]$ExpectedVersion = "",
        [int]$TimeoutSeconds = 20
    )

    # 只检查 health 不够：旧进程占用同一端口时也会返回 200。版本必须与
    # BUILD_INFO.json 一致，任何不一致都触发部署失败和自动回滚。
    $baseURL = $HealthBaseURL.TrimEnd('/')
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $lastError = "no response"
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            $health = Invoke-RestMethod -Method Get -Uri "$baseURL/healthz" -TimeoutSec 2
            $version = Invoke-RestMethod -Method Get -Uri "$baseURL/version" -TimeoutSec 2
            if ($health.status -ne "ok") {
                throw "health status is '$($health.status)'"
            }
            if ($ExpectedVersion -and $version.version -ne $ExpectedVersion) {
                throw "version is '$($version.version)', expected '$ExpectedVersion'"
            }
            return $version
        } catch {
            $lastError = $_.Exception.Message
            Start-Sleep -Milliseconds 250
        }
    }
    throw "Server did not become healthy within $TimeoutSeconds seconds: $lastError"
}

function Get-ReleaseVersion {
    param([Parameter(Mandatory = $true)][string]$ReleaseRoot)

    $buildInfoPath = Join-Path $ReleaseRoot "BUILD_INFO.json"
    if (-not (Test-Path -LiteralPath $buildInfoPath -PathType Leaf)) {
        throw "BUILD_INFO.json is missing from release."
    }
    $buildInfo = Get-Content -Raw -LiteralPath $buildInfoPath | ConvertFrom-Json
    $version = [string]$buildInfo.version
    if ([string]::IsNullOrWhiteSpace($version)) {
        throw "BUILD_INFO.json contains an empty version."
    }
    $safeVersion = ($version -replace '[^0-9A-Za-z._-]', '-') -replace '-+', '-'
    $safeVersion = $safeVersion.Trim('-', '.')
    if ([string]::IsNullOrWhiteSpace($safeVersion)) {
        throw "Release version cannot be used as a directory name: $version"
    }
    return [pscustomobject]@{ Version = $version; SafeVersion = $safeVersion; BuildInfo = $buildInfo }
}
