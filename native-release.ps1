# Native release identity is covered by the outer SHA256SUMS/ZIP, avoiding a
# self-referential manifest hash. No server configuration values live here.
function Get-NativeReleaseHash([string]$Path) {
 $stream=[IO.File]::OpenRead($Path);$sha=[Security.Cryptography.SHA256]::Create()
 try{return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant()}
 finally{$stream.Dispose();$sha.Dispose()}
}
# Package versions come from the selected source and its content. These checks
# bind metadata together; they do not choose which gameplay version may ship.
function Assert-NativeManifestContent($Manifest,$Rules,$Economy) {
 if($Manifest.current_transport_profile -cne 'warcraft-round-v1' -or
    [string]$Manifest.protocol_version -cnotmatch '^[1-9][0-9]*$' -or
    [string]$Manifest.contract_version -cnotmatch '^[1-9][0-9]*$' -or
    [string]::IsNullOrWhiteSpace([string]$Rules.version) -or
    [string]::IsNullOrWhiteSpace([string]$Economy.version) -or
    [string]$Economy.schema_version -cnotmatch '^[1-9][0-9]*$' -or
    $Manifest.client_migration_required -isnot [bool]){throw 'Incomplete or unsupported package contract metadata'}
 if($Manifest.current_ruleset_version -cne $Rules.version -or $Manifest.ruleset_version -cne $Rules.version -or $Manifest.current_economy_version -cne $Economy.version){
  throw ('Content/manifest mismatch: manifest ruleset='+$Manifest.ruleset_version+', current_ruleset='+$Manifest.current_ruleset_version+', generated ruleset='+$Rules.version+', manifest economy='+$Manifest.current_economy_version+', generated economy='+$Economy.version)
 }
}
function New-NativeReleaseIdentity {
 param([string]$PackageRoot,[string]$AuditPath,[string]$Version)
 $audit=Get-Content -LiteralPath $AuditPath -Raw -Encoding UTF8|ConvertFrom-Json
 if($audit.status -ne 'passed' -or $audit.stage -notin @('M4-native-core-and-host-verification','daily-package-verification') -or $audit.production_gameplay -ne 'cpp'){throw 'A passed production verification audit is required'}
 Assert-NativeCurrentContractAudit $audit
 Assert-NativeContentContract -PackageRoot $PackageRoot -Audit $audit
 $release=@($audit.native|Where-Object {$_.configuration -eq 'Release'})
 if($release.Count -ne 1 -or $release[0].probe -ne 'passed'){throw 'Release DLL verification is incomplete'}
 if($audit.stage -eq 'daily-package-verification') {
  if($release[0].go_integration -ne 'smoke_passed' -or $release[0].ctest -ne 'not_run'){throw 'Daily smoke verification is incomplete'}
 } elseif($release[0].ctest -ne 'passed' -or $release[0].go_integration -ne 'passed'){throw 'Full verification is incomplete'}
 $dll=Join-Path $PackageRoot 'gamecore.dll'
 if((Get-NativeReleaseHash $dll) -cne $release[0].sha256){throw 'Packaged DLL differs from verified Release DLL'}
 $files=@(Get-ChildItem -LiteralPath $PackageRoot -File -Recurse|Where-Object {$_.Name -notin @('RELEASE_IDENTITY.json','SHA256SUMS')}|Sort-Object FullName|ForEach-Object {
  [ordered]@{path=$_.FullName.Substring($PackageRoot.Length+1).Replace('\','/');sha256=(Get-NativeReleaseHash $_.FullName)}
 })
 $identity=[ordered]@{
  schema_version=1;version=$Version;target='windows/amd64';production_gameplay='cpp'
  transport_profile='warcraft-round-v1';abi_version=1;dll_build_id=$release[0].build_id
  dll_sha256=$release[0].sha256;verified_source_sha256=$audit.source.sha256
  verification_audit_sha256=(Get-NativeReleaseHash $AuditPath)
  deployment_admission='requires_native_maintenance_v1'
  configuration_policy='explicit_server_owned_lua_migration';data_policy='shared_native_data_never_release_owned'
  preflight_requires_stopped_runtime=$true;files=$files
 }
 $buildInfo=Get-Content -LiteralPath (Join-Path $PackageRoot 'BUILD_INFO.json') -Raw -Encoding UTF8|ConvertFrom-Json
 if($audit.PSObject.Properties.Name -contains 'room_state_mode'){$identity['room_state_mode']=$audit.room_state_mode}
 if($buildInfo.PSObject.Properties.Name -contains 'redis_configuration_rebind'){$identity['redis_configuration_rebind']=$buildInfo.redis_configuration_rebind}
 Assert-NativeRoomStateMode ([pscustomobject]$identity) $audit $buildInfo
 Assert-NativeRedisRebindCapability ([pscustomobject]$identity) $buildInfo
 [IO.File]::WriteAllText((Join-Path $PackageRoot 'RELEASE_IDENTITY.json'),($identity|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
}
function Assert-NativeRedisRebindCapability($Identity,$BuildInfo) {
 $declared=@(@($Identity,$BuildInfo)|Where-Object {$_.PSObject.Properties.Name -contains 'redis_configuration_rebind'})
 if(!$declared.Count){return}
 if($declared.Count -ne 2){throw 'Redis configuration rebind capability differs from build metadata'}
 foreach($record in $declared){
  if($record.redis_configuration_rebind -isnot [int] -and $record.redis_configuration_rebind -isnot [long]){throw 'Invalid Redis configuration rebind capability'}
  if($record.redis_configuration_rebind -ne 1 -or $record.room_state_mode -cne 'ephemeral'){throw 'Unsupported Redis configuration rebind capability'}
 }
 if(@($Identity.files|Where-Object {$_.path -ceq 'redisctl.exe'}).Count -ne 1){throw 'Redis configuration rebind requires a manifest-bound redisctl.exe'}
}
# An explicit mode changes what the deployment adapter snapshots. Bind it to
# the hashed audit and build metadata; an absent mode retains old-package behavior.
function Assert-NativeRoomStateMode($Identity,$Audit,$BuildInfo) {
 $records=@($Identity,$Audit,$BuildInfo)
 $declared=@($records|Where-Object {$_.PSObject.Properties.Name -contains 'room_state_mode'})
 if(!$declared.Count){return}
 if($declared.Count -ne 3){throw 'Room state mode is missing from release, audit or build metadata'}
 foreach($record in $records){if($record.room_state_mode -cne 'ephemeral'){throw 'Unsupported or inconsistent room state mode'}}
}
function Assert-NativeCurrentContractAudit($Audit) {
 $contract=$Audit.current_client_contract
 # "Current" denotes the complete audit format, not a fixed latest version.
 if($contract.profile -cne 'warcraft-round-v1' -or
    [string]$contract.protocol -cnotmatch '^[1-9][0-9]*$' -or
    [string]$contract.contract -cnotmatch '^[1-9][0-9]*$' -or
    [string]::IsNullOrWhiteSpace([string]$contract.ruleset) -or
    [string]::IsNullOrWhiteSpace([string]$contract.economy) -or
    [string]$contract.economy_schema -cnotmatch '^[1-9][0-9]*$' -or
    [string]$contract.contract_sha256 -cnotmatch '^[a-f0-9]{64}$' -or
    $contract.new_authentication_required -isnot [bool] -or $contract.new_authentication_required -ne $false -or
    $contract.client_request_changes_required -isnot [bool]){throw 'A complete verified package contract identity is required; fixed gameplay versions are not imposed'}
}
function Test-NativeReleaseIdentity {
 param([string]$PackageRoot,[switch]$AllowHistorical)
 $identity=Get-Content -LiteralPath (Join-Path $PackageRoot 'RELEASE_IDENTITY.json') -Raw -Encoding UTF8|ConvertFrom-Json
 if($identity.schema_version -ne 1 -or $identity.production_gameplay -ne 'cpp' -or $identity.target -ne 'windows/amd64' -or $identity.abi_version -ne 1 -or $identity.transport_profile -ne 'warcraft-round-v1'){throw 'Unsupported native release identity'}
 $seen=@{}
 foreach($item in $identity.files){
  $name=[string]$item.path
  if([IO.Path]::IsPathRooted($name) -or $name.Contains(':') -or $name.Contains('\') -or @($name.Split('/')|Where-Object {$_ -in @('','..','.')}).Count -or $seen.ContainsKey($name)){throw 'Unsafe or duplicate identity path'}
  $seen[$name]=$true
  if((Get-NativeReleaseHash (Join-Path $PackageRoot $name)) -cne $item.sha256){throw "Native identity mismatch: $name"}
 }
 $actual=@(Get-ChildItem -LiteralPath $PackageRoot -Recurse -File|Where-Object {$_.Name -notin @('RELEASE_IDENTITY.json','SHA256SUMS')})
 if($actual.Count -ne $seen.Count){throw 'Native identity file set differs'}
 foreach($file in $actual){if(!$seen.ContainsKey($file.FullName.Substring($PackageRoot.Length+1).Replace('\','/'))){throw 'Unlisted native release file'}}
 foreach($required in @('server.exe','gamecore.dll','configmigrate.exe','verification.json','toolchain.lock.json','BUILD_INFO.json')){if(!$seen.ContainsKey($required)){throw "Missing native release component: $required"}}
 if((Get-NativeReleaseHash (Join-Path $PackageRoot 'gamecore.dll')) -cne $identity.dll_sha256){throw 'DLL identity mismatch'}
 $auditPath=Join-Path $PackageRoot 'verification.json'
 if((Get-NativeReleaseHash $auditPath) -cne $identity.verification_audit_sha256){throw 'Verification audit identity mismatch'}
 $audit=Get-Content -LiteralPath $auditPath -Raw -Encoding UTF8|ConvertFrom-Json
 $buildInfo=Get-Content -LiteralPath (Join-Path $PackageRoot 'BUILD_INFO.json') -Raw -Encoding UTF8|ConvertFrom-Json
 Assert-NativeRoomStateMode $identity $audit $buildInfo
 Assert-NativeRedisRebindCapability $identity $buildInfo
 if($AllowHistorical){Assert-NativeInstalledContractAudit $audit}else{Assert-NativeCurrentContractAudit $audit}
 Assert-NativeContentContract -PackageRoot $PackageRoot -Audit $audit
 if($audit.status -cne 'passed' -or $audit.source.sha256 -cne $identity.verified_source_sha256){throw 'Verification source identity mismatch'}
 $release=@($audit.native|Where-Object {$_.configuration -eq 'Release'})
 if($release.Count -ne 1 -or $release[0].sha256 -cne $identity.dll_sha256 -or $release[0].build_id -cne $identity.dll_build_id){throw 'Verified DLL identity mismatch'}
 if($identity.deployment_admission -cne 'requires_native_maintenance_v1'){throw 'Unsupported deployment admission; this helper cannot authorize activation'}
 return $identity
}

function Assert-NativeContentContract {
 param([string]$PackageRoot,$Audit)
 $contract=$null
 if($Audit.PSObject.Properties.Name -contains 'current_client_contract'){$contract=$Audit.current_client_contract}
 elseif($Audit.PSObject.Properties.Name -contains 'legacy_client_contract'){$contract=$Audit.legacy_client_contract}
 else{throw 'Missing contract audit'}
 $rules=Get-Content -LiteralPath (Join-Path $PackageRoot 'configs/combat/ruleset.json') -Raw -Encoding UTF8|ConvertFrom-Json
 $economy=Get-Content -LiteralPath (Join-Path $PackageRoot 'configs/combat/economy.json') -Raw -Encoding UTF8|ConvertFrom-Json
 if($rules.version -cne $contract.ruleset){throw 'Actual Ruleset differs from audit; relabelling historical evidence is forbidden'}
 if($contract.PSObject.Properties.Name -contains 'contract_sha256'){
   Assert-NativeCurrentContractAudit $Audit
   if(!(Test-Path -LiteralPath (Join-Path $PackageRoot 'nativearchiveaudit.exe'))){throw 'Missing read-only archive audit tool'}
   if($contract.economy -cne $economy.version -or $contract.economy_schema -ne $economy.schema_version){throw 'Actual economy differs from verified audit'}
   $path=Join-Path $PackageRoot 'client-contract.json'
   if((Get-NativeReleaseHash $path) -cne $contract.contract_sha256){throw 'Packaged contract differs from verified manifest'}
   $manifest=Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json
   Assert-NativeManifestContent $manifest $rules $economy
   if([string]$manifest.protocol_version -cne [string]$contract.protocol -or $manifest.contract_version -ne $contract.contract -or $manifest.current_transport_profile -cne $contract.profile -or $manifest.client_migration_required -ne $contract.client_request_changes_required){throw 'Packaged contract differs from verified audit identity'}
   return
 }
 # Read-only compatibility for old audit formats that predate manifest/economy
 # binding. These records cannot create new packages; never invent their hashes.
 Assert-NativeInstalledContractAudit $Audit
 $profile=([string]$contract.contract)+'/'+[string]$rules.version
 switch -CaseSensitive ($profile){
  '25/demo-skill-runtime-v12' {if($economy.schema_version -ne 3 -or $economy.version -cne 'match-economy-v3'){throw 'Historical economy mismatch'}}
  '25/demo-skill-runtime-v13' {if($economy.schema_version -ne 3 -or $economy.version -cne 'match-economy-v3'){throw 'Historical economy mismatch'}}
  '24/demo-skill-runtime-v11' {if($economy.schema_version -ne 3 -or $economy.version -cne 'match-economy-v3'){throw 'Historical economy mismatch'}}
  default {throw 'Historical audit lacks complete contract/content identity'}
 }
}
function Assert-NativeLegacyContractAudit($Audit) {
 $contract=$Audit.legacy_client_contract
 if($contract.profile -cne 'warcraft-round-v1' -or [string]$contract.protocol -cne '9' -or $contract.contract -ne 24 -or $contract.ruleset -cne 'demo-skill-runtime-v11' -or $contract.new_authentication_required -isnot [bool] -or $contract.new_authentication_required -ne $false -or $contract.client_request_changes_required -isnot [bool] -or $contract.client_request_changes_required -ne $false){throw 'Verified original client contract is required; experimental audits cannot authorize a production identity'}
}
function Assert-NativeInstalledContractAudit($Audit) {
 if($Audit.PSObject.Properties.Name -contains 'current_client_contract') {
  $c=$Audit.current_client_contract
  if(@($c.PSObject.Properties.Name|Where-Object {$_ -in @('contract_sha256','economy','economy_schema')}).Count){
   Assert-NativeCurrentContractAudit $Audit
   return
  }
  if($c.contract -eq 25 -and $c.ruleset -cin @('demo-skill-runtime-v12','demo-skill-runtime-v13')){
   if($c.profile -cne 'warcraft-round-v1' -or [string]$c.protocol -cne '9' -or $c.new_authentication_required -isnot [bool] -or $c.new_authentication_required -ne $false -or $c.client_request_changes_required -isnot [bool] -or $c.client_request_changes_required -ne $false){throw 'Historical contract identity mismatch'}
  }else{Assert-NativeCurrentContractAudit $Audit}
 } elseif($Audit.PSObject.Properties.Name -contains 'legacy_client_contract') {
  Assert-NativeLegacyContractAudit $Audit
 } else {
  throw 'Release audit is missing a supported client contract record'
 }
}
