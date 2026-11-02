function Get-ManagedServerConfig {
 param([Parameter(Mandatory=$true)][string]$InstallRoot,[Parameter(Mandatory=$true)][string]$ReleaseRoot)
 # Legacy JSON path only. It is preserved, never initialized from the package:
 # a native release supplies host.json/gameplay.lua/economy.lua and migrates
 # this file once, after which it is an untouched record.
 $target=Join-Path $InstallRoot 'shared\server.json'
 $selected=$env:SERVER_CONFIG_FILE
 $envFile=Join-Path $InstallRoot 'shared\.env'
 if([string]::IsNullOrWhiteSpace($selected) -and (Test-Path -LiteralPath $envFile)){
  foreach($line in [IO.File]::ReadAllLines($envFile)){
   if($line -match '^\s*SERVER_CONFIG_FILE\s*=\s*(.*?)\s*$'){$selected=$Matches[1].Trim('"',"'")}
  }
 }
 if(![string]::IsNullOrWhiteSpace($selected)){
  if($selected -notmatch '^(?:[A-Za-z]:[\\/]|\\\\[^\\/]+[\\/][^\\/]+[\\/])'){throw 'SERVER_CONFIG_FILE must be absolute'}
  $target=[IO.Path]::GetFullPath($selected)
 }
 if(!(Test-Path -LiteralPath $target -PathType Leaf)){
  throw "Server configuration missing: $target. Create it through the management configuration editor before deploying this legacy release; the package never initializes it. Native releases carry host.json/gameplay.lua/economy.lua instead."
 }
 Write-Host "SERVER CONFIG PRESERVED: $target"
 return $target
}
