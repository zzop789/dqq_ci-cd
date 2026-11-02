param(
 [Parameter(Mandatory=$true)][string]$StoppedSharedBackup,
 [Parameter(Mandatory=$true)][string]$Candidate,
 [Parameter(Mandatory=$true)][string]$AuditExecutable,
 [Parameter(Mandatory=$true)][string]$OldDLLSHA256,
 [Parameter(Mandatory=$true)][string]$ArtifactSHA256,
 [Parameter(Mandatory=$true)][string]$ApprovalDocument,
 [Parameter(Mandatory=$true)][string]$ApprovalReference,
 [Parameter(Mandatory=$true)][string]$Output,
 [switch]$IngressClosed,[switch]$SessionRejoinApproved
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'native-maintenance.ps1')
if(!$IngressClosed -or !$SessionRejoinApproved -or !$ApprovalReference){throw 'Explicit ingress closure, session rejoin approval and reference required'}
if($OldDLLSHA256 -cnotmatch '^[a-f0-9]{64}$' -or $ArtifactSHA256 -cnotmatch '^[a-f0-9]{64}$'){throw 'Exact DLL and artifact hashes required'}
if(Test-Path -LiteralPath $Output){throw 'Output already exists'}
$StoppedSharedBackup=[IO.Path]::GetFullPath($StoppedSharedBackup)
$before=Get-NativeStateTreeJSON $StoppedSharedBackup
$report=Get-Content -LiteralPath (Join-Path $Candidate 'migration-report.json') -Raw -Encoding UTF8|ConvertFrom-Json
$files=[ordered]@{}
foreach($name in @('host.json','gameplay.lua','economy.lua')){
 if((Get-NativeReleaseHash (Join-Path $StoppedSharedBackup $name)) -cne $report.sources_sha256.$name){throw ('Candidate source changed: '+$name)}
 $bytes=[IO.File]::ReadAllBytes((Join-Path $Candidate $name))
 if((Get-NativeReleaseHash (Join-Path $Candidate $name)) -cne $report.files_sha256.$name){throw ('Candidate changed: '+$name)}
 $files[$name]=[Convert]::ToBase64String($bytes)
}
$manifest=& $AuditExecutable -data (Join-Path $StoppedSharedBackup 'native-data') -manifest-only
if($LASTEXITCODE -ne 0){throw 'Source manifest failed'}
$source=($manifest -join "`n")|ConvertFrom-Json
if($source.status -cne 'identity_only_not_terminal_proof'){throw 'Unexpected audit output'}
if((Get-NativeStateTreeJSON $StoppedSharedBackup) -cne $before){throw 'Backup changed while preparing request'}
$approval=[IO.File]::ReadAllBytes($ApprovalDocument)
$request=[ordered]@{schema_version=1;artifact_sha256=$ArtifactSHA256;source_tree=$before;source_data_sha256=$source.source_sha256;old_dll_sha256=$OldDLLSHA256;approval_ref=$ApprovalReference;approval_sha256=(Get-NativeReleaseHash $ApprovalDocument);approval_document=[Convert]::ToBase64String($approval);session_rejoin_approved=$true;ingress_closed=$true;files=$files;report=$report}
$bytes=[Text.UTF8Encoding]::new($false).GetBytes(($request|ConvertTo-Json -Depth 40))
$stream=[IO.File]::Open($Output,'CreateNew','Write','None')
try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
Write-Host ('Prepared only; not uploaded or activated. SHA256: '+(Get-NativeReleaseHash $Output))
