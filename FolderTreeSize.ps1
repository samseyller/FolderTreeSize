<#
.SYNOPSIS
  Tree-view folder size report (total recursive size per folder), N levels deep.

.EXAMPLE
  .\FolderTreeSize.ps1 -Path "C:\Users\" -Depth 3

.EXAMPLE
  .\FolderTreeSize.ps1 -Path "C:\Projects" -Depth 2 -MinSizeMB 10
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
    [double]$MinSizeMB = 0
)

# --- Helper Functions ------------------------------------------------------

function Format-Bytes {
    param([long]$Bytes)

    if ($Bytes -lt 1KB) { return "{0} B" -f $Bytes }
    if ($Bytes -lt 1MB) { return "{0:N1} KB" -f ($Bytes / 1KB) }
    if ($Bytes -lt 1GB) { return "{0:N1} MB" -f ($Bytes / 1MB) }
    if ($Bytes -lt 1TB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    return "{0:N2} TB" -f ($Bytes / 1TB)
}

# Cache folder sizes so we don't re-scan the same folder repeatedly
$script:SizeCache = @{}

function Get-FolderSizeBytes {
    param([Parameter(Mandatory)] [string]$Folder)

    $full = (Resolve-Path -LiteralPath $Folder).Path
    if ($script:SizeCache.ContainsKey($full)) {
        return $script:SizeCache[$full]
    }

    $sum = 0L
    try {
        # Enumerate files only, recursively
        Get-ChildItem -LiteralPath $full -File -Recurse -Force -ErrorAction SilentlyContinue |
            ForEach-Object { $sum += $_.Length }
    } catch {
        # ignore any unexpected issues
    }

    $script:SizeCache[$full] = $sum
    return $sum
}

function Write-FolderTree {
    param(
        [Parameter(Mandatory)] [string]$Folder,
        [Parameter(Mandatory)] [int]$MaxDepth,
        [int]$CurrentDepth = 0,
        [string]$Prefix = "",
        [bool]$IsLast = $true
    )

    $sizeBytes = Get-FolderSizeBytes -Folder $Folder
    $sizeMB = $sizeBytes / 1MB

    # Print current node (root prints without branch glyph)
    if ($CurrentDepth -eq 0) {
        Write-Host ("{0}  ({1})" -f $Folder, (Format-Bytes $sizeBytes))
    } else {
        if ($sizeMB -ge $MinSizeMB) {
            $branch = if ($IsLast) { "└── " } else { "├── " }
            Write-Host ("{0}{1}{2}  ({3})" -f $Prefix, $branch, (Split-Path -Leaf $Folder), (Format-Bytes $sizeBytes))
        } else {
            return
        }
    }

    if ($CurrentDepth -ge $MaxDepth) { return }

    # Get immediate subfolders
    $children = @()
    try {
        $children = Get-ChildItem -LiteralPath $Folder -Directory -Force -ErrorAction SilentlyContinue |
                    Sort-Object Name
    } catch { }

    for ($i = 0; $i -lt $children.Count; $i++) {
        $child = $children[$i]
        $childIsLast = ($i -eq ($children.Count - 1))

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


        Write-FolderTree -Folder $child.FullName `
                         -MaxDepth $MaxDepth `
                         -CurrentDepth ($CurrentDepth + 1) `
                         -Prefix $nextPrefix `
                         -IsLast $childIsLast
    }
}

# --- Run -------------------------------------------------------------------

$resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
Write-FolderTree -Folder $resolved -MaxDepth $Depth
