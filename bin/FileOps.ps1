# FileOps.ps1
# File operations: temp directory, safe copy/move/remove, recycle bin, output paths

# ─── Recycle Bin API ───

if (-not ([System.Management.Automation.PSTypeName]'RecycleBin').Type) {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public class RecycleBin
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct SHFILEOPSTRUCT
    {
        public IntPtr hwnd;
        public uint wFunc;
        [MarshalAs(UnmanagedType.LPWStr)] public string pFrom;
        [MarshalAs(UnmanagedType.LPWStr)] public string pTo;
        public ushort fFlags;
        public bool fAnyOperationsAborted;
        public IntPtr hNameMappings;
        [MarshalAs(UnmanagedType.LPWStr)] public string lpszProgressTitle;
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern int SHFileOperation(ref SHFILEOPSTRUCT FileOp);

    private const uint FO_DELETE = 0x0003;
    private const ushort FOF_ALLOWUNDO = 0x0040;
    private const ushort FOF_NOCONFIRMATION = 0x0010;
    private const ushort FOF_SILENT = 0x0004;

    public static int MoveToRecycleBin(string path)
    {
        SHFILEOPSTRUCT fileOp = new SHFILEOPSTRUCT();
        fileOp.wFunc = FO_DELETE;
        fileOp.pFrom = path + '\0' + '\0';
        fileOp.fFlags = FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_SILENT;
        return SHFileOperation(ref fileOp);
    }
}
"@
}

function Remove-ToRecycleBin {
    param([string]$Path)
    $result = [RecycleBin]::MoveToRecycleBin($Path)
    if ($result -ne 0) {
        Write-Warning "Failed to move to recycle bin (error $result): $Path"
    }
}

# ─── Temp Directory ───

$script:CachedTempDir = $null

function Get-TempDir {
    if ($script:CachedTempDir -and (Test-Path -LiteralPath $script:CachedTempDir)) {
        return $script:CachedTempDir
    }

    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) 'avif_compress'
    if (-not (Test-Path -LiteralPath $tempDir)) {
        New-Item -Path $tempDir -ItemType Directory -Force | Out-Null
    }

    $script:CachedTempDir = $tempDir
    return $tempDir
}

# ─── Safe File Operations ───

function Remove-ItemSafe {
    <#
    .SYNOPSIS
        Removes a file with retry on lock.
    #>
    param([string]$Path)
    for ($i = 0; $i -lt 5; $i++) {
        try {
            if (Test-Path -LiteralPath $Path) {
                Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
            }
            return $true
        }
        catch {
            Start-Sleep -Milliseconds 500
        }
    }
    return $false
}

function Remove-TempFiles {
    <#
    .SYNOPSIS
        Sweeps a folder (recursively) and removes all .ACtmp files.
        Called after encoding completes to clean up any leftovers.
    #>
    param([string]$FolderPath)

    if (-not $FolderPath -or -not (Test-Path -LiteralPath $FolderPath -PathType Container)) {
        return
    }

    Get-ChildItem -LiteralPath $FolderPath -Filter '*.ACtmp' -File -Recurse -ErrorAction SilentlyContinue |
        ForEach-Object {
			$null = Remove-ItemSafe -Path $_.FullName
		}
}

function New-TempCopy {
    <#
    .SYNOPSIS
        Copies a file to temp directory with a GUID name.
        Returns temp path or $null on failure.
    #>
    param([string]$Path)

    try {
        $tempDir = Get-TempDir
        $safeName = [Guid]::NewGuid().ToString() + [System.IO.Path]::GetExtension($Path)
        $tempPath = Join-Path $tempDir $safeName
        [System.IO.File]::Copy($Path, $tempPath, $true)
        return $tempPath
    }
    catch {
        return $null
    }
}

function Rename-TempToFinal {
    <#
    .SYNOPSIS
        Renames .ACtmp file to its final name.
        Atomic operation on same volume (no copy needed).
    #>
    param(
        [string]$TempPath,
        [string]$FinalPath
    )
    try {
        if ([System.IO.File]::Exists($TempPath)) {
            if ([System.IO.File]::Exists($FinalPath)) {
                [System.IO.File]::Delete($FinalPath)
            }
            [System.IO.File]::Move($TempPath, $FinalPath)
            return $true
        }
        return $false
    }
    catch {
        return $false
    }
}

# ─── Output Path ───

function Get-UniqueOutputPath {
    <#
    .SYNOPSIS
        Generates a unique output path, avoiding collisions.
        Falls back to GUID suffix after 100 attempts.
    #>
    param(
        [string]$SourceFile,
        [string]$TargetExt
    )

    $dir  = [System.IO.Path]::GetDirectoryName($SourceFile)
    $name = [System.IO.Path]::GetFileNameWithoutExtension($SourceFile)

    $outFile = [System.IO.Path]::Combine($dir, "$name.$TargetExt")
    if (-not [System.IO.File]::Exists($outFile)) { return $outFile }

    $counter = 1
    while ($true) {
        $outFile = [System.IO.Path]::Combine($dir, "${name}_${counter}.$TargetExt")
        if (-not [System.IO.File]::Exists($outFile)) { return $outFile }
        $counter++
        if ($counter -gt 100) {
            $guid = [Guid]::NewGuid().ToString('N').Substring(0, 8)
            return [System.IO.Path]::Combine($dir, "${name}_${guid}.$TargetExt")
        }
    }
}

# ─── Output Validation ───

function Test-EncodedOutput {
    <#
    .SYNOPSIS
        Checks that an encoded output file exists and exceeds minimum size.
    #>
    param(
        [string]$Path,
        [int]$MinBytes = 100
    )

    if (-not (Test-Path -LiteralPath $Path)) { return $false }

    try {
        $len = (Get-Item -LiteralPath $Path).Length
        return ($len -gt $MinBytes)
    }
    catch {
        return $false
    }
}

# ─── Corrupt File Handling ───

function Move-ToCorruptFolder {
    <#
    .SYNOPSIS
        Moves a file to _corrupt subfolder in its directory.
        Handles name collisions with counter suffix.
        Returns destination path or $null on failure.
    #>
    param([System.IO.FileInfo]$File)

    $corruptDir = Join-Path $File.DirectoryName '_corrupt'
    if (-not (Test-Path -LiteralPath $corruptDir)) {
        New-Item -Path $corruptDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
    }

    $dest = Join-Path $corruptDir $File.Name
    $counter = 1
    while ([System.IO.File]::Exists($dest)) {
        $nameNoExt = [System.IO.Path]::GetFileNameWithoutExtension($File.Name)
        $extPart = $File.Extension
        $dest = Join-Path $corruptDir "${nameNoExt}_${counter}${extPart}"
        $counter++
    }

    try {
        [System.IO.File]::Move($File.FullName, $dest)
        return $dest
    }
    catch {
        try {
            [System.IO.File]::Copy($File.FullName, $dest, $true)
            [System.IO.File]::Delete($File.FullName)
            return $dest
        }
        catch {
            return $null
        }
    }
}