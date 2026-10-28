param(
    [string]$Root = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
    [switch]$LegacyOpenNegative,
    [switch]$LegacyEnumerationNegative
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
. (Join-Path $Root 'tool/windows/remove_brand_user_data.ps1') -LibraryOnly
Initialize-XbSafeDataRemoval
if (-not ('XbCleanupRaceRegression' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Collections;
using System.Collections.Generic;
using System.Reflection;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class XbCleanupRaceRegression {
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
    static extern SafeFileHandle CreateFile(string path,uint access,uint share,IntPtr security,uint creation,uint flags,IntPtr template);
    [DllImport("kernel32.dll",SetLastError=true)]
    static extern bool DeviceIoControl(SafeFileHandle file,uint code,byte[] input,uint size,IntPtr output,uint outSize,out uint returned,IntPtr overlapped);
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
    static extern uint GetFinalPathNameByHandle(SafeFileHandle file,StringBuilder text,uint count,uint flags);
    static Type model;
    static object Call(string name,params object[] args) {
        var method=model.GetMethod(name,BindingFlags.Static|BindingFlags.NonPublic);
        if(method==null) throw new Exception("Missing production boundary: "+name);
        try { return method.Invoke(null,args); }
        catch(TargetInvocationException e) { throw e.InnerException; }
    }
    static object Field(object target,string name) { return target.GetType().GetField(name).GetValue(target); }
    static SafeFileHandle Handle(object entry) { return (SafeFileHandle)Field(entry,"handle"); }
    static void Close(object entry) { if(entry!=null) ((IDisposable)entry).Dispose(); }
    static void Check(bool ok,string message) { if(!ok) throw new Exception(message); }
    static object Walk(string path,bool deleting,List<object> held) {
        string drive=Path.GetPathRoot(path);
        object parent=Call("OpenDrive",drive);held.Add(parent);
        string[] names=path.Substring(drive.Length).Split('\\');
        for(int i=0;i<names.Length;i++) {
            parent=Call("OpenRelative",parent,names[i],deleting && i==names.Length-1,false,true,null);
            held.Add(parent);
        }
        return parent;
    }
    static List<object> Children(object entry) {
        var list=new List<object>();
        foreach(object child in (IEnumerable)Call("ReadChildren",entry)) list.Add(child);
        return list;
    }
    static IList NewEntries() {
        return (IList)Activator.CreateInstance(typeof(List<>).MakeGenericType(model.GetNestedType("Entry",BindingFlags.NonPublic)));
    }
    static void DisposeAll(IEnumerable entries) { foreach(object e in entries) Close(e); }
    static string Read(string path) {
        using(var file=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.ReadWrite|FileShare.Delete))
        using(var text=new StreamReader(file)) return text.ReadToEnd();
    }
    static string Final(SafeFileHandle file) {
        var text=new StringBuilder(32768);
        if(GetFinalPathNameByHandle(file,text,(uint)text.Capacity,0)==0) throw new System.ComponentModel.Win32Exception();
        return text.ToString();
    }
    static void Junction(string path,string destination) {
        byte[] sub=Encoding.Unicode.GetBytes("\\??\\"+destination), print=Encoding.Unicode.GetBytes(destination);
        byte[] data=new byte[16+sub.Length+2+print.Length+2];
        Buffer.BlockCopy(BitConverter.GetBytes(0xA0000003u),0,data,0,4);
        Buffer.BlockCopy(BitConverter.GetBytes((ushort)(data.Length-8)),0,data,4,2);
        Buffer.BlockCopy(BitConverter.GetBytes((ushort)sub.Length),0,data,10,2);
        Buffer.BlockCopy(BitConverter.GetBytes((ushort)(sub.Length+2)),0,data,12,2);
        Buffer.BlockCopy(BitConverter.GetBytes((ushort)print.Length),0,data,14,2);
        Buffer.BlockCopy(sub,0,data,16,sub.Length);Buffer.BlockCopy(print,0,data,18+sub.Length,print.Length);
        using(var file=CreateFile(path,0x40000000,7,IntPtr.Zero,3,0x2200000,IntPtr.Zero)) {
            if(file.IsInvalid) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            uint done;
            if(!DeviceIoControl(file,0x900A4,data,(uint)data.Length,IntPtr.Zero,0,out done,IntPtr.Zero))
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        }
    }
    static object RawOpen(object parent,string name,bool directory) {
        return Call("CreateRelative",parent,name,true,true,directory);
    }
    static void NativeBoundary(string fixture,string brand,string stage,bool legacyOpen,bool legacyEnumeration) {
        string company=Path.Combine(fixture,"known","com.cloud.app"), brandRoot=Path.Combine(company,brand);
        string guard=stage=="company"?company:Path.Combine(brandRoot,"empty-cache");
        string outside=Path.Combine(fixture,"outside");
        string childName=stage=="company"?brand:"sentinel.txt";
        string sentinel=stage=="company"?Path.Combine(outside,brand,"sentinel.txt"):Path.Combine(outside,"sentinel.txt");
        Directory.CreateDirectory(guard);Directory.CreateDirectory(Path.GetDirectoryName(sentinel));
        File.WriteAllText(sentinel,"outside-preserved");
        if(stage!="company") File.WriteAllText(Path.Combine(brandRoot,"own.json"),"own-preserved");
        var held=new List<object>(); bool changed=false; object opened=null;
        try {
            object parent=Walk(guard,stage!="company",held);
            // Controls prove the real native APIs work before inserting the race.
            Directory.CreateDirectory(Path.Combine(guard,"normal"));
            opened=RawOpen(parent,"normal",true);Check(opened!=null,"Normal relative open failed");Close(opened);opened=null;
            Check(Children(parent).Count==1,"Normal handle enumeration failed");
            Directory.Delete(Path.Combine(guard,"normal"));
            Junction(guard,outside);changed=true;
            if(legacyOpen) {
                // Exactly the previous unsafe I/O boundary; test-only, never installed.
                using(var file=CreateFile(Path.Combine(guard,childName),0x10080,3,IntPtr.Zero,3,0x2200000,IntPtr.Zero)) {
                    Check(!file.IsInvalid,"Legacy control did not reach the candidate");
                    Check(!Final(file).Contains("\\outside\\"),"UNSAFE_ABSOLUTE_OPEN");
                }
            } else {
                try { opened=RawOpen(parent,childName,stage=="company"); }
                catch(System.ComponentModel.Win32Exception) { }
                catch(IOException) { }
                Check(opened==null,"Relative primitive followed a changed parent");
            }
            if(legacyEnumeration) {
                Check(Directory.GetFileSystemEntries(guard).Length==0,"UNSAFE_PATH_ENUMERATION");
            } else {
                try { Check(Children(parent).Count==0,"Handle enumeration followed changed directory"); }
                catch(System.ComponentModel.Win32Exception) { }
                catch(IOException) { }
            }
            Check(Read(sentinel)=="outside-preserved","Outside sentinel changed");
        } finally {
            Close(opened);DisposeAll(held);
            if(changed) Directory.Delete(guard);
        }
    }
    static void AfterPreflight(string fixture,string brand) {
        string target=Path.Combine(fixture,"known","com.cloud.app",brand), outside=Path.Combine(fixture,"outside");
        string cache=Path.Combine(target,"cache");
        Directory.CreateDirectory(cache);Directory.CreateDirectory(outside);
        File.WriteAllText(Path.Combine(target,"own.json"),"own-preserved");File.WriteAllText(Path.Combine(outside,"sentinel.txt"),"outside-preserved");
        var held=new List<object>();IList entries=NewEntries();bool changed=false;
        try {
            object root=Walk(target,true,held);Call("Collect",root,entries,0);
            Junction(cache,outside);changed=true;
            bool rejected=false;
            try { Call("DeleteEntries",entries); } catch(IOException) { rejected=true; }
            Check(rejected,"Preflight directory mutation not rejected");
            Check(Read(Path.Combine(target,"own.json"))=="own-preserved","Own tree partially removed before rejection");
            Check(Read(Path.Combine(outside,"sentinel.txt"))=="outside-preserved","Outside sentinel deleted");
        } finally { DisposeAll(entries);DisposeAll(held);if(changed && Directory.Exists(cache)) Directory.Delete(cache); }
    }
    static void ReplacedIdentity(string fixture,string brand) {
        string target=Path.Combine(fixture,"known","com.cloud.app",brand);
        Directory.CreateDirectory(target);string path=Path.Combine(target,"config.json");File.WriteAllText(path,"old");
        var held=new List<object>();object child=null;
        try {
            object parent=Walk(target,true,held);object expected=Children(parent)[0];
            child=Call("OpenRelative",parent,"config.json",true,false,false,expected);Close(child);child=null;
            File.Move(path,Path.Combine(target,"original.json"));File.WriteAllText(path,"replacement");
            bool rejected=false;
            try { child=Call("OpenRelative",parent,"config.json",true,false,false,expected); }
            catch(IOException) { rejected=true; }
            Check(rejected,"REPLACED_IDENTITY_ACCEPTED");
            Check(Read(path)=="replacement","Replacement touched");
        } finally { Close(child);DisposeAll(held); }
    }
    static void InvalidChildren(string fixture,string brand) {
        string target=Path.Combine(fixture,"known","com.cloud.app",brand);Directory.CreateDirectory(target);
        var held=new List<object>();
        try {
            object parent=Walk(target,true,held);
            foreach(string name in new[]{"", ".", "..", "..\\outside", "x/y", "x:y", "tail.", "tail ", Path.Combine(fixture,"outside")}) {
                bool rejected=false;object opened=null;
                try { opened=RawOpen(parent,name,true); }
                catch(ArgumentException) { rejected=true; }
                finally { Close(opened); }
                Check(rejected,"Non-component child name accepted");
            }
        } finally { DisposeAll(held); }
    }
    static void MultiPage(string fixture,string brand) {
        string known=Path.Combine(fixture,"known"), target=Path.Combine(known,"com.cloud.app",brand);
        Directory.CreateDirectory(target);
        for(int i=0;i<320;i++) File.WriteAllText(Path.Combine(target,i.ToString("D4")+new string('x',80)+".json"),"fixture");
        object result=model.GetMethod("Remove").Invoke(null,new object[]{known,brand});
        Check((bool)result && !Directory.Exists(target),"Multi-page directory cleanup incomplete");
        Check(Directory.Exists(Path.Combine(known,"com.cloud.app")),"Shared parent removed");
    }
    public static int Run(Type production,bool legacyOpen,bool legacyEnumeration) {
        model=production;int passed=0,failed=0;
        foreach(string brand in new[]{"omofly","daishu"}) {
            foreach(string stage in new[]{"company","empty-child","after-preflight","identity","invalid-child","multi-page"}) {
                string fixture=Path.Combine(Path.GetTempPath(),"cleanup-race-"+Guid.NewGuid().ToString("N"));Directory.CreateDirectory(fixture);
                try {
                    if(stage=="company" || stage=="empty-child") NativeBoundary(fixture,brand,stage,legacyOpen,legacyEnumeration);
                    else if(stage=="after-preflight") AfterPreflight(fixture,brand);
                    else if(stage=="identity") ReplacedIdentity(fixture,brand);
                    else if(stage=="invalid-child") InvalidChildren(fixture,brand);
                    else MultiPage(fixture,brand);
                    passed++;Console.WriteLine("PASS: "+brand+" "+stage);
                } catch(Exception e) { failed++;Console.WriteLine("FAIL: "+brand+" "+stage+" "+e.Message); }
                finally { Directory.Delete(fixture,true); }
            }
        }
        Console.WriteLine("Race checks: "+passed+" passed, "+failed+" failed");return failed==0?0:1;
    }
}
'@
}
$code=[XbCleanupRaceRegression]::Run([XbBrandDataRemoval],$LegacyOpenNegative.IsPresent,$LegacyEnumerationNegative.IsPresent)
exit $code
