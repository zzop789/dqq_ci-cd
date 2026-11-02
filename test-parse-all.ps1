# Parses every deployment script with the host that runs this file, catching
# version-specific syntax support before an isolated rehearsal is attempted.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$files=@(
 'worker.ps1','native-worker.ps1','native-maintenance.ps1','native-release.ps1',
 'prepare-server-config.ps1','install-remote.ps1','update-remote.ps1','upload-remote.ps1',
 'deploy/common.ps1','deploy/deploy.ps1','deploy/install.ps1','deploy/rollback.ps1','deploy/start.ps1','deploy/stop.ps1','deploy/status.ps1','deploy/uninstall.ps1',
 'test-native-worker.ps1','test-native-package.ps1','test-worker.ps1','test-package-worker.ps1','test-agent.ps1','test-prepare-server-config.ps1'
)
$bad=0
foreach($f in $files){
 $errors=$null
 [void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $f),[ref]$null,[ref]$errors)
 if($errors -and $errors.Count){
  $bad++
  Write-Host ('FAIL '+$f)
  $errors|ForEach-Object{Write-Host ('  '+$_.Message+' @ line '+$_.Extent.StartLineNumber)}
 }
}
if($bad){throw ($bad.ToString()+' file(s) failed to parse under '+$PSVersionTable.PSVersion.ToString())}
Write-Host ('PASS: '+$files.Count+' scripts parse under '+$PSVersionTable.PSVersion.ToString()+' ('+$PSVersionTable.PSEdition+')')
