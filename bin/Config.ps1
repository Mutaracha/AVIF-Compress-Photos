# Config.ps1
# Project configuration: path resolution, settings loading, validation,
# custom overrides, runtime state, parallelism

# ═══════════════════════════════════════════════════════════════════════
# FORMAT REGISTRY (static images only)
# ═══════════════════════════════════════════════════════════════════════
# Animated formats handled separately in analysis/planning code:
#   .gif animated → Gif2Webp task
#   .webp animated → skipped (not supported)

$script:FormatRegistry = @(
    [PSCustomObject]@{ Ext = '.jpg';  DisplayName = 'JPG';  TaskType = 'AvifDirect'; AnalysisGroup = 'DotNet';  SupportsAlpha = $false }
    [PSCustomObject]@{ Ext = '.jpeg'; DisplayName = 'JPEG'; TaskType = 'AvifDirect'; AnalysisGroup = 'DotNet';  SupportsAlpha = $false }
    [PSCustomObject]@{ Ext = '.png';  DisplayName = 'PNG';  TaskType = 'AvifDirect'; AnalysisGroup = 'DotNet';  SupportsAlpha = $true  }
    [PSCustomObject]@{ Ext = '.bmp';  DisplayName = 'BMP';  TaskType = 'AvifPipe';   AnalysisGroup = 'DotNet';  SupportsAlpha = $false }
    [PSCustomObject]@{ Ext = '.tiff'; DisplayName = 'TIFF'; TaskType = 'AvifPipe';   AnalysisGroup = 'DotNet';  SupportsAlpha = $true  }
    [PSCustomObject]@{ Ext = '.tif';  DisplayName = 'TIF';  TaskType = 'AvifPipe';   AnalysisGroup = 'DotNet';  SupportsAlpha = $true  }
    [PSCustomObject]@{ Ext = '.webp'; DisplayName = 'WebP'; TaskType = 'AvifPipe';   AnalysisGroup = 'Binary';  SupportsAlpha = $true  }
    [PSCustomObject]@{ Ext = '.gif';  DisplayName = 'GIF';  TaskType = 'AvifPipe';   AnalysisGroup = 'Binary';  SupportsAlpha = $true  }
    [PSCustomObject]@{ Ext = '.jp2';  DisplayName = 'JP2';  TaskType = 'AvifPipe';   AnalysisGroup = 'Ffprobe'; SupportsAlpha = $false }
)

function Get-SupportedExtensions {
    return @($script:FormatRegistry.Ext)
}

function Get-SupportedFormatsDisplayText {
    $names = @($script:FormatRegistry | Select-Object -ExpandProperty DisplayName -Unique)
    return $names -join ', '
}

function Get-DirectAvifExtensions {
    return @($script:FormatRegistry | Where-Object { $_.TaskType -eq 'AvifDirect' } | ForEach-Object { $_.Ext })
}

function Get-PipeAvifExtensions {
    return @($script:FormatRegistry | Where-Object { $_.TaskType -eq 'AvifPipe' } | ForEach-Object { $_.Ext })
}

function Get-FormatInfo {
    param([string]$Extension)
    return $script:FormatRegistry | Where-Object { $_.Ext -eq $Extension.ToLowerInvariant() } | Select-Object -First 1
}

# ═══════════════════════════════════════════════════════════════════════
# PATH RESOLUTION
# ═══════════════════════════════════════════════════════════════════════

function Get-ProjectRoot {
    return Split-Path -Parent $PSScriptRoot
}

function Get-SettingsPath {
    return Join-Path (Get-ProjectRoot) 'Settings.psd1'
}

function Get-StatePath {
    return Join-Path (Join-Path (Get-ProjectRoot) 'installers') 'state.psd1'
}

# ═══════════════════════════════════════════════════════════════════════
# PSD1 FILE OPERATIONS (centralized read/write)
# ═══════════════════════════════════════════════════════════════════════

function Set-Psd1Value {
    <#
    .SYNOPSIS
    Updates a single key=value in a .psd1 file using regex replacement.
    Centralizes all .psd1 modifications to one function.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,

        [Parameter(Mandatory)]
        [string]$Key,

        [Parameter(Mandatory)]
        $Value
    )

    if (-not (Test-Path -LiteralPath $FilePath)) {
        Write-Warning "Config file not found: $FilePath"
        return $false
    }

    try {
        $content = Get-Content -LiteralPath $FilePath -Raw -Encoding UTF8
        $pattern = "($Key\s*=\s*)\S+"
        $replacement = "`${1}$Value"

        if ($content -notmatch $Key) {
            Write-Warning "Key '$Key' not found in $FilePath"
            return $false
        }

        $newContent = $content -replace $pattern, $replacement
        Set-Content -LiteralPath $FilePath -Value $newContent -Encoding UTF8 -NoNewline
        return $true
    }
    catch {
        Write-Warning "Failed to update $Key in ${FilePath}: $($_.Exception.Message)"
        return $false
    }
}

# ═══════════════════════════════════════════════════════════════════════
# SETTINGS LOADER
# ═══════════════════════════════════════════════════════════════════════

function Get-ProjectSettings {
    $settingsFile = Get-SettingsPath
    if (-not (Test-Path -LiteralPath $settingsFile)) {
        Write-Host '     [!] Settings.psd1 not found.' -ForegroundColor Red
        exit 1
    }
    return Import-PowerShellDataFile -LiteralPath $settingsFile
}

# ═══════════════════════════════════════════════════════════════════════
# RUNTIME STATE
# ═══════════════════════════════════════════════════════════════════════

function Get-RuntimeState {
    <#
    .SYNOPSIS
    Loads runtime state from installers/state.psd1.
    Creates default state file if missing.
    #>
    $statePath = Get-StatePath

    if (-not (Test-Path -LiteralPath $statePath)) {
        $defaultState = @(
            '@{'
            '    FFmpegChecked   = 0'
            '    AvifencChecked  = 0'
            '    Gif2WebpChecked = 0'
            '}'
        )
        $stateDir = Split-Path -Parent $statePath
        if (-not (Test-Path -LiteralPath $stateDir)) {
            New-Item -Path $stateDir -ItemType Directory -Force | Out-Null
        }
        Set-Content -LiteralPath $statePath -Value ($defaultState -join "`r`n") -Encoding UTF8
    }

    return Import-PowerShellDataFile -LiteralPath $statePath
}

function Set-StateFlag {
    <#
    .SYNOPSIS
    Updates a flag in state.psd1 (e.g., AvifencChecked = 1).
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Key,

        [Parameter(Mandatory)]
        [int]$Value
    )
    $statePath = Get-StatePath
    Set-Psd1Value -FilePath $statePath -Key $Key -Value $Value
}

# ═══════════════════════════════════════════════════════════════════════
# CUSTOM CONFIG OVERRIDE
# ═══════════════════════════════════════════════════════════════════════

function Merge-CustomOverrides {
    <#
    .SYNOPSIS
    Reads custom config temp file and applies overrides to settings hashtable.
    Deletes the temp file after reading.
    #>
    param(
        [hashtable]$Settings,
        [string]$CustomConfigPath
    )

    if (-not $CustomConfigPath -or -not (Test-Path -LiteralPath $CustomConfigPath)) {
        return
    }

    $overrides = @{}
    Get-Content -LiteralPath $CustomConfigPath -Encoding UTF8 | ForEach-Object {
        if ($_ -match '^(\w+)=(.*)$') {
            $overrides[$Matches[1]] = $Matches[2]
        }
    }

    Remove-Item -LiteralPath $CustomConfigPath -Force -ErrorAction SilentlyContinue

    if ($overrides.ContainsKey('PIXFMT'))    { $Settings.FFmpeg.StaticPixFmt             = $overrides['PIXFMT'] }
    if ($overrides.ContainsKey('AVIF_Q'))    { $Settings.Avifenc.Opaque.Q                = [int]$overrides['AVIF_Q'] }
    if ($overrides.ContainsKey('AVIF_S'))    { $Settings.Avifenc.Opaque.S                = [int]$overrides['AVIF_S'] }
    if ($overrides.ContainsKey('SHARPNESS')) { $Settings.Avifenc.Opaque.Sharpness        = [int]$overrides['SHARPNESS'] }
    if ($overrides.ContainsKey('QALPHA'))    { $Settings.Avifenc.AlphaPng.QAlpha         = [int]$overrides['QALPHA'] }
    if ($overrides.ContainsKey('WEBP_Q'))    { $Settings.WebP.Qv                         = [int]$overrides['WEBP_Q'] }
    if ($overrides.ContainsKey('WEBP_CL'))   { $Settings.WebP.CompressionLevel           = [int]$overrides['WEBP_CL'] }
    if ($overrides.ContainsKey('WEBP_PIX'))  { $Settings.WebP.PixFmt                     = $overrides['WEBP_PIX'] }
}

# ═══════════════════════════════════════════════════════════════════════
# GLOBAL AVIF QUALITY OVERRIDE
# ═══════════════════════════════════════════════════════════════════════

function Merge-GlobalAvifQuality {
    <#
    .SYNOPSIS
    If General.AvifQuality is set, overrides Q in all avifenc sections.
    #>
    param([hashtable]$Settings)

    $rawQ = $Settings.General.AvifQuality
    if ($null -eq $rawQ) { return }

    $qStr = "$rawQ".Trim()
    if ($qStr -eq '') { return }

    $globalQ = [int]$rawQ
    $Settings.Avifenc.Opaque.Q   = $globalQ
    $Settings.Avifenc.AlphaPng.Q = $globalQ
    $Settings.Avifenc.AlphaGif.Q = $globalQ
}

# ═══════════════════════════════════════════════════════════════════════
# SETTINGS VALIDATION
# ═══════════════════════════════════════════════════════════════════════

function Test-ProjectSettings {
    <#
    .SYNOPSIS
    Validates all settings values. Returns list of errors.
    Empty list = all valid.
    #>
    param([hashtable]$Settings)

    $errors = [System.Collections.Generic.List[string]]::new()

    # ── General ──
    $g = $Settings.General
    if ($null -eq $g) {
        $errors.Add('Missing section: General')
        return $errors
    }

    # AvifQuality: null or 0-100
    if ($null -ne $g.AvifQuality -and "$($g.AvifQuality)".Trim() -ne '') {
        try {
            $q = [int]$g.AvifQuality
            if ($q -lt 0 -or $q -gt 100) { $errors.Add("General.AvifQuality must be 0-100 (got: $q)") }
        }
        catch { $errors.Add("General.AvifQuality is not a valid number: $($g.AvifQuality)") }
    }

    # DeleteOriginals: 0 or 1
    if ($g.DeleteOriginals -notin @(0, 1, '0', '1')) {
        $errors.Add("General.DeleteOriginals must be 0 or 1 (got: $($g.DeleteOriginals))")
    }

    # AnalysisThreads: 0+ integer
    try {
        $at = [int]$g.AnalysisThreads
        if ($at -lt 0) { $errors.Add("General.AnalysisThreads must be >= 0 (got: $at)") }
    }
    catch { $errors.Add("General.AnalysisThreads is not a valid number") }

    # DebugMode: 0 or 1
    if ($g.DebugMode -notin @(0, 1, '0', '1')) {
        $errors.Add("General.DebugMode must be 0 or 1 (got: $($g.DebugMode))")
    }

    # TimeoutSec: >= 0
    try {
        $ts = [int]$g.TimeoutSec
        if ($ts -lt 0) { $errors.Add("General.TimeoutSec must be >= 0 (got: $ts)") }
    }
    catch { $errors.Add("General.TimeoutSec is not a valid number") }

    # MinProcessSizeKB: >= 0
    try {
        $ms = [int]$g.MinProcessSizeKB
        if ($ms -lt 0) { $errors.Add("General.MinProcessSizeKB must be >= 0 (got: $ms)") }
    }
    catch { $errors.Add("General.MinProcessSizeKB is not a valid number") }

    # ── FFmpeg ──
    $ff = $Settings.FFmpeg
    if ($null -eq $ff) {
        $errors.Add('Missing section: FFmpeg')
    }
    elseif ($ff.StaticPixFmt -notin @('yuv420p', 'yuv444p')) {
        $errors.Add("FFmpeg.StaticPixFmt must be yuv420p or yuv444p (got: $($ff.StaticPixFmt))")
    }

    # ── Avifenc ──
    $av = $Settings.Avifenc
    if ($null -eq $av) {
        $errors.Add('Missing section: Avifenc')
    }
    else {
        # Opaque
        $op = $av.Opaque
        if ($op) {
            try { $v = [int]$op.Q;         if ($v -lt 0 -or $v -gt 100) { $errors.Add("Avifenc.Opaque.Q must be 0-100") } } catch { $errors.Add("Avifenc.Opaque.Q invalid") }
            try { $v = [int]$op.S;         if ($v -lt 0 -or $v -gt 10)  { $errors.Add("Avifenc.Opaque.S must be 0-10") } }  catch { $errors.Add("Avifenc.Opaque.S invalid") }
            try { $v = [int]$op.Sharpness; if ($v -lt 0 -or $v -gt 7)   { $errors.Add("Avifenc.Opaque.Sharpness must be 0-7") } } catch { $errors.Add("Avifenc.Opaque.Sharpness invalid") }
        }
        else { $errors.Add('Missing section: Avifenc.Opaque') }

        # AlphaPng
        $ap = $av.AlphaPng
        if ($ap) {
            try { $v = [int]$ap.Q;      if ($v -lt 0 -or $v -gt 100) { $errors.Add("Avifenc.AlphaPng.Q must be 0-100") } }      catch { $errors.Add("Avifenc.AlphaPng.Q invalid") }
            try { $v = [int]$ap.QAlpha; if ($v -lt 0 -or $v -gt 100) { $errors.Add("Avifenc.AlphaPng.QAlpha must be 0-100") } } catch { $errors.Add("Avifenc.AlphaPng.QAlpha invalid") }
        }
        else { $errors.Add('Missing section: Avifenc.AlphaPng') }

        # AlphaGif
        $ag = $av.AlphaGif
        if ($ag) {
            try { $v = [int]$ag.Q;      if ($v -lt 0 -or $v -gt 100) { $errors.Add("Avifenc.AlphaGif.Q must be 0-100") } }      catch { $errors.Add("Avifenc.AlphaGif.Q invalid") }
            try { $v = [int]$ag.QAlpha; if ($v -lt 0 -or $v -gt 100) { $errors.Add("Avifenc.AlphaGif.QAlpha must be 0-100") } } catch { $errors.Add("Avifenc.AlphaGif.QAlpha invalid") }
        }
        else { $errors.Add('Missing section: Avifenc.AlphaGif') }
    }

    # ── WebP ──
    $wp = $Settings.WebP
    if ($null -eq $wp) {
        $errors.Add('Missing section: WebP')
    }
    else {
        try { $v = [int]$wp.Qv;               if ($v -lt 0 -or $v -gt 100) { $errors.Add("WebP.Qv must be 0-100") } }     catch { $errors.Add("WebP.Qv invalid") }
        try { $v = [int]$wp.CompressionLevel; if ($v -lt 1 -or $v -gt 6)   { $errors.Add("WebP.CompressionLevel must be 1-6") } } catch { $errors.Add("WebP.CompressionLevel invalid") }
    }

    return $errors
}

# ═══════════════════════════════════════════════════════════════════════
# DEPENDENCY CHECKS (unified model)
# ═══════════════════════════════════════════════════════════════════════

function Test-ToolInstalled {
    <#
    .SYNOPSIS
    Checks if a tool is available. Uses state flag for fast path.
    If missing, runs installer script. Updates state flag.
    Returns $true if tool is available after check.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Command,

        [Parameter(Mandatory)]
        [string]$DisplayName,

        [Parameter(Mandatory)]
        [string]$StateKey,

        [Parameter(Mandatory)]
        [string]$InstallerScript
    )

    $state = Get-RuntimeState

    # Fast path: flag is set, verify tool exists
<#     if ([int]$state.$StateKey -eq 1) {
        if (Get-Command $Command -ErrorAction SilentlyContinue) {
            return $true
        }
        # Tool disappeared — reset flag
        Set-StateFlag -Key $StateKey -Value 0
    } #>
	$isFlagged = ([int]$state.$StateKey -eq 1)

    # 1. Проверяем, существует ли команда прямо сейчас
    $isInstalled = [bool](Get-Command $Command -ErrorAction SilentlyContinue)

    if ($isInstalled) {
        # Команда есть. Если флаг был 0, обновляем его на 1
        if (-not $isFlagged) {
            Set-StateFlag -Key $StateKey -Value 1
        }
        return $true
    }

    # 2. Команды нет. Если флаг был 1, сбрасываем его
    if ($isFlagged) {
        Set-StateFlag -Key $StateKey -Value 0
    }

    # Tool not available — check if installer exists
    if (-not (Test-Path -LiteralPath $InstallerScript)) {
        Reset-Screen
        Write-Host "     [!] $DisplayName not found and installer missing." -ForegroundColor Red
        Write-Host "     Expected: $InstallerScript" -ForegroundColor Red
        return $false
    }

    # Show setup prompt
    Reset-Screen
    Write-BoxMenu -Title "[!] $DisplayName needs setup" -Lines @(
        "$DisplayName is required but not installed."
        ''
        '[Enter]  Install automatically'
        '[1]      Exit'
    )

    $choice = Read-Choice -Prompt 'Your choice [Enter]: ' -Default ''
    if ($choice -eq '1') {
        return $false
    }

	# Run installer
	Reset-Screen
	Write-BoxTitleOnly "Installing $DisplayName..."
	Write-Host

	try {
		& $InstallerScript
	}
	catch {
		Write-Host
		Write-Host "    [!] $DisplayName installation failed." -ForegroundColor Yellow
		Write-Host "    $($_.Exception.Message)" -ForegroundColor DarkYellow
		return $false
	}

    # Verify after install
    if (Get-Command $Command -ErrorAction SilentlyContinue) {
        Set-StateFlag -Key $StateKey -Value 1
        return $true
    }

    # Installed but not in PATH yet — needs restart
    Set-StateFlag -Key $StateKey -Value 1
    Reset-Screen
    Write-BoxMenu -Title "$DisplayName installed successfully!" -Lines @(
        '[!] PATH was updated. Please restart this script'
        '    for changes to take effect.'
    )
    Write-Host '    Press any key to exit. Then run the script again.'
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    exit 0
}

function Test-RequiredTools {
    <#
    .SYNOPSIS
    Verifies that ffmpeg, ffprobe, avifenc, gif2webp are available.
    Resets state flags for any missing tools.
    Called from Build/Compress scripts as a safety check.
    #>
    $missing = @()
    $statePath = Get-StatePath

    if (-not (Get-Command 'ffmpeg' -ErrorAction SilentlyContinue)) {
        $missing += 'ffmpeg'
        Set-Psd1Value -FilePath $statePath -Key 'FFmpegChecked' -Value 0
    }

    if (-not (Get-Command 'ffprobe' -ErrorAction SilentlyContinue)) {
        $missing += 'ffprobe'
        Set-Psd1Value -FilePath $statePath -Key 'FFmpegChecked' -Value 0
    }

    if (-not (Get-Command 'avifenc' -ErrorAction SilentlyContinue)) {
        $missing += 'avifenc'
        Set-Psd1Value -FilePath $statePath -Key 'AvifencChecked' -Value 0
    }

    if (-not (Get-Command 'gif2webp' -ErrorAction SilentlyContinue)) {
        $missing += 'gif2webp'
        Set-Psd1Value -FilePath $statePath -Key 'Gif2WebpChecked' -Value 0
    }

    if ($missing.Count -gt 0) {
        foreach ($tool in $missing) {
            Write-Host "     [!] $tool not found in PATH." -ForegroundColor Red
        }
        exit 1
    }
}

# ═══════════════════════════════════════════════════════════════════════
# CPU / PARALLELISM
# ═══════════════════════════════════════════════════════════════════════

function Get-ParallelismSettings {
    <#
    .SYNOPSIS
    Returns CPU-based parallelism values.
    Validates AnalysisThreads, resets to auto if invalid.
    #>
    param([hashtable]$Settings)

    $cpuThreads = (Get-CimInstance Win32_Processor |
        Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum

    # Read and validate AnalysisThreads
    $analysisThreads = 0
    try { $analysisThreads = [int]$Settings.General.AnalysisThreads }
    catch { $analysisThreads = -1 }

    if ($analysisThreads -lt 0 -or $analysisThreads -gt $cpuThreads) {
        $analysisThreads = 0
        $Settings.General.AnalysisThreads = 0
        Set-Psd1Value -FilePath (Get-SettingsPath) -Key 'AnalysisThreads' -Value 0
    }

    if ($analysisThreads -eq 0) {
        $analysisThreads = [Math]::Max(2, [Math]::Min($cpuThreads, 16))
    }

    # Encoding parallelism: CPU-based baseline
    $cpuBasedParallel = [Math]::Max(1, [Math]::Floor($cpuThreads / 4))

    # Memory check: each avifenc task can use up to 2.5 GB
    $memPerTaskGB = 2.5
    $availableMemGB = 0
    try {
        $os = Get-CimInstance Win32_OperatingSystem
        # FreePhysicalMemory is in KB
        $availableMemGB = [math]::Round($os.FreePhysicalMemory / 1KB / 1KB, 1)
    }
    catch {
        $availableMemGB = 8
    }

    # Reserve 2 GB for system, rest for tasks
    $usableMemGB = [Math]::Max(0, $availableMemGB - 2)
    $memBasedParallel = [Math]::Max(1, [Math]::Floor($usableMemGB / $memPerTaskGB))

    $encodingParallel = [Math]::Min($cpuBasedParallel, $memBasedParallel)

    return [PSCustomObject]@{
        CpuThreads         = $cpuThreads
        AvailableMemGB     = $availableMemGB
        AvifencJobsPerTask = 4
        AnalysisThrottle   = $analysisThreads
        EncodingParallel   = $encodingParallel
    }
}