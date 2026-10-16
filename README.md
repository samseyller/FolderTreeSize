# FolderTreeSize

A PowerShell script that prints a folder tree with the total size of each folder.

```
C:\Projects  (1.52 GB)
├── App  (1.20 GB)
│   ├── build  (1.10 GB)
│   └── dist  (100.4 MB)
└── Docs  (320.0 MB)
```

Works with Windows PowerShell 5.1 and PowerShell 7+.

## Usage

```powershell
.\FolderTreeSize.ps1 -Path <folder> [-Depth <n>] [-MinSizeMB <mb>] [-FollowJunctions]
```

| Parameter          | Default | Description                                                       |
|--------------------|---------|-------------------------------------------------------------------|
| `-Path`            | —       | Folder to report on (required).                                   |
| `-Depth`           | `2`     | Number of levels to display. Sizes always include the full tree. |
| `-MinSizeMB`       | `0`     | Hide folders smaller than this.                                   |
| `-FollowJunctions` | off     | Include the contents of junctions, directory symlinks and mount points. |

## Examples

```powershell
.\FolderTreeSize.ps1 -Path C:\Users -Depth 3
.\FolderTreeSize.ps1 -Path C:\Projects -MinSizeMB 100
.\FolderTreeSize.ps1 -Path D:\Data -FollowJunctions
```

If script execution is blocked, run it with:

```powershell
powershell -ExecutionPolicy Bypass -File .\FolderTreeSize.ps1 -Path C:\Users
```

## How sizes are counted

- **Junctions are not followed by default.** Junctions, directory symlinks and volume mount points appear in the tree marked `[junction -> target, not followed]` with no size.
- **No space is counted twice.** Each hard-linked file is counted only once. With `-FollowJunctions`, a folder that can be reached by more than one path, or through a junction loop, is also counted only once. The tree marks those repeats `already counted`.
- When the same data appears in several places, its size goes to the first place found. Real folders are scanned before any junctions, in name order.
- Sizes are logical file sizes, not size on disk: compressed files and cloud-only (OneDrive) files count at their full size.
- Folders that can't be read (for example, access denied) are skipped, and a count of them is printed at the end. Run as Administrator to include them.
