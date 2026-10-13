# Logging.ps1
# Unified logging module for AVIF Compressor
# Encoding logs, warning/corrupt logs, debug plan logs, crash logs

# ─── Log Directory ───

$script:CachedLogDir = $null

function Get-LogDir {
    if ($script:CachedLogDir -and (Test-Path -LiteralPath $script:CachedLogDir)) {
        return $script:CachedLogDir
    }

    $projectRoot = Split-Path -Parent $PSScriptRoot
    $logDir = Join-Path $projectRoot 'logs'

    if (-not (Test-Path -LiteralPath $logDir)) {
        New-Item -Path $logDir -ItemType Directory -Force | Out-Null
    }

    $script:CachedLogDir = $logDir
    return $logDir
}

# ─── Log Path Generator ───

function New-EncodingLogPath {
    param([string]$Mode)

    $logDir = Get-LogDir
    $stamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'

    if ($Mode -eq 'SingleFile') {
        return Join-Path $logDir "encoding_single_$stamp.log"
    }
    else {
        return Join-Path $logDir "encoding_$stamp.log"
    }
}

# ─── Encoding Log Header ───

$script:LogSeparator = '================================================================'

function Write-EncodingLogHeader {
    param(
        [string]$LogFile,
        [string]$Source,
        [string]$Mode
    )

    $lines = @(
        $script:LogSeparator
        'ENCODING LOG'
        $script:LogSeparator
        "Time:     $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        "Source:   $Source"
        "Mode:     $Mode"
        $script:LogSeparator
        ''
    )

    try {
        Set-Content -LiteralPath $LogFile -Value ($lines -join "`r`n") -Encoding UTF8
    }
    catch { }
}

# ─── Encoding Log Entries ───
<#
.SYNOPSIS
	Writes SUCCESS entry (only when fallback was used).
#>

function Write-SuccessEntry {
    param(
        [string]$LogFile,
        [PSCustomObject]$Task,
        [string]$PipeCommand,
        [string]$FallbackStep1 = '',
        [string]$FallbackStep2 = '',
        [string]$PlanMessage,
        [bool]$IsSingleFile = $false
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('[SUCCESS]')
    if (-not $IsSingleFile) {
        $lines.Add("    Path:      $($Task.SourcePath)")
    }
    $lines.Add("    Plan:      $PlanMessage")
    $lines.Add("    Command:   $PipeCommand")
    if ($FallbackStep1) { $lines.Add("    Fallback1: $FallbackStep1") }
    if ($FallbackStep2) { $lines.Add("    Fallback2: $FallbackStep2") }
    $lines.Add($script:LogSeparator)

    try { Add-Content -LiteralPath $LogFile -Value ($lines -join "`r`n") -Encoding UTF8 }
    catch { }
}

function Write-EncodingLogFooter {
    <#
    .SYNOPSIS
        Appends duration footer to encoding log (SingleFile mode).
    #>
    param(
        [string]$LogFile,
        [double]$DurationSec
    )

    if ($DurationSec -le 0) { return }

    try {
        Add-Content -LiteralPath $LogFile -Value "Duration: $(Format-Duration -Seconds $DurationSec)" -Encoding UTF8
    }
    catch { }
}

function Write-SkipEntry {
    param(
        [string]$LogFile,
        [PSCustomObject]$Task,
        [string]$PipeCommand,
        [string]$Reason,
        [string]$PlanMessage,
        [bool]$IsSingleFile = $false
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('[SKIP]')
    if (-not $IsSingleFile) {
        $lines.Add("    Path:      $($Task.SourcePath)")
    }
    $lines.Add("    Plan:     $PlanMessage")
    $lines.Add("    Command:  $PipeCommand")
    $lines.Add("    Reason:   $Reason")
    $lines.Add($script:LogSeparator)

    try {
        Add-Content -LiteralPath $LogFile -Value ($lines -join "`r`n") -Encoding UTF8
    }
    catch { }
}

function Write-FailedEntry {
    param(
        [string]$LogFile,
        [PSCustomObject]$Task,
        [string]$PipeCommand,
        [string]$ExecMode,
        [string]$FallbackStep1,
        [string]$FallbackStep2,
        [string]$Reason,
        [int]$ExitCode,
        [string]$PlanMessage,
        [string]$Stderr,
        [bool]$IsSingleFile = $false
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('[FAILED]')
    if (-not $IsSingleFile) {
        $lines.Add("    Path:      $($Task.SourcePath)")
    }
    $lines.Add("    Plan:      $PlanMessage")
    $lines.Add("    Kind:      $($Task.FileKind)")
    $lines.Add("    Target:    .$($Task.TargetExtension)")
    $lines.Add("    Command:   $PipeCommand")
    $lines.Add("    ExecMode:  $ExecMode")

    if ($FallbackStep1) {
        $lines.Add("    Fallback1: $FallbackStep1")
    }
    if ($FallbackStep2) {
        $lines.Add("    Fallback2: $FallbackStep2")
    }

    $lines.Add("    Reason:    $Reason")
    $lines.Add("    ExitCode:  $ExitCode")

    if ($Stderr) {
        $lines.Add('--------------------------------------------------------------------------------')
        $lines.Add($Stderr)
    }

    $lines.Add($script:LogSeparator)

    try {
        Add-Content -LiteralPath $LogFile -Value ($lines -join "`r`n") -Encoding UTF8
    }
    catch { }
}

function Write-WarningTaskEntry {
    <#
    .SYNOPSIS
        Writes WARNING entry for runtime issues (file missing, modified, etc.)
    #>
    param(
        [string]$LogFile,
        [PSCustomObject]$Task,
        [string]$Reason,
        [bool]$IsSingleFile = $false
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('[WARNING]')
    if (-not $IsSingleFile) {
        $lines.Add("    Path:      $($Task.SourcePath)")
    }
    $lines.Add("    Reason:   $Reason")
    $lines.Add($script:LogSeparator)

    try {
        Add-Content -LiteralPath $LogFile -Value ($lines -join "`r`n") -Encoding UTF8
    }
    catch { }
}

# ─── Warning Log (analysis stage, accumulative) ───

function Write-WarningLine {
    <#
    .SYNOPSIS
        Appends one-line warning entry: path | reason | time
    #>
    param(
        [string]$LogFile,
        [string]$FilePath,
        [string]$Reason
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

    try {
        Add-Content -LiteralPath $LogFile -Value "$FilePath | $Reason | $timestamp" -Encoding UTF8
    }
    catch { }
}

# ─── Corrupt Log (analysis stage, accumulative) ───

function Write-CorruptLine {
    <#
    .SYNOPSIS
        Appends one-line corrupt entry: destination path | reason | time
    #>
    param(
        [string]$LogFile,
        [string]$DestPath,
        [string]$Reason
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

    try {
        Add-Content -LiteralPath $LogFile -Value "$DestPath | $Reason | $timestamp" -Encoding UTF8
    }
    catch { }
}

# ─── Debug Plan Log ───

function Write-DebugPlanLog {
    param(
        [PSCustomObject]$Plan,
        [PSCustomObject]$Summary
    )

    $logDir  = Get-LogDir
    $stamp   = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
    $logFile = Join-Path $logDir "plan_$stamp.log"

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add($script:LogSeparator)
    $lines.Add("ENCODING PLAN v$($Plan.PlanVersion)")
    $lines.Add($script:LogSeparator)
    $lines.Add("Created:     $($Plan.CreatedAt)")
    $lines.Add("Mode:        $($Plan.Mode)")
    $lines.Add("Source:      $($Plan.SourceRoot)")
    $lines.Add('')
    $lines.Add('--- SUMMARY ---')
    $lines.Add("TotalFiles:       $($Summary.TotalFiles)")
    $lines.Add("SupportedFiles:   $($Summary.SupportedFiles)")
    $lines.Add("TasksCount:       $($Summary.TasksCount)")
    $lines.Add("SkippedCount:     $($Summary.SkippedCount)")
    $lines.Add("StaticCount:      $($Summary.StaticCount)")
    $lines.Add("AnimatedGifCount: $($Summary.AnimatedGifCount)")
    $lines.Add("AlphaCount:       $($Summary.AlphaCount)")
    $lines.Add('')

    # Task type breakdown
    $byType = $Plan.Tasks | Group-Object TaskType
    $lines.Add('--- TASK TYPES ---')
    foreach ($g in $byType) {
        $lines.Add("$($g.Name): $($g.Count) tasks")
    }
    $lines.Add('')

    $lines.Add('--- TASKS ---')
    $taskNum = 0
    foreach ($t in $Plan.Tasks) {
        $taskNum++
        $lines.Add('')
        $lines.Add("[$taskNum] $($t.FileName)")
        $lines.Add("    Path:       $($t.SourcePath)")
        $lines.Add("    Plan:       $($t.PlanMessage)")
        $lines.Add("    TaskType:   $($t.TaskType)")
        $lines.Add("    Target:     .$($t.TargetExtension)")
        $lines.Add("    Phase:      $($t.Phase)")
        $lines.Add("    Size:       $($t.SizeBytes) bytes")
        $lines.Add("    Dimensions: $($t.Width)x$($t.Height)")

        if ($t.PSObject.Properties['HasAlpha']) {
            $lines.Add("    HasAlpha:   $($t.HasAlpha)")
        }
        if ($t.PSObject.Properties['PixelFormat'] -and $t.PixelFormat) {
            $lines.Add("    PixFmt:     $($t.PixelFormat)")
        }
        if ($t.PSObject.Properties['FfmpegArgs'] -and $t.FfmpegArgs) {
            $lines.Add("    FfmpegArgs: $($t.FfmpegArgs)")
        }
        $lines.Add("    EncArgs:    $($t.EncoderArgs)")
    }

    $lines.Add('')
    $lines.Add($script:LogSeparator)

    try {
        $lines | Set-Content -LiteralPath $logFile -Encoding UTF8
    }
    catch { }
}

# ═══════════════════════════════════════════════════════════════════════════════
# FATAL ERROR HANDLER
# ═══════════════════════════════════════════════════════════════════════════════

function Show-FatalError {
    param(
        [System.Management.Automation.ErrorRecord]$ErrorRecord,
        [bool]$DebugMode = $false
    )

    [Console]::CursorVisible = $true
    Write-Host

    Write-BoxHeader -Title 'FATAL ERROR' -Color Red
    Write-BoxEmpty -Color Red
    Write-BoxLine -Text "  $($ErrorRecord.Exception.Message)" -Color Red
    Write-BoxEmpty -Color Red
    Write-BoxLine -Text "  Line: $($ErrorRecord.InvocationInfo.ScriptLineNumber)" -Color Red
    Write-BoxLine -Text "  File: $($ErrorRecord.InvocationInfo.ScriptName)" -Color Red

    if ($DebugMode) {
        Write-BoxEmpty -Color Red
        Write-BoxLine -Text '  --- Stack Trace ---' -Color Red

        $stackLines = $ErrorRecord.ScriptStackTrace -split "`n"
        foreach ($line in $stackLines) {
            $trimmed = $line.Trim()
            if ($trimmed) {
                if ($trimmed.Length -gt 64) { $trimmed = $trimmed.Substring(0, 61) + '...' }
                Write-BoxLine -Text "  $trimmed" -Color Red
            }
        }
    }

    Write-BoxEmpty -Color Red
    Write-BoxFooter -Color Red

    if ($DebugMode) {
        try {
            $logDir = Get-LogDir
            $crashLog = Join-Path $logDir "crash_$(Get-Date -Format 'yyyy-MM-dd_HH-mm-ss').log"
            @(
                $script:LogSeparator
                'FATAL ERROR'
                $script:LogSeparator
                "Time:    $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
                "Error:   $($ErrorRecord.Exception.Message)"
                "Line:    $($ErrorRecord.InvocationInfo.ScriptLineNumber)"
                "File:    $($ErrorRecord.InvocationInfo.ScriptName)"
                "Command: $($ErrorRecord.InvocationInfo.Line.Trim())"
                ''
                '--- Stack Trace ---'
                $ErrorRecord.ScriptStackTrace
                ''
                '--- Exception ---'
                $ErrorRecord.Exception.ToString()
                $script:LogSeparator
            ) | Set-Content -LiteralPath $crashLog -Encoding UTF8

            Write-Host
            Write-Host "    Crash log: $crashLog" -ForegroundColor DarkGray
        }
        catch { }
    }

    Write-Host
}

# ─── Clean Empty Log ───

function Remove-EmptyLog {
    param(
        [string]$LogFile,
        [switch]$HasErrors,
        [switch]$HasWarnings,
        [switch]$AlwaysKeep
    )

    if ($AlwaysKeep) { return }
    if ($HasErrors) { return }
    if ($HasWarnings) { return }

    if (Test-Path -LiteralPath $LogFile) {
        Remove-Item -LiteralPath $LogFile -Force -ErrorAction SilentlyContinue
    }
}