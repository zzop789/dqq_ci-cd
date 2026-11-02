# Runs the isolated deployment rehearsals under every installed PowerShell host
# so a version-specific difference cannot pass unnoticed.
param([switch]$IncludePackage)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSCommandPath
$pkg=Join-Path $root 'local-artifacts\835cccaaa4b140cd907c882987516218\kk-mid-server-local-20260921045056-835cccaaa4b1-windows-amd64'
$legacy=Join-Path $root 'local-artifacts\0f16f4a54a3946fea9881bce033e76c6\kk-mid-server-local-20260915175822-0f16f4a54a39-windows-amd64\configs\server.json'
$hosts=@()
foreach($candidate in @('powershell.exe','pwsh.exe')){
 $command=Get-Command $candidate -ErrorAction SilentlyContinue
 if($command){$hosts+=,@($candidate,$command.Source)}
}
if(!$hosts.Count){throw 'No PowerShell host found'}
$results=@()
foreach($hostInfo in $hosts){
 $name=$hostInfo[0];$exePath=$hostInfo[1]
 $version=(& $exePath -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>&1|Select-Object -First 1)
 Write-Host ('=== '+$name+' '+$version+' ===')
 $steps=@(
  @{label='ps-parse';file='test-parse-all.ps1';args=@()},
  @{label='worker';file='test-worker.ps1';args=@()},
  @{label='prepare-server-config';file='test-prepare-server-config.ps1';args=@()},
  @{label='native-worker';file='test-native-worker.ps1';args=@()}
 )
 if($IncludePackage){$steps+=(@{label='native-package';file='test-native-package.ps1';args=@('-PackageRoot',$pkg,'-LegacyConfig',$legacy)})}
 foreach($step in $steps){
  $target=Join-Path $root $step.file
  $started=Get-Date
  $output=& $exePath -NoProfile -ExecutionPolicy Bypass -File $target @($step.args) 2>&1 | Out-String
  $code=$LASTEXITCODE
  $seconds=[Math]::Round(((Get-Date)-$started).TotalSeconds,1)
  $verdict=if($code -eq 0){'PASS'}else{'FAIL'}
  $results+=[pscustomobject]@{Host=$name;Version=$version;Step=$step.label;Result=$verdict;Seconds=$seconds}
  Write-Host ('  {0,-24} {1} ({2}s)' -f $step.label,$verdict,$seconds)
  if($code -ne 0){
   Write-Host '  --- failure output (last 20 lines) ---'
   ($output -split "`r?`n"|Where-Object{$_ -ne ''}|Select-Object -Last 20)|ForEach-Object{Write-Host ('  '+$_)}
  }
 }
}
Write-Host ''
Write-Host '=== summary ==='
$results|Format-Table -AutoSize|Out-String|Write-Host
$failed=@($results|Where-Object{$_.Result -ne 'PASS'})
if($failed.Count){Write-Host ($failed.Count.ToString()+' step(s) failed');exit 1}
Write-Host 'ALL STEPS PASSED'
