Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'install-remote.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw ($errors.Message -join ';')}
# Execute only the environment initialization block, never service registration.
$block=$ast.Find({param($node) $node -is [Management.Automation.Language.IfStatementAst] -and $node.Extent.Text.StartsWith('if(!(Test-Path -LiteralPath $layout.Environment))')},$true)
if(!$block){throw 'Environment initialization block not found'}
$root=Join-Path $PSScriptRoot ('test-results\install-env-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root|Out-Null
$layout=[pscustomobject]@{Environment=(Join-Path $root '.env');Logs=(Join-Path $root 'logs')}
$initialize=[scriptblock]::Create($block.Extent.Text)
& $initialize
$lines=[IO.File]::ReadAllLines($layout.Environment)
foreach($expected in @('HTTP_ADDR=:8080','PUBLIC_BASE_URL=http://192.168.2.7:8080')){
 if(@($lines|Where-Object {$_ -eq $expected}).Count -ne 1){throw "Missing or repeated setting: $expected"}
}
if(@($lines|Where-Object {$_ -match '^DUEL_'}).Count){throw 'Gameplay settings must not be initialized in environment'}
[IO.File]::WriteAllText($layout.Environment,"HTTP_ADDR=:8080`r`nPUBLIC_BASE_URL=http://existing.example:8080`r`nCUSTOM_SETTING=keep`r`n")
$before=[Convert]::ToBase64String([IO.File]::ReadAllBytes($layout.Environment))
& $initialize
if([Convert]::ToBase64String([IO.File]::ReadAllBytes($layout.Environment)) -cne $before){throw 'Existing environment was overwritten'}
Write-Output 'PASS: fresh defaults correct; existing environment preserved byte-for-byte; no services touched.'
Write-Output "Evidence: $root"
