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