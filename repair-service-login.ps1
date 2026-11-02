# Run on the remote server as administrator. Adds only the installed Agent account's service logon right.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
if(!(New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Administrator PowerShell required'}
$service=Get-CimInstance Win32_Service -Filter "Name='ZYF-CICD-Agent'"
if(!$service){throw 'Agent service is not registered'}
$account=[string]$service.StartName
if($account.StartsWith('.\')){$account=$env:COMPUTERNAME+$account.Substring(1)}
$sid=(New-Object Security.Principal.NTAccount($account)).Translate([Security.Principal.SecurityIdentifier])
$sidBytes=New-Object byte[] $sid.BinaryLength
$sid.GetBinaryForm($sidBytes,0)
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class ZyfServiceLogon {
 [StructLayout(LayoutKind.Sequential)] struct Attributes {
  public uint Length; public IntPtr RootDirectory; public IntPtr ObjectName;
  public uint Flags; public IntPtr SecurityDescriptor; public IntPtr SecurityQualityOfService;
 }
 [StructLayout(LayoutKind.Sequential)] struct UnicodeString { public ushort Length, MaximumLength; public IntPtr Buffer; }
 [DllImport("advapi32.dll")] static extern uint LsaOpenPolicy(IntPtr system, ref Attributes attributes, uint access, out IntPtr handle);
 [DllImport("advapi32.dll")] static extern uint LsaAddAccountRights(IntPtr handle, byte[] sid, UnicodeString[] rights, uint count);
 [DllImport("advapi32.dll")] static extern uint LsaNtStatusToWinError(uint status);
 [DllImport("advapi32.dll")] static extern uint LsaClose(IntPtr handle);
 static void Check(uint status) { if(status!=0) throw new Win32Exception((int)LsaNtStatusToWinError(status)); }
 public static void Grant(byte[] sid) {
  var attrs=new Attributes(); attrs.Length=(uint)Marshal.SizeOf(typeof(Attributes));
  IntPtr handle; Check(LsaOpenPolicy(IntPtr.Zero,ref attrs,0x810,out handle));
  string name="SeServiceLogonRight"; IntPtr buffer=Marshal.StringToHGlobalUni(name);
  try { var right=new UnicodeString{Length=(ushort)(name.Length*2),MaximumLength=(ushort)((name.Length+1)*2),Buffer=buffer};
   Check(LsaAddAccountRights(handle,sid,new[]{right},1));
  } finally { Marshal.FreeHGlobal(buffer); LsaClose(handle); }
 }
}
'@
[ZyfServiceLogon]::Grant($sidBytes)
Write-Output "Granted SeServiceLogonRight to $account ($sid)"
Start-Service ZYF-CICD-Agent
(Get-Service ZYF-CICD-Agent).WaitForStatus([ServiceProcess.ServiceControllerStatus]::Running,[TimeSpan]::FromSeconds(20))
Get-Service ZYF-CICD-Agent | Select-Object Name,Status
