# CompressPhotos.ps1
# Stage 3: Execute encoding plan with parallel processing
# Reads compress_plan.clixml, encodes files, shows progress, writes logs

param(
    [string]$SessionId = ''
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# ═══════════════════════════════════════════════════════════════════════
# LOAD MODULES
# ═══════════════════════════════════════════════════════════════════════

. "$PSScriptRoot\Config.ps1"
. "$PSScriptRoot\UI.ps1"
. "$PSScriptRoot\Logging.ps1"
. "$PSScriptRoot\FileOps.ps1"
. "$PSScriptRoot\Process.ps1"
. "$PSScriptRoot\ImageEncoding.ps1"

# ═══════════════════════════════════════════════════════════════════════
# ERROR HANDLER
# ═══════════════════════════════════════════════════════════════════════

trap {
    $debugMode = $false
    try {
        $s = Import-PowerShellDataFile (Get-SettingsPath)
        $debugMode = [bool][int]$s.General.DebugMode
    } catch { }
    Show-FatalError -ErrorRecord $_ -DebugMode $debugMode

    # Cleanup on crash
    if ($script:stderrPool) {
        Remove-StderrPool -Pool $script:stderrPool
    }
    [Console]::CursorVisible = $true
    exit 99
}

$ErrorActionPreference = 'Stop'

# ═══════════════════════════════════════════════════════════════════════
# LOAD PLAN
# ═══════════════════════════════════════════════════════════════════════

$planTempFile = Join-Path ([System.IO.Path]::GetTempPath()) 'compress_plan.clixml'

if (-not (Test-Path -LiteralPath $planTempFile)) {
    Write-Host '     [!] Encoding plan not found.' -ForegroundColor Red
    exit 1
}

$plan = Import-Clixml -LiteralPath $planTempFile

# Reject a plan created in another session
if ([string]::IsNullOrEmpty($SessionId) -or [string]$plan.SessionId -ne $SessionId) {
    Remove-Item -LiteralPath $planTempFile -Force -ErrorAction SilentlyContinue
    Write-Host '     [!] Encoding plan belongs to another session. Nothing was processed.' -ForegroundColor Red
    exit 1
}

# Validate before deleting
if ($null -eq $plan.Tasks -or $plan.Tasks.Count -eq 0) {
    Remove-Item -LiteralPath $planTempFile -Force -ErrorAction SilentlyContinue
    Write-Host '     [!] No tasks in plan.' -ForegroundColor Yellow
    exit 1
}

Remove-Item -LiteralPath $planTempFile -Force -ErrorAction SilentlyContinue

# ═══════════════════════════════════════════════════════════════════════
# RUNTIME SETUP
# ═══════════════════════════════════════════════════════════════════════

$settings = Get-ProjectSettings
$parallel = Get-ParallelismSettings -Settings $settings
$maxParallel = $parallel.EncodingParallel

$script:stderrPool = Initialize-StderrPool -SlotCount $maxParallel
$stderrAvailable = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
$script:stderrPool | ForEach-Object { $stderrAvailable.Enqueue($_) }

$isSingleMode    = $plan.Mode -eq 'SingleFile'
$alwaysLogSingle = $isSingleMode -and [bool][int]$plan.PlanOptions.SingleFileDebugLog

$script:runLog      = New-EncodingLogPath -Mode $plan.Mode
$script:runLogReady = $false

# ═══════════════════════════════════════════════════════════════════════
# STATE
# ═══════════════════════════════════════════════════════════════════════

$script:startTime         = Get-Date
$script:totalOriginalSize = [long]0
$script:totalNewSize      = [long]0
$script:successCount      = 0
$script:skipCount         = 0
$script:errorCount        = 0
$script:processed         = 0
$script:hasErrors         = $false
$script:hasWarnings       = $false
$script:stopRequested     = $false
$script:resumePlanPath    = $null

# Per-format statistics for detailed report
$script:formatStats = @{}

# ═══════════════════════════════════════════════════════════════════════
# HELPER FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════

# Clean up stale stderr files from previous sessions
$tempDir = Get-TempDir
$currentPid = $PID
Get-ChildItem -LiteralPath $tempDir -Filter 'stderr_*_slot_*.log' -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notmatch "stderr_${currentPid}_" } |
    ForEach-Object {
        $null = Remove-ItemSafe -Path $_.FullName
    }

function Get-ShortReason {
    param(
        [string]$Stderr,
        [int]$ExitCode
    )

    if (-not $Stderr) {
        return "Unknown error (exit code: $ExitCode)"
    }

    $lines = $Stderr.Trim() -split "`n" | ForEach-Object { $_.Trim() }

    $meaningful = $lines | Where-Object {
        $_ -match '(Invalid data|Error|Cannot|Nothing was written|Memory|allocate|corrupt|unsupported|failed|timeout|not found)'
    } | Select-Object -Last 1

    if (-not $meaningful) {
        $meaningful = $lines | Where-Object { $_ } | Select-Object -Last 1
    }

    if (-not $meaningful) {
        return "Unknown error (exit code: $ExitCode)"
    }

    return ($meaningful -replace '^\[.+?\]\s*', '')
}

function Ensure-RunLog {
    if (-not $script:runLogReady) {
        Write-EncodingLogHeader -LogFile $script:runLog -Source $plan.SourceRoot -Mode $plan.Mode
        $script:runLogReady = $true
    }
}

function Test-TaskReady {
    <#
    .SYNOPSIS
    Validates that a task's source file is still valid for processing.
    Returns $true if ready, $false if should be skipped.
    #>
    param([PSCustomObject]$Task)

    if (-not [System.IO.File]::Exists($Task.SourcePath)) {
        $script:skipCount++
        $script:processed++
        Ensure-RunLog
        Write-WarningTaskEntry -LogFile $script:runLog -Task $Task `
            -Reason 'Source file no longer exists.' `
            -IsSingleFile $isSingleMode
        $script:hasWarnings = $true
        return $false
    }

    try {
        $currentInfo = Get-Item -LiteralPath $Task.SourcePath -ErrorAction Stop
        if ($currentInfo.LastWriteTimeUtc -ne $Task.LastWriteTimeUtc) {
            $script:skipCount++
            $script:processed++
            Ensure-RunLog
            Write-WarningTaskEntry -LogFile $script:runLog -Task $Task `
                -Reason 'File was modified after plan was built.' `
                -IsSingleFile $isSingleMode
            $script:hasWarnings = $true
            return $false
        }
    }
    catch {
        $script:skipCount++
        $script:processed++
        Ensure-RunLog
        Write-WarningTaskEntry -LogFile $script:runLog -Task $Task `
            -Reason "Cannot read source file: $($_.Exception.Message)" `
            -IsSingleFile $isSingleMode
        $script:hasWarnings = $true
        return $false
    }

    return $true
}

# ═══════════════════════════════════════════════════════════════════════
# RESULT REGISTRATION
# ═══════════════════════════════════════════════════════════════════════

function Update-FormatStats {
    <#
    .SYNOPSIS
    Updates per-format statistics for detailed report.
    #>
    param(
        [string]$Extension,
        [string]$Outcome,      # 'Success', 'Skip', 'Error'
        [long]$OriginalSize = 0,
        [long]$NewSize = 0
    )

    $key = $Extension.ToLowerInvariant()
    if (-not $script:formatStats.ContainsKey($key)) {
        $script:formatStats[$key] = @{
            Success  = 0; Skip = 0; Error = 0
            OriginalBytes = [long]0; NewBytes = [long]0
        }
    }

    $stats = $script:formatStats[$key]
    $stats[$Outcome]++
    $stats.OriginalBytes += $OriginalSize
    $stats.NewBytes      += $NewSize
}

function Register-Success {
    param(
        [PSCustomObject]$Task,
        [string]$OutputPath,
        [PSCustomObject]$ExecResult
    )

    # Check output exists and get size
    try {
        $newSize = (Get-Item -LiteralPath $OutputPath -ErrorAction Stop).Length
    }
    catch {
        $ExecResult.Stderr = "Failed to read output file size: $($_.Exception.Message)`r`n" + $ExecResult.Stderr
        Register-Failure -Task $Task -ExecResult $ExecResult
        return
    }

    # Skip if not smaller
    if ($newSize -ge $Task.SizeBytes) {
        $null = Remove-ItemSafe -Path $OutputPath
        $script:skipCount++

        $beforeKB = [math]::Round($Task.SizeBytes / 1KB, 1)
        $afterKB  = [math]::Round($newSize / 1KB, 1)

        Ensure-RunLog
        Write-SkipEntry -LogFile $script:runLog -Task $Task `
            -PipeCommand $ExecResult.PipeCommand `
            -Reason "Output ($afterKB KB) is not smaller than source ($beforeKB KB)" `
            -PlanMessage $Task.PlanMessage `
            -IsSingleFile $isSingleMode
        $script:hasWarnings = $true

        $ext = [System.IO.Path]::GetExtension($Task.SourcePath)
        Update-FormatStats -Extension $ext -Outcome 'Skip'
        return
    }

    # Success confirmed
    $script:successCount++
    $script:totalOriginalSize += $Task.SizeBytes
    $script:totalNewSize      += $newSize

    $ext = [System.IO.Path]::GetExtension($Task.SourcePath)
    Update-FormatStats -Extension $ext -Outcome 'Success' `
        -OriginalSize $Task.SizeBytes -NewSize $newSize

    # Delete original after confirmed success
    if ($plan.PlanOptions.DeleteOriginals) {
        Remove-ToRecycleBin -Path $Task.SourcePath
    }

    # Log if fallback or debug single
    if ($ExecResult.UsedFallback -or $alwaysLogSingle) {
        Ensure-RunLog
        Write-SuccessEntry -LogFile $script:runLog -Task $Task `
            -PipeCommand $ExecResult.PipeCommand `
            -FallbackStep1 $ExecResult.FallbackStep1 `
            -FallbackStep2 $ExecResult.FallbackStep2 `
            -PlanMessage $Task.PlanMessage `
            -IsSingleFile $isSingleMode
    }
}

function Register-Failure {
    param(
        [PSCustomObject]$Task,
        [PSCustomObject]$ExecResult
    )

    $script:errorCount++
    $script:hasErrors = $true

    $reason = if ($ExecResult.TimedOut) { 'Timeout' }
              else { Get-ShortReason -Stderr $ExecResult.Stderr -ExitCode $ExecResult.ExitCode }

    $ext = [System.IO.Path]::GetExtension($Task.SourcePath)
    Update-FormatStats -Extension $ext -Outcome 'Error'

    Ensure-RunLog
    Write-FailedEntry -LogFile $script:runLog -Task $Task `
        -PipeCommand $ExecResult.PipeCommand `
        -ExecMode $ExecResult.ExecutionMode `
        -FallbackStep1 $ExecResult.FallbackStep1 `
        -FallbackStep2 $ExecResult.FallbackStep2 `
        -Reason $reason `
        -ExitCode $ExecResult.ExitCode `
        -PlanMessage $Task.PlanMessage `
        -Stderr $ExecResult.Stderr `
        -IsSingleFile $isSingleMode
}

# ═══════════════════════════════════════════════════════════════════════
# TASK QUEUE OPERATIONS
# ═══════════════════════════════════════════════════════════════════════

function Start-NextTask {
    <#
    .SYNOPSIS
    Dequeues and starts the next valid task from the queue.
    Returns job object or $null if queue is exhausted or no slots available.
    #>
    param(
        [System.Collections.Concurrent.ConcurrentQueue[PSObject]]$Queue,
        [System.Collections.Concurrent.ConcurrentQueue[string]]$StderrSlots
    )

    while ($Queue.Count -gt 0 -and -not $script:stopRequested) {
        $task = $null
        if (-not $Queue.TryDequeue([ref]$task)) { return $null }

        if (-not (Test-TaskReady -Task $task)) { continue }

        $outFile = Get-UniqueOutputPath -SourceFile $task.SourcePath -TargetExt $task.TargetExtension

        # Get stderr slot
        $slot = $null
        if (-not $StderrSlots.TryDequeue([ref]$slot)) { return $null }

        try {
            $job = Start-EncodingJob -Task $task -OutputPath $outFile -StderrSlot $slot
            return $job
        }
        catch {
            $StderrSlots.Enqueue($slot)

            $script:errorCount++
            $script:hasErrors = $true

            Ensure-RunLog
            Write-FailedEntry -LogFile $script:runLog -Task $task `
                -PipeCommand '' -ExecMode 'JobStart' `
                -FallbackStep1 '' -FallbackStep2 '' `
                -Reason $_.Exception.Message -ExitCode -1 `
                -PlanMessage $task.PlanMessage -Stderr '' `
                -IsSingleFile $isSingleMode

            $ext = [System.IO.Path]::GetExtension($task.SourcePath)
            Update-FormatStats -Extension $ext -Outcome 'Error'
            $script:processed++
        }
    }

    return $null
}

function Complete-Job {
    <#
    .SYNOPSIS
    Finalizes a completed encoding job: collects result, registers outcome.
    #>
    param(
        [PSCustomObject]$Job,
        [System.Collections.Concurrent.ConcurrentQueue[string]]$StderrSlots
    )

    try { [void]$Job.Process.WaitForExit(3000) } catch { }

    $execResult = Finalize-EncodingJob -Job $Job -TimeoutSec $plan.PlanOptions.TimeoutSec

    if ($execResult.Success -and (Test-Path -LiteralPath $Job.OutputPath)) {
        try {
            Register-Success -Task $Job.Task -OutputPath $Job.OutputPath -ExecResult $execResult
        }
        catch {
            $execResult.Success = $false
            $execResult.Stderr = ($execResult.Stderr + "`r`nRegister-Success failed: " + $_.Exception.Message).Trim()
            Register-Failure -Task $Job.Task -ExecResult $execResult
        }
    }
    else {
        Register-Failure -Task $Job.Task -ExecResult $execResult
    }

    Remove-JobArtifacts -Job $Job

    # Return stderr slot
    $StderrSlots.Enqueue($Job.StderrLog)

    # Dispose process
    try { $Job.Process.Dispose() } catch { }

    $script:processed++
}

# ═══════════════════════════════════════════════════════════════════════
# MAIN PROCESSING LOOP (producer-consumer, single fill point)
# ═══════════════════════════════════════════════════════════════════════

function Process-TaskQueue {
    <#
    .SYNOPSIS
    Processes a queue of encoding tasks with parallel execution.
    Single fill point for running slots. Periodic progress updates.
    #>
    param(
        [Parameter(Mandatory)]
        [array]$TaskList,

        [int]$Parallel,
        [int]$TotalTasks,

        [array]$RemainingPhaseTasks = @(),

        [Parameter(Mandatory)]
        [System.Collections.Concurrent.ConcurrentQueue[string]]$StderrSlots,

        [bool]$AllowStop = $true
    )

    $queue = [System.Collections.Concurrent.ConcurrentQueue[PSObject]]::new()
    $TaskList | ForEach-Object { $queue.Enqueue($_) }

    $running = @{}
    $lastProgressUpdate = [DateTime]::MinValue
    $progressInterval   = [TimeSpan]::FromMilliseconds(500)

    # ── Initial fill ──
    while ($running.Count -lt $Parallel -and $queue.Count -gt 0) {
        $job = Start-NextTask -Queue $queue -StderrSlots $StderrSlots
        if ($null -eq $job) { break }
        $running[$job.SourcePath] = $job
    }

    while ($running.Count -gt 0) {

        # ── Timeout detection ──
        if ($plan.PlanOptions.TimeoutSec -gt 0) {
            $now = Get-Date
            $timedOutKeys = @($running.Keys | Where-Object {
                $j = $running[$_]
                (-not $j.Process.HasExited) -and
                (($now - $j.StartedAt).TotalSeconds -gt $plan.PlanOptions.TimeoutSec)
            })

            foreach ($key in $timedOutKeys) {
                $job = $running[$key]
                Stop-JobProcesses -MainProcess $job.Process

                $timeoutResult = [PSCustomObject]@{
                    Success       = $false
                    UsedFallback  = $false
                    TimedOut      = $true
                    ExitCode      = -1
                    Stderr        = "Timeout after $($plan.PlanOptions.TimeoutSec) seconds."
                    OutputPath    = $job.OutputPath
                    ExecutionMode = $job.Task.TaskType
                    FailedStage   = 'Timeout'
                    PipeCommand   = $job.CommandLine
                    FallbackStep1 = ''
                    FallbackStep2 = ''
                }

                Register-Failure -Task $job.Task -ExecResult $timeoutResult
                Remove-JobArtifacts -Job $job
                $StderrSlots.Enqueue($job.StderrLog)
                try { $job.Process.Dispose() } catch { }
                $running.Remove($key)
                $script:processed++
            }
        }

        # ── Completed jobs ──
        $completedKeys = @($running.Keys | Where-Object { $running[$_].Process.HasExited })

        foreach ($key in $completedKeys) {
            Complete-Job -Job $running[$key] -StderrSlots $StderrSlots
            $running.Remove($key)
        }

        # ── Refill slots immediately after completions ──
        if (($completedKeys.Count -gt 0 -or $timedOutKeys.Count -gt 0) -and -not $script:stopRequested) {
            while ($running.Count -lt $Parallel -and $queue.Count -gt 0) {
                $job = Start-NextTask -Queue $queue -StderrSlots $StderrSlots
                if ($null -eq $job) { break }
                $running[$job.SourcePath] = $job
            }
        }

        # ── Progress update (periodic) ──
        $now = [DateTime]::Now
        if (($now - $lastProgressUpdate) -ge $progressInterval) {
            Show-Progress -Current $script:processed -Total $TotalTasks `
                -Success $script:successCount -Errors $script:errorCount `
                -Skipped $script:skipCount -Running $running.Count `
                -BaseY $script:progressBarBaseY -StopRequested $script:stopRequested
            $lastProgressUpdate = $now
        }

        # ── Stop request (Q key, folder mode only) ──
        if ($AllowStop) {
            try {
                if ([Console]::KeyAvailable) {
                    $key = [Console]::ReadKey($true)
                    if ($key.Key -eq 'Q') {
                        $script:stopRequested = $true
                    }
                }
            }
            catch { }
        }

        # ── Idle wait (only if nothing completed this iteration) ──
        if ($completedKeys.Count -eq 0 -and
            ($null -eq $timedOutKeys -or $timedOutKeys.Count -eq 0)) {
            Start-Sleep -Milliseconds 100
        }

        # ── Break if stop requested and no running jobs ──
        if ($script:stopRequested -and $running.Count -eq 0) {
            break
        }
    }

    # ── Handle stop: save resume plan ──
    if ($script:stopRequested -and $plan.Mode -eq 'Folder') {
        $remainingTasks = [System.Collections.Generic.List[PSObject]]::new()

        while ($queue.Count -gt 0) {
            $t = $null
            if ($queue.TryDequeue([ref]$t)) {
                $remainingTasks.Add($t)
                $script:skipCount++
                $script:processed++
            }
        }

        $allRemaining = @($remainingTasks) + @($RemainingPhaseTasks)

        if ($allRemaining.Count -gt 0) {
            $resumePath = Join-Path $plan.SourceRoot 'EncodingPlan_Resume.clixml'
            $resumePlan = [PSCustomObject]@{
                PlanVersion = $plan.PlanVersion
                CreatedAt   = Get-Date
                Mode        = $plan.Mode
                SourceRoot  = $plan.SourceRoot
                PlanOptions = $plan.PlanOptions
                Summary     = $plan.Summary
                Tasks       = $allRemaining
                PlanFile    = $plan.PlanFile
            }
            $resumePlan | Export-Clixml -LiteralPath $resumePath -Force
            $script:resumePlanPath = $resumePath
        }
    }
}
# ═══════════════════════════════════════════════════════════════════════
# EXECUTION
# ═══════════════════════════════════════════════════════════════════════

# Header
Clear-Host
Show-Logo
Write-ExecutionHeader -Plan $plan -ShowStopHint (-not $isSingleMode)

# Reserve space for progress bar
for ($i = 0; $i -lt 5; $i++) { Write-Host '' }

$cursorY = $Host.UI.RawUI.CursorPosition.Y
$script:progressBarBaseY = [Math]::Max(0, $cursorY - 5)

[Console]::CursorVisible = $false

Show-Progress -Current 0 -Total $plan.Tasks.Count `
    -Success 0 -Errors 0 -Skipped 0 -Running 0 `
    -BaseY $script:progressBarBaseY

# Split phases
$phase1 = @($plan.Tasks | Where-Object { $_.Phase -eq 1 })
$phase2 = @($plan.Tasks | Where-Object { $_.Phase -eq 2 })
$phase3 = @($plan.Tasks | Where-Object { $_.Phase -eq 3 })

$allowStop = -not $isSingleMode

# ── Phase 1: AvifDirect ──
if ($phase1.Count -gt 0 -and -not $script:stopRequested) {
    Process-TaskQueue -TaskList $phase1 -Parallel $maxParallel `
        -TotalTasks $plan.Tasks.Count `
        -RemainingPhaseTasks ($phase2 + $phase3) `
        -StderrSlots $stderrAvailable `
        -AllowStop $allowStop
}

# ── Phase 2: AvifPipe ──
if ($phase2.Count -gt 0 -and -not $script:stopRequested) {
    Process-TaskQueue -TaskList $phase2 -Parallel $maxParallel `
        -TotalTasks $plan.Tasks.Count `
        -RemainingPhaseTasks $phase3 `
        -StderrSlots $stderrAvailable `
        -AllowStop $allowStop
}

# ── Phase 3: Gif2Webp ──
if ($phase3.Count -gt 0 -and -not $script:stopRequested) {
    Process-TaskQueue -TaskList $phase3 -Parallel $maxParallel `
        -TotalTasks $plan.Tasks.Count `
        -RemainingPhaseTasks @() `
        -StderrSlots $stderrAvailable `
        -AllowStop $allowStop
}

# Count skipped phases
if ($script:stopRequested) {
    $unskippedPhases = @()
    if ($phase2.Count -gt 0) { $unskippedPhases += $phase2 }
    if ($phase3.Count -gt 0) { $unskippedPhases += $phase3 }
    # Only count tasks not already processed
    foreach ($t in $unskippedPhases) {
        if ($script:processed -lt $plan.Tasks.Count) {
            $script:skipCount++
            $script:processed++
        }
    }
}

# Final progress
Show-Progress -Current $plan.Tasks.Count -Total $plan.Tasks.Count `
    -Success $script:successCount -Errors $script:errorCount `
    -Skipped $script:skipCount -Running 0 `
    -BaseY $script:progressBarBaseY -Force

# ═══════════════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════════════

$elapsedTotal = ((Get-Date) - $script:startTime).TotalSeconds

Clear-Host
Show-Logo

Write-FinalSummary `
    -SuccessCount $script:successCount `
    -SkipCount $script:skipCount `
    -ErrorCount $script:errorCount `
    -TotalOriginalSize $script:totalOriginalSize `
    -TotalNewSize $script:totalNewSize `
    -StopRequested $script:stopRequested `
    -ResumePlanPath $script:resumePlanPath `
    -ElapsedSeconds $elapsedTotal

# Detailed report
if ($script:successCount -gt 0 -or $script:errorCount -gt 0) {
    Write-DetailedReport -FormatStats $script:formatStats
}

# Log summary
if (($script:errorCount -gt 0 -or $script:hasWarnings -or $alwaysLogSingle) -and $script:runLogReady) {
    Write-LogSummary -ErrorCount $script:errorCount `
        -HasWarnings $script:hasWarnings -LogFilePath $script:runLog
}

Write-Host

# Write duration for single file
if ($isSingleMode -and $script:runLogReady) {
    Write-EncodingLogFooter -LogFile $script:runLog -DurationSec $elapsedTotal
}

# ═══════════════════════════════════════════════════════════════════════
# CLEANUP
# ═══════════════════════════════════════════════════════════════════════

# Brief delay to let child processes fully release file handles
Start-Sleep -Milliseconds 500

if ($plan.Mode -eq 'Folder') {
    Remove-TempFiles -FolderPath $plan.SourceRoot

    $resumeCheck = Join-Path $plan.SourceRoot 'EncodingPlan_Resume.clixml'
    if (-not $script:stopRequested -and (Test-Path -LiteralPath $resumeCheck)) {
        Remove-Item -LiteralPath $resumeCheck -Force -ErrorAction SilentlyContinue
    }
}

Remove-EmptyLog -LogFile $script:runLog `
    -HasErrors:$script:hasErrors `
    -HasWarnings:$script:hasWarnings `
    -AlwaysKeep:$alwaysLogSingle

Remove-StderrPool -Pool $script:stderrPool

# ═══════════════════════════════════════════════════════════════════════
# LOG OPEN PROMPT
# ═══════════════════════════════════════════════════════════════════════

$hasLogToShow = ($script:errorCount -gt 0 -or $script:hasWarnings -or $alwaysLogSingle) -and
                $script:runLogReady -and
                (Test-Path -LiteralPath $script:runLog)

if ($hasLogToShow) {
    [Console]::CursorVisible = $true
    Write-Host
    Write-BoxTitleOnly 'Press [1] to open log  |  Enter to exit'
    $logKey = Read-MenuKey -AllowedKeys @('1', 'Enter')
    if ($logKey -eq '1') {
        Start-Process -FilePath $script:runLog
    }
}
else {
    [Console]::CursorVisible = $true
    Write-Host
    Write-Host '    Press any key to exit.'
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
}