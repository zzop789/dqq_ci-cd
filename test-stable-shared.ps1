Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'native-maintenance.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('zyf-stable-shared-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root)|Out-Null
$held=$null
try{
 $live=Join-Path $root 'shared';$backup=Join-Path $root 'backup';$candidate=Join-Path $root 'candidate'
 [IO.Directory]::CreateDirectory((Join-Path $live 'logs'))|Out-Null
 [IO.Directory]::CreateDirectory((Join-Path $live 'native-data'))|Out-Null
 [IO.File]::WriteAllText((Join-Path $live 'native-data/rooms.wal'),'confirmed-state')
 [IO.File]::WriteAllText((Join-Path $live '.env'),'old-env')
 [IO.File]::WriteAllText((Join-Path $live 'gameplay.lua'),'actual-8-players')
 $held=[IO.File]::Open((Join-Path $live 'logs/server.log'),'Create','ReadWrite','None')
 $before=Copy-NativeStateTree $live $backup
 $null=Copy-NativeStateTree $backup $candidate
 [IO.File]::WriteAllText((Join-Path $candidate '.env'),'new-env')
 [IO.File]::WriteAllText((Join-Path $candidate 'RULES.md'),'new-rules')
 $after=Get-NativeStateTreeJSON $candidate
 # Simulate abrupt termination after the first changed config file.
 [IO.File]::Copy((Join-Path $candidate '.env'),(Join-Path $live '.env'),$true)
 Assert-NativeConfigTransition $live $before $after
 Set-NativeConfigFiles $backup $live $root
 Set-NativeConfigFiles $backup $live $root
 if((Get-NativeStateTreeJSON $live) -cne $before){throw 'Interrupted config restore failed'}
 Set-NativeConfigFiles $candidate $live $root
 if((Get-NativeStateTreeJSON $live) -cne $after){throw 'Activation failed with locked logs'}
 # An external config write must not be overwritten by recovery.
 [IO.File]::WriteAllText((Join-Path $live '.env'),'unknown-edit')
 $rejected=$false;try{Assert-NativeConfigTransition $live $before $after}catch{$rejected=$true}
 if(!$rejected){throw 'Unknown config accepted'}
 [IO.File]::WriteAllText((Join-Path $live '.env'),'new-env')
 [IO.File]::WriteAllText((Join-Path $live 'native-data/rooms.wal'),'new-confirmed-state')
 $rejected=$false;try{Assert-NativeConfigTransition $live $before $after}catch{$rejected=$true}
 if(!$rejected){throw 'Changed persistent data accepted'}
 if(!(Test-Path (Join-Path $live 'logs/server.log'))){throw 'Logs moved'}
 Write-Host 'PASS: locked logs excluded; mixed config recovery idempotent; WAL and unknown config conflicts rejected.'
}finally{
 if($held){$held.Dispose()}
 $resolved=[IO.Path]::GetFullPath($root)
 $prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\zyf-stable-shared-'
 if(!$resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe cleanup'}
 Remove-Item -LiteralPath $resolved -Recurse -Force
}
