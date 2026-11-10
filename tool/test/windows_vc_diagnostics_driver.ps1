# Native diagnostic harness runner; never starts a VC payload or installs the app.
param([Parameter(Mandatory=$true)][string]$Directory,
      [Parameter(Mandatory=$true)][string]$Language,
      [ValidateSet('normal','locked')][string]$Mode='normal')
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
Add-Type -AssemblyName System.Windows.Forms
Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.ComponentModel;
using System.Diagnostics;
using System.Collections.Generic;
using System.Text;
public static class XbClipboardTest {
 [DllImport("user32.dll")] public static extern bool OpenClipboard(IntPtr h);
 [DllImport("user32.dll")] public static extern bool CloseClipboard();
 [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h,uint m,IntPtr w,IntPtr l);
}
public sealed class XbHarnessJob : IDisposable {
 [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
 struct SI {
  public int cb; public string reserved, desktop, title;
  public int x,y,xSize,ySize,xChars,yChars,fill,flags;
  public short show, reserved2; public IntPtr reservedPtr, stdin, stdout, stderr;
 }
 [StructLayout(LayoutKind.Sequential)]
 struct PI { public IntPtr process, thread; public uint pid, tid; }
 [StructLayout(LayoutKind.Sequential)]
 struct BasicLimits { public long processTime,jobTime; public uint flags;
  public UIntPtr minWorking,maxWorking; public uint activeLimit; public UIntPtr affinity;
  public uint priority,scheduling; }
 [StructLayout(LayoutKind.Sequential)]
 struct ExtendedLimits { public BasicLimits basic; public ulong readOps,writeOps,otherOps,readBytes,writeBytes,otherBytes;
  public UIntPtr processMemory,jobMemory,peakProcess,peakJob; }
 [StructLayout(LayoutKind.Sequential)]
 struct Accounting { public long user,kernel,periodUser,periodKernel; public uint faults,total,active,terminated; }
 [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
 static extern IntPtr CreateJobObject(IntPtr attrs,string name);
 [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetInformationJobObject(IntPtr job,int kind,ref ExtendedLimits limits,uint size);
 [DllImport("kernel32.dll", SetLastError=true)] static extern bool QueryInformationJobObject(IntPtr job,int kind,out Accounting value,uint size,IntPtr length);
 [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
 static extern bool CreateProcess(string app,StringBuilder command,IntPtr pa,IntPtr ta,
  bool inherit,uint flags,IntPtr env,string cwd,ref SI si,out PI pi);
 [DllImport("kernel32.dll", SetLastError=true)] static extern bool AssignProcessToJobObject(IntPtr job,IntPtr process);
 [DllImport("kernel32.dll", SetLastError=true)] static extern uint ResumeThread(IntPtr thread);
 [DllImport("kernel32.dll", SetLastError=true)] static extern bool TerminateJobObject(IntPtr job,uint code);
 [DllImport("kernel32.dll", SetLastError=true)] static extern bool TerminateProcess(IntPtr process,uint code);
 [DllImport("kernel32.dll", SetLastError=true)] static extern bool IsProcessInJob(IntPtr process,IntPtr job,out bool inside);
 [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
 IntPtr job;
 public XbHarnessJob(string exe,string arguments,string cwd) {
  job=CreateJobObject(IntPtr.Zero,null);
  if(job==IntPtr.Zero) throw new Win32Exception();
  var limits=new ExtendedLimits(); limits.basic.flags=0x2000;
  if(!SetInformationJobObject(job,9,ref limits,(uint)Marshal.SizeOf(typeof(ExtendedLimits)))) {
   int error=Marshal.GetLastWin32Error(); CloseHandle(job); job=IntPtr.Zero; throw new Win32Exception(error);
  }
  SI si=new SI(); si.cb=Marshal.SizeOf(typeof(SI)); PI pi;
  if(!CreateProcess(exe,new StringBuilder("\""+exe+"\" "+arguments),IntPtr.Zero,IntPtr.Zero,
    false,4,IntPtr.Zero,cwd,ref si,out pi)) {
   int error=Marshal.GetLastWin32Error(); CloseHandle(job); job=IntPtr.Zero;
   throw new Win32Exception(error);
  }
  try {
   if(!AssignProcessToJobObject(job,pi.process) || ResumeThread(pi.thread)==0xffffffff)
    throw new Win32Exception();
  } catch { TerminateProcess(pi.process,1); CloseHandle(job); job=IntPtr.Zero; throw; }
  finally { CloseHandle(pi.thread); CloseHandle(pi.process); }
 }
 public int[] ProcessIds() {
  var ids=new List<int>();
  foreach(var p in Process.GetProcesses()) {
   using(p) { try {bool inside; if(IsProcessInJob(p.Handle,job,out inside) && inside) ids.Add(p.Id);}
    catch(Win32Exception) {} catch(InvalidOperationException) {} }
  }
  return ids.ToArray();
 }
 public void Stop() { if(job!=IntPtr.Zero && !TerminateJobObject(job,1)) throw new Win32Exception(); }
 public uint ActiveCount() { Accounting value;
  if(!QueryInformationJobObject(job,1,out value,(uint)Marshal.SizeOf(typeof(Accounting)),IntPtr.Zero)) throw new Win32Exception();
  return value.active;
 }
 public void Dispose() { if(job!=IntPtr.Zero) {CloseHandle(job); job=IntPtr.Zero;} }
}
'@
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
$result=Join-Path $Directory 'native-result.txt'
$exe=Join-Path $Directory 'diagnostic-harness.exe'
$job=$null
$saved=New-Object Windows.Forms.DataObject
$original=[Windows.Forms.Clipboard]::GetDataObject()
if($null -ne $original){
    foreach($format in $original.GetFormats($false)){
        $value=$original.GetData($format,$false)
        if($null -ne $value){$saved.SetData($format,$false,$value)}
    }
}
$locked=$false
$dismissed=$false
$exitCode=0
try {
    if(Test-Path $result){Remove-Item $result}
    if($Mode -eq 'locked'){
        $locked=[XbClipboardTest]::OpenClipboard([IntPtr]::Zero)
        if(!$locked){throw 'Cannot establish clipboard-lock negative control'}
    }
    # Assign the suspended loader before it can spawn the actual Inno process.
    # Every descendant belongs to this private job, including short-lived children.
    $job=New-Object XbHarnessJob($exe,('/SP- /LANG='+$Language+' /locktest='+[int]$locked),$Directory)
    $deadline=(Get-Date).AddSeconds(40)
    while(!(Test-Path $result) -and (Get-Date) -lt $deadline){
        if($locked){
            $owned=$job.ProcessIds()
            $processes=@(Get-Process | Where-Object {$_.Id -in $owned -and $_.ProcessName -eq 'diagnostic-harness.tmp'})
            foreach($process in $processes){
                $condition=New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::ProcessIdProperty,$process.Id)
                $windows=[Windows.Automation.AutomationElement]::RootElement.FindAll([Windows.Automation.TreeScope]::Children,$condition)
                foreach($window in $windows){
                    $texts=$window.FindAll([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.Condition]::TrueCondition)
                    $isCopyError=$false
                    foreach($element in $texts){
                        $name=$element.Current.Name
                        # Chinese text built as code points so PS5.1 reads this ASCII file safely.
                        $chinese=-join ([char[]]@(0x65e0,0x6cd5,0x8bbf,0x95ee,0x526a,0x8d34,0x677f))
                        if($name.Contains('The clipboard is unavailable.') -or $name.Contains($chinese)){$isCopyError=$true}
                    }
                    if($isCopyError){
                        # Inno owns this dialog; its custom OK button need not use IDOK.
                        [XbClipboardTest]::PostMessage([IntPtr]$window.Current.NativeWindowHandle,0x10,[IntPtr]::Zero,[IntPtr]::Zero)|Out-Null
                        $dismissed=$true
                    }
                }
            }
        }
        Start-Sleep -Milliseconds 150
    }
    if(!(Test-Path $result)){throw 'Harness result timed out'}
    $text=Get-Content $result -Raw -Encoding UTF8
    if(!$text.StartsWith('PASS:')){throw $text}
    if($locked){if(!$dismissed){throw 'Expected clipboard failure dialog was not observed'}}
    else {
        $copy=[Windows.Forms.Clipboard]::GetText()
        if(!$copy.Contains('Prerequisite result: 1') -or !$copy.Contains('VC=1')){throw 'Clipboard readback mismatch'}
    }
    Write-Output "PASS $Language $Mode"
} catch {
    Write-Output ('FAIL '+$_.Exception.Message)
    $exitCode=1
} finally {
    if($locked){[XbClipboardTest]::CloseClipboard()|Out-Null}
    try {
        if($null -ne $job){
            $job.Stop()
            $cleanupDeadline=(Get-Date).AddSeconds(5)
            while($job.ActiveCount() -gt 0 -and (Get-Date) -lt $cleanupDeadline){Start-Sleep -Milliseconds 50}
            if($job.ActiveCount() -gt 0){throw 'Owned harness processes survived cleanup'}
            Write-Output 'CLEANUP owned-processes=0'
        }
    } catch {Write-Output ('Process cleanup failed: '+$_.Exception.Message); $exitCode=1}
    finally {if($null -ne $job){$job.Dispose()}}
    try {
        if($saved.GetFormats($false).Count -gt 0){[Windows.Forms.Clipboard]::SetDataObject($saved,$true)}
        else {[Windows.Forms.Clipboard]::Clear()}
    } catch {Write-Output ('Cleanup failed: '+$_.Exception.Message); $exitCode=1}
}
exit $exitCode
