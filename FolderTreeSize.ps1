<#
.SYNOPSIS
  Tree-view folder size report (total recursive size per folder), N levels deep.

.DESCRIPTION
  Scans the folder tree once and reports the total size of each folder.

  Junctions, directory symbolic links and volume mount points are NOT followed
  by default; they are listed but contribute no size. Use -FollowJunctions to
  include their contents.

  Space is never counted twice:
    - Hard-linked files are identified by their file ID and counted once.
    - When following junctions, every folder is identified by its file ID, so a
      folder reached through several paths (or a junction loop) is counted once.
      Real folders in the tree are scanned before any junction is followed, so a
      folder's size is credited to its real location where possible.

.PARAMETER Path
  Folder to report on.

.PARAMETER Depth
  Number of folder levels to display (sizes always include the full tree).

.PARAMETER MinSizeMB
  Hide folders smaller than this size.

.PARAMETER FollowJunctions
  Follow junctions, directory symbolic links and volume mount points.

.EXAMPLE
  .\FolderTreeSize.ps1 -Path "C:\Users\" -Depth 3

.EXAMPLE
  .\FolderTreeSize.ps1 -Path "C:\Projects" -Depth 2 -MinSizeMB 10

.EXAMPLE
  .\FolderTreeSize.ps1 -Path "C:\Users\me" -FollowJunctions
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Path,

    [Parameter()]
    [ValidateRange(0, 99)]
    [int]$Depth = 2,

    [Parameter()]
    [double]$MinSizeMB = 0,

    [Parameter()]
    [switch]$FollowJunctions
)

# --- Native Helpers --------------------------------------------------------

# Win32 directory enumeration and file IDs. Written in C# (compatible with
# Windows PowerShell 5.1) because per-file work in PowerShell is too slow.
if (-not ('FolderTreeSize.Native' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace FolderTreeSize {
    public sealed class DirEntry {
        public string Name;
        public string FullPath;
        public bool IsLink;        // junction, mount point or directory symlink
        public uint ReparseTag;
    }

    public sealed class DirListing {
        public bool Ok;
        public long FileBytes;     // files directly in this folder, de-duplicated
        public List<DirEntry> Dirs = new List<DirEntry>();
    }

    public static class Native {
        const uint FILE_ATTRIBUTE_DIRECTORY     = 0x10;
        const uint FILE_ATTRIBUTE_REPARSE_POINT = 0x400;
        const uint REPARSE_TAG_NAME_SURROGATE   = 0x20000000;
        const uint FILE_FLAG_BACKUP_SEMANTICS   = 0x02000000;
        const uint FILE_FLAG_OPEN_REPARSE_POINT = 0x00200000;
        const int  ERROR_FILE_NOT_FOUND         = 2;
        static readonly IntPtr INVALID_HANDLE_VALUE = new IntPtr(-1);

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct WIN32_FIND_DATA {
            public uint dwFileAttributes;
            public System.Runtime.InteropServices.ComTypes.FILETIME ftCreationTime, ftLastAccessTime, ftLastWriteTime;
            public uint nFileSizeHigh, nFileSizeLow, dwReserved0, dwReserved1;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string cFileName;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 14)]  public string cAlternateFileName;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct BY_HANDLE_FILE_INFORMATION {
            public uint FileAttributes;
            public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime, LastAccessTime, LastWriteTime;
            public uint VolumeSerialNumber, FileSizeHigh, FileSizeLow, NumberOfLinks, FileIndexHigh, FileIndexLow;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct FILE_ID_INFO {
            public ulong VolumeSerialNumber, FileIdLow, FileIdHigh;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern IntPtr FindFirstFileExW(string lpFileName, int fInfoLevelId, out WIN32_FIND_DATA lpFindFileData,
                                              int fSearchOp, IntPtr lpSearchFilter, int dwAdditionalFlags);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool FindNextFileW(IntPtr hFindFile, out WIN32_FIND_DATA lpFindFileData);

        [DllImport("kernel32.dll")]
        static extern bool FindClose(IntPtr hFindFile);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern SafeFileHandle CreateFileW(string lpFileName, uint dwDesiredAccess, uint dwShareMode, IntPtr lpSecurityAttributes,
                                                 uint dwCreationDisposition, uint dwFlagsAndAttributes, IntPtr hTemplateFile);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool GetFileInformationByHandle(SafeFileHandle hFile, out BY_HANDLE_FILE_INFORMATION lpFileInformation);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool GetFileInformationByHandleEx(SafeFileHandle hFile, int fileInformationClass, out FILE_ID_INFO lpFileInformation, uint dwBufferSize);

        static string LongPath(string p) {
            if (p.StartsWith(@"\\?\") || p.StartsWith(@"\\.\")) return p;
            if (p.StartsWith(@"\\")) return @"\\?\UNC\" + p.Substring(2);
            return @"\\?\" + p;
        }

        // Unique ID of a file or folder ("volume:fileid"), or null if it can't be read.
        // followLink: identify a link's target rather than the link itself.
        // multiLinkOnly: return null for files with a single hard link (they can't be duplicates).
        public static string GetId(string path, bool followLink, bool multiLinkOnly) {
            uint flags = FILE_FLAG_BACKUP_SEMANTICS | (followLink ? 0 : FILE_FLAG_OPEN_REPARSE_POINT);
            using (SafeFileHandle h = CreateFileW(LongPath(path), 0, 7, IntPtr.Zero, 3, flags, IntPtr.Zero)) {
                if (h.IsInvalid) return null;

                BY_HANDLE_FILE_INFORMATION bh;
                if (!GetFileInformationByHandle(h, out bh)) return null;
                if (multiLinkOnly && bh.NumberOfLinks <= 1) return null;

                // 128-bit ID (needed on ReFS); fall back to the 64-bit index
                FILE_ID_INFO fi;
                if (GetFileInformationByHandleEx(h, 18, out fi, (uint)Marshal.SizeOf(typeof(FILE_ID_INFO))))
                    return fi.VolumeSerialNumber.ToString("x") + ":" + fi.FileIdHigh.ToString("x16") + fi.FileIdLow.ToString("x16");
                return bh.VolumeSerialNumber.ToString("x") + ":" + bh.FileIndexHigh.ToString("x8") + bh.FileIndexLow.ToString("x8");
            }
        }

        // Lists one folder: total size of its files (skipping hard links already
        // in seenFiles) and its subfolders.
        public static DirListing List(string dir, HashSet<string> seenFiles) {
            DirListing r = new DirListing();
            WIN32_FIND_DATA fd;
            // FindExInfoBasic = 1, FIND_FIRST_EX_LARGE_FETCH = 2
            IntPtr h = FindFirstFileExW(LongPath(Path.Combine(dir, "*")), 1, out fd, 0, IntPtr.Zero, 2);
            if (h == INVALID_HANDLE_VALUE) {
                r.Ok = Marshal.GetLastWin32Error() == ERROR_FILE_NOT_FOUND;
                return r;
            }
            try {
                do {
                    string name = fd.cFileName;
                    if (name == "." || name == "..") continue;

                    string full = Path.Combine(dir, name);
                    bool isReparse = (fd.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0;
                    bool isLink = isReparse && (fd.dwReserved0 & REPARSE_TAG_NAME_SURROGATE) != 0;

                    if ((fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0) {
                        DirEntry e = new DirEntry();
                        e.Name = name;
                        e.FullPath = full;
                        e.IsLink = isLink;
                        e.ReparseTag = isReparse ? fd.dwReserved0 : 0;
                        r.Dirs.Add(e);
                        continue;
                    }

                    // File symlinks point at data that lives elsewhere
                    if (isLink) continue;

                    long size = ((long)fd.nFileSizeHigh << 32) | fd.nFileSizeLow;
                    if (size == 0) continue;

                    string id = GetId(full, false, true);
                    if (id != null && !seenFiles.Add(id)) continue;   // hard link already counted

                    r.FileBytes += size;
                } while (FindNextFileW(h, out fd));
            } finally {
                FindClose(h);
            }
            r.Dirs.Sort((a, b) => string.Compare(a.Name, b.Name, StringComparison.OrdinalIgnoreCase));
            r.Ok = true;
            return r;
        }
    }
}
'@
}

# --- Helper Functions ------------------------------------------------------

function Format-Bytes {
    param([long]$Bytes)

    if ($Bytes -lt 1KB) { return "{0} B" -f $Bytes }
    if ($Bytes -lt 1MB) { return "{0:N1} KB" -f ($Bytes / 1KB) }
    if ($Bytes -lt 1GB) { return "{0:N1} MB" -f ($Bytes / 1MB) }
    if ($Bytes -lt 1TB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    return "{0:N2} TB" -f ($Bytes / 1TB)
}

function New-Node {
    param([string]$Name, [string]$FullPath, $Parent)

    $node = [pscustomobject]@{
        Name     = $Name
        Path     = $FullPath
        Parent   = $Parent
        Bytes    = 0L
        Children = New-Object System.Collections.Generic.List[object]
        Note     = $null
    }
    if ($Parent) { $Parent.Children.Add($node) }
    return $node
}

function Get-LinkDescription {
    param([FolderTreeSize.DirEntry]$Entry)

    $kind = switch ('{0:X8}' -f $Entry.ReparseTag) {
        'A0000003' { "junction" }
        'A000000C' { "symlink" }
        default    { "link" }
    }
    $target = $null
    try { $target = @((Get-Item -LiteralPath $Entry.FullPath -Force -ErrorAction Stop).Target)[0] } catch { }
    if ($target) { return "$kind -> $target" }
    return $kind
}

# Scans the whole tree once. Only folders within $MaxDepth get a node; deeper
# folders add their size to their nearest displayed ancestor.
function Measure-FolderTree {
    param(
        [Parameter(Mandatory)] [string]$Root,
        [Parameter(Mandatory)] [int]$MaxDepth,
        [bool]$FollowLinks
    )

    $seenFiles = New-Object 'System.Collections.Generic.HashSet[string]'
    $seenDirs  = New-Object 'System.Collections.Generic.HashSet[string]'
    $script:Unreadable = 0

    $rootNode = New-Node -Name $Root -FullPath $Root -Parent $null
    $pending  = New-Object System.Collections.Generic.Stack[object]
    $links    = New-Object System.Collections.Generic.Queue[object]   # followed after the real tree
    $pending.Push([pscustomobject]@{ Path = $Root; Node = $rootNode; Depth = 0; OwnsNode = $true })

    while ($pending.Count -gt 0 -or $links.Count -gt 0) {
        $item = if ($pending.Count -gt 0) { $pending.Pop() } else { $links.Dequeue() }

        # When following links, a folder reachable by several paths is counted once
        if ($FollowLinks) {
            $id = [FolderTreeSize.Native]::GetId($item.Path, $true, $false)
            if ($id -and -not $seenDirs.Add($id)) {
                if ($item.OwnsNode) {
                    $item.Node.Note = if ($item.Node.Note) { "$($item.Node.Note), already counted" } else { "already counted" }
                }
                continue
            }
        }

        $listing = [FolderTreeSize.Native]::List($item.Path, $seenFiles)
        if (-not $listing.Ok) { $script:Unreadable++; continue }

        for ($n = $item.Node; $n; $n = $n.Parent) { $n.Bytes += $listing.FileBytes }

        # Push in reverse so folders are scanned in name order; a hard-linked
        # file is credited to the first folder (by name) that contains it
        $childDepth = $item.Depth + 1
        for ($i = $listing.Dirs.Count - 1; $i -ge 0; $i--) {
            $entry = $listing.Dirs[$i]
            $node = $item.Node
            $ownsNode = $childDepth -le $MaxDepth
            if ($ownsNode) {
                $node = New-Node -Name $entry.Name -FullPath $entry.FullPath -Parent $item.Node
            }

            if ($entry.IsLink) {
                if ($ownsNode) { $node.Note = Get-LinkDescription $entry }
                if (-not $FollowLinks) {
                    if ($ownsNode) { $node.Note += ", not followed" }
                    continue
                }
                $links.Enqueue([pscustomobject]@{ Path = $entry.FullPath; Node = $node; Depth = $childDepth; OwnsNode = $ownsNode })
            } else {
                $pending.Push([pscustomobject]@{ Path = $entry.FullPath; Node = $node; Depth = $childDepth; OwnsNode = $ownsNode })
            }
        }
    }

    return $rootNode
}

function Write-FolderTree {
    param(
        [Parameter(Mandatory)] $Node,
        [int]$CurrentDepth = 0,
        [string]$Prefix = "",
        [bool]$IsLast = $true
    )

    $line = "{0}  ({1})" -f $Node.Name, (Format-Bytes $Node.Bytes)
    if ($Node.Note) { $line += "  [$($Node.Note)]" }

    # Print current node (root prints without branch glyph)
    if ($CurrentDepth -eq 0) {
        Write-Host $line
    } else {
        $branch = if ($IsLast) { "└── " } else { "├── " }
        Write-Host ("{0}{1}{2}" -f $Prefix, $branch, $line)
    }

    $children = @($Node.Children | Where-Object { ($_.Bytes / 1MB) -ge $MinSizeMB } | Sort-Object Name)

    for ($i = 0; $i -lt $children.Count; $i++) {
        # Build next prefix: keep vertical pipe for non-last siblings
        if ($CurrentDepth -eq 0) {
            $nextPrefix = ""
        }
        else {
            if ($IsLast) {
                $pad = "    "
            }
            else {
                $pad = "│   "
            }

            $nextPrefix = $Prefix + $pad
        }

        Write-FolderTree -Node $children[$i] `
                         -CurrentDepth ($CurrentDepth + 1) `
                         -Prefix $nextPrefix `
                         -IsLast ($i -eq ($children.Count - 1))
    }
}

# --- Run -------------------------------------------------------------------

$resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
if (-not (Test-Path -LiteralPath $resolved -PathType Container)) {
    throw "Not a folder: $resolved"
}

$tree = Measure-FolderTree -Root $resolved -MaxDepth $Depth -FollowLinks $FollowJunctions.IsPresent
Write-FolderTree -Node $tree

if ($script:Unreadable -gt 0) {
    Write-Host ("Note: {0} folder(s) could not be read (access denied?) and were not counted." -f $script:Unreadable) -ForegroundColor Yellow
}
