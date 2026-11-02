# Explicit opt-in; not executed by ordinary build/deploy.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'native-worker.ps1')
foreach($profile in @(
 @{protocol='9';contract=26;ruleset='demo-skill-runtime-v15';economy='match-economy-v4';schema=4},
 @{protocol='9';contract=27;ruleset='demo-skill-runtime-v16';economy='match-economy-v4';schema=4},
 @{protocol='12';contract=43;ruleset='fixture-independent-version';economy='fixture-economy-v8';schema=8}
)){
$audit=[pscustomobject]@{current_client_contract=[pscustomobject]@{profile='warcraft-round-v1';protocol=$profile.protocol;contract=$profile.contract;ruleset=$profile.ruleset;economy=$profile.economy;economy_schema=$profile.schema;contract_sha256=('a'*64);new_authentication_required=$false;client_request_changes_required=$true}}
$good=[pscustomobject]@{runtime_identity=[pscustomobject]@{protocol_version=$profile.protocol;contract_version=$profile.contract;ruleset_version=$profile.ruleset;economy_version=$profile.economy}}
Assert-NativeRuntimeContract $good $audit
foreach($field in @('protocol_version','contract_version','ruleset_version','economy_version')){
 $bad=($good|ConvertTo-Json)|ConvertFrom-Json
 $bad.runtime_identity.$field='wrong'
 $rejected=$false;try{Assert-NativeRuntimeContract $bad $audit}catch{$rejected=$true}
 if(!$rejected){throw ('Runtime mismatch accepted: '+$field)}
}
$rejected=$false;try{Assert-NativeRuntimeContract ([pscustomobject]@{}) $audit}catch{$rejected=$true}
if(!$rejected){throw 'Missing runtime identity accepted'}
}
Write-Host 'Runtime identity regressions passed'
