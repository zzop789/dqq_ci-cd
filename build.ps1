Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
# Server repository is the authoritative release-identity implementation.
$settings=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'config.json') -Raw -Encoding UTF8|ConvertFrom-Json
$identitySource=Join-Path $settings.local_repo 'scripts/native-release.ps1'
if(!(Test-Path -LiteralPath $identitySource) -or (Get-FileHash -LiteralPath $identitySource).Hash -cne (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'native-release.ps1')).Hash){throw 'native-release.ps1 differs from server scripts/native-release.ps1; review and synchronize the authoritative helper before building'}
# Keep the Go build cache inside the project: it survives sandbox or profile
# restrictions on %LOCALAPPDATA%\go-build and makes rebuilds reproducible.
$env:GOCACHE=Join-Path $PSScriptRoot '.gocache'
New-Item -ItemType Directory -Path $env:GOCACHE -Force|Out-Null
Push-Location $PSScriptRoot
try {
 & go test -count=1 ./...
 if($LASTEXITCODE -ne 0){throw 'Tests failed'}
 & go vet ./...
 if($LASTEXITCODE -ne 0){throw 'Vet failed'}
 & go build -trimpath -o zyf-cicd-update.exe .
 if($LASTEXITCODE -ne 0){throw 'Build failed'}
 # A running manager locks zyf-cicd.exe, and a locked output makes go build fail
 # without a usable exit code. Publish explicitly so this can never be silent.
 $managerPath=Join-Path $PSScriptRoot 'zyf-cicd.exe'
 $published=$false
 for($attempt=0;$attempt -lt 3 -and !$published;$attempt++){
  try{Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'zyf-cicd-update.exe') -Destination $managerPath -Force;$published=$true}
  catch{if($attempt -eq 2){throw 'zyf-cicd.exe is in use. Exit the local manager (界面“退出本机后台”) and run build.ps1 again.'};Start-Sleep -Milliseconds 500}
 }
 Write-Host 'Published zyf-cicd.exe from this build.'
 $stage=Join-Path $PSScriptRoot ('package-'+[guid]::NewGuid().ToString('N'))
 New-Item -ItemType Directory -Path $stage|Out-Null
 Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'zyf-cicd-update.exe') -Destination (Join-Path $stage 'zyf-cicd.exe')
 foreach($item in @('worker.ps1','native-worker.ps1','native-maintenance.ps1','native-release.ps1','native-migration.ps1','host-policy-worker.ps1','prepare-native-migration-request.ps1','prepare-server-config.ps1','install-remote.ps1','update-remote.ps1','config.json','deploy','README.md','remote-authorize-key.ps1','操作手册.md','同事电脑接入手册.md')){Copy-Item -LiteralPath (Join-Path $PSScriptRoot $item) -Destination $stage -Recurse -Force}
 $manifest=[ordered]@{}
 foreach($name in @('zyf-cicd.exe','worker.ps1','native-worker.ps1','native-maintenance.ps1','native-release.ps1','native-migration.ps1','host-policy-worker.ps1','prepare-server-config.ps1','deploy/common.ps1')){$manifest[$name]=(Get-FileHash -LiteralPath (Join-Path $stage $name) -Algorithm SHA256).Hash.ToLowerInvariant()}
 [IO.File]::WriteAllText((Join-Path $stage 'agent-files.json'),($manifest|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
 Compress-Archive -Path (Join-Path $stage '*') -DestinationPath (Join-Path $PSScriptRoot 'remote-package.zip') -Force
 Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'remote-package.zip') -Algorithm SHA256|Format-List
 $archiveHash=(Get-FileHash -LiteralPath (Join-Path $PSScriptRoot 'remote-package.zip') -Algorithm SHA256).Hash.ToLowerInvariant()
 [IO.File]::WriteAllText((Join-Path $PSScriptRoot 'remote-package.zip.sha256'),($archiveHash+'  remote-package.zip'))
 # Delete only the verified temporary child of this project.
 $full=[IO.Path]::GetFullPath($stage)
 if(!$full.StartsWith(([IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')+'\'),[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe staging path'}
 Remove-Item -LiteralPath $full -Recurse -Force
}finally{Pop-Location}
