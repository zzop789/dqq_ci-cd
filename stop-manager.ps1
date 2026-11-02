# Stops the local manager the same way the UI does, so the executable is not
# replaced while it is running. No effect when the manager is not running.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$base='http://127.0.0.1:18765'
$process=Get-Process zyf-cicd -ErrorAction SilentlyContinue
if(!$process){Write-Host 'manager is not running';exit 0}
# The session token is generated per manager start and embedded in the served
# page. config.json holds the remote agent token, which is not accepted here.
$token=''
try{$page=(Invoke-WebRequest -Uri ($base+'/') -UseBasicParsing -TimeoutSec 5).Content}catch{throw ('manager did not serve its page: '+$_.Exception.Message)}
$match=[regex]::Match($page,"token='([0-9a-f]{32,})'")
if(!$match.Success){$match=[regex]::Match($page,'token="([0-9a-f]{32,})"')}
if(!$match.Success){throw 'could not read the session token from the manager page'}
$token=$match.Groups[1].Value
try{$result=Invoke-RestMethod -Uri ($base+'/api/exit') -Method Post -Headers @{'X-CICD-Token'=$token} -TimeoutSec 10}
catch{throw ('exit request failed: '+$_.Exception.Message)}
Write-Host ('exit accepted: closed='+$result.closed)
for($attempt=0;$attempt -lt 40;$attempt++){
 if(!(Get-Process zyf-cicd -ErrorAction SilentlyContinue)){Write-Host 'manager stopped';exit 0}
 Start-Sleep -Milliseconds 250
}
$remaining=Get-Process zyf-cicd -ErrorAction SilentlyContinue
if($remaining){throw ('manager still running: pid '+$remaining.Id)}
