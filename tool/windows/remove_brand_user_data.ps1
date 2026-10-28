param(
    [ValidateSet('omofly','daishu')][string]$Brand,
    [switch]$LibraryOnly
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-XbCleanupIdentity([string]$CurrentSid, [string[]]$ShellSids) {
    $unique = @($ShellSids | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    return -not [string]::IsNullOrWhiteSpace($CurrentSid) -and $unique.Count -eq 1 -and $unique[0] -eq $CurrentSid
}

function Test-XbCleanupRootOwnership([string]$Path, [string]$Profile) {
    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($Profile)) { return $false }
    try {
        $root = [IO.Path]::GetFullPath($Path)
        $profileRoot = [IO.Path]::GetFullPath($Profile).TrimEnd([IO.Path]::DirectorySeparatorChar)
        return $profileRoot.Length -gt 3 -and $root.StartsWith($profileRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
    } catch { return $false }
}

function Get-XbCleanupContext {
    $current = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $session = (Get-Process -Id $PID).SessionId
    $shells = @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" | Where-Object { $_.SessionId -eq $session })
    $sids = @($shells | ForEach-Object {
        $owner = Invoke-CimMethod -InputObject $_ -MethodName GetOwnerSid
        if ($owner.ReturnValue -ne 0) { throw 'Cannot confirm desktop user' }
        $owner.Sid
    })
    if (-not (Test-XbCleanupIdentity $current $sids)) { throw 'Cannot confirm same desktop user' }
    $roots = @(
        [Environment]::GetFolderPath([Environment+SpecialFolder]::ApplicationData),
        [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    )
    $profile = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    foreach ($root in $roots) {
        if (-not (Test-XbCleanupRootOwnership $root $profile)) { throw 'Redirected user directory cannot be confirmed' }
    }
    return $roots
}

function Initialize-XbSafeDataRemoval {
    if ('XbBrandDataRemoval' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class XbBrandDataRemoval {
    const uint ReadAttributes=0x80, DeleteAccess=0x10000, Synchronize=0x100000;
    const uint OpenReparsePoint=0x200000, BackupSemantics=0x2000000;
    const uint Reparse=0x400, DirectoryAttribute=0x10;
    const uint DontReparse=0x1000, CaseInsensitive=0x40;
    [StructLayout(LayoutKind.Sequential)]
    struct Info {
        public uint attributes;
        public System.Runtime.InteropServices.ComTypes.FILETIME creation, access, write;
        public uint volume, sizeHigh, sizeLow, links, indexHigh, indexLow;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct FileIdentity { public ulong volume, low, high; }
    [StructLayout(LayoutKind.Sequential)]
    struct UnicodeName { public ushort length, capacity; public IntPtr buffer; }
    [StructLayout(LayoutKind.Sequential)]
    struct ObjectAttributes {
        public uint length; public IntPtr root, name; public uint flags;
        public IntPtr security, quality;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct IoStatus { public IntPtr status; public UIntPtr information; }
    [StructLayout(LayoutKind.Sequential)]
    struct Overlapped { public IntPtr internalLow, internalHigh; public uint offset, offsetHigh; public IntPtr signal; }
    [StructLayout(LayoutKind.Sequential)]
    struct Disposition { [MarshalAs(UnmanagedType.U1)] public bool delete; }
    [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
    static extern SafeFileHandle CreateFile(string path,uint access,uint share,IntPtr security,uint creation,uint flags,IntPtr template);
    [DllImport("kernel32.dll",SetLastError=true)]
    static extern bool GetFileInformationByHandle(SafeFileHandle file,out Info info);
    [DllImport("kernel32.dll",SetLastError=true)]
    static extern bool GetFileInformationByHandleEx(SafeFileHandle file,int kind,IntPtr data,uint size);
    [DllImport("kernel32.dll",SetLastError=true)]
    static extern bool SetFileInformationByHandle(SafeFileHandle file,int kind,ref Disposition info,uint size);
    [DllImport("kernel32.dll",SetLastError=true)]
    static extern bool LockFileEx(SafeFileHandle file,uint flags,uint reserved,uint low,uint high,ref Overlapped overlapped);
    [DllImport("ntdll.dll")]
    static extern int NtCreateFile(out SafeFileHandle file,uint access,ref ObjectAttributes attributes,out IoStatus status,IntPtr allocation,uint fileAttributes,uint share,uint disposition,uint options,IntPtr ea,uint eaLength);
    [DllImport("ntdll.dll")]
    static extern uint RtlNtStatusToDosError(int status);

    sealed class Entry : IDisposable {
        public SafeFileHandle handle;
        // Diagnostic/lock-order label only. Never use this path for descendant I/O.
        public string path;
        public bool directory;
        public FileIdentity identity;
        public void Dispose() { if(handle!=null) handle.Dispose(); }
    }
    sealed class Child { public string name; public bool directory; public ulong low,high; }
    static void ValidateName(string name) {
        if(String.IsNullOrEmpty(name) || name=="." || name==".." || name.Length>255 || name.EndsWith(".") || name.EndsWith(" ") || name.IndexOfAny(new[]{'\\','/',':','\0'})>=0)
            throw new ArgumentException("Expected a single child name");
    }
    static Info ReadInfo(SafeFileHandle handle) {
        Info info;
        if(!GetFileInformationByHandle(handle,out info)) throw new Win32Exception(Marshal.GetLastWin32Error());
        if((info.attributes&Reparse)!=0) throw new IOException("Reparse point: data retained");
        return info;
    }
    static FileIdentity ReadIdentity(SafeFileHandle handle) {
        IntPtr buffer=Marshal.AllocHGlobal(24);
        try {
            if(!GetFileInformationByHandleEx(handle,18,buffer,24)) throw new Win32Exception(Marshal.GetLastWin32Error());
            return (FileIdentity)Marshal.PtrToStructure(buffer,typeof(FileIdentity));
        } finally { Marshal.FreeHGlobal(buffer); }
    }
    static Entry Accept(SafeFileHandle handle,string label,bool directory,bool instanceLock) {
        try {
            var info=ReadInfo(handle);
            if(((info.attributes&DirectoryAttribute)!=0)!=directory) throw new IOException("Object type changed");
            var identity=ReadIdentity(handle);
            if(instanceLock) {
                var overlapped=new Overlapped();
                if(!LockFileEx(handle,3,0,uint.MaxValue,uint.MaxValue,ref overlapped)) throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            return new Entry { handle=handle,path=label,directory=directory,identity=identity };
        } catch { handle.Dispose(); throw; }
    }
    static Entry OpenDrive(string drive) {
        if(drive.Length!=3 || !Char.IsLetter(drive[0]) || drive[1]!=':' || drive[2]!='\\') throw new ArgumentException("Expected local drive root");
        var handle=CreateFile("\\\\?\\"+drive,ReadAttributes|Synchronize|1,3,IntPtr.Zero,3,OpenReparsePoint|BackupSemantics,IntPtr.Zero);
        if(handle.IsInvalid) { int code=Marshal.GetLastWin32Error();handle.Dispose();throw new Win32Exception(code); }
        return Accept(handle,drive,true,false);
    }
    // RootDirectory anchors lookup to the existing parent object. The name is
    // exactly one component; no descendant operation re-resolves an ancestor path.
    static Entry CreateRelative(Entry parent,string name,bool deleting,bool missingAllowed,bool directory) {
        ValidateName(name);
        bool instanceLock=deleting && !directory && String.Equals(name,"FlClash.lock",StringComparison.OrdinalIgnoreCase);
        uint access=ReadAttributes|Synchronize|(directory?1u:0u)|(deleting?DeleteAccess:0u)|(instanceLock?0xC0000000u:0u);
        IntPtr text=Marshal.StringToHGlobalUni(name), unicode=IntPtr.Zero;
        bool reference=false;
        try {
            var value=new UnicodeName { length=(ushort)(name.Length*2),capacity=(ushort)((name.Length+1)*2),buffer=text };
            unicode=Marshal.AllocHGlobal(Marshal.SizeOf(typeof(UnicodeName)));
            Marshal.StructureToPtr(value,unicode,false);
            parent.handle.DangerousAddRef(ref reference);
            var attrs=new ObjectAttributes { length=(uint)Marshal.SizeOf(typeof(ObjectAttributes)),root=parent.handle.DangerousGetHandle(),name=unicode,flags=CaseInsensitive|DontReparse };
            SafeFileHandle handle;IoStatus io;
            int status=NtCreateFile(out handle,access,ref attrs,out io,IntPtr.Zero,0,3,1,OpenReparsePoint|0x20u|(directory?1u:0x40u),IntPtr.Zero,0);
            if(status<0) {
                if(handle!=null) handle.Dispose();
                int code=(int)RtlNtStatusToDosError(status);
                if(missingAllowed && (code==2 || code==3)) return null;
                throw new Win32Exception(code);
            }
            return Accept(handle,Path.Combine(parent.path,name),directory,instanceLock);
        } finally {
            if(reference) parent.handle.DangerousRelease();
            if(unicode!=IntPtr.Zero) Marshal.FreeHGlobal(unicode);
            Marshal.FreeHGlobal(text);
        }
    }
    static Entry OpenRelative(Entry parent,string name,bool deleting,bool missingAllowed,bool directory,Child expected) {
        ReadInfo(parent.handle);
        var child=CreateRelative(parent,name,deleting,missingAllowed,directory);
        try {
            ReadInfo(parent.handle);
            if(child!=null && (child.identity.volume!=parent.identity.volume ||
                (expected!=null && (child.identity.low!=expected.low || child.identity.high!=expected.high))))
                throw new IOException("Enumerated object identity changed");
            return child;
        } catch { if(child!=null) child.Dispose();throw; }
    }
    // FILE_ID_EXTD_DIR_INFO is read from the existing directory handle, not from
    // Directory.EnumerateFileSystemEntries(path). Unsupported filesystems fail closed.
    static IEnumerable<Child> ReadChildren(Entry entry) {
        const int size=65536, header=88;
        IntPtr buffer=Marshal.AllocHGlobal(size);
        var seen=new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        try {
            bool restart=true;
            while(true) {
                if(!GetFileInformationByHandleEx(entry.handle,restart?20:19,buffer,size)) {
                    int code=Marshal.GetLastWin32Error();
                    if(code==18) yield break;
                    throw new Win32Exception(code);
                }
                restart=false;
                int offset=0;
                while(true) {
                    if(offset<0 || offset>size-header) throw new IOException("Invalid directory record");
                    IntPtr row=IntPtr.Add(buffer,offset);
                    int next=Marshal.ReadInt32(row,0), length=Marshal.ReadInt32(row,60);
                    if(length<=0 || (length&1)!=0 || length>size-offset-header || (next!=0 && (next<header+length || next>size-offset)))
                        throw new IOException("Invalid directory name record");
                    string name=Marshal.PtrToStringUni(IntPtr.Add(row,header),length/2);
                    if(name!="." && name!="..") {
                        ValidateName(name);
                        if(!seen.Add(name) || seen.Count>10000) throw new IOException("Directory changed or cleanup limit reached");
                        uint attributes=(uint)Marshal.ReadInt32(row,56);
                        if((attributes&Reparse)!=0) throw new IOException("Reparse point: data retained");
                        yield return new Child { name=name,directory=(attributes&DirectoryAttribute)!=0,low=(ulong)Marshal.ReadInt64(row,72),high=(ulong)Marshal.ReadInt64(row,80) };
                    }
                    if(next==0) break;
                    offset+=next;
                }
            }
        } finally { Marshal.FreeHGlobal(buffer); }
    }
    static void Collect(Entry entry,List<Entry> entries,int depth) {
        entries.Add(entry);
        if(depth>128 || entries.Count>10000) throw new IOException("Cleanup limit: data retained");
        ReadInfo(entry.handle);
        if(!entry.directory) return;
        foreach(var child in ReadChildren(entry))
            Collect(OpenRelative(entry,child.name,true,false,child.directory,child),entries,depth+1);
    }
    static void DeleteEntries(List<Entry> entries) {
        // Validate all pinned objects again before the first deletion. Any later
        // metadata change can only affect these handles, never redirect traversal.
        foreach(var entry in entries) ReadInfo(entry.handle);
        var target=entries[0];
        int lockIndex=entries.FindIndex(e=>String.Equals(e.path,Path.Combine(target.path,"FlClash.lock"),StringComparison.OrdinalIgnoreCase));
        if(lockIndex>1) { var instance=entries[lockIndex];entries.RemoveAt(lockIndex);entries.Insert(1,instance); }
        for(int i=entries.Count-1;i>=0;i--) {
            ReadInfo(entries[i].handle);
            var disposition=new Disposition { delete=true };
            if(!SetFileInformationByHandle(entries[i].handle,4,ref disposition,(uint)Marshal.SizeOf(typeof(Disposition))))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            entries[i].Dispose();
        }
    }
    public static bool Remove(string knownFolder,string brand) {
        if(brand!="omofly" && brand!="daishu") throw new ArgumentException("Unknown brand");
        if(String.IsNullOrWhiteSpace(knownFolder) || knownFolder.Length<4 || !Char.IsLetter(knownFolder[0]) || knownFolder[1]!=':' || knownFolder[2]!='\\' || knownFolder.IndexOf(':',2)>=0 || knownFolder.IndexOf('/')>=0)
            throw new ArgumentException("Expected local known folder");
        string root=Path.GetFullPath(knownFolder).TrimEnd('\\');
        if(root.Length<=3 || !String.Equals(root,knownFolder.TrimEnd('\\'),StringComparison.OrdinalIgnoreCase)) throw new ArgumentException("Non-canonical known folder");
        var parents=new List<Entry>();var entries=new List<Entry>();
        try {
            string drive=Path.GetPathRoot(root);
            var parent=OpenDrive(drive);parents.Add(parent);
            foreach(string component in root.Substring(drive.Length).Split('\\')) {
                if(String.IsNullOrWhiteSpace(component) || component.EndsWith(".") || component.EndsWith(" ")) throw new ArgumentException("Invalid path component");
                parent=OpenRelative(parent,component,false,true,true,null);
                if(parent==null) return true;
                parents.Add(parent);
            }
            var company=OpenRelative(parent,"com.cloud.app",false,true,true,null);
            if(company==null) return true;
            parents.Add(company);
            var target=OpenRelative(company,brand,true,true,true,null);
            if(target==null) return true;
            Collect(target,entries,0);
            DeleteEntries(entries);
            return true;
        } finally {
            foreach(var entry in entries) entry.Dispose();
            for(int i=parents.Count-1;i>=0;i--) parents[i].Dispose();
        }
    }
}
'@
}

function Remove-XbBrandDataRoots([string[]]$Roots, [string]$Slug) {
    Initialize-XbSafeDataRemoval
    $results = @()
    foreach ($root in $Roots) {
        try {
            [void][XbBrandDataRemoval]::Remove($root, $Slug)
            $results += [pscustomobject]@{ Root=$root; Removed=$true }
        } catch {
            $results += [pscustomobject]@{ Root=$root; Removed=$false }
        }
    }
    return $results
}

if (-not $LibraryOnly) {
    if ([string]::IsNullOrWhiteSpace($Brand)) { exit 20 }
    try { $roots = Get-XbCleanupContext } catch { exit 10 }
    $name = if ($Brand -eq 'omofly') { 'OmoFly' } else { 'Daishu' }
    # A different installation may share this brand's user directory. Do not
    # terminate it or delete its live data just because this copy is uninstalling.
    try {
        $active = @(Get-CimInstance Win32_Process | Where-Object { $_.Name -in @("$name.exe", "${name}Core.exe", "${name}HelperService.exe") })
        if ($active.Count -gt 0) { exit 20 }
    } catch { exit 20 }
    $results = @(Remove-XbBrandDataRoots $roots $Brand)
    $results | ConvertTo-Json -Compress | Write-Output
    if (@($results | Where-Object { -not $_.Removed }).Count -gt 0) { exit 20 }
    exit 0
}
