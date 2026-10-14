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

# ─── Output Path (H-2) ───

function Find-FreeOutputPath {
    <#
    .SYNOPSIS
        First free output name in order: base.ext, base_1.ext, base_2.ext, ...
        A name is free when it is not on disk, not reserved by the current plan,
        and is not the source file itself.
    #>
    param(
        [string]$Dir,
        [string]$BaseName,
        [string]$TargetExt,
        [System.Collections.Generic.HashSet[string]]$Reserved,
        [string]$SourcePath
    )

    $srcFull = [System.IO.Path]::GetFullPath($SourcePath)
    for ($i = 0; $i -lt 10000; $i++) {
        if ($i -eq 0) { $name = $BaseName + '.' + $TargetExt }
        else          { $name = $BaseName + '_' + $i + '.' + $TargetExt }
        $path = [System.IO.Path]::Combine($Dir, $name)
        if ($path -ieq $srcFull) { continue }
        if ($Reserved.Contains($path)) { continue }
        if ([System.IO.File]::Exists($path)) { continue }
        [void]$Reserved.Add($path)
        return $path
    }
    throw "No free output name for '$BaseName' in '$Dir'."
}

# ─── Done manifest (no-delete mode only, H-2) ───
# File .avifcompress_done.txt in the source folder. One line per converted source:
# name <TAB> size <TAB> LastWriteTimeUtc ticks <TAB> output name <TAB> date <TAB> SessionId

$script:DoneManifestName = '.avifcompress_done.txt'
$script:doneCache = @{}

function Get-DoneManifestEntries {
    param([string]$Dir)

    $key = $Dir.ToLowerInvariant()
    if ($script:doneCache.ContainsKey($key)) { return $script:doneCache[$key] }

    $list = [System.Collections.Generic.List[PSObject]]::new()
    $path = [System.IO.Path]::Combine($Dir, $script:DoneManifestName)
    if ([System.IO.File]::Exists($path)) {
        foreach ($line in [System.IO.File]::ReadAllLines($path, [System.Text.Encoding]::UTF8)) {
            if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) { continue }
            $parts = $line -split "`t"
            if ($parts.Count -lt 4) { continue }
            $size = [int64]0; $ticks = [int64]0
            if (-not ([int64]::TryParse($parts[1], [ref]$size) -and [int64]::TryParse($parts[2], [ref]$ticks))) { continue }
            $list.Add([PSCustomObject]@{ Name = $parts[0]; Size = $size; Ticks = $ticks; Output = $parts[3] })
        }
    }
    $script:doneCache[$key] = $list
    return $list
}

function Test-AlreadyDone {
    <#
    .SYNOPSIS
        True if the manifest has this source (same name, size, time) and its output is still on disk.
        A source with no entry, or with a changed size/time, is treated as not done.
    #>
    param([System.IO.FileInfo]$File)

    $dir = $File.DirectoryName
    foreach ($e in (Get-DoneManifestEntries -Dir $dir)) {
        if ($e.Name -ieq $File.Name -and $e.Size -eq $File.Length -and $e.Ticks -eq $File.LastWriteTimeUtc.Ticks) {
            if ([System.IO.File]::Exists([System.IO.Path]::Combine($dir, $e.Output))) { return $true }
        }
    }
    return $false
}

function Add-DoneRecord {
    param(
        [string]$SourcePath,
        [int64]$SizeBytes,
        [datetime]$LastWriteTimeUtc,
        [string]$OutputPath,
        [string]$SessionId
    )

    $dir  = [System.IO.Path]::GetDirectoryName($SourcePath)
    $path = [System.IO.Path]::Combine($dir, $script:DoneManifestName)
    $sb = [System.Text.StringBuilder]::new()
    if (-not [System.IO.File]::Exists($path)) {
        [void]$sb.Append("# AVIF Compressor: sources converted in this folder. Do not edit.`r`n")
    }
    $line = @(
        [System.IO.Path]::GetFileName($SourcePath),
        $SizeBytes,
        $LastWriteTimeUtc.Ticks,
        [System.IO.Path]::GetFileName($OutputPath),
        (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),
        $SessionId
    ) -join "`t"
    [void]$sb.Append($line + "`r`n")
    [System.IO.File]::AppendAllText($path, $sb.ToString(), [System.Text.UTF8Encoding]::new($false))
    $script:doneCache.Remove($dir.ToLowerInvariant())
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