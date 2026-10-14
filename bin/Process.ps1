# Process.ps1
# Process management: stderr pool, job launcher, direct execution, process tree control
# Unified launcher model, session-isolated stderr slots

# ═══════════════════════════════════════════════════════════════════════
# STDERR SLOT POOL
# ═══════════════════════════════════════════════════════════════════════

function Initialize-StderrPool {
    <#
    .SYNOPSIS
    Creates a pool of reusable stderr files, isolated by session PID.
    Returns array of file paths.
    #>
    param([int]$SlotCount)

    $tempDir = Get-TempDir
    $sessionId = $PID
    $pool = [System.Collections.Generic.List[string]]::new($SlotCount)

    for ($i = 0; $i -lt $SlotCount; $i++) {
        $path = Join-Path $tempDir "stderr_${sessionId}_slot_$i.log"
        [System.IO.File]::WriteAllText($path, '', [System.Text.Encoding]::UTF8)
        $pool.Add($path)
    }

    return $pool.ToArray()
}

function Remove-StderrPool {
    <#
    .SYNOPSIS
    Cleans up stderr pool files.
    #>
    param([string[]]$Pool)
    if ($null -eq $Pool) { return }
    foreach ($p in $Pool) {
        $null = Remove-ItemSafe -Path $p
    }
}

# ═══════════════════════════════════════════════════════════════════════
# PROCESS TREE CONTROL
# ═══════════════════════════════════════════════════════════════════════

function Stop-ProcessTree {
    <#
    .SYNOPSIS
    Recursively kills a process and all its children by PID.
    #>
    param([int]$ProcessId)
    try {
        $children = Get-CimInstance Win32_Process -Filter "ParentProcessId = $ProcessId" `
            -ErrorAction SilentlyContinue
        foreach ($child in $children) {
            Stop-ProcessTree -ProcessId $child.ProcessId
        }
        Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
    }
    catch { }
}

function Stop-JobProcesses {
    <#
    .SYNOPSIS
    Kills the main process and its child tree.
    PID-based tracking (safe for parallel execution).
    #>
    param([System.Diagnostics.Process]$MainProcess)

    if ($null -eq $MainProcess) { return }
    try {
        if (-not $MainProcess.HasExited) {
            Stop-ProcessTree -ProcessId $MainProcess.Id
        }
    }
    catch { }
}

# ═══════════════════════════════════════════════════════════════════════
# UNIFIED JOB LAUNCHER
# ═══════════════════════════════════════════════════════════════════════

# ═══════════════════════════════════════════════════════════════════════
# KILL-ON-CLOSE JOB OBJECT (M-2)
# Child processes (cmd, ffmpeg, avifenc) are assigned to a job. When this PowerShell
# process exits for any reason, Windows closes the job handle and kills the children.
# ═══════════════════════════════════════════════════════════════════════

if (-not ('AvifJobNative.Job' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace AvifJobNative {
    [StructLayout(LayoutKind.Sequential)]
    public struct JOBOBJECT_BASIC_LIMIT_INFORMATION {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct IO_COUNTERS {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }
    public static class Job {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern IntPtr CreateJobObject(IntPtr lpJobAttributes, string lpName);
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool SetInformationJobObject(IntPtr hJob, int infoClass, ref JOBOBJECT_EXTENDED_LIMIT_INFORMATION info, uint cbInfo);
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool AssignProcessToJobObject(IntPtr hJob, IntPtr hProcess);
    }
}
'@
}

$script:JobHandle = [IntPtr]::Zero

function Initialize-KillOnCloseJob {
    if ($script:JobHandle -ne [IntPtr]::Zero) { return $true }

    $h = [AvifJobNative.Job]::CreateJobObject([IntPtr]::Zero, $null)
    if ($h -eq [IntPtr]::Zero) { return $false }

    $info = New-Object AvifJobNative.JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    $info.BasicLimitInformation.LimitFlags = 0x2000   # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
    $size = [System.Runtime.InteropServices.Marshal]::SizeOf([type]'AvifJobNative.JOBOBJECT_EXTENDED_LIMIT_INFORMATION')
    if (-not [AvifJobNative.Job]::SetInformationJobObject($h, 9, [ref]$info, [uint32]$size)) {   # 9 = ExtendedLimitInformation
        return $false
    }

    $script:JobHandle = $h
    return $true
}

function Add-ProcessToJob {
    param([System.Diagnostics.Process]$Process)

    if ($script:JobHandle -eq [IntPtr]::Zero -or $null -eq $Process) { return }
    try { [void][AvifJobNative.Job]::AssignProcessToJobObject($script:JobHandle, $Process.Handle) }
    catch { }
}

function Start-ShellJob {
    <#
    .SYNOPSIS
    Starts a command via cmd /d /c with stderr redirected to a slot file.
    Used for both pipe commands and direct tool invocations.
    Returns PSCustomObject with Process and StderrLog.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$CommandLine,

        [Parameter(Mandatory)]
        [string]$StderrSlot
    )

    # Clear slot before use
    [System.IO.File]::WriteAllText($StderrSlot, '', [System.Text.Encoding]::UTF8)

    $cmdArgs = "/d /c `"chcp 65001 >nul & $CommandLine 2>`"$StderrSlot`"`""

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = 'cmd'
    $psi.Arguments              = $cmdArgs
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardError  = $false
    $psi.RedirectStandardOutput = $false
    $psi.CreateNoWindow         = $true

    $proc = [System.Diagnostics.Process]::Start($psi)
    Add-ProcessToJob -Process $proc

    return [PSCustomObject]@{
        Process   = $proc
        StderrLog = $StderrSlot
    }
}

# ═══════════════════════════════════════════════════════════════════════
# DIRECT COMMAND EXECUTION (synchronous, with stderr capture)
# ═══════════════════════════════════════════════════════════════════════

function Invoke-DirectCommand {
    <#
    .SYNOPSIS
    Executes a command directly (no shell pipe).
    Stderr captured via async read. Used for fallback operations.
    .OUTPUTS
    PSCustomObject with: TimedOut, ExitCode, Stderr, CommandLine
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Executable,

        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [int]$TimeoutSec = 120
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $Executable
    $psi.Arguments              = $Arguments -join ' '
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardError  = $true
    $psi.RedirectStandardOutput = $false
    $psi.CreateNoWindow         = $true

    $proc = [System.Diagnostics.Process]::Start($psi)
    Add-ProcessToJob -Process $proc

    # Async stderr to prevent deadlock
    $stderrBuilder = [System.Text.StringBuilder]::new()
    $stderrEvent = Register-ObjectEvent -InputObject $proc -EventName 'ErrorDataReceived' -Action {
        if ($null -ne $EventArgs.Data) {
            [void]$Event.MessageData.AppendLine($EventArgs.Data)
        }
    } -MessageData $stderrBuilder

    $proc.BeginErrorReadLine()

    # Wait with timeout
    $exited = $false
    if ($TimeoutSec -gt 0) {
        $exited = $proc.WaitForExit($TimeoutSec * 1000)
    }
    else {
        $proc.WaitForExit()
        $exited = $true
    }

    $timedOut = -not $exited
    if ($timedOut) {
        Stop-JobProcesses -MainProcess $proc
        # Brief wait for cleanup
        try { [void]$proc.WaitForExit(5000) } catch { }
    }

    # Flush async reads
    if (-not $timedOut) {
        try { $proc.WaitForExit() } catch { }
    }

    # Cleanup event
    Unregister-Event -SourceIdentifier $stderrEvent.Name -ErrorAction SilentlyContinue
    Remove-Job -Id $stderrEvent.Id -Force -ErrorAction SilentlyContinue

    $exitCode = if ($proc.HasExited) { $proc.ExitCode } else { -1 }
    $stderr   = $stderrBuilder.ToString()
    $cmdLine  = "$Executable $($Arguments -join ' ')"

    # Dispose process
    try { $proc.Dispose() } catch { }

    return [PSCustomObject]@{
        TimedOut    = $timedOut
        ExitCode    = $exitCode
        Stderr      = $stderr
        CommandLine = $cmdLine
    }
}

# ═══════════════════════════════════════════════════════════════════════
# STDERR READER UTILITY
# ═══════════════════════════════════════════════════════════════════════

function Read-StderrSlot {
    <#
    .SYNOPSIS
    Reads stderr content from a slot file. Returns empty string on failure.
    #>
    param([string]$SlotPath)

    if (-not $SlotPath -or -not (Test-Path -LiteralPath $SlotPath)) {
        return ''
    }

    try {
        return [System.IO.File]::ReadAllText($SlotPath)
    }
    catch {
        return ''
    }
}