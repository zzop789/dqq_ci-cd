param([string]$Executable=(Join-Path $PSScriptRoot 'zyf-cicd-update.exe'))
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if(Get-NetTCPConnection -State Listen -LocalPort 19090 -ErrorAction SilentlyContinue){throw 'Port 19090 occupied; will not interfere with another agent.'}
$source=Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'test-results') -Directory -Filter 'worker-*'|Sort-Object LastWriteTime -Descending|Select-Object -First 1
if(!$source){throw 'Run test-worker.ps1 first'}
$root=Join-Path $PSScriptRoot ('test-results\agent-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root|Out-Null
Copy-Item -LiteralPath (Join-Path $source.FullName 'rollback-success\deploy') -Destination $root -Recurse
Copy-Item -LiteralPath (Join-Path $source.FullName 'rollback-success\game') -Destination $root -Recurse
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'worker.ps1') -Destination $root
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'prepare-server-config.ps1') -Destination $root
$token=[guid]::NewGuid().ToString('N')
$cfg=@{token=$token;install_root=(Join-Path $root 'game');health_url='http://127.0.0.1:1';repo='fixture';branch='fixture'}
[IO.File]::WriteAllText((Join-Path $root 'config.json'),($cfg|ConvertTo-Json))
$agent=Start-Process -FilePath $Executable -ArgumentList @('-agent','-home',('"'+$root+'"')) -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $root 'agent.log') -RedirectStandardError (Join-Path $root 'agent-error.log')
try {
 $headers=@{'X-CICD-Token'=$token}
 $ready=$false
 for($attempt=0;$attempt -lt 20;$attempt++) {try{$null=Invoke-RestMethod 'http://127.0.0.1:19090/api/ping' -Headers $headers -TimeoutSec 1;$ready=$true;break}catch{Start-Sleep -Milliseconds 200}}
 if(!$ready){throw 'Agent did not start'}
 $id=[guid]::NewGuid().ToString('N')
 $job=@{id=$id;action='rollback';maintenance=$true;expected='B';commit=''}
 $accepted=Invoke-RestMethod 'http://127.0.0.1:19090/api/jobs' -Method Post -Headers $headers -ContentType 'application/json' -Body ($job|ConvertTo-Json)
 for($attempt=0;$attempt -lt 30;$attempt++){
  $jobs=Invoke-RestMethod 'http://127.0.0.1:19090/api/jobs' -Headers $headers
  $completed=@($jobs|Where-Object id -eq $id)[0]
  if($completed.status -notin @('queued','running')){break}
  Start-Sleep -Milliseconds 200
 }
 if($completed.status -ne 'succeeded'){throw ('HTTP to worker failed: '+($completed|ConvertTo-Json))}
 $again=Invoke-RestMethod 'http://127.0.0.1:19090/api/jobs' -Method Post -Headers $headers -ContentType 'application/json' -Body ($job|ConvertTo-Json)
 if($again.status -ne 'succeeded'){throw 'Retry replayed completed task'}
 $runtime=Get-Content -LiteralPath (Join-Path $root 'game\runtime.txt')
 if($runtime -ne 'A'){throw 'Wrong version after rollback'}
 $log=Invoke-RestMethod ("http://127.0.0.1:19090/api/log?id=$id") -Headers $headers
 if($log.text -notmatch 'DEPLOYMENT SUCCEEDED'){throw 'Missing durable worker log'}
 $result=@{passed=$true;task=$id;coverage='HTTP authentication -> durable task -> Windows Job Object -> PowerShell worker -> rollback -> idempotent retry -> log'}
 [IO.File]::WriteAllText((Join-Path $root 'results.json'),($result|ConvertTo-Json))
 Write-Host 'AGENT INTEGRATION PASSED'
 Write-Host "Evidence: $root"
}finally{
 if(!$agent.HasExited){Stop-Process -Id $agent.Id; $agent.WaitForExit()}
}
