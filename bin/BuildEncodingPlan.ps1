# BuildEncodingPlan.ps1
# Stage 2: Build typed encoding tasks from analysis results
# Reads compress_analysis.clixml, outputs compress_plan.clixml
#Requires -Version 7.0

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
. "$PSScriptRoot\ImageProbe.ps1"
. "$PSScriptRoot\FileOps.ps1"

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
    exit 99
}

$ErrorActionPreference = 'Stop'

# ═══════════════════════════════════════════════════════════════════════
# LOAD ANALYSIS RESULTS
# ═══════════════════════════════════════════════════════════════════════

$analysisTempPath = Join-Path ([System.IO.Path]::GetTempPath()) 'compress_analysis.clixml'

if (-not (Test-Path -LiteralPath $analysisTempPath)) {
    Write-Host '     [!] Analysis results not found.' -ForegroundColor Red
    Write-Host "     Expected: $analysisTempPath" -ForegroundColor Red
    exit 0
}

$analysis = Import-Clixml -LiteralPath $analysisTempPath
Remove-Item -LiteralPath $analysisTempPath -Force -ErrorAction SilentlyContinue

# Reject analysis results from another session (stale file from an interrupted run)
if ([string]::IsNullOrEmpty($SessionId) -or [string]$analysis.SessionId -ne $SessionId) {
    Write-Host '     [!] Analysis results belong to another session. Run the analysis again.' -ForegroundColor Red
    exit 1
}

# Unpack
$mode            = $analysis.Mode
$sourceRoot      = $analysis.SourceRoot
$candidates      = $analysis.Candidates
$analysisResults = $analysis.AnalysisResults
$skipReasons     = $analysis.SkipReasons
$settings        = $analysis.Settings

if ($null -eq $candidates -or $candidates.Count -eq 0) {
    Write-Host '     [!] No candidates in analysis results.' -ForegroundColor Yellow
    exit 0
}

# ═══════════════════════════════════════════════════════════════════════
# EXTENSION SETS
# ═══════════════════════════════════════════════════════════════════════

$directExts = Get-DirectAvifExtensions    # .jpg .jpeg .png
$pipeExts   = Get-PipeAvifExtensions      # .bmp .tiff .tif .webp .gif

# ═══════════════════════════════════════════════════════════════════════
# TASK BUILDERS
# ═══════════════════════════════════════════════════════════════════════

function New-AvifDirectTask {
    <#
    .SYNOPSIS
    Builds an AvifDirect task for jpg, jpeg, png (with/without alpha).
    avifenc reads the file directly, no ffmpeg needed.
    #>
    param(
        [PSObject]$File,
        [hashtable]$Meta,
        [hashtable]$Settings,
        [switch]$BatchMode,
        [int]$AvifencJobs
    )

    $avif = $Settings.Avifenc

    if ($Meta.HasAlpha) {
        # Alpha PNG → direct avifenc with alpha args
        $opaqueS = $avif.Opaque.S
        $alphaS  = $opaqueS + $avif.AlphaPng.SpeedDelta
        $alphaS  = [Math]::Max(0, [Math]::Min(10, $alphaS))

        $encParts = @(
            "-s $alphaS"
            "-q $($avif.AlphaPng.Q)"
            "--qalpha $($avif.AlphaPng.QAlpha)"
            "-r $($avif.AlphaPng.Rate)"
        )
        if ([int]$avif.AlphaPng.AutoTiling) { $encParts += '--autotiling' }
        $encParts += @(
            "-a color:enable-chroma-deltaq=$($avif.Opaque.EnableChromaDeltaQ)"
            "-a color:aq-mode=$($avif.Opaque.AqMode)"
            "-a color:tune=$($avif.AlphaPng.Tune)"
            "-a color:sharpness=$($avif.Opaque.Sharpness)"
        )
        if ($BatchMode) { $encParts += "-j $AvifencJobs" }
        $encParts += '"{input}" "{output}"'

        $planMsg = 'PNG with alpha -> AVIF (direct avifenc)'
    }
    else {
        # Opaque → direct avifenc
        $encParts = @(
            "-s $($avif.Opaque.S)"
            "-q $($avif.Opaque.Q)"
        )
        if ([int]$avif.Opaque.AutoTiling) { $encParts += '--autotiling' }
        $encParts += @(
            "-a color:enable-chroma-deltaq=$($avif.Opaque.EnableChromaDeltaQ)"
            "-a color:aq-mode=$($avif.Opaque.AqMode)"
            "-a color:tune=$($avif.Opaque.Tune)"
            "-a color:sharpness=$($avif.Opaque.Sharpness)"
        )
        if ($BatchMode) { $encParts += "-j $AvifencJobs" }
        $encParts += '"{input}" "{output}"'

        $ext = $File.Extension.ToLowerInvariant()
        $planMsg = "$($ext.TrimStart('.').ToUpper()) -> AVIF (direct avifenc)"
    }

    return [PSCustomObject]@{
        TaskType         = 'AvifDirect'
        SourcePath       = $File.FullName
        FileName         = $File.Name
        SizeBytes        = $File.Length
        LastWriteTimeUtc = $File.LastWriteTimeUtc
        TargetExtension  = 'avif'
        Phase            = 1
        HasAlpha         = $Meta.HasAlpha
        Width            = $Meta.Width
        Height           = $Meta.Height
        EncoderArgs      = ($encParts -join ' ')
        PlanMessage      = $planMsg
    }
}

function New-AvifPipeTask {
    <#
    .SYNOPSIS
    Builds an AvifPipe task for bmp, tiff, webp, static gif.
    ffmpeg decodes and pipes to avifenc.
    #>
    param(
        [PSObject]$File,
        [hashtable]$Meta,
        [hashtable]$Settings,
        [switch]$BatchMode,
        [int]$AvifencJobs
    )

    $avif   = $Settings.Avifenc
    $ffmpeg = $Settings.FFmpeg
    $ext    = $File.Extension.ToLowerInvariant()

    # Determine if this is a static GIF or other pipe format
    $isStaticGif = ($ext -eq '.gif')

    if ($Meta.HasAlpha -or $isStaticGif) {
        # Alpha or static GIF → PNG pipe
        if ($isStaticGif) {
            $opaqueS = $avif.Opaque.S
            $gifS    = $opaqueS + $avif.AlphaGif.SpeedDelta
            $gifS    = [Math]::Max(0, [Math]::Min(10, $gifS))

            $ffmpegArgs = "-hide_banner -y -v error -i `"{input}`" -map 0:v:0 -frames:v 1 -f image2pipe -vcodec png -"

            $encParts = @(
                "--input-format png"
                "-s $gifS"
                "-q $($avif.AlphaGif.Q)"
                "--qalpha $($avif.AlphaGif.QAlpha)"
                "-y $($avif.AlphaGif.Y)"
                "-r $($avif.AlphaGif.Rate)"
            )
            if ([int]$avif.AlphaGif.AutoTiling) { $encParts += '--autotiling' }
            $encParts += @(
                "-a color:enable-chroma-deltaq=$($avif.Opaque.EnableChromaDeltaQ)"
                "-a color:aq-mode=$($avif.Opaque.AqMode)"
                "-a color:tune=$($avif.AlphaGif.Tune)"
                "-a color:sharpness=$($avif.Opaque.Sharpness)"
            )
            if ($BatchMode) { $encParts += "-j $AvifencJobs" }
            $encParts += '--stdin "{output}"'

            $planMsg    = 'Static GIF -> AVIF via PNG pipe'
            $pixelFmt   = ''
        }
        else {
            # Non-GIF with alpha → PNG pipe
            $opaqueS = $avif.Opaque.S
            $alphaS  = $opaqueS + $avif.AlphaPng.SpeedDelta
            $alphaS  = [Math]::Max(0, [Math]::Min(10, $alphaS))

            $ffmpegArgs = "-hide_banner -y -v error -i `"{input}`" -map 0:v:0 -frames:v 1 -f image2pipe -vcodec png -"

            $encParts = @(
                "--input-format png"
                "-s $alphaS"
                "-q $($avif.AlphaPng.Q)"
                "--qalpha $($avif.AlphaPng.QAlpha)"
                "-r $($avif.AlphaPng.Rate)"
            )
            if ([int]$avif.AlphaPng.AutoTiling) { $encParts += '--autotiling' }
            $encParts += @(
                "-a color:enable-chroma-deltaq=$($avif.Opaque.EnableChromaDeltaQ)"
                "-a color:aq-mode=$($avif.Opaque.AqMode)"
                "-a color:tune=$($avif.AlphaPng.Tune)"
                "-a color:sharpness=$($avif.Opaque.Sharpness)"
            )
            if ($BatchMode) { $encParts += "-j $AvifencJobs" }
            $encParts += '--stdin "{output}"'

            $planMsg  = 'Static image with alpha -> AVIF via PNG pipe'
            $pixelFmt = ''
        }
    }
    else {
        # Opaque, no alpha → Y4M pipe
        $pixelFmt   = $ffmpeg.StaticPixFmt
        $ffmpegArgs = "-hide_banner -y -v error -i `"{input}`" -map 0:v:0 -frames:v 1 -pix_fmt $pixelFmt -f yuv4mpegpipe -"

        $encParts = @(
            "-s $($avif.Opaque.S)"
            "-q $($avif.Opaque.Q)"
        )
        if ([int]$avif.Opaque.AutoTiling) { $encParts += '--autotiling' }
        $encParts += @(
            "-a color:enable-chroma-deltaq=$($avif.Opaque.EnableChromaDeltaQ)"
            "-a color:aq-mode=$($avif.Opaque.AqMode)"
            "-a color:tune=$($avif.Opaque.Tune)"
            "-a color:sharpness=$($avif.Opaque.Sharpness)"
        )
        if ($BatchMode) { $encParts += "-j $AvifencJobs" }
        $encParts += '--stdin "{output}"'

        $planMsg = "Static image -> AVIF via Y4M pipe ($pixelFmt)"
    }

    return [PSCustomObject]@{
        TaskType         = 'AvifPipe'
        SourcePath       = $File.FullName
        FileName         = $File.Name
        SizeBytes        = $File.Length
        LastWriteTimeUtc = $File.LastWriteTimeUtc
        TargetExtension  = 'avif'
        Phase            = 2
        HasAlpha         = $Meta.HasAlpha
        Width            = $Meta.Width
        Height           = $Meta.Height
        PixelFormat      = $pixelFmt
        FfmpegArgs       = $ffmpegArgs
        EncoderArgs      = ($encParts -join ' ')
        PlanMessage      = $planMsg
    }
}

function New-Gif2WebpTask {
    <#
    .SYNOPSIS
    Builds a Gif2Webp task for animated GIF.
    gif2webp handles alpha internally — no alpha detection needed.
    #>
    param(
        [PSObject]$File,
        [hashtable]$Meta,
        [hashtable]$Settings
    )

    $webp = $Settings.WebP

    $encParts = @(
        '-mixed'
        "-q $($webp.Qv)"
        "-m $($webp.CompressionLevel)"
        '-min_size'
        '-mt'
        '"{input}" -o "{output}"'
    )

    return [PSCustomObject]@{
        TaskType         = 'Gif2Webp'
        SourcePath       = $File.FullName
        FileName         = $File.Name
        SizeBytes        = $File.Length
        LastWriteTimeUtc = $File.LastWriteTimeUtc
        TargetExtension  = 'webp'
        Phase            = 3
        Width            = $Meta.Width
        Height           = $Meta.Height
        EncoderArgs      = ($encParts -join ' ')
        PlanMessage      = 'Animated GIF -> WebP (gif2webp)'
    }
}

# ═══════════════════════════════════════════════════════════════════════
# BUILD TASKS
# ═══════════════════════════════════════════════════════════════════════

$parallel = Get-ParallelismSettings -Settings $settings

$tasks            = [System.Collections.Generic.List[PSObject]]::new()
$staticCount      = 0
$animatedGifCount = 0
$alphaCount       = 0
$isBatch          = ($mode -eq 'Folder')

foreach ($file in $candidates) {
    $meta = $analysisResults[$file.FullName]
    if ($null -eq $meta) { continue }

    $ext = $file.Extension.ToLowerInvariant()

    # ── Animated GIF → Gif2Webp ──
    if ($ext -eq '.gif' -and $meta.ContainsKey('IsAnimated') -and $meta.IsAnimated) {
        $task = New-Gif2WebpTask -File $file -Meta $meta -Settings $settings
        $animatedGifCount++
        $tasks.Add($task)
        continue
    }

    # ── Direct avifenc formats (jpg, jpeg, png) ──
    if ($directExts -contains $ext) {
        $task = New-AvifDirectTask -File $file -Meta $meta -Settings $settings `
            -BatchMode:$isBatch -AvifencJobs $parallel.AvifencJobsPerTask
        $staticCount++
        if ($meta.HasAlpha) { $alphaCount++ }
        $tasks.Add($task)
        continue
    }

    # ── Pipe formats (bmp, tiff, webp, static gif) ──
    if ($pipeExts -contains $ext) {
        $task = New-AvifPipeTask -File $file -Meta $meta -Settings $settings `
            -BatchMode:$isBatch -AvifencJobs $parallel.AvifencJobsPerTask
        $staticCount++
        if ($meta.HasAlpha) { $alphaCount++ }
        $tasks.Add($task)
        continue
    }
}

# ═══════════════════════════════════════════════════════════════════════
# RESERVE OUTPUT NAMES (H-2): base.ext, base_1.ext, ... in path order
# ═══════════════════════════════════════════════════════════════════════

$reserved = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($t in @($tasks | Sort-Object { $_.SourcePath.ToLowerInvariant() })) {
    $outPath = Find-FreeOutputPath -Dir ([System.IO.Path]::GetDirectoryName($t.SourcePath)) `
        -BaseName ([System.IO.Path]::GetFileNameWithoutExtension($t.SourcePath)) `
        -TargetExt $t.TargetExtension -Reserved $reserved -SourcePath $t.SourcePath
    $t | Add-Member -NotePropertyName OutputPath -NotePropertyValue $outPath -Force
}

# ═══════════════════════════════════════════════════════════════════════
# ASSEMBLE PLAN
# ═══════════════════════════════════════════════════════════════════════

$timeoutValue = if ($mode -eq 'SingleFile') {
    [int]$settings.General.TimeoutSecSingleFile
}
else {
    [int]$settings.General.TimeoutSec
}

$planOptions = [PSCustomObject]@{
    MinProcessSizeBytes  = [int64]($settings.General.MinProcessSizeKB * 1KB)
    TimeoutSec           = $timeoutValue
    SingleFileDebugLog   = [bool][int]$settings.General.DebugLogSingleFile
    DeleteOriginals      = $analysis.DeleteOriginals
    DebugLogEncodingPlan = [bool][int]$settings.General.DebugLogEncodingPlan
}

$summaryObj = [PSCustomObject]@{
    TotalFiles       = $analysis.AllFilesCount
    SupportedFiles   = $analysis.SupportedCount
    TasksCount       = $tasks.Count
    SkippedCount     = $analysis.SkippedCount
    StaticCount      = $staticCount
    AnimatedGifCount = $animatedGifCount
    AlphaCount       = $alphaCount
}

$planTempFile = Join-Path ([System.IO.Path]::GetTempPath()) 'compress_plan.clixml'

$plan = [PSCustomObject]@{
    PlanVersion = '4.0'
    CreatedAt   = Get-Date
    Mode        = $mode
    SourceRoot  = $sourceRoot
    PlanOptions = $planOptions
    Summary     = $summaryObj
    Tasks       = @($tasks)
    PlanFile    = $planTempFile
    SessionId   = $SessionId
}

$plan | Export-Clixml -LiteralPath $planTempFile -Force

# ═══════════════════════════════════════════════════════════════════════
# DEBUG LOG (optional)
# ═══════════════════════════════════════════════════════════════════════

if ($mode -eq 'Folder' -and [int]$settings.General.DebugLogEncodingPlan -eq 1) {
    Write-DebugPlanLog -Plan $plan -Summary $summaryObj
}

# ═══════════════════════════════════════════════════════════════════════
# CONSOLE SUMMARY
# ═══════════════════════════════════════════════════════════════════════

Reset-Screen

Write-PlanSummary -Summary $summaryObj -SkipReasons $skipReasons

if ($summaryObj.TasksCount -eq 0) {
    Write-Host
    Write-Host '     [!] No tasks to process.' -ForegroundColor Red
    exit 0
}

exit 0