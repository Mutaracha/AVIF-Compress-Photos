# ImageEncoding.ps1
# Encoding operations: command builders, job start/finalize, cleanup
# Supports three task types: AvifDirect, AvifPipe, Gif2Webp

# ═══════════════════════════════════════════════════════════════════════
# PIPE RESULT CHECK
# ═══════════════════════════════════════════════════════════════════════

function Test-PipeFailed {
    <#
    .SYNOPSIS
    Checks if a pipe encoding result indicates failure.
    #>
    param(
        [int]$ExitCode,
        [string]$Stderr,
        [string]$OutputPath
    )

    if ($ExitCode -ne 0) { return $true }
    if (-not (Test-EncodedOutput -Path $OutputPath -MinBytes 100)) { return $true }
    if ($Stderr -match 'Y4M frame header too large|Error reading|Couldn''t read|Failed to read|Invalid Y4M|No such file') {
        return $true
    }
    return $false
}

# ═══════════════════════════════════════════════════════════════════════
# COMMAND BUILDERS
# ═══════════════════════════════════════════════════════════════════════

function Build-AvifDirectCommand {
    <#
    .SYNOPSIS
    Builds avifenc command for direct encoding (no ffmpeg).
    #>
    param(
        [PSCustomObject]$Task,
        [string]$InputPath,
        [string]$OutputPath
    )

    $enc = $Task.EncoderArgs.Replace('{input}', $InputPath).Replace('{output}', $OutputPath)
    return "avifenc $enc"
}

function Build-AvifPipeCommand {
    <#
    .SYNOPSIS
    Builds ffmpeg | avifenc pipe command.
    #>
    param(
        [PSCustomObject]$Task,
        [string]$InputPath,
        [string]$OutputPath
    )

    $ff  = $Task.FfmpegArgs.Replace('{input}', $InputPath).Replace('{output}', $OutputPath)
    $enc = $Task.EncoderArgs.Replace('{input}', $InputPath).Replace('{output}', $OutputPath)
    return "ffmpeg $ff | avifenc $enc"
}

function Build-Gif2WebpCommand {
    <#
    .SYNOPSIS
    Builds gif2webp command for animated GIF.
    #>
    param(
        [PSCustomObject]$Task,
        [string]$InputPath,
        [string]$OutputPath
    )

    $enc = $Task.EncoderArgs.Replace('{input}', $InputPath).Replace('{output}', $OutputPath)
    return "gif2webp $enc"
}

function Build-FallbackArgs {
    <#
    .SYNOPSIS
    Builds ffmpeg + avifenc arguments for temp-file fallback.
    Used when pipe or direct encoding fails.
    #>
    param(
        [PSCustomObject]$Task,
        [string]$InputPath,
        [string]$TempIntermediate,
        [string]$OutputPath
    )

    # Step 1: ffmpeg → intermediate file
    if ($Task.TaskType -eq 'AvifDirect') {
        # Direct task failed → fallback via ffmpeg decode to intermediate
        $pixFmt = 'yuv444p'
        $ffArgs = @(
            '-hide_banner', '-y', '-v', 'error',
            '-i', "`"$InputPath`"",
            '-map', '0:v:0', '-frames:v', '1',
            '-pix_fmt', $pixFmt,
            "`"$TempIntermediate`""
        )
    }
    elseif ($Task.PSObject.Properties['PixelFormat'] -and $Task.PixelFormat) {
        # AvifPipe opaque → Y4M intermediate
        $ffArgs = @(
            '-hide_banner', '-y', '-v', 'error',
            '-i', "`"$InputPath`"",
            '-map', '0:v:0', '-frames:v', '1',
            '-pix_fmt', $Task.PixelFormat,
            "`"$TempIntermediate`""
        )
    }
    else {
        # AvifPipe alpha → PNG intermediate
        $ffArgs = @(
            '-hide_banner', '-y', '-v', 'error',
            '-i', "`"$InputPath`"",
            '-map', '0:v:0', '-frames:v', '1',
            "`"$TempIntermediate`""
        )
    }

    # Step 2: avifenc args (remove --stdin, add file paths)
    $encArgs = $Task.EncoderArgs
    $encArgs = $encArgs -replace '--stdin\s*"?\{output\}"?', ''
    $encArgs = $encArgs -replace '"\{input\}"\s*"\{output\}"', ''
    $encArgs = $encArgs.Replace('{output}', '').Replace('{input}', '').Trim()

    $avifArgs = @("`"$TempIntermediate`"") + ($encArgs -split '\s+' | Where-Object { $_ }) + @("`"$OutputPath`"")

    return [PSCustomObject]@{
        FfmpegArgs  = $ffArgs
        AvifencArgs = $avifArgs
    }
}

# ═══════════════════════════════════════════════════════════════════════
# ENCODING JOB MANAGEMENT
# ═══════════════════════════════════════════════════════════════════════

function Start-EncodingJob {
    <#
    .SYNOPSIS
    Starts an encoding job based on task type.
    Output goes to .ACtmp extension, renamed on success.
    #>
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Task,

        [Parameter(Mandatory)]
        [string]$OutputPath,

        [Parameter(Mandatory)]
        [string]$StderrSlot
    )

    $tempOutput = $OutputPath + '.ACtmp'

    $cmdLine = switch ($Task.TaskType) {
        'AvifDirect' { Build-AvifDirectCommand -Task $Task -InputPath $Task.SourcePath -OutputPath $tempOutput }
        'AvifPipe'   { Build-AvifPipeCommand   -Task $Task -InputPath $Task.SourcePath -OutputPath $tempOutput }
        'Gif2Webp'   { Build-Gif2WebpCommand   -Task $Task -InputPath $Task.SourcePath -OutputPath $tempOutput }
    }

    $jobProc = Start-ShellJob -CommandLine $cmdLine -StderrSlot $StderrSlot

    return [PSCustomObject]@{
        Task        = $Task
        SourcePath  = $Task.SourcePath
        OutputPath  = $OutputPath
        TempOutput  = $tempOutput
        StderrLog   = $jobProc.StderrLog
        Process     = $jobProc.Process
        StartedAt   = Get-Date
        CommandLine = $cmdLine
    }
}

function Finalize-EncodingJob {
    <#
    .SYNOPSIS
    Collects results from a completed encoding job.
    Handles primary result check and fallback for AVIF tasks.
    Gif2Webp has no fallback — fails directly.
    #>
    param(
        [Parameter(Mandatory)]
        [PSCustomObject]$Job,

        [int]$TimeoutSec = 120
    )

    $result = [PSCustomObject]@{
        Success       = $false
        UsedFallback  = $false
        TimedOut      = $false
        ExitCode      = -1
        Stderr        = ''
        FailedStage   = ''
        ExecutionMode = $Job.Task.TaskType
        PipeCommand   = $Job.CommandLine
        FallbackStep1 = ''
        FallbackStep2 = ''
        OutputPath    = $Job.OutputPath
    }

    # ── Timeout check ──
    if (-not $Job.Process.HasExited) {
        $result.TimedOut    = $true
        $result.FailedStage = 'Primary'
        Stop-JobProcesses -MainProcess $Job.Process
        return $result
    }

    # ── Read stderr ──
    $result.Stderr   = Read-StderrSlot -SlotPath $Job.StderrLog
    $result.ExitCode = $Job.Process.ExitCode

    # ── Gif2Webp: simple check, no fallback ──
    if ($Job.Task.TaskType -eq 'Gif2Webp') {
        if ($result.ExitCode -eq 0 -and (Test-EncodedOutput -Path $Job.TempOutput -MinBytes 100)) {
            $null = Rename-TempToFinal -TempPath $Job.TempOutput -FinalPath $Job.OutputPath
            $result.Success = (Test-EncodedOutput -Path $Job.OutputPath -MinBytes 100)
        }
        else {
            $result.FailedStage = 'Gif2Webp'
        }
        return $result
    }

    # ── AvifDirect: check result ──
    if ($Job.Task.TaskType -eq 'AvifDirect') {
        $directFailed = ($result.ExitCode -ne 0) -or
                        (-not (Test-EncodedOutput -Path $Job.TempOutput -MinBytes 100))

        if (-not $directFailed) {
            $null = Rename-TempToFinal -TempPath $Job.TempOutput -FinalPath $Job.OutputPath
            $result.Success = (Test-EncodedOutput -Path $Job.OutputPath -MinBytes 100)
            return $result
        }

        # Fallback: ffmpeg decode → temp file → avifenc
        $null = Remove-ItemSafe -Path $Job.TempOutput
        return Invoke-AvifFallback -Job $Job -Result $result -TimeoutSec $TimeoutSec
    }

    # ── AvifPipe: check pipe result ──
    $pipeFailed = Test-PipeFailed -ExitCode $result.ExitCode `
        -Stderr $result.Stderr -OutputPath $Job.TempOutput

    if (-not $pipeFailed) {
        $null = Rename-TempToFinal -TempPath $Job.TempOutput -FinalPath $Job.OutputPath
        $result.Success = (Test-EncodedOutput -Path $Job.OutputPath -MinBytes 100)
        return $result
    }

    # Fallback
    $null = Remove-ItemSafe -Path $Job.TempOutput
    return Invoke-AvifFallback -Job $Job -Result $result -TimeoutSec $TimeoutSec
}

# ═══════════════════════════════════════════════════════════════════════
# AVIF FALLBACK (shared by AvifDirect and AvifPipe)
# ═══════════════════════════════════════════════════════════════════════

function Invoke-AvifFallback {
    <#
    .SYNOPSIS
    Fallback encoding: ffmpeg → temp intermediate file → avifenc → output.
    Used when primary encoding (direct or pipe) fails.
    #>
    param(
        [PSCustomObject]$Job,
        [PSCustomObject]$Result,
        [int]$TimeoutSec
    )

    $Result.UsedFallback  = $true
    $Result.ExecutionMode = 'TempFileFallback'

    $tempDir = Get-TempDir

    # Determine intermediate format
    $hasAlpha = $false
    if ($Job.Task.PSObject.Properties['HasAlpha']) {
        $hasAlpha = $Job.Task.HasAlpha
    }

    $intermediateExt = if ($hasAlpha) { '.png' } else { '.y4m' }
    $tempIntermediate = Join-Path $tempDir ([Guid]::NewGuid().ToString() + $intermediateExt)

    $fb = Build-FallbackArgs -Task $Job.Task `
        -InputPath $Job.SourcePath `
        -TempIntermediate $tempIntermediate `
        -OutputPath $Job.TempOutput

    $Result.FallbackStep1 = "ffmpeg $($fb.FfmpegArgs -join ' ')"
    $Result.FallbackStep2 = "avifenc $($fb.AvifencArgs -join ' ')"

    # Both steps share one time budget (M-3): the limit applies to the whole fallback
    $fallbackDeadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)

    # Step 1: FFmpeg → temp intermediate
    $step1 = Invoke-DirectCommand -Executable 'ffmpeg' -Arguments $fb.FfmpegArgs -TimeoutSec $TimeoutSec

    if ($step1.TimedOut -or $step1.ExitCode -ne 0 -or
        -not (Test-Path -LiteralPath $tempIntermediate)) {
        $Result.Stderr += "`r`n--- fallback step1 ---`r`n" + $step1.Stderr
        $Result.FailedStage = 'FallbackFFmpeg'
        $Result.ExitCode    = $step1.ExitCode
        $null = Remove-ItemSafe -Path $tempIntermediate
        return $Result
    }

    # Step 2: avifenc → output
    $step2Timeout = $TimeoutSec
    if ($TimeoutSec -gt 0) {
        $remaining = [int][Math]::Ceiling(($fallbackDeadline - [DateTime]::UtcNow).TotalSeconds)
        $step2Timeout = [Math]::Max(1, $remaining)
    }
    $step2 = Invoke-DirectCommand -Executable 'avifenc' -Arguments $fb.AvifencArgs -TimeoutSec $step2Timeout

    $null = Remove-ItemSafe -Path $tempIntermediate

    if ($step2.TimedOut -or $step2.ExitCode -ne 0 -or
        -not (Test-EncodedOutput -Path $Job.TempOutput -MinBytes 100)) {
        $Result.Stderr += "`r`n--- fallback step2 ---`r`n" + $step2.Stderr
        $Result.FailedStage = 'FallbackAvifenc'
        $Result.ExitCode    = $step2.ExitCode
        $null = Remove-ItemSafe -Path $Job.TempOutput
        return $Result
    }

    $null = Rename-TempToFinal -TempPath $Job.TempOutput -FinalPath $Job.OutputPath
    $Result.Success  = (Test-EncodedOutput -Path $Job.OutputPath -MinBytes 100)
    $Result.ExitCode = 0
    return $Result
}

# ═══════════════════════════════════════════════════════════════════════
# JOB CLEANUP
# ═══════════════════════════════════════════════════════════════════════

function Remove-JobArtifacts {
    <#
    .SYNOPSIS
    Cleans up .ACtmp file on failure.
    Stderr slot belongs to pool — not deleted here.
    #>
    param([PSCustomObject]$Job)

    if ($Job.TempOutput -and (Test-Path -LiteralPath $Job.TempOutput)) {
        $null = Remove-ItemSafe -Path $Job.TempOutput
    }
}