# AnalyzeFiles.ps1
# Stage 1: File collection, pre-filtering, multi-stage analysis
# Outputs analysis results to temp file for BuildEncodingPlan.ps1
#Requires -Version 7.0

param(
    [string]$TargetFolder = '',
    [string]$SingleFile   = '',
    [switch]$DeleteOriginal,
    [string]$CustomConfig = ''
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
. "$PSScriptRoot\ImageProbe.ps1"

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
# SETTINGS
# ═══════════════════════════════════════════════════════════════════════

$settings = Get-ProjectSettings
Merge-GlobalAvifQuality -Settings $settings

if ($PSBoundParameters.ContainsKey('DeleteOriginal')) {
    $settings.General.DeleteOriginals = if ($DeleteOriginal) { 1 } else { 0 }
}

Merge-CustomOverrides -Settings $settings -CustomConfigPath $CustomConfig

# ═══════════════════════════════════════════════════════════════════════
# DEPENDENCY CHECK
# ═══════════════════════════════════════════════════════════════════════

Test-RequiredTools

# ═══════════════════════════════════════════════════════════════════════
# DETERMINE MODE
# ═══════════════════════════════════════════════════════════════════════

$mode       = ''
$sourceRoot = ''

if ($SingleFile -and $SingleFile.Trim() -ne '') {
    if (-not (Test-Path -LiteralPath $SingleFile -PathType Leaf)) {
        Write-Host "     [!] File not found: $SingleFile" -ForegroundColor Red
        exit 1
    }
    $mode       = 'SingleFile'
    $sourceRoot = $SingleFile
}
elseif ($TargetFolder -and $TargetFolder.Trim() -ne '') {
    if (-not (Test-Path -LiteralPath $TargetFolder -PathType Container)) {
        Write-Host "     [!] Folder not found: $TargetFolder" -ForegroundColor Red
        exit 1
    }
    $mode       = 'Folder'
    $sourceRoot = $TargetFolder
}
else {
    Write-Host '     [!] Specify -TargetFolder or -SingleFile.' -ForegroundColor Red
    exit 1
}

# ═══════════════════════════════════════════════════════════════════════
# COLLECT FILES
# ═══════════════════════════════════════════════════════════════════════

$allSupportedExt = Get-SupportedExtensions

if ($mode -eq 'SingleFile') {
    $allFiles = @(Get-Item -LiteralPath $SingleFile)
}
else {
    $allFiles = @(
        Get-ChildItem -LiteralPath $TargetFolder -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.DirectoryName -notmatch '[\\/]_corrupt([\\/]|$)' }
    )
}

if ($null -eq $allFiles -or $allFiles.Count -eq 0) {
    Write-Host '     [!] Nothing found.' -ForegroundColor Yellow
    exit 0
}

$supportedFiles = @($allFiles | Where-Object {
    $allSupportedExt -contains $_.Extension.ToLowerInvariant()
})

# ═══════════════════════════════════════════════════════════════════════
# EXTENSION TABLE (folder mode)
# ═══════════════════════════════════════════════════════════════════════

if ($mode -eq 'Folder') {
    $grouped = $allFiles |
        Group-Object { if ($_.Extension) { $_.Extension.ToLowerInvariant() } else { '<none>' } } |
        Sort-Object Count -Descending

    $compressExts = $grouped | Where-Object { $allSupportedExt -contains $_.Name }
    $avifExts     = $grouped | Where-Object { $_.Name -eq '.avif' }
    $skipExts     = $grouped | Where-Object {
        $_.Name -ne '.avif' -and $allSupportedExt -notcontains $_.Name
    }

    Write-ExtensionTable -CompressGroups $compressExts -AvifGroups $avifExts -SkipGroups $skipExts
}

if ($supportedFiles.Count -eq 0) {
    Write-Host '     [!] No supported files found.' -ForegroundColor Yellow
    exit 0
}

# ═══════════════════════════════════════════════════════════════════════
# PRE-FILTER
# ═══════════════════════════════════════════════════════════════════════

$skipReasons = [ordered]@{
    TooSmall            = 0
    OutputExists        = 0
    AnimatedWebP        = 0
    Corrupt             = 0
    UnsupportedMetadata = 0
    Unreadable          = 0
    ZeroBytes           = 0
}

$minSize = $settings.General.MinProcessSizeKB * 1KB

# Base-name map for rerun protection (folder mode only)
$baseNameMap = @{}
if ($mode -eq 'Folder') {
    foreach ($f in $supportedFiles) {
        $key = '{0}|{1}' -f $f.DirectoryName.ToLowerInvariant(),
            [System.IO.Path]::GetFileNameWithoutExtension($f.Name).ToLowerInvariant()
        if (-not $baseNameMap.ContainsKey($key)) { $baseNameMap[$key] = 0 }
        $baseNameMap[$key]++
    }
}

$candidates = [System.Collections.Generic.List[PSObject]]::new()

foreach ($file in $supportedFiles) {
    # Zero bytes
    if ($file.Length -eq 0) {
        $skipReasons['ZeroBytes']++
        continue
    }

    # Too small
    if ($file.Length -lt $minSize) {
        $skipReasons['TooSmall']++
        continue
    }

    # Output exists check (folder mode only)
    if ($mode -ne 'SingleFile') {
        $ext = $file.Extension.ToLowerInvariant()
        $targetExt = if ($ext -eq '.gif') { 'webp' } else { 'avif' }
        $defaultOut = [System.IO.Path]::ChangeExtension($file.FullName, ".$targetExt")

        $groupKey = '{0}|{1}' -f $file.DirectoryName.ToLowerInvariant(),
            [System.IO.Path]::GetFileNameWithoutExtension($file.Name).ToLowerInvariant()
        $sameBaseCount = if ($baseNameMap.ContainsKey($groupKey)) { $baseNameMap[$groupKey] } else { 1 }

        if ([System.IO.File]::Exists($defaultOut) -and $sameBaseCount -le 1) {
            $skipReasons['OutputExists']++
            continue
        }
    }

    $candidates.Add($file)
}

if ($candidates.Count -eq 0) {
    Write-Host '     [!] No files to process after filtering.' -ForegroundColor Yellow
    exit 0
}

# ═══════════════════════════════════════════════════════════════════════
# SPLIT INTO ANALYSIS GROUPS
# ═══════════════════════════════════════════════════════════════════════

$directExts = Get-DirectAvifExtensions
$pipeExts   = Get-PipeAvifExtensions

# Group A: .NET decoder (jpg, jpeg, png, bmp, tiff)
$groupDotNet = [System.Collections.Generic.List[PSObject]]::new()

# Group B: Binary parsers (gif, webp)
$groupBinary = [System.Collections.Generic.List[PSObject]]::new()

# Group C: Ffprobe (jp2 and other)
$groupFfprobe  = [System.Collections.Generic.List[PSObject]]::new()

foreach ($file in $candidates) {
	$ext = $file.Extension.ToLowerInvariant()
    $formatInfo = Get-FormatInfo -Extension $ext
	if ($formatInfo -and $formatInfo.AnalysisGroup -eq 'Binary') {
		$groupBinary.Add($file)
	}
	elseif ($formatInfo -and $formatInfo.AnalysisGroup -eq 'Ffprobe') {
		$groupFfprobe.Add($file)
	}
	else {
		$groupDotNet.Add($file)
	}
}

# ═══════════════════════════════════════════════════════════════════════
# ANALYSIS
# ═══════════════════════════════════════════════════════════════════════

$parallel = Get-ParallelismSettings -Settings $settings

# Show analysis status
Write-AnalysisBox -FileCount $candidates.Count -Threads $parallel.AnalysisThrottle

$analysisResults = [System.Collections.Concurrent.ConcurrentDictionary[string, hashtable]]::new()

# ── Stage 1: .NET analysis ──
$ffprobeFallback = @()

if ($groupDotNet.Count -gt 0) {
    $dotNetResult = Invoke-DotNetAnalysis -Files $groupDotNet -ThrottleLimit $parallel.AnalysisThrottle

    foreach ($kvp in $dotNetResult.Results.GetEnumerator()) {
        $analysisResults[$kvp.Key] = $kvp.Value
    }

    $ffprobeFallback = @($dotNetResult.Fallback)
}

# ── Stage 2: Binary parsers (GIF + WebP) ──
$suspicious = @()

if ($groupBinary.Count -gt 0) {
    $binResult = Invoke-BinaryParserAnalysis -Files $groupBinary -ThrottleLimit $parallel.AnalysisThrottle

    foreach ($kvp in $binResult.Results.GetEnumerator()) {
        $analysisResults[$kvp.Key] = $kvp.Value
    }

    $suspicious = @($binResult.Suspicious)
}

# ── Stage 3: ffprobe fallback ──
$ffprobeFallback = @($ffprobeFallback) + @($groupFfprobe)

if ($ffprobeFallback.Count -gt 0) {
    $probeResult = Invoke-FfprobeFallback -Files $ffprobeFallback -ThrottleLimit $parallel.AnalysisThrottle

    foreach ($kvp in $probeResult.Results.GetEnumerator()) {
        $analysisResults[$kvp.Key] = $kvp.Value
    }

    $suspicious = @($suspicious) + @($probeResult.Suspicious)
}

# ── Stage 4: Decode test (suspicious files) ──
if ($suspicious.Count -gt 0) {
    $logDir     = Get-LogDir
    $corruptLog = Join-Path $logDir 'corrupt.log'
    $warnLog    = Join-Path $logDir 'warnings.log'

    $decodeResult = Test-CanDecode -Files $suspicious `
        -ThrottleLimit ([Math]::Min(4, $parallel.AnalysisThrottle))

    # Decodable but unparseable → skip with warning
    foreach ($filePath in $decodeResult.Decodable) {
        $skipReasons['UnsupportedMetadata']++
        Write-WarningLine -LogFile $warnLog -FilePath $filePath -Reason 'UnsupportedMetadata'
    }

    # Corrupt → move to _corrupt
    foreach ($file in $decodeResult.Corrupt) {
        $dest = Move-ToCorruptFolder -File $file
        $skipReasons['Corrupt']++
        if ($dest) {
            Write-CorruptLine -LogFile $corruptLog -DestPath $dest -Reason 'DecodeTestFailed'
        }
    }
}

# ═══════════════════════════════════════════════════════════════════════
# POST-ANALYSIS FILTERING
# ═══════════════════════════════════════════════════════════════════════

# Filter out animated WebP and unreadable files from candidates
$filteredCandidates = [System.Collections.Generic.List[PSObject]]::new()

foreach ($file in $candidates) {
    if (-not $analysisResults.ContainsKey($file.FullName)) {
        # Was handled in decode test (corrupt/unsupported)
        continue
    }

    $meta = $analysisResults[$file.FullName]
    $ext  = $file.Extension.ToLowerInvariant()

    # Animated WebP → skip
    if ($ext -eq '.webp' -and $meta.ContainsKey('IsAnimated') -and $meta.IsAnimated) {
        $skipReasons['AnimatedWebP']++
        continue
    }

    # Zero dimensions → unreadable
    if ($meta.Width -eq 0 -or $meta.Height -eq 0) {
        $skipReasons['Unreadable']++
        continue
    }

    $filteredCandidates.Add($file)
}

# ═══════════════════════════════════════════════════════════════════════
# BUILD OUTPUT
# ═══════════════════════════════════════════════════════════════════════

# Convert ConcurrentDictionary to regular hashtable for serialization
$resultsForExport = @{}
foreach ($kvp in $analysisResults.GetEnumerator()) {
    $resultsForExport[$kvp.Key] = $kvp.Value
}

$skippedCount = 0
foreach ($v in $skipReasons.Values) { $skippedCount += $v }

$analysisOutput = [PSCustomObject]@{
    Mode              = $mode
    SourceRoot        = $sourceRoot
    AllFilesCount     = $allFiles.Count
    SupportedCount    = $supportedFiles.Count
    CandidateCount    = $filteredCandidates.Count
    SkippedCount      = $skippedCount
    SkipReasons       = $skipReasons
    Candidates        = @($filteredCandidates)
    AnalysisResults   = $resultsForExport
    Settings          = $settings
    DeleteOriginals   = [bool]$settings.General.DeleteOriginals
    AnalysisThreads   = $parallel.AnalysisThrottle
}

# Write to temp
$tempPath = Join-Path ([System.IO.Path]::GetTempPath()) 'compress_analysis.clixml'
$analysisOutput | Export-Clixml -LiteralPath $tempPath -Force

# ═══════════════════════════════════════════════════════════════════════
# STATUS UPDATE
# ═══════════════════════════════════════════════════════════════════════

<# Reset-Screen #>
Write-AnalysisComplete -FileCount $filteredCandidates.Count

if ($filteredCandidates.Count -eq 0) {
    Write-Host
    Write-Host '     [!] No files to process after analysis.' -ForegroundColor Yellow
    exit 0
}

exit 0