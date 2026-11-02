param([Parameter(Mandatory=$true)][string]$HomeDir,[Parameter(Mandatory=$true)][string]$JobID)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
if($JobID -notmatch '^[a-f0-9]{32}$'){throw 'Invalid build ID'}
$cfg=Get-Content -LiteralPath (Join-Path $HomeDir 'config.json') -Raw -Encoding UTF8|ConvertFrom-Json
$repo=[IO.Path]::GetFullPath([string]$cfg.local_repo)
if(!(Test-Path -LiteralPath (Join-Path $repo 'scripts\package.ps1'))){throw 'Configure local_repo to the local game repository'}
. (Join-Path $repo 'scripts\verification-input.ps1')
$output=Join-Path $HomeDir "local-artifacts\$JobID"
if(Test-Path -LiteralPath $output){throw 'Build directory already exists; create a new build task'}
New-Item -ItemType Directory -Path $output -Force|Out-Null
$version='local-'+[DateTime]::UtcNow.ToString('yyyyMMddHHmmss')+'-'+$JobID.Substring(0,12)
function Source-Manifest {
 # Match package verification's input boundary, so documentation updates cannot
 # invalidate an otherwise unchanged package at this outer gate.
 $source=Get-VerificationInput -RepoRoot $repo
 $records=foreach($entry in $source.files){$entry.sha256.ToUpperInvariant()+'  '+$entry.path}
 return ($records -join "`n")
}
$before=Source-Manifest
[IO.File]::WriteAllText((Join-Path $output 'SOURCE_SHA256SUMS'),$before,[Text.UTF8Encoding]::new($false))
Write-Host "LOCAL BUILD $version : $repo"
Write-Host 'No commit, push or remote repository access. Do not edit source files during this build.'
Push-Location $repo
try {
 # The game package entry owns content generation and daily build checks.
 # Full combat regression is explicitly opt-in via test.cmd.
 # Keep DLL probe, host smoke, source identity and archive checks.
 & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $repo 'scripts\package.ps1') -Version $version -OutputRoot $output
 if($LASTEXITCODE -ne 0){throw 'Local packaging failed'}
}finally{Pop-Location}
if((Source-Manifest) -cne $before){throw 'Source changed during build; artifact not approved. Wait for edits to finish and rebuild.'}
. (Join-Path $HomeDir 'deploy\common.ps1')
$release=Join-Path $output "kk-mid-server-$version-windows-amd64"
Test-ReleaseChecksums -ReleaseRoot $release
Test-ExternalPackageChecksum -PackageZip "$release.zip" -ChecksumFile "$release.zip.sha256"
Move-Item -LiteralPath "$release.zip" -Destination (Join-Path $output 'package.zip')
$hash=Get-Sha256Hex -Path (Join-Path $output 'package.zip')
$info=Get-Content -LiteralPath (Join-Path $release 'BUILD_INFO.json') -Raw -Encoding UTF8|ConvertFrom-Json
[IO.File]::WriteAllText((Join-Path $output 'result.json'),(@{artifact=$hash;version=$version;git_commit=$info.git_commit;git_dirty=$info.git_dirty;source=$repo}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
Write-Host "LOCAL BUILD SUCCEEDED: version=$version dirty=$($info.git_dirty) SHA256=$hash"
