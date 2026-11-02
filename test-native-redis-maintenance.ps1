# Explicit opt-in regression. All effects are mocked in memory: no Redis,
# state files, registry, services, native executables or listeners are used.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'native-worker.ps1')

$layout=[pscustomobject]@{}
$checkpointPath='memory:checkpoint'
function New-RedisSummary([string]$ID,[string]$SHA,[string]$DLL) {
 return [pscustomobject]@{schema_version=2;id=($ID*32);sha256=($SHA*64);dll_sha256=($DLL*64)}
}
function Reset-RedisRecoveryFixture([string]$Scenario) {
 $script:old=New-RedisSummary 'a' '1' 'c';$script:target=New-RedisSummary 'b' '2' 'd'
 $script:cp=[pscustomobject]@{redis=[pscustomobject]@{phase='published';old=$script:old;target=$script:target}}
 $script:active=if($Scenario -like 'old*'){$script:old}else{$script:target}
 $script:active=($script:active|ConvertTo-Json)|ConvertFrom-Json
 if($Scenario -eq 'foreign'){$script:active=New-RedisSummary 'e' '3' 'f'}
 if($Scenario -like '*bad-sha'){$script:active.sha256='9'*64}
 $script:publishes=0;$script:reads=0;$script:writes=0;$script:deletes=0;$script:stoppedChecks=0
 $script:loseReply=($Scenario -eq 'lost-reply')
 $script:checkpointPresent=$true
 $script:persisted=$script:cp|ConvertTo-Json -Depth 6 -Compress
}
function Get-NativeRedisCheckpointContext($Checkpoint) {
 return [pscustomobject]@{OldRelease='memory:old-release';TargetRelease='memory:target-release';Shared='memory:backup-shared';Redis=$Checkpoint.redis}
}
function Read-DeploymentState($Layout) {return [pscustomobject]@{service_name='memory:game';state='Stopped'}}
function Assert-NativeStopped($State) {
 if($State.state -cne 'Stopped'){throw 'Fixture runtime was not stopped'}
 $script:stoppedChecks++
}
function Get-NativeRedisActive([string]$Release,[string]$Shared) {
 if($Release -cne 'memory:target-release' -or $Shared -cne 'memory:backup-shared'){throw 'Read used an unreviewed release or environment'}
 $script:reads++
 return $script:active
}
function Write-MaintenanceState([string]$Path,$Value) {
 if($Path -cne $checkpointPath){throw 'Unexpected checkpoint path'}
 $script:writes++;$script:checkpointPresent=$true
 $script:persisted=$Value|ConvertTo-Json -Depth 6 -Compress
}
function Remove-Item { $script:deletes++;throw 'Redis restoration must not delete the program checkpoint' }
function Invoke-NativeRedisTool([string]$Release,[string]$Shared,[string[]]$Arguments) {
 if($Release -cne 'memory:old-release' -or $Shared -cne 'memory:backup-shared'){throw 'Restore did not use the old verified release and environment'}
 $expected=@('config-publish','--version',$script:old.id,'--expected',$script:target.id)
 if(($Arguments -join '|') -cne ($expected -join '|')){throw 'Restore did not use exact target-to-old CAS'}
 if($script:cp.redis.phase -cne 'restoring' -or ($script:persisted|ConvertFrom-Json).redis.phase -cne 'restoring'){throw 'Publish occurred before restoration intent was recorded'}
 Assert-NativeRedisSummaryEqual $script:active $script:target
 $script:publishes++;$script:active=$script:old
 if($script:loseReply){throw 'Fixture: publication committed but reply was lost'}
 return [pscustomobject]@{status='published';expected_previous_id=$script:target.id;version=$script:old}
}

foreach($scenario in @('old','target','foreign','old-bad-sha','target-bad-sha','lost-reply')) {
 Reset-RedisRecoveryFixture $scenario
 $failure=''
 try{Restore-NativeRedisConfiguration $script:cp}catch{$failure=$_.Exception.Message}
 if($scenario -in @('foreign','old-bad-sha','target-bad-sha')) {
  $expectedFailure=if($scenario -eq 'foreign'){'Redis active configuration changed outside this deployment'}else{'Redis configuration identity changed: sha256'}
  if(!$failure.StartsWith($expectedFailure,[StringComparison]::Ordinal)){throw ($scenario+': wrong rejection: '+$failure)}
  if($script:publishes -ne 0 -or $script:writes -ne 0 -or $script:cp.redis.phase -cne 'published'){throw ($scenario+': conflicting publication changed recovery state')}
 }elseif($scenario -eq 'lost-reply') {
  if($failure -cne 'Fixture: publication committed but reply was lost'){throw ('Unknown result was not propagated: '+$failure)}
  if($script:publishes -ne 1 -or $script:cp.redis.phase -cne 'restoring' -or !$script:checkpointPresent){throw 'Unknown publication lost its recovery intent'}
  # Simulate a fresh recovery reading only the durable checkpoint and actual
  # Redis value. The already committed restore must not be published twice.
  $script:cp=$script:persisted|ConvertFrom-Json
  $script:loseReply=$false
  Restore-NativeRedisConfiguration $script:cp
  if($script:publishes -ne 1 -or $script:reads -ne 2 -or $script:cp.redis.phase -cne 'restored'){throw 'Retry did not resolve the committed but unconfirmed restore'}
 }else {
  if($failure){throw ($scenario+': unexpected restoration failure: '+$failure)}
  $expectedPublishes=if($scenario -eq 'target'){1}else{0}
  $expectedReads=if($scenario -eq 'target'){2}else{1}
  if($script:publishes -ne $expectedPublishes -or $script:reads -ne $expectedReads -or $script:cp.redis.phase -cne 'restored'){throw ($scenario+': incorrect restoration or readback')}
  Assert-NativeRedisSummaryEqual $script:active $script:old
 }
 if(!$script:checkpointPresent -or $script:deletes -ne 0 -or $script:stoppedChecks -lt 1){throw ($scenario+': program recovery checkpoint or stopped-runtime check was lost')}
}
Write-Host 'PASS: Redis recovery CAS, idempotency, external conflicts and unknown publication outcomes.'
